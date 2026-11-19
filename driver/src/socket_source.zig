// socket_source.zig — client for tobiifreed over its unix socket.
//
// Gaze: subscribe at init, samples are delivered to the onGaze callback from
// poll(). Commands: every daemon command is available as an async call that
// takes a completion callback, invoked from poll() when the reply (or an
// error) arrives. Nothing blocks except writing a large cal_apply blob.
//
// Driving it from a GTK (GLib) main loop:
//
//   var src = try SocketSource.init();
//   src.onGaze(myGaze);
//   _ = g_unix_fd_add(src.fd, G_IO_IN | G_IO_HUP | G_IO_ERR, onReadable, &src);
//   fn onReadable(_: c_int, _: c_uint, data: ?*anyopaque) callconv(.c) c_int {
//       const s: *SocketSource = @ptrCast(@alignCast(data));
//       s.poll();                                  // dispatches gaze + replies
//       return @intFromBool(s.connected);          // G_SOURCE_REMOVE on EOF
//   }
//   try src.setDisplayAreaCorners(area, onAreaSet, ctx);
//
// Replies carry the command type, and the daemon answers commands of one
// type in order, so callbacks are matched FIFO per command type. Several
// different commands may be in flight; calibration commands are serialised
// by the daemon (others get Err.busy while one runs).
//
// Blocking use (CLIs, tests): `call(cmd, payload, timeout_ms)` sends one
// command and polls until its reply arrives.
//
// Reply payloads (slices are only valid during the callback):
//   get_display_area / set_display_area / set_display_area_corners: 9×f64 LE
//     corners (decodeDisplayArea) — for sets, the area the device holds after
//     the set.
//   start_calibration / add_calibration_point / cal_apply: empty (add_point:
//     raw device reply).
//   finish_calibration: calibration blob.
//   get_calibration_stimulus: decodeStimulus.
// Errors: proto.Err codes, or a device TTP status (see daemon_protocol.zig);
// Err.disconnected when the daemon goes away with the request outstanding.

const std = @import("std");
const proto = @import("daemon_protocol");
const gs = @import("gaze_source");

const log = std.log.scoped(.socket);

pub const Reply = union(enum) {
    ok: []const u8,
    err: u32,
};

pub const ReplyFn = *const fn (ctx: ?*anyopaque, cmd: proto.Cmd, reply: Reply) void;

pub const Corners = [9]f64;

/// One point of the calibration active on the device (get_calibration_stimulus).
pub const CalPoint = struct {
    /// Target, normalised display coordinates (0..1, origin top-left).
    x: f64,
    y: f64,
    /// Per eye: status (2 = valid and used, as in Tobii stream engine) and two
    /// values that look like residuals (meaning not confirmed). NaN if absent.
    left: Eye,
    right: Eye,
    pub const Eye = struct { status: f64, a: f64, b: f64 };
};

pub const Stimulus = struct {
    points: [32]CalPoint,
    n: u32,
    raw: []const u8,
};

const MAX_INFLIGHT = 32;
const INITIAL_BUF = 16 * 1024;
const MAX_BUF = 2 * 1024 * 1024; // calibration blobs are ~400–640 KB

const Inflight = struct {
    seq: u64,
    cmd: proto.Cmd,
    cb: ?ReplyFn,
    ctx: ?*anyopaque,
};

