// tobiifree-warp — move the mouse cursor to where the person is looking, on
// a shortcut.
//
//   tobiifree-warp [serve] [options]   long-running server
//   tobiifree-warp jump [--dry-run]    poke the server (bind this to a key)
//
// The server is a gaze client of tobiifreed (corrected gaze, as every
// client gets it by default), keeps the last samples in a ring and listens
// on $XDG_RUNTIME_DIR/tobiifree-warp.sock. A jump (the client, or SIGUSR1)
// picks the median of the most recent stable run of the last window
// (select.zig), maps it to the output of tobii.json (layout.zig) and moves
// the cursor through the compositor (backend.zig: Hyprland IPC).
//
// Every failure is a silent no-op: no server socket, no daemon, no tracker,
// eyes lost or moving → the cursor stays put; one log line on stderr.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const core = @import("tobiifree_core");
const SocketSource = @import("socket_source").SocketSource;
const select = @import("select.zig");
const layout = @import("layout.zig");
const gaze = @import("gaze.zig");
const Backend = @import("backend.zig").Backend;
const Hyprland = @import("backend.zig").Hyprland;

const log = std.log.scoped(.warp);

pub const std_options: std.Options = .{
    .log_level = .info,
    // SocketSource logs every (re)connect attempt at info: keep the journal
    // quiet while the daemon is away; we log state changes ourselves.
    .log_scope_levels = &.{.{ .scope = .socket, .level = .warn }},
};

const SOCK_NAME = "tobiifree-warp.sock";

fn nowNs() i64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch unreachable;
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn msSince(t0: i64, t1: i64) f64 {
    return @as(f64, @floatFromInt(t1 - t0)) / 1e6;
}

fn controlPath(buf: []u8) ![:0]const u8 {
    const rt = posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
    return std.fmt.bufPrintZ(buf, "{s}/" ++ SOCK_NAME, .{rt});
}

fn unixAddr(path: []const u8) !posix.sockaddr.un {
    var addr: posix.sockaddr.un = .{ .path = undefined, .family = posix.AF.UNIX };
    @memset(&addr.path, 0);
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

// ── Client ──────────────────────────────────────────────────────────

/// Exit status is 0 for every no-op: a key binding has nothing to do with
/// an error, and the person travels without the tracker.
fn jumpClient(dry: bool) u8 {
    const t0 = nowNs();
    var path_buf: [512]u8 = undefined;
    const path = controlPath(&path_buf) catch return 0;
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return 0;
    defer posix.close(fd);
    const addr = unixAddr(path) catch return 0;
    posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch {
        std.debug.print("tobiifree-warp: server not running\n", .{});
        return 0;
    };
    // The server waits at most ~settle_ms for a fixation, then answers.
    const tv = posix.timeval{ .sec = 1, .usec = 0 };
    posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    var req: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&req, "jump {d}{s}\n", .{ t0, if (dry) " dry" else "" }) catch return 0;
    _ = posix.write(fd, line) catch return 0;
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const k = posix.read(fd, buf[n..]) catch break;
        if (k == 0) break;
        n += k;
    }
    const answer = std.mem.trimRight(u8, buf[0..n], "\n");
    if (dry) {
        std.fs.File.stdout().writeAll(buf[0..n]) catch {};
    } else if (answer.len > 0) {
        std.debug.print("tobiifree-warp: {s} (client {d:.1} ms)\n", .{ answer, msSince(t0, nowNs()) });
    }
    return 0;
}

// ── Config ──────────────────────────────────────────────────────────

const Opts = struct {
    output: ?[]const u8 = null,
    dry_run: bool = false,
    params: select.Params = .{},
    /// How long a jump may wait for a fixation when the eye is moving.
    settle_ms: f64 = 200,
};

/// tobii.json: "output" (the screen the tracker is on) and the display area
/// size in mm (degrees for the dispersion threshold).
fn loadTobiiJson(gpa: std.mem.Allocator, o: *Opts) void {
    const home = posix.getenv("HOME") orelse return;
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.config/tobii.json", .{home}) catch return;
    const text = std.fs.cwd().readFileAlloc(gpa, path, 1 << 20) catch |err| {
        log.warn("{s}: {}", .{ path, err });
        return;
    };
    defer gpa.free(text);
    const v = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |err| {
        log.warn("{s}: {}", .{ path, err });
        return;
    };
    defer v.deinit();
    if (v.value != .object) return;
    if (o.output == null) if (v.value.object.get("output")) |out| if (out == .string) {
        o.output = gpa.dupe(u8, out.string) catch null;
    };
    if (v.value.object.get("display_area")) |da| if (da == .object) {
        if (num(da.object.get("w_mm"))) |w| o.params.width_mm = w;
        if (num(da.object.get("h_mm"))) |h| o.params.height_mm = h;
    };
}

