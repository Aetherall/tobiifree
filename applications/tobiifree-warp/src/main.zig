// tobiifree-warp — move the mouse cursor to where the person is looking, on
// a shortcut.
//
//   tobiifree-warp [serve] [options]   long-running server
//   tobiifree-warp jump [--dry-run]    poke the server (bind this to a key)
//   tobiifree-warp follow-start [--dry-run] / follow-stop
//                                      cursor follows the gaze while a key
//                                      is held (follow.zig)
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
const follow = @import("follow.zig");
const output_id = @import("output_id");
const hid = @import("hid.zig");
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
/// `extra`: request tokens (" min=5 timeout=600000 glide=100 …").
fn client(verb: []const u8, dry: bool, extra: []const u8) u8 {
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
    var req: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&req, "{s} {d}{s}{s}\n", .{ verb, t0, if (dry) " dry" else "", extra }) catch return 0;
    _ = posix.write(fd, line) catch return 0;
    var buf: [1024]u8 = undefined;
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
    /// --output: a connector or "desc:<description>". Without it, tobii.json
    /// "output_desc" / "output" (re-read on every jump / follow start).
    output: ?[]const u8 = null,
    dry_run: bool = false,
    params: select.Params = .{},
    /// How long a jump may wait for a fixation when the eye is moving.
    settle_ms: f64 = 200,
    filter: follow.FilterParams = .{},
    ease: follow.EaseParams = .{},
    /// device: the device-filtered gaze as is (as the overlay draws it);
    /// fixation: follow.zig's fixation filter and easing.
    follow_filter: enum { device, fixation } = .device,
    /// Follow stops by itself after this long (missed key release).
    follow_timeout_ms: i64 = 10_000,
    /// Keyboard to notify on follow-start --notify-hid.
    hid: hid.Config = .{},
};

fn loadTobiiText(gpa: std.mem.Allocator) ?[]u8 {
    const home = posix.getenv("HOME") orelse return null;
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/.config/tobii.json", .{home}) catch return null;
    return std.fs.cwd().readFileAlloc(gpa, path, 1 << 20) catch null;
}

/// tobii.json: the display area size in mm (degrees for the dispersion
/// threshold). The output is resolved per jump (resolveOutput).
fn loadTobiiJson(gpa: std.mem.Allocator, o: *Opts) void {
    const path = "~/.config/tobii.json";
    const text = loadTobiiText(gpa) orelse {
        log.warn("{s}: not readable, default screen size", .{path});
        return;
    };
    defer gpa.free(text);
    const v = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |err| {
        log.warn("{s}: {}", .{ path, err });
        return;
    };
    defer v.deinit();
    if (v.value != .object) return;
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
    verb: []const u8 = "jump",
    /// follow-start --min-distance-deg (0: plain follow).
    min_deg: f64 = 0,
    /// follow-start --timeout-ms (0: the server's --follow-timeout-ms).
    timeout_ms: i64 = 0,
    /// follow-start --glide-ms (0: jump / the follow filter's easing).
    glide_ms: f64 = 0,
    curve: follow.Curve = .inout,
    /// follow-start --notify-hid.
    notify: bool = false,
};