pub const SocketSource = struct {
    fd: std.posix.fd_t,
    connected: bool,
    gaze_cb: ?gs.GazeFn,
    allocator: std.mem.Allocator,
    // Read buffer: accumulates partial messages (grows for large replies).
    buf: []u8,
    buf_len: usize,
    inflight: [MAX_INFLIGHT]?Inflight,
    next_seq: u64,

    pub fn init() !SocketSource {
        return initWithAllocator(std.heap.page_allocator);
    }

    pub fn initWithAllocator(allocator: std.mem.Allocator) !SocketSource {
        var path_buf: [512]u8 = undefined;
        const path = proto.socketPath(&path_buf) orelse {
            log.warn("no socket path (XDG_RUNTIME_DIR not set?)", .{});
            return error.NoSocketPath;
        };

        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
        errdefer std.posix.close(fd);

        var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
        @memset(&addr.path, 0);
        if (path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);

        log.info("connecting to {s}", .{path});
        std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch |err| {
            return switch (err) {
                error.ConnectionRefused, error.FileNotFound => {
                    log.info("daemon not running ({})", .{err});
                    return error.NoDaemon;
                },
                else => err,
            };
        };

        var self = try fromFd(allocator, fd);
        // Subscribe to gaze immediately.
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, 0x500, .little); // STREAM_GAZE
        self.sendRaw(.subscribe, &payload) catch {};
        log.info("connected to tobiifreed", .{});
        return self;
    }

    /// Wrap an already connected, non-blocking stream fd (tests, custom paths).
    pub fn fromFd(allocator: std.mem.Allocator, fd: std.posix.fd_t) !SocketSource {
        return .{
            .fd = fd,
            .connected = true,
            .gaze_cb = null,
            .allocator = allocator,
            .buf = try allocator.alloc(u8, INITIAL_BUF),
            .buf_len = 0,
            .inflight = [_]?Inflight{null} ** MAX_INFLIGHT,
            .next_seq = 0,
        };
    }

    pub fn gazeSource(self: *SocketSource) gs.GazeSource {
        return .{ .socket = self };
    }

    pub fn onGaze(self: *SocketSource, cb: gs.GazeFn) void {
        self.gaze_cb = cb;
    }

    // ── Commands (async) ────────────────────────────────────────────

    pub fn getDisplayArea(self: *SocketSource, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        try self.request(.get_display_area, &.{}, cb, ctx);
    }

    /// Corners TL, TR, BL (mm, tracker frame). Reply: area actually set.
    pub fn setDisplayAreaCorners(self: *SocketSource, c: Corners, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        var p: [proto.DISPLAY_AREA_SIZE]u8 = undefined;
        proto.encodeDisplayArea(&p, c);
        try self.request(.set_display_area_corners, &p, cb, ctx);
    }

    /// Rect form: width, height, bottom-left x/y, z (no tilt). Reply: area set.
    pub fn setDisplayArea(self: *SocketSource, w: f64, h: f64, ox: f64, oy: f64, z: f64, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        var p: [40]u8 = undefined;
        for ([_]f64{ w, h, ox, oy, z }, 0..) |v, i| std.mem.writeInt(u64, p[i * 8 ..][0..8], @bitCast(v), .little);
        try self.request(.set_display_area, &p, cb, ctx);
    }

    pub fn startCalibration(self: *SocketSource, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        try self.request(.start_calibration, &.{}, cb, ctx);
    }

    /// x, y normalised display coordinates (0..1, origin top-left), both eyes.
    pub fn addCalibrationPoint(self: *SocketSource, x: f64, y: f64, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        var p: [16]u8 = undefined;
        std.mem.writeInt(u64, p[0..8], @bitCast(x), .little);
        std.mem.writeInt(u64, p[8..16], @bitCast(y), .little);
        try self.request(.add_calibration_point, &p, cb, ctx);
    }

    /// Reply: the calibration blob (also saved by the daemon).
    /// End the calibration session without applying it; the device keeps its
    /// current calibration.
    pub fn cancelCalibration(self: *SocketSource, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        try self.request(.cancel_calibration, &.{}, cb, ctx);
    }

    pub fn finishCalibration(self: *SocketSource, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        try self.request(.finish_calibration, &.{}, cb, ctx);
    }

    pub fn calApply(self: *SocketSource, blob: []const u8, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        try self.request(.cal_apply, blob, cb, ctx);
    }

    pub fn getCalibrationStimulus(self: *SocketSource, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        try self.request(.get_calibration_stimulus, &.{}, cb, ctx);
    }

    // ── Correction map (daemon-side, see correction.zig) ───────────

    /// Install a correction map (correction.json text). Err.mismatch if it was
    /// made for another calibration blob or display area.
    pub fn setCorrection(self: *SocketSource, json: []const u8, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        try self.request(.set_correction, json, cb, ctx);
    }

    /// Reply: u8 state (0 none, 1 active, 2 stored but inactive) + json.
    pub fn getCorrection(self: *SocketSource, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        try self.request(.get_correction, &.{}, cb, ctx);
    }

    /// Delete the stored map.
    pub fn clearCorrection(self: *SocketSource, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        try self.request(.clear_correction, &.{}, cb, ctx);
    }

    /// Enable/disable the map for every client (runtime only).
    pub fn setCorrectionEnabled(self: *SocketSource, on: bool, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        try self.request(.set_correction_enabled, &.{@intFromBool(on)}, cb, ctx);
    }

    /// Raw (uncorrected) gaze for this connection only.
    pub fn setGazeRaw(self: *SocketSource, raw: bool, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        try self.request(.set_gaze_raw, &.{@intFromBool(raw)}, cb, ctx);
    }

    /// Send any command; `cb` gets its reply from poll().
    pub fn request(self: *SocketSource, cmd: proto.Cmd, payload: []const u8, cb: ?ReplyFn, ctx: ?*anyopaque) !void {
        if (!self.connected) return error.Disconnected;
        const slot = for (&self.inflight) |*s| {
            if (s.* == null) break s;
        } else return error.TooManyRequests;
        try self.sendRaw(cmd, payload);
        slot.* = .{ .seq = self.next_seq, .cmd = cmd, .cb = cb, .ctx = ctx };
        self.next_seq += 1;
    }

    // ── Reply decoding ──────────────────────────────────────────────

    pub fn decodeDisplayArea(payload: []const u8) ?Corners {
        if (payload.len < proto.DISPLAY_AREA_SIZE) return null;
        return proto.decodeDisplayArea(payload[0..proto.DISPLAY_AREA_SIZE]);
    }

    /// get_calibration_stimulus reply: [u32 n][n × 8 f64][raw TTP payload],
    /// records x, y, status_L, a_L, b_L, status_R, a_R, b_R.
    pub fn decodeStimulus(payload: []const u8) ?Stimulus {
        if (payload.len < 4) return null;
        const n = std.mem.readInt(u32, payload[0..4], .little);
        const rec = 8 * 8;
        if (n > 32 or payload.len < 4 + n * rec) return null;
        var s = Stimulus{ .points = undefined, .n = n, .raw = payload[4 + n * rec ..] };
        for (0..n) |i| {
            var f: [8]f64 = undefined;
            for (&f, 0..) |*v, k| v.* = @bitCast(std.mem.readInt(u64, payload[4 + i * rec + k * 8 ..][0..8], .little));
            s.points[i] = .{
                .x = f[0],
                .y = f[1],
                .left = .{ .status = f[2], .a = f[3], .b = f[4] },
                .right = .{ .status = f[5], .a = f[6], .b = f[7] },
            };
        }
        return s;
    }

    // ── Blocking convenience ────────────────────────────────────────

    pub const Owned = struct {
        cmd_err: ?u32,
        data: []u8,
        allocator: std.mem.Allocator,
        pub fn deinit(self: Owned) void {
            self.allocator.free(self.data);
        }
    };

    const CallState = struct { done: bool = false, result: ?Owned = null, alloc: std.mem.Allocator, oom: bool = false };

    fn callCb(ctx: ?*anyopaque, _: proto.Cmd, reply: Reply) void {
        const st: *CallState = @ptrCast(@alignCast(ctx.?));
        st.done = true;
        switch (reply) {
            .ok => |p| {
                const d = st.alloc.dupe(u8, p) catch {
                    st.oom = true;
                    return;
                };
                st.result = .{ .cmd_err = null, .data = d, .allocator = st.alloc };
            },
            .err => |code| st.result = .{ .cmd_err = code, .data = &.{}, .allocator = st.alloc },
        }
    }

    /// Send `cmd` and wait (polling the socket; gaze callbacks still fire)
    /// until its reply arrives. Returns the reply (caller deinit()s) whose
    /// cmd_err is set on a daemon/device error.
    pub fn call(self: *SocketSource, cmd: proto.Cmd, payload: []const u8, timeout_ms: i64) !Owned {
        var st = CallState{ .alloc = self.allocator };
        try self.request(cmd, payload, callCb, &st);
        const deadline = std.time.milliTimestamp() + timeout_ms;
        while (!st.done) {
            const left = deadline - std.time.milliTimestamp();
            if (left <= 0) {
                self.forget(&st);
                return error.Timeout;
            }
            var pfd = [1]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
            _ = std.posix.poll(&pfd, @intCast(@min(left, 100))) catch {};
            self.poll();
            if (!self.connected and !st.done) return error.Disconnected;
        }
        if (st.oom) return error.OutOfMemory;
        return st.result.?;
    }

    /// Drop the callback of an abandoned call (its reply is then ignored).
    fn forget(self: *SocketSource, ctx: *anyopaque) void {
        for (&self.inflight) |*s| {
            if (s.*) |e| if (e.ctx == ctx) {
                s.* = .{ .seq = e.seq, .cmd = e.cmd, .cb = null, .ctx = null };
            };
        }
    }

    // ── I/O ─────────────────────────────────────────────────────────

    fn sendRaw(self: *SocketSource, cmd: proto.Cmd, payload: []const u8) !void {
        var hdr: [proto.HEADER_SIZE]u8 = undefined;
        proto.encodeHeader(&hdr, @intFromEnum(cmd), @intCast(payload.len));
        try self.writeAll(&hdr);
        try self.writeAll(payload);
    }

    /// Non-blocking socket: wait for POLLOUT on EAGAIN (only matters for
    /// cal_apply blobs larger than the socket buffer).
    fn writeAll(self: *SocketSource, data: []const u8) !void {
        var rest = data;
        while (rest.len > 0) {
            const n = std.posix.write(self.fd, rest) catch |err| switch (err) {
                error.WouldBlock => {
                    var pfd = [1]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                    if (try std.posix.poll(&pfd, 5000) == 0) return error.Timeout;
                    continue;
                },
                else => {
                    self.markDisconnected();
                    return error.Disconnected;
                },
            };
            rest = rest[n..];
        }
    }

    /// Read everything available and dispatch complete messages. Never blocks.
    pub fn poll(self: *SocketSource) void {
        while (self.connected) {
            if (self.buf_len == self.buf.len) {
                if (!self.grow(self.buf.len * 2)) {
                    log.err("message larger than {} bytes, disconnecting", .{MAX_BUF});
                    self.markDisconnected();
                    return;
                }
            }
            const n = std.posix.read(self.fd, self.buf[self.buf_len..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    self.markDisconnected();
                    return;
                },
            };
            if (n == 0) {
                self.markDisconnected();
                return;
            }
            self.buf_len += n;
            self.processMessages();
        }
    }

    fn grow(self: *SocketSource, want: usize) bool {
        if (want > MAX_BUF) return false;
        self.buf = self.allocator.realloc(self.buf, want) catch return false;
        return true;
    }

    fn processMessages(self: *SocketSource) void {
        var pos: usize = 0;
        while (pos + proto.HEADER_SIZE <= self.buf_len) {
            const hdr = proto.decodeHeader(self.buf[pos..][0..proto.HEADER_SIZE]);
            const msg_end = pos + proto.HEADER_SIZE + hdr.payload_len;
            if (msg_end > self.buf_len) {
                // Make room for the whole message up front.
                const need = msg_end - pos;
                if (need > self.buf.len and !self.grow(@max(need, self.buf.len * 2))) {
                    log.err("message of {} bytes too large, disconnecting", .{need});
                    self.markDisconnected();
                    return;
                }
                break;
            }
            self.dispatchMessage(hdr.msg_type, self.buf[pos + proto.HEADER_SIZE .. msg_end]);
            pos = msg_end;
        }
        if (pos > 0) {
            const remaining = self.buf_len - pos;
            if (remaining > 0) std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[pos..self.buf_len]);
            self.buf_len = remaining;
        }
    }

    /// Oldest in-flight request of this command type (replies of one type
    /// come back in order).
    fn takeInflight(self: *SocketSource, cmd_type: u8) ?Inflight {
        var best: ?usize = null;
        for (self.inflight, 0..) |s, i| {
            if (s) |e| if (@intFromEnum(e.cmd) == cmd_type) {
                if (best == null or e.seq < self.inflight[best.?].?.seq) best = i;
            };
        }
        const i = best orelse return null;
        const e = self.inflight[i].?;
        self.inflight[i] = null;
        return e;
    }

    fn dispatchMessage(self: *SocketSource, msg_type: u8, payload: []const u8) void {
        switch (msg_type) {
            @intFromEnum(proto.Srv.gaze) => {
                if (payload.len >= @sizeOf(proto.GazeSample)) {
                    if (self.gaze_cb) |cb| {
                        // Copy into an aligned local — the read buffer has no alignment guarantee.
                        var sample: proto.GazeSample = undefined;
                        @memcpy(std.mem.asBytes(&sample), payload[0..@sizeOf(proto.GazeSample)]);
                        cb(&sample);
                    }
                }
            },
            @intFromEnum(proto.Srv.response) => {
                if (payload.len < 1) return;
                self.complete(payload[0], .{ .ok = payload[1..] });
            },
            @intFromEnum(proto.Srv.display_area) => {
                self.complete(@intFromEnum(proto.Cmd.get_display_area), .{ .ok = payload });
            },
            @intFromEnum(proto.Srv.err) => {
                if (payload.len < 5) return;
                const code = std.mem.readInt(u32, payload[1..5], .little);
                log.warn("daemon error for cmd=0x{x:0>2}: 0x{x}", .{ payload[0], code });
                self.complete(payload[0], .{ .err = code });
            },
            else => {},
        }
    }

    fn complete(self: *SocketSource, cmd_type: u8, reply: Reply) void {
        const e = self.takeInflight(cmd_type) orelse {
            log.debug("unsolicited reply for cmd=0x{x:0>2}", .{cmd_type});
            return;
        };
        if (e.cb) |cb| cb(e.ctx, e.cmd, reply);
    }

    fn markDisconnected(self: *SocketSource) void {
        if (!self.connected) return;
        self.connected = false;
        log.info("daemon connection closed", .{});
        for (&self.inflight) |*s| {
            if (s.*) |e| {
                s.* = null;
                if (e.cb) |cb| cb(e.ctx, e.cmd, .{ .err = proto.Err.disconnected });
            }
        }
    }

    pub fn deinit(self: *SocketSource) void {
        log.info("disconnecting", .{});
        if (self.connected) {
            var cmd_buf: [proto.HEADER_SIZE]u8 = undefined;
            proto.encodeHeader(&cmd_buf, @intFromEnum(proto.Cmd.disconnect), 0);
            _ = std.posix.write(self.fd, &cmd_buf) catch {};
        }
        self.connected = false;
        std.posix.close(self.fd);
        self.allocator.free(self.buf);
    }
};