fn num(v: ?std.json.Value) ?f64 {
    const x = v orelse return null;
    return switch (x) {
        .float => |f| if (f > 0) f else null,
        .integer => |i| if (i > 0) @floatFromInt(i) else null,
        else => null,
    };
}

// ── Server ──────────────────────────────────────────────────────────

const Jump = struct {
    /// Client connection to answer, null for SIGUSR1.
    fd: ?posix.fd_t,
    /// Key press as seen by the client (its first instruction), or the
    /// signal's arrival.
    t_start: i64,
    t_recv: i64,
    dry: bool,
};

const Server = struct {
    gpa: std.mem.Allocator,
    opts: Opts,
    backend: Backend,
    ring: select.Ring = .{},
    src: ?SocketSource = null,
    /// Backoff between daemon connection attempts.
    retry_ms: i64 = 250,
    next_retry: i64 = 0,
    ever_connected: bool = false,
    last_sample: i64 = 0,
    samples_flowing: bool = false,
    corrected: ?bool = null,
    pending: ?Jump = null,
    listen_fd: posix.fd_t,
    sig_fd: posix.fd_t,
    path: [:0]const u8,

    const RETRY_MIN_MS = 250;
    const RETRY_MAX_MS = 5000;
    /// No samples for this long while connected: say so once (tracker
    /// unplugged, or the daemon paused the stream).
    const QUIET_MS = 3000;

    fn onGaze(s: *const core.GazeSample) void {
        const self = g_server;
        const t = nowNs();
        self.last_sample = t;
        if (!self.samples_flowing) {
            self.samples_flowing = true;
            log.info("gaze samples flowing", .{});
        }
        const c = s.present_mask & core.GAZE_BIT_CORRECTED != 0;
        if (self.corrected == null or self.corrected.? != c) {
            self.corrected = c;
            log.info("gaze {s}", .{if (c) "corrected by the daemon's correction map" else "not corrected (no active correction map in the daemon)"});
        }
        if (gaze.toSample(s, t)) |g| self.ring.push(g);
    }

    fn connect(self: *Server, now: i64) void {
        var s = SocketSource.initWithAllocator(self.gpa) catch |err| {
            if (self.retry_ms == RETRY_MIN_MS) log.info("tobiifreed not reachable ({}), retrying with backoff", .{err});
            self.next_retry = now + self.retry_ms * std.time.ns_per_ms;
            self.retry_ms = @min(self.retry_ms * 2, RETRY_MAX_MS);
            return;
        };
        s.onGaze(onGaze);
        self.src = s;
        self.ever_connected = true;
        self.retry_ms = RETRY_MIN_MS;
        self.last_sample = now;
        self.samples_flowing = false;
        self.corrected = null;
        log.info("connected to tobiifreed", .{});
    }

    fn dropSource(self: *Server, now: i64) void {
        if (self.src) |*s| s.deinit();
        self.src = null;
        self.ring.clear();
        self.samples_flowing = false;
        self.next_retry = now + self.retry_ms * std.time.ns_per_ms;
        log.info("tobiifreed connection lost, reconnecting", .{});
    }

    fn run(self: *Server) !void {
        while (true) {
            const now = nowNs();
            if (self.src == null and now >= self.next_retry) self.connect(now);

            // Timeout: next reconnect attempt, pending jump deadline, quiet check.
            var timeout_ms: i64 = -1;
            if (self.src == null) timeout_ms = @max(0, @divFloor(self.next_retry - now, std.time.ns_per_ms) + 1);
            if (self.src != null and self.samples_flowing) {
                const quiet_at = self.last_sample + QUIET_MS * std.time.ns_per_ms;
                timeout_ms = minTimeout(timeout_ms, @max(0, @divFloor(quiet_at - now, std.time.ns_per_ms) + 1));
            }
            if (self.pending) |p| {
                const deadline = p.t_recv + @as(i64, @intFromFloat(self.opts.settle_ms * 1e6));
                timeout_ms = minTimeout(timeout_ms, @max(0, @divFloor(deadline - now, std.time.ns_per_ms) + 1));
            }

            var fds: [3]posix.pollfd = .{
                .{ .fd = self.sig_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.listen_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = if (self.src) |s| s.fd else -1, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&fds, @intCast(@min(timeout_ms, std.math.maxInt(i32)))) catch |err| switch (err) {
                else => return err,
            };

            if (fds[0].revents & posix.POLL.IN != 0) {
                var si: linux.signalfd_siginfo = undefined;
                const n = posix.read(self.sig_fd, std.mem.asBytes(&si)) catch 0;
                if (n == @sizeOf(linux.signalfd_siginfo)) switch (si.signo) {
                    posix.SIG.USR1 => self.startJump(.{ .fd = null, .t_start = nowNs(), .t_recv = nowNs(), .dry = self.opts.dry_run }),
                    posix.SIG.TERM, posix.SIG.INT, posix.SIG.HUP => {
                        log.info("signal {d}, exiting", .{si.signo});
                        return;
                    },
                    else => {},
                };
            }
            if (self.src) |*s| {
                if (fds[2].revents != 0) s.poll();
                if (!s.connected) self.dropSource(nowNs());
            }
            if (self.src != null and self.samples_flowing and nowNs() - self.last_sample > QUIET_MS * std.time.ns_per_ms) {
                self.samples_flowing = false;
                self.ring.clear();
                log.info("no gaze samples for {d} s (tracker unplugged?)", .{QUIET_MS / 1000});
            }
            if (fds[1].revents & posix.POLL.IN != 0) self.accept();
            if (self.pending != null) self.evaluate();
        }
    }

    fn minTimeout(a: i64, b: i64) i64 {
        return if (a < 0) b else @min(a, b);
    }

    fn accept(self: *Server) void {
        const fd = posix.accept(self.listen_fd, null, null, posix.SOCK.CLOEXEC) catch return;
        const t_recv = nowNs();
        // The client writes its request right after connecting.
        const tv = posix.timeval{ .sec = 0, .usec = 50_000 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        var buf: [128]u8 = undefined;
        var n: usize = 0;
        while (n < buf.len) {
            const k = posix.read(fd, buf[n..]) catch break;
            if (k == 0) break;
            n += k;
            if (std.mem.indexOfScalar(u8, buf[0..n], '\n') != null) break;
        }
        var it = std.mem.tokenizeAny(u8, buf[0..n], " \n");
        const verb = it.next() orelse "";
        if (!std.mem.eql(u8, verb, "jump")) {
            reply(fd, "error unknown request\n");
            posix.close(fd);
            return;
        }
        var j = Jump{ .fd = fd, .t_start = t_recv, .t_recv = t_recv, .dry = self.opts.dry_run };
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "dry")) j.dry = true else if (std.fmt.parseInt(i64, tok, 10)) |t| {
                if (t <= t_recv and t_recv - t < 10 * std.time.ns_per_s) j.t_start = t;
            } else |_| {}
        }
        self.startJump(j);
    }

    fn startJump(self: *Server, j: Jump) void {
        if (self.pending) |old| self.finish(old, "noop superseded by a newer jump");
        self.pending = j;
        self.evaluate();
    }

    /// Decide the pending jump if possible: act on a fixation, give up at
    /// once without fresh gaze, wait (up to settle_ms) while the eye moves.
    fn evaluate(self: *Server) void {
        const j = self.pending orelse return;
        const now = nowNs();
        const res = select.select(&self.ring, now, self.opts.params);
        var msg_buf: [256]u8 = undefined;
        switch (res) {
            .ok => |pick| {
                self.pending = null;
                self.act(j, pick, now);
            },
            .stale => |s| {
                self.pending = null;
                const why = if (self.src == null) "tobiifreed not connected" else if (!self.samples_flowing) "no gaze samples (tracker away?)" else "no valid gaze (eyes not tracked)";
                const msg = if (s.age_ms) |a|
                    std.fmt.bufPrint(&msg_buf, "noop {s}, newest sample {d:.0} ms old", .{ why, a }) catch "noop"
                else
                    std.fmt.bufPrint(&msg_buf, "noop {s}", .{why}) catch "noop";
                self.finish(j, msg);
            },
            .unstable => |u| {
                if (msSince(j.t_recv, now) < self.opts.settle_ms) return; // wait for the next samples
                self.pending = null;
                const msg = std.fmt.bufPrint(&msg_buf, "noop gaze not settled after {d:.0} ms (run {d}/{d} samples, jump {d:.1} deg)", .{ self.opts.settle_ms, u.run, u.n_window, u.dispersion_deg }) catch "noop";
                self.finish(j, msg);
            },
        }
    }

    fn act(self: *Server, j: Jump, pick: select.Pick, t_decide: i64) void {
        var msg_buf: [384]u8 = undefined;
        var mons = self.backend.monitors() catch |err| {
            const msg = std.fmt.bufPrint(&msg_buf, "noop compositor unreachable ({})", .{err}) catch "noop";
            return self.finish(j, msg);
        };
        defer mons.deinit();
        const mon: layout.Monitor = blk: {
            if (self.opts.output) |name| {
                if (layout.find(mons.monitors, name)) |m| break :blk m;
                const msg = std.fmt.bufPrint(&msg_buf, "noop output {s} not present", .{name}) catch "noop";
                return self.finish(j, msg);
            }
            if (mons.focused) |f| break :blk mons.monitors[f];
            return self.finish(j, "noop no output");
        };
        const t_mons = nowNs();
        const p = layout.mapNorm(mon, pick.x, pick.y);
        const detail = std.fmt.bufPrint(&msg_buf, "{d:.0},{d:.0} on {s} (gaze {d:.3},{d:.3}, {d}/{d} samples, {d:.2} deg, newest {d:.0} ms)", .{
            p[0], p[1], mon.name, pick.x, pick.y, pick.n, pick.n_window, pick.dispersion_deg, pick.age_ms,
        }) catch "";
        var out_buf: [512]u8 = undefined;
        if (j.dry) {
            const msg = std.fmt.bufPrint(&out_buf, "target {s} [dry run] latency {d:.2} ms", .{ detail, msSince(j.t_start, nowNs()) }) catch "target";
            return self.finish(j, msg);
        }
        self.backend.moveCursor(p[0], p[1]) catch |err| {
            const msg = std.fmt.bufPrint(&out_buf, "noop move failed ({}) for {s}", .{ err, detail }) catch "noop";
            return self.finish(j, msg);
        };
        const t_done = nowNs();
        const msg = std.fmt.bufPrint(&out_buf, "moved {s}; latency {d:.2} ms (to server {d:.2}, wait {d:.1}, monitors {d:.2}, move {d:.2})", .{
            detail,
            msSince(j.t_start, t_done),
            msSince(j.t_start, j.t_recv),
            msSince(j.t_recv, t_decide),
            msSince(t_decide, t_mons),
            msSince(t_mons, t_done),
        }) catch "moved";
        self.finish(j, msg);
    }

    fn finish(_: *Server, j: Jump, msg: []const u8) void {
        log.info("jump: {s}", .{msg});
        if (j.fd) |fd| {
            var buf: [600]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s}\n", .{msg}) catch "\n";
            reply(fd, line);
            posix.close(fd);
        }
    }

    fn deinit(self: *Server) void {
        if (self.pending) |p| self.finish(p, "noop server exiting");
        self.pending = null;
        if (self.src) |*s| s.deinit();
        posix.close(self.listen_fd);
        std.fs.cwd().deleteFileZ(self.path) catch {};
    }
};