const Follow = struct {
    /// Owns the monitor names.
    mons: layout.Parsed,
    mon: layout.Monitor,
    filter: follow.Filter,
    easer: follow.Easer,
    session: follow.Session,
    last_step: i64,
    last_sent: [2]f64,
    fixations: usize = 0,
    /// fixation filter: target refinements within fixations (beyond the
    /// deadband); device filter: valid samples followed.
    updates: usize = 0,
    /// Next new fixation is the first: ease it in.
    first: bool = true,
    /// MAGIC pointing: move only when the gaze is more than this far from
    /// the cursor (degrees; 0 = always).
    min_deg: f64 = 0,
    /// Physical size of a logical pixel of the output (mm), for min_deg.
    mm_per_px: [2]f64 = .{ 0, 0 },
    /// Targets not followed: within min_deg of the cursor.
    near: usize = 0,
    /// Cursor found away from where we left it (moved by the person).
    moved_by_user: usize = 0,
    /// --glide-ms: moves glide from the cursor to the target.
    glide_ms: f64 = 0,
    curve: follow.Curve = .inout,
    glide: ?follow.Glide = null,
    glides: usize = 0,
    /// --notify-hid: tell the keyboard on the first real move.
    notify: follow.NotifyOnce = .{ .enabled = false, .dry = false },
    /// When the notification went out (or failed), for the summary.
    notify_ms: ?f64 = null,
    notify_ok: bool = false,
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
    follow: ?Follow = null,
    hid: hid.Notifier,
    /// Last output resolution logged.
    out_note: [512]u8 = undefined,
    out_note_len: usize = 0,
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
        // Per sample the bit is off where the map has no data (outside its
        // grid), so only say whether any sample of the connection was.
        const c = s.present_mask & core.GAZE_BIT_CORRECTED != 0;
        if (self.corrected == null) {
            self.corrected = c;
            log.info("gaze {s}", .{if (c) "corrected by the daemon's correction map" else "not corrected (yet; no active correction map in the daemon?)"});
        } else if (c and !self.corrected.?) {
            self.corrected = true;
            log.info("gaze corrected by the daemon's correction map", .{});
        }
        if (gaze.toSample(s, t)) |g| {
            self.ring.push(g);
            if (self.follow != null and self.opts.follow_filter == .fixation) self.followSample(g);
        }
        if (self.follow != null and self.opts.follow_filter == .device) {
            if (gaze.toSampleP(s, t, .filtered)) |g| self.followDevice(g);
        }
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
        self.stopFollow(.daemon_lost, null);
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
            if (self.follow) |f| {
                timeout_ms = minTimeout(timeout_ms, @max(0, @divFloor(f.session.deadline() - now, std.time.ns_per_ms) + 1));
                if (!f.easer.done() or f.glide != null) timeout_ms = minTimeout(timeout_ms, self.opts.ease.tick_ms);
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
            if (self.follow) |f| {
                if (f.session.expired(nowNs())) self.stopFollow(.timeout, null) else self.followStep(null);
            }
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
        var j = Jump{ .fd = fd, .t_start = t_recv, .t_recv = t_recv, .dry = self.opts.dry_run };
        while (it.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "glide=")) {
                j.glide_ms = std.math.clamp(std.fmt.parseFloat(f64, tok[6..]) catch 0, 0, 2000);
            } else if (std.mem.eql(u8, tok, "curve=in")) {
                j.curve = .in;
            } else if (std.mem.eql(u8, tok, "notify")) {
                j.notify = true;
            } else if (std.mem.startsWith(u8, tok, "timeout=")) {
                j.timeout_ms = std.fmt.parseInt(i64, tok[8..], 10) catch 0;
                j.timeout_ms = std.math.clamp(j.timeout_ms, 0, 3600_000);
            } else if (std.mem.startsWith(u8, tok, "min=")) {
                j.min_deg = std.fmt.parseFloat(f64, tok[4..]) catch 0;
                if (!(j.min_deg >= 0 and j.min_deg < 90)) j.min_deg = 0;
            } else if (std.mem.eql(u8, tok, "dry")) j.dry = true else if (std.fmt.parseInt(i64, tok, 10)) |t| {
                if (t <= t_recv and t_recv - t < 10 * std.time.ns_per_s) j.t_start = t;
            } else |_| {}
        }
        if (std.mem.eql(u8, verb, "jump")) {
            self.startJump(j);
        } else if (std.mem.eql(u8, verb, "follow-start")) {
            j.verb = "follow-start";
            self.startFollow(j);
        } else if (std.mem.eql(u8, verb, "follow-stop")) {
            j.verb = "follow-stop";
            if (self.follow == null) self.finish(j, "noop not following") else self.stopFollow(.release, j);
        } else {
            reply(fd, "error unknown request\n");
            posix.close(fd);
        }
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
        const mon = self.resolveOutput(&mons) orelse return self.finish(j, "noop tracker's output not present");
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

    // ── Output ──────────────────────────────────────────────────────

    /// The tracker's output among the current monitors: --output, else
    /// tobii.json's "output_desc" then "output" (re-read each time, so a
    /// new setup or a connector swap needs no restart), else the focused
    /// monitor. Logs when the outcome changes.
    fn resolveOutput(self: *Server, mons: *const layout.Parsed) ?layout.Monitor {
        var saved: output_id.Saved = .{};
        defer saved.free(self.gpa);
        const want: output_id.Want = if (self.opts.output) |spec| output_id.parseSpec(spec) else blk: {
            if (loadTobiiText(self.gpa)) |text| {
                defer self.gpa.free(text);
                saved = output_id.parseSaved(self.gpa, text);
            }
            break :blk saved.want();
        };
        if (want.isEmpty()) {
            const f = mons.focused orelse return null;
            self.noteOutput("no output configured, using the focused one", false);
            return mons.monitors[f];
        }
        var cands: [16]output_id.Candidate = undefined;
        const n = @min(mons.monitors.len, cands.len);
        for (mons.monitors[0..n], 0..) |m, i| cands[i] = .{ .connector = m.name, .desc = m.desc };
        const r = output_id.resolve(cands[0..n], want);
        var buf: [512]u8 = undefined;
        self.noteOutput(output_id.explain(&buf, cands[0..n], want, r), r == null or r.?.stale);
        const m = r orelse return null;
        return mons.monitors[m.index];
    }

    /// Log `line` once (until it changes).
    fn noteOutput(self: *Server, line: []const u8, warn: bool) void {
        if (std.mem.eql(u8, line, self.out_note[0..self.out_note_len])) return;
        const k = @min(line.len, self.out_note.len);
        @memcpy(self.out_note[0..k], line[0..k]);
        self.out_note_len = k;
        if (warn) log.warn("{s}", .{line}) else log.info("{s}", .{line});
    }

    // ── Follow mode ─────────────────────────────────────────────────

    fn startFollow(self: *Server, j: Jump) void {
        var msg_buf: [256]u8 = undefined;
        if (self.follow != null) self.stopFollow(.superseded, null);
        if (self.src == null) return self.finish(j, "noop tobiifreed not connected");
        // Monitor geometry once per session.
        var mons = self.backend.monitors() catch |err| {
            const msg = std.fmt.bufPrint(&msg_buf, "noop compositor unreachable ({})", .{err}) catch "noop";
            return self.finish(j, msg);
        };
        const mon = self.resolveOutput(&mons) orelse {
            mons.deinit();
            return self.finish(j, "noop tracker's output not present");
        };
        const cur = if (j.dry) layout.mapNorm(mon, 0.5, 0.5) else self.backend.cursorPos() catch layout.mapNorm(mon, 0.5, 0.5);
        self.follow = .{
            .mons = mons,
            .mon = mon,
            .filter = follow.Filter.init(self.opts.filter, self.opts.params),
            .easer = follow.Easer.init(cur),
            .session = .{ .started_ns = j.t_start, .timeout_ms = if (j.timeout_ms > 0) j.timeout_ms else self.opts.follow_timeout_ms, .dry = j.dry },
            .last_step = nowNs(),
            .last_sent = cur,
            .min_deg = j.min_deg,
            .glide_ms = j.glide_ms,
            .curve = j.curve,
            .notify = .{ .enabled = j.notify, .dry = j.dry },
            .mm_per_px = blk: {
                const ls = mon.logicalSize();
                break :blk .{ self.opts.params.width_mm / ls[0], self.opts.params.height_mm / ls[1] };
            },
        };
        // Open the keyboard now so the notification at the first move is a
        // single write.
        if (j.notify and !j.dry) _ = self.hid.prepare();
        // Seed from the current fixation, if any: the cursor sets off at once.
        const f = &self.follow.?;
        var seeded = false;
        if (self.opts.follow_filter == .fixation) switch (select.select(&self.ring, nowNs(), self.opts.params)) {
            .ok => |pick| {
                const c = f.filter.seed(&[_]select.Sample{.{ .t_ns = nowNs(), .x = pick.x, .y = pick.y }});
                f.fixations += 1;
                f.first = false;
                const px = layout.mapNorm(mon, c[0], c[1]);
                if (follow.farEnough(cur, px, f.mm_per_px, 0, f.min_deg)) {
                    self.moveTo(f, px, self.opts.ease.first_tau_ms);
                    seeded = true;
                } else f.near += 1;
            },
            else => {},
        };
        var min_buf: [48]u8 = undefined;
        const min_txt = std.fmt.bufPrint(&min_buf, "{s}{s}{s}", .{
            if (j.min_deg > 0) ", min distance" else "",
            if (j.glide_ms > 0) ", glide" else "",
            if (j.notify) ", HID notify" else "",
        }) catch "";
        const msg = std.fmt.bufPrint(&msg_buf, "following on {s} from {d:.0},{d:.0}{s}{s}{s}", .{
            mon.name, cur[0], cur[1], min_txt, if (seeded or self.opts.follow_filter == .device) "" else ", waiting for a fixation", if (j.dry) " [dry run]" else "",
        }) catch "following";
        self.finish(j, msg);
        if (seeded) self.followStep(null);
    }

    /// A valid sample while following.
    /// Default follow: like tobiifree-overlay, the cursor goes straight to
    /// the device-filtered gaze of every valid sample (invalid: holds).
    fn followDevice(self: *Server, g: select.Sample) void {
        const f = if (self.follow) |*ff| ff else return;
        f.updates += 1; // valid samples followed
        const px = layout.mapNorm(f.mon, g.x, g.y);
        if (!self.followGate(f, px, g.view_mm)) return;
        self.moveTo(f, px, 0);
        self.followStep(g.t_ns);
    }

    /// --follow-filter fixation.
    fn followSample(self: *Server, g: select.Sample) void {
        const f = if (self.follow) |*ff| ff else return;
        const e = f.filter.update(g);
        const target = e.target orelse return;
        const px = layout.mapNorm(f.mon, target[0], target[1]);
        if (e.kind != .held and !self.followGate(f, px, g.view_mm)) return;
        switch (e.kind) {
            .new_fixation => {
                f.fixations += 1;
                const tau = if (f.first) self.opts.ease.first_tau_ms else self.opts.ease.saccade_tau_ms;
                f.first = false;
                self.moveTo(f, px, tau);
                if (f.session.dry) log.info("follow: fixation {d} at {d:.0},{d:.0} (gaze {d:.3},{d:.3})", .{ f.fixations, px[0], px[1], target[0], target[1] });
            },
            .update => {
                f.updates += 1;
                self.moveTo(f, px, self.opts.ease.fix_tau_ms);
            },
            .held => return,
        }
        self.followStep(g.t_ns);
    }

    /// The decision to move to `px`: notify the keyboard first (once per
    /// session), then glide (--glide-ms) or ease with `tau`.
    fn moveTo(self: *Server, f: *Follow, px: [2]f64, tau: f64) void {
        const now = nowNs();
        const cur = if (f.glide) |g| g.at(now) else f.easer.pos;
        if (f.notify.take(cur, px)) {
            f.notify_ok = self.hid.send(hid.CMD_MOVED);
            f.notify_ms = msSince(f.session.started_ns, nowNs());
        } else if (f.notify.enabled and f.notify.dry and f.notify_ms == null and
            (@abs(px[0] - cur[0]) >= 1 or @abs(px[1] - cur[1]) >= 1))
        {
            f.notify_ms = msSince(f.session.started_ns, now); // would have notified
        }
        if (f.glide_ms > 0) {
            if (f.glide) |*g| if (!g.done(now)) {
                g.retarget(px, now);
                return;
            };
            if (@abs(px[0] - cur[0]) < 1 and @abs(px[1] - cur[1]) < 1) return;
            f.glide = follow.Glide.start(cur, px, now, f.glide_ms, f.curve);
            f.glides += 1;
            return;
        }
        f.easer.setTarget(px, tau);
    }

    /// --min-distance-deg: true when `px` is far enough from the cursor to
    /// move. The cursor is re-read from the compositor (~0.1 ms) because
    /// the person may move the pointer during a follow (that is the point
    /// of MAGIC pointing: gaze for the coarse jump, trackpad for the last
    /// degrees); comparing with where we left it would fight the trackpad.
    /// In a dry run nothing moves, so the tracked position is used.
    fn followGate(self: *Server, f: *Follow, px: [2]f64, view_mm: f64) bool {
        if (!(f.min_deg > 0)) return true;
        var cur = f.easer.pos;
        if (!f.session.dry) {
            if (self.backend.cursorPos()) |p| {
                if (@abs(p[0] - f.last_sent[0]) > 1 or @abs(p[1] - f.last_sent[1]) > 1) {
                    f.moved_by_user += 1;
                    // Ease from where the cursor really is.
                    f.easer = follow.Easer.init(p);
                    f.glide = null;
                    f.last_sent = p;
                }
                cur = p;
            } else |_| {}
        }
        if (follow.farEnough(cur, px, f.mm_per_px, view_mm, f.min_deg)) return true;
        f.near += 1;
        return false;
    }

    /// Advance the easing to now and send the cursor if its pixel changed.
    /// `sample_t`: arrival of the sample that triggered this step (lag stats).
    fn followStep(self: *Server, sample_t: ?i64) void {
        const f = if (self.follow) |*ff| ff else return;
        const now = nowNs();
        if (f.glide) |g| {
            // The glide drives the position; the easer just follows it.
            const p = g.at(now);
            f.easer = follow.Easer.init(p);
            if (g.done(now)) f.glide = null;
        } else _ = f.easer.step(msSince(f.last_step, now));
        f.last_step = now;
        const p = f.easer.pixel();
        if (p[0] == f.last_sent[0] and p[1] == f.last_sent[1]) return;
        f.last_sent = p;
        if (!f.session.dry) {
            self.backend.moveCursor(p[0], p[1]) catch |err| {
                log.warn("follow: move failed ({})", .{err});
                return self.stopFollow(.move_failed, null);
            };
        }
        const done = nowNs();
        f.session.recordMove(now, done);
        if (sample_t) |t| {
            f.session.lag_ns_sum += done - t;
            f.session.lag_n += 1;
        }
    }

    fn stopFollow(self: *Server, why: follow.StopReason, j: ?Jump) void {
        var f = self.follow orelse return;
        self.follow = null;
        defer f.mons.deinit();
        const now = nowNs();
        const s = f.session;
        var buf: [768]u8 = undefined;
        var hb: [64]u8 = undefined;
        const hid_txt = if (!f.notify.enabled) "off" else if (f.notify_ms) |t|
            std.fmt.bufPrint(&hb, "{s} at {d:.1} ms", .{ if (s.dry) "would be sent" else if (f.notify_ok) "sent" else "FAILED", t }) catch "?"
        else
            "not sent (no move)";
        const first_ms = if (s.first_move_ns) |t| msSince(s.started_ns, t) else -1;
        const msg = std.fmt.bufPrint(&buf, "stopped ({s}) after {d:.2} s at {d:.0},{d:.0}: {s} filter, {d} fixations, {d} updates, {d} moves, {d} within {d:.1} deg, {d} pointer moves by the person, {d} glides, HID {s}{s}; first move {d:.1} ms after start; move {d:.3} ms avg / {d:.3} max; sample→cursor {d:.2} ms avg", .{
            @tagName(why),
            msSince(s.started_ns, now) / 1000,
            f.last_sent[0],
            f.last_sent[1],
            @tagName(self.opts.follow_filter),
            f.fixations,
            f.updates,
            s.moves,
            f.near,
            f.min_deg,
            f.moved_by_user,
            f.glides,
            hid_txt,
            if (s.dry) " (dry run)" else "",
            first_ms,
            if (s.moves > 0) @as(f64, @floatFromInt(s.move_ns_sum)) / @as(f64, @floatFromInt(s.moves)) / 1e6 else 0,
            @as(f64, @floatFromInt(s.move_ns_max)) / 1e6,
            if (s.lag_n > 0) @as(f64, @floatFromInt(s.lag_ns_sum)) / @as(f64, @floatFromInt(s.lag_n)) / 1e6 else 0,
        }) catch "stopped";
        if (j) |jj| self.finish(jj, msg) else log.info("follow: {s}", .{msg});
    }

    fn finish(_: *Server, j: Jump, msg: []const u8) void {
        log.info("{s}: {s}", .{ j.verb, msg });
        if (j.fd) |fd| {
            var buf: [1024]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s}\n", .{msg}) catch "\n";
            reply(fd, line);
            posix.close(fd);
        }
    }

    fn deinit(self: *Server) void {
        if (self.pending) |p| self.finish(p, "noop server exiting");
        self.pending = null;
        self.stopFollow(.exiting, null);
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
        .hid = .{ .cfg = opts.hid },
    };
    g_server = &srv;
    defer srv.deinit();

    log.info("follow: filter {s}; fixation filter: radius {d:.2} deg, deadband {d:.2} deg, confirm {d}, window {d}, tau fixation {d:.0} / saccade {d:.0} / first {d:.0} ms, timeout {d} ms", .{
        @tagName(opts.follow_filter), opts.filter.radius_deg, opts.filter.deadband_deg, opts.filter.confirm, opts.filter.window, opts.ease.fix_tau_ms, opts.ease.saccade_tau_ms, opts.ease.first_tau_ms, opts.follow_timeout_ms,
    });
    log.info("listening on {s}; output {s}, window {d:.0} ms, max dispersion {d:.2} deg, settle {d:.0} ms, display {d:.0}x{d:.0} mm{s}", .{
        path,
        opts.output orelse "(tobii.json)",
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
    \\       tobiifree-warp follow-start [--dry-run] [--min-distance-deg N] [--timeout-ms MS]
    \\                                          cursor follows the gaze (key press); with
    \\                                          N > 0 only when the gaze is more than N deg
    \\                                          from the cursor (MAGIC pointing); --timeout-ms
    \\                                          overrides the server's --follow-timeout-ms
    \\                                          [--glide-ms N] [--glide-curve inout|in]: glide
    \\                                          to the gaze over N ms instead of jumping
    \\                                          [--notify-hid]: on the first real move, send a
    \\                                          Raw HID 'M' report to the keyboard
    \\       tobiifree-warp hid-probe [--hid-* …]    print the hidraw node --notify-hid uses
    \\       tobiifree-warp follow-stop                ...until this (key release)
    \\
    \\server options:
    \\  --output NAME|desc:DESC   output the tracker is on, by connector or monitor
    \\                            description (default: tobii.json "output_desc",
    \\                            then "output"; the focused one if neither)
    \\  --window-ms MS            gaze history considered on a jump (150)
    \\  --max-dispersion-deg DEG  fixation threshold, max spread of the samples (1.5)
    \\  --stale-ms MS             newest sample older than this: no gaze, do nothing (300)
    \\  --settle-ms MS            how long a jump may wait for the eye to settle (200)
    \\  --dry-run                 log the target, never move the cursor
    \\
    \\follow mode (cursor follows the gaze between follow-start and follow-stop):
    \\  --follow-filter MODE      device: the device-filtered gaze of every sample, as
    \\                            tobiifree-overlay draws it (default); fixation: the
    \\                            fixation filter below
    \\  (fixation filter only:)
    \\  --radius-deg DEG          a sample this close to the fixation joins it (1.5)
    \\  --deadband-deg DEG        within a fixation, move only when the median drifts this far (0.4)
    \\  --confirm N               samples that must agree to start a new fixation (2)
    \\  --fix-window N            fixation target = median of its last N samples (12)
    \\  --fix-tau-ms MS           easing time constant within a fixation (80)
    \\  --saccade-tau-ms MS       easing to a new fixation, 0 = jump (0)
    \\  --first-tau-ms MS         easing of the first move (60)
    \\  --glide-step-ms MS        easing / glide step (8, ~120 Hz)
    \\  --hid-id BUS:VID:PID      keyboard for --notify-hid (0003:0000FEED:00000130)
    \\  --hid-interface N|any     its Raw HID USB interface (1; any: by descriptor)
    \\  (both:)
    \\  --follow-timeout-ms MS    stop by itself after this long, missed release (10000)
    \\
;

fn parseF0(args: *std.process.ArgIterator, name: []const u8) ?f64 {
    const v = args.next() orelse {
        std.debug.print("{s} needs a value\n", .{name});
        return null;
    };
    const f = std.fmt.parseFloat(f64, v) catch {
        std.debug.print("{s}: bad number '{s}'\n", .{ name, v });
        return null;
    };
    if (!(f >= 0)) {
        std.debug.print("{s}: must be >= 0\n", .{name});
        return null;
    }
    return f;
}

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

/// `hid-probe`: which hidraw node --notify-hid would write to (no write).
fn hidProbe(opts: Opts) u8 {
    var buf: [256]u8 = undefined;
    if (hid.find(opts.hid, &buf)) |p| {
        std.fs.File.stdout().writeAll(p) catch {};
        std.fs.File.stdout().writeAll("\n") catch {};
        return 0;
    }
    std.debug.print("no hidraw device {s} on interface {?d}\n", .{ opts.hid.hid_id, opts.hid.iface });
    return 1;
}

pub fn main() u8 {
    var args = std.process.args();
    _ = args.next();
    var opts = Opts{};
    var mode: enum { serve, jump, follow_start, follow_stop, hid_probe } = .serve;
    var min_deg: f64 = 0;
    var timeout_ms: f64 = 0;
    var glide_ms: f64 = 0;
    var curve_in = false;
    var notify_hid = false;
    var first = true;
    while (args.next()) |a| {
        defer first = false;
        if (first and std.mem.eql(u8, a, "jump")) {
            mode = .jump;
        } else if (first and std.mem.eql(u8, a, "follow-start")) {
            mode = .follow_start;
        } else if (first and std.mem.eql(u8, a, "follow-stop")) {
            mode = .follow_stop;
        } else if (first and std.mem.eql(u8, a, "hid-probe")) {
            mode = .hid_probe;
        } else if (first and std.mem.eql(u8, a, "serve")) {
            mode = .serve;
        } else if (std.mem.eql(u8, a, "--glide-ms") and mode == .follow_start) {
            glide_ms = parseF0(&args, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--glide-curve") and mode == .follow_start) {
            const v = args.next() orelse "";
            if (std.mem.eql(u8, v, "in")) curve_in = true else if (!std.mem.eql(u8, v, "inout")) {
                std.debug.print("--glide-curve: inout or in\n", .{});
                return 2;
            }
        } else if (std.mem.eql(u8, a, "--notify-hid") and mode == .follow_start) {
            notify_hid = true;
        } else if (std.mem.eql(u8, a, "--hid-id") and (mode == .serve or mode == .hid_probe)) {
            opts.hid.hid_id = args.next() orelse return 2;
        } else if (std.mem.eql(u8, a, "--hid-interface") and (mode == .serve or mode == .hid_probe)) {
            const v = args.next() orelse return 2;
            opts.hid.iface = if (std.mem.eql(u8, v, "any")) null else std.fmt.parseInt(u8, v, 10) catch return 2;
        } else if (std.mem.eql(u8, a, "--hid-sysfs") and (mode == .serve or mode == .hid_probe)) {
            opts.hid.sysfs_dir = args.next() orelse return 2;
        } else if (std.mem.eql(u8, a, "--hid-dev-dir") and (mode == .serve or mode == .hid_probe)) {
            opts.hid.dev_dir = args.next() orelse return 2;
        } else if (std.mem.eql(u8, a, "--glide-step-ms") and mode == .serve) {
            opts.ease.tick_ms = @intFromFloat(std.math.clamp(parseF(&args, a) orelse return 2, 1, 100));
        } else if (std.mem.eql(u8, a, "--timeout-ms") and mode == .follow_start) {
            timeout_ms = parseF(&args, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--min-distance-deg") and mode == .follow_start) {
            min_deg = parseF0(&args, a) orelse return 2;
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
        } else if (std.mem.eql(u8, a, "--follow-filter") and mode == .serve) {
            const v = args.next() orelse "";
            if (std.mem.eql(u8, v, "device")) opts.follow_filter = .device else if (std.mem.eql(u8, v, "fixation")) opts.follow_filter = .fixation else {
                std.debug.print("--follow-filter: device or fixation\n", .{});
                return 2;
            }
        } else if (std.mem.eql(u8, a, "--radius-deg") and mode == .serve) {
            opts.filter.radius_deg = parseF(&args, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--deadband-deg") and mode == .serve) {
            opts.filter.deadband_deg = parseF0(&args, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--confirm") and mode == .serve) {
            opts.filter.confirm = @intFromFloat(@max(1, @min(8, parseF(&args, a) orelse return 2)));
        } else if (std.mem.eql(u8, a, "--fix-window") and mode == .serve) {
            opts.filter.window = @intFromFloat(@max(1, @min(64, parseF(&args, a) orelse return 2)));
        } else if (std.mem.eql(u8, a, "--fix-tau-ms") and mode == .serve) {
            opts.ease.fix_tau_ms = parseF0(&args, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--saccade-tau-ms") and mode == .serve) {
            opts.ease.saccade_tau_ms = parseF0(&args, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--first-tau-ms") and mode == .serve) {
            opts.ease.first_tau_ms = parseF0(&args, a) orelse return 2;
        } else if (std.mem.eql(u8, a, "--follow-timeout-ms") and mode == .serve) {
            opts.follow_timeout_ms = @intFromFloat(@min(3600e3, parseF(&args, a) orelse return 2));
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.fs.File.stdout().writeAll(usage) catch {};
            return 0;
        } else {
            std.debug.print("unknown argument '{s}'\n{s}", .{ a, usage });
            return 2;
        }
    }
    return switch (mode) {
        .jump => client("jump", opts.dry_run, ""),
        .follow_start => blk: {
            var tb: [200]u8 = undefined;
            var w = std.Io.Writer.fixed(&tb);
            if (min_deg > 0) w.print(" min={d}", .{min_deg}) catch {};
            if (timeout_ms > 0) w.print(" timeout={d:.0}", .{timeout_ms}) catch {};
            if (glide_ms > 0) w.print(" glide={d}", .{glide_ms}) catch {};
            if (curve_in) w.writeAll(" curve=in") catch {};
            if (notify_hid) w.writeAll(" notify") catch {};
            break :blk client("follow-start", opts.dry_run, w.buffered());
        },
        .follow_stop => client("follow-stop", false, ""),
        .hid_probe => hidProbe(opts),
        .serve => serve(std.heap.page_allocator, opts),
    };
}

test {
    _ = select;
    _ = layout;
    _ = gaze;
    _ = follow;
    _ = hid;
}