// ── Tests (fake daemon on a socketpair) ─────────────────────────────

const testing = std.testing;

fn testPair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0, &fds);
    if (rc != 0) return error.SocketPair;
    return fds;
}

fn daemonWrite(fd: std.posix.fd_t, msg_type: proto.Srv, cmd_type: u8, payload: []const u8) !void {
    var hdr: [proto.HEADER_SIZE + 1]u8 = undefined;
    proto.encodeHeader(hdr[0..proto.HEADER_SIZE], @intFromEnum(msg_type), @intCast(1 + payload.len));
    hdr[proto.HEADER_SIZE] = cmd_type;
    _ = try std.posix.write(fd, &hdr);
    var rest = payload;
    while (rest.len > 0) {
        const n = std.posix.write(fd, rest) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            else => return err,
        };
        rest = rest[n..];
    }
}

const Recorder = struct {
    n: usize = 0,
    cmds: [8]proto.Cmd = undefined,
    errs: [8]?u32 = undefined,
    lens: [8]usize = undefined,
    area: ?Corners = null,

    fn cb(ctx: ?*anyopaque, cmd: proto.Cmd, reply: Reply) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx.?));
        r.cmds[r.n] = cmd;
        switch (reply) {
            .ok => |p| {
                r.errs[r.n] = null;
                r.lens[r.n] = p.len;
                if (cmd == .set_display_area_corners or cmd == .get_display_area) r.area = SocketSource.decodeDisplayArea(p);
            },
            .err => |e| {
                r.errs[r.n] = e;
                r.lens[r.n] = 0;
            },
        }
        r.n += 1;
    }
};