fn reply(fd: posix.fd_t, msg: []const u8) void {
    _ = posix.send(fd, msg, linux.MSG.NOSIGNAL) catch {};
}

var g_server: *Server = undefined;

/// Bind the control socket. A live server there → error.AlreadyRunning; a
/// stale socket file (crash) is replaced.
fn listenControl(path: [:0]const u8) !posix.fd_t {
    const addr = try unixAddr(path);
    probe: {
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch break :probe;
        defer posix.close(fd);
        if (posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un))) |_| {
            return error.AlreadyRunning;
        } else |_| {}
    }
    std.fs.cwd().deleteFileZ(path) catch {};
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
    errdefer posix.close(fd);
    try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    try posix.listen(fd, 8);
    return fd;
}

/// systemd Type=notify readiness (no-op without $NOTIFY_SOCKET).
fn sdNotifyReady() void {
    const p = posix.getenv("NOTIFY_SOCKET") orelse return;
    if (p.len == 0) return;
    var addr: posix.sockaddr.un = .{ .path = undefined, .family = posix.AF.UNIX };
    @memset(&addr.path, 0);
    if (p.len >= addr.path.len) return;
    @memcpy(addr.path[0..p.len], p);
    if (addr.path[0] == '@') addr.path[0] = 0; // abstract namespace
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.DGRAM | posix.SOCK.CLOEXEC, 0) catch return;
    defer posix.close(fd);
    const len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + p.len);
    _ = posix.sendto(fd, "READY=1", 0, @ptrCast(&addr), len) catch {};
}

fn serve(gpa: std.mem.Allocator, opts_in: Opts) u8 {
    var opts = opts_in;
    loadTobiiJson(gpa, &opts);

    var path_buf: [512]u8 = undefined;
    const path = controlPath(&path_buf) catch {
        log.err("XDG_RUNTIME_DIR not set", .{});
        return 1;
    };

    // Signals through a signalfd (no async handlers): USR1 = jump,
    // TERM/INT/HUP = clean exit.
    var mask = posix.sigemptyset();
    for ([_]u6{ posix.SIG.USR1, posix.SIG.TERM, posix.SIG.INT, posix.SIG.HUP }) |sig| posix.sigaddset(&mask, sig);
    posix.sigprocmask(posix.SIG.BLOCK, &mask, null);
    const sig_fd = posix.signalfd(-1, &mask, linux.SFD.CLOEXEC) catch |err| {
        log.err("signalfd: {}", .{err});
        return 1;
    };
    // Writing to a client that went away must not kill us.
    var ign: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(posix.SIG.PIPE, &ign, null);

    const listen_fd = listenControl(path) catch |err| {
        if (err == error.AlreadyRunning) log.err("already running ({s})", .{path}) else log.err("{s}: {}", .{ path, err });
        return 1;
    };

    var srv = Server{
        .gpa = gpa,
        .opts = opts,
        .backend = .{ .hyprland = Hyprland.init(gpa) },
        .listen_fd = listen_fd,
        .sig_fd = sig_fd,
        .path = path,
    };
    g_server = &srv;
    defer srv.deinit();

    log.info("listening on {s}; output {s}, window {d:.0} ms, max dispersion {d:.2} deg, settle {d:.0} ms, display {d:.0}x{d:.0} mm{s}", .{
        path,
        opts.output orelse "(focused)",
        opts.params.window_ms,
        opts.params.max_dispersion_deg,
        opts.settle_ms,
        opts.params.width_mm,
        opts.params.height_mm,
        if (opts.dry_run) ", dry run" else "",
    });
    sdNotifyReady();
    srv.run() catch |err| {
        log.err("event loop: {}", .{err});
        return 1;
    };
    return 0;
}