test "commands are encoded and replies dispatched per command type" {
    const fds = try testPair();
    defer std.posix.close(fds[1]);
    var src = try SocketSource.fromFd(testing.allocator, fds[0]);
    defer src.deinit();

    var rec = Recorder{};
    const area: Corners = .{ -265.68, 308.89, 0, 265.68, 308.89, 0, -265.68, 10, 0 };
    try src.setDisplayAreaCorners(area, Recorder.cb, &rec);
    try src.getCalibrationStimulus(Recorder.cb, &rec);

    // The daemon sees: [0x04][72][9×f64] then [0x24][0].
    var in: [128]u8 = undefined;
    const n = try std.posix.read(fds[1], &in);
    try testing.expectEqual(@as(usize, proto.HEADER_SIZE + 72 + proto.HEADER_SIZE), n);
    try testing.expectEqual(@as(u8, 0x04), in[0]);
    try testing.expectEqual(@as(u32, 72), std.mem.readInt(u32, in[1..5], .little));
    try testing.expectEqual(area, proto.decodeDisplayArea(in[5..77]));
    try testing.expectEqual(@as(u8, 0x24), in[77]);

    // Replies out of order across types: stimulus error first, then the area.
    var err_buf: [proto.HEADER_SIZE + 1 + 4]u8 = undefined;
    proto.encodeError(&err_buf, 0x24, 0x20000502);
    _ = try std.posix.write(fds[1], &err_buf);
    var a: [72]u8 = undefined;
    proto.encodeDisplayArea(&a, area);
    try daemonWrite(fds[1], .response, 0x04, &a);

    src.poll();
    try testing.expectEqual(@as(usize, 2), rec.n);
    try testing.expectEqual(proto.Cmd.get_calibration_stimulus, rec.cmds[0]);
    try testing.expectEqual(@as(?u32, 0x20000502), rec.errs[0]);
    try testing.expectEqual(proto.Cmd.set_display_area_corners, rec.cmds[1]);
    try testing.expectEqual(area, rec.area.?);
}