const usage =
    \\usage: tobiifree-warp [serve] [options]   run the server (default)
    \\       tobiifree-warp jump [--dry-run]    move the cursor to the gaze (bind to a key)
    \\
    \\server options:
    \\  --output NAME             output the tracker is on (default: tobii.json "output")
    \\  --window-ms MS            gaze history considered on a jump (150)
    \\  --max-dispersion-deg DEG  fixation threshold, max spread of the samples (1.5)
    \\  --stale-ms MS             newest sample older than this: no gaze, do nothing (300)
    \\  --settle-ms MS            how long a jump may wait for the eye to settle (200)
    \\  --dry-run                 log the target, never move the cursor
    \\
;

fn parseF(args: *std.process.ArgIterator, name: []const u8) ?f64 {
    const v = args.next() orelse {
        std.debug.print("{s} needs a value\n", .{name});
        return null;
    };
    const f = std.fmt.parseFloat(f64, v) catch {
        std.debug.print("{s}: bad number '{s}'\n", .{ name, v });
        return null;
    };
    if (!(f > 0)) {
        std.debug.print("{s}: must be > 0\n", .{name});
        return null;
    }
    return f;
}

pub fn main() u8 {
    var args = std.process.args();
    _ = args.next();
    var opts = Opts{};
    var mode: enum { serve, jump } = .serve;
    var first = true;
    while (args.next()) |a| {
        defer first = false;
        if (first and std.mem.eql(u8, a, "jump")) {
            mode = .jump;
        } else if (first and std.mem.eql(u8, a, "serve")) {
            mode = .serve;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--output") and mode == .serve) {
            opts.output = args.next() orelse {
                std.debug.print("--output needs a name\n", .{});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "--window-ms") and mode == .serve) {
            opts.params.window_ms = parseF(&args, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--max-dispersion-deg") and mode == .serve) {
            opts.params.max_dispersion_deg = parseF(&args, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--stale-ms") and mode == .serve) {
            opts.params.stale_ms = parseF(&args, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--settle-ms") and mode == .serve) {
            opts.settle_ms = parseF(&args, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.fs.File.stdout().writeAll(usage) catch {};
            return 0;
        } else {
            std.debug.print("unknown argument '{s}'\n{s}", .{ a, usage });
            return 2;
        }
    }
    return switch (mode) {
        .jump => jumpClient(opts.dry_run),
        .serve => serve(std.heap.page_allocator, opts),
    };
}

test {
    _ = select;
    _ = layout;
    _ = gaze;
}