test "large reply split across reads grows the buffer" {
    const fds = try testPair();
    defer std.posix.close(fds[1]);
    var src = try SocketSource.fromFd(testing.allocator, fds[0]);
    defer src.deinit();

    var rec = Recorder{};
    try src.finishCalibration(Recorder.cb, &rec);
    var sink: [64]u8 = undefined;
    _ = try std.posix.read(fds[1], &sink);

    const blob = try testing.allocator.alloc(u8, 100 * 1024);
    defer testing.allocator.free(blob);
    for (blob, 0..) |*b, i| b.* = @truncate(i);

    // Write in pieces, polling in between (socket buffer is smaller than the blob).
    var hdr: [proto.HEADER_SIZE + 1]u8 = undefined;
    proto.encodeHeader(hdr[0..proto.HEADER_SIZE], @intFromEnum(proto.Srv.response), @intCast(1 + blob.len));
    hdr[proto.HEADER_SIZE] = @intFromEnum(proto.Cmd.finish_calibration);
    _ = try std.posix.write(fds[1], &hdr);
    var off: usize = 0;
    while (off < blob.len) {
        off += std.posix.write(fds[1], blob[off..@min(blob.len, off + 8192)]) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => return err,
        };
        src.poll();
    }
    src.poll();
    try testing.expectEqual(@as(usize, 1), rec.n);
    try testing.expectEqual(@as(usize, blob.len), rec.lens[0]);
}

test "outstanding requests fail with disconnected on EOF" {
    const fds = try testPair();
    var src = try SocketSource.fromFd(testing.allocator, fds[0]);
    defer src.deinit();
    var rec = Recorder{};
    try src.startCalibration(Recorder.cb, &rec);
    std.posix.close(fds[1]);
    src.poll();
    try testing.expect(!src.connected);
    try testing.expectEqual(@as(usize, 1), rec.n);
    try testing.expectEqual(@as(?u32, proto.Err.disconnected), rec.errs[0]);
    try testing.expectError(error.Disconnected, src.getDisplayArea(null, null));
}

test "decodeStimulus" {
    var p: [4 + 2 * 64 + 3]u8 = undefined;
    std.mem.writeInt(u32, p[0..4], 2, .little);
    const v = [_]f64{ 0.1, 0.1, 2, 0.02, 0.03, 2, 0.04, 0.05, 0.9, 0.5, 2, 0.01, 0.01, 1, 0.02, 0.02 };
    for (v, 0..) |x, i| std.mem.writeInt(u64, p[4 + i * 8 ..][0..8], @bitCast(x), .little);
    @memcpy(p[132..135], "raw");
    const s = SocketSource.decodeStimulus(&p).?;
    try testing.expectEqual(@as(u32, 2), s.n);
    try testing.expectEqual(@as(f64, 0.9), s.points[1].x);
    try testing.expectEqual(@as(f64, 0.05), s.points[0].right.b);
    try testing.expectEqual(@as(f64, 1), s.points[1].right.status);
    try testing.expectEqualStrings("raw", s.raw);
}
