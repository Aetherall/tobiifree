// tobiifreed — eye tracker daemon.
//
// Owns the USB connection to the Tobii ET5 and exposes gaze data and the
// tracker's commands over a unix socket (and optionally WebSocket). Multiple
// clients can connect simultaneously.
//
// Usage:
//   tobiifreed                           # run with ~/.config/tobii.json
//   tobiifreed --ws [addr:]port          # also serve WebSocket clients
//   tobiifreed --keep-device-area        # don't push the config's display area at startup
//   tobiifreed --no-restore-calibration  # don't cal_apply the stored calibration at startup
//   tobiifreed --init-config             # create default config file
//   tobiifreed --no-device               # testing: never open the tracker (daemon-side commands only)
//   tobiifreed --no-device --fake-gaze X,Y  # testing: + 30 Hz synthetic samples at (X, Y), and the
//                                        #   stored calibration counts as applied
//
// Threads:
//   USB thread  — tracker.poll(): feeds USB data to the core, which calls
//                 onGaze / onResponse. Both only copy into queues and poke
//                 the notify pipe; no client I/O happens on this thread.
//   main thread — client sockets, request building/sending, response routing,
//                 config/calibration persistence.
//   job thread  — one at a time: start/finish calibration, cal_apply. These
//                 own the USB transport while they run (gaze pauses);
//                 meanwhile device commands get Err.busy.
//   The USB thread also does (re)connection and the restore of area +
//   calibration (startup, reconnect).
//
// Persistence:
//   display area — every successful set_display_area[_corners] from a client
//     is written to ~/.config/tobii.json as explicit corners (+ the legacy
//     w/h/cx/cy fields). At startup the config's area is pushed to the device
//     whenever it differs from what the device reports (config = source of
//     truth); --keep-device-area restores the old "only when reset" rule.
//   calibration — a successful finish_calibration stores the blob at
//     $XDG_STATE_HOME/tobiifree/calibration.bin (~/.local/state/…). At startup
//     and after every reconnect, if the file exists, the USB thread
//     cal_apply's it *after* the sockets are up (~0.3 s for a 270 KB blob on
//     an ET5): clients can connect at once, gaze starts flowing when the apply
//     ends (or fails / times out after 120 s), and device commands sent
//     meanwhile get Err.busy.
//
// Correction map: $XDG_STATE_HOME/tobiifree/correction.json (written through
// set_correction by tobiifree-setup) describes a residual field measured
// after the calibration; while active, the 2D gaze fields of every sample
// are corrected (grid lookup, see driver/src/correction.zig) and flagged
// GAZE_BIT_CORRECTED, except for clients that asked for raw gaze
// (set_gaze_raw). It is active only while the device runs the calibration
// blob it was measured with (SHA-256) and the display area is the same; a new
// finish_calibration or a different display area deletes it (also checked at
// startup); a client cal_apply of another blob just deactivates it.
//
// Hotplug: when the tracker disappears (USB error NO_DEVICE/IO) device
// commands get Err.no_device, the daemon polls for the tracker every second,
// and on return redoes the handshake, pushes the config's display area and
// re-applies the stored calibration (a power-cycled ET5 forgets both). The
// daemon also starts without a tracker and waits for it.

const std = @import("std");
const core = @import("tobiifree_core");
const Tracker = @import("tracker").Tracker;
const LibusbTransport = @import("libusb_transport").LibusbTransport;
const Server = @import("server").Server;
const WsServer = @import("ws_server").WsServer;
const config = @import("config.zig");
const proto = @import("daemon_protocol");
const corr_mod = @import("correction");

const log = std.log.scoped(.tobiifreed);

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const gpa = std.heap.c_allocator;

// WsServer.sendToClient frames data into a fixed `[4 + 8192]u8` buffer, and the
// data it receives is `HEADER_SIZE + 1 (cmd_type) + payload`. Bound payloads
// sent over WS accordingly so encodeWsFrame never writes past that buffer.
const WS_MAX_RESPONSE_PAYLOAD = 8192 - proto.HEADER_SIZE - 1;

/// Max TTP response payload routed back to a client (display area: 164 B).
const RESP_MAX = 8192;
/// Device request timeout before the client gets Err.timeout.
const REQUEST_TIMEOUT_MS = 5000;

// ── State ───────────────────────────────────────────────────────────

var transport: LibusbTransport = undefined;
var tracker: Tracker = undefined;
var server: Server = undefined;
var ws: ?WsServer = null;
var quit: bool = false;
var notify_pipe: [2]std.posix.fd_t = .{ -1, -1 };

fn notifyMain() void {
    _ = std.posix.write(notify_pipe[1], &.{1}) catch {};
}

// ── Gaze ring buffer: USB thread → main thread ─────────────────────

const GAZE_RING_SIZE = 64;
var gaze_ring: [GAZE_RING_SIZE]core.GazeSample = undefined;
var gaze_write: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var gaze_read: u32 = 0; // only touched by main thread
var gaze_count: u64 = 0;

fn onGaze(sample: *const core.GazeSample) void {
    const w = gaze_write.load(.monotonic);
    gaze_ring[w % GAZE_RING_SIZE] = sample.*;
    gaze_write.store(w +% 1, .release);
    notifyMain();
}

fn drainGaze() void {
    const w = gaze_write.load(.acquire);
    while (gaze_read != w) {
        const sample = &gaze_ring[gaze_read % GAZE_RING_SIZE];
        gaze_count += 1;
        if (gaze_count <= 3 or gaze_count % 500 == 0) {
            log.debug("gaze #{d}: vL={d} vR={d} x={d:.3} y={d:.3}", .{
                gaze_count, sample.validity_L, sample.validity_R,
                sample.gaze_point_2d_norm[0], sample.gaze_point_2d_norm[1],
            });
        }
        if (applied_gen.load(.acquire) != corr_seen_gen) updateCorrectionActive();
        var corrected: core.GazeSample = undefined;
        const cs: ?*const core.GazeSample = if (correctSample(sample, &corrected)) &corrected else null;
        server.broadcastGaze(sample, cs);
        if (ws) |*w_| w_.broadcastGaze(sample, cs);
        gaze_read +%= 1;
    }
}

// ── Client replies ──────────────────────────────────────────────────

/// Write all bytes to a (possibly non-blocking) socket fd.
/// Client sockets are accepted with SOCK_NONBLOCK, so write() may return EAGAIN
/// when the kernel send buffer is full. We use poll(POLLOUT) to wait until space
/// is available before retrying rather than silently dropping bytes.
fn writeAll(fd: std.posix.fd_t, data: []const u8) void {
    var remaining = data;
    while (remaining.len > 0) {
        const n = std.posix.write(fd, remaining) catch |err| {
            if (err == error.WouldBlock) {
                var pfd = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                const nready = std.posix.poll(&pfd, 5000) catch return;
                if (nready == 0) return;
                const bad = std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
                if (pfd[0].revents & bad != 0) return;
                continue;
            }
            return; // real error (EPIPE, EBADF, …) — give up
        };
        if (n == 0) return;
        remaining = remaining[n..];
    }
}

const Client = struct {
    fd: std.posix.fd_t,
    is_ws: bool,
};

fn sendError(c: Client, cmd_type: u8, code: u32) void {
    var err_buf: [proto.HEADER_SIZE + 1 + 4]u8 = undefined;
    proto.encodeError(&err_buf, cmd_type, code);
    if (c.is_ws) {
        if (ws) |*w| w.sendToClient(c.fd, &err_buf);
    } else {
        writeAll(c.fd, &err_buf);
    }
    log.debug("error 0x{x} for cmd=0x{x:0>2} to fd={}", .{ code, cmd_type, c.fd });
}

/// Send a Srv.response with `payload` (any size on the unix socket).
fn sendReply(c: Client, cmd_type: u8, payload: []const u8) void {
    if (c.is_ws) {
        // WS framing requires a contiguous buffer. Calibration blobs are too
        // large to fit; reply with an explicit error so the client doesn't
        // hang waiting for a response that will never arrive.
        if (payload.len > WS_MAX_RESPONSE_PAYLOAD) {
            log.warn("WS payload too large ({} bytes), sending error", .{payload.len});
            sendError(c, cmd_type, proto.Err.too_large);
            return;
        }
        var buf: [proto.HEADER_SIZE + 1 + 8192]u8 = undefined;
        const msg_len = proto.encodeResponse(&buf, cmd_type, payload);
        if (ws) |*w| w.sendToClient(c.fd, buf[0..msg_len]);
        return;
    }
    // Unix socket: header + cmd_type, then the payload. Two writes on a
    // SOCK_STREAM socket are ordered and contiguous for the reader.
    var hdr: [proto.HEADER_SIZE + 1]u8 = undefined;
    proto.encodeHeader(hdr[0..proto.HEADER_SIZE], @intFromEnum(proto.Srv.response), @intCast(1 + payload.len));
    hdr[proto.HEADER_SIZE] = cmd_type;
    writeAll(c.fd, &hdr);
    if (payload.len > 0) writeAll(c.fd, payload);
}

// ── Pending device requests ─────────────────────────────────────────
//
// Single request/response commands are sent from the main thread and
// registered here; the USB thread's onResponse takes the entry and queues
// the payload for the main thread, which builds the client reply.

const Kind = enum {
    /// get_display_area: reply 9×f64.
    get_area,
    /// 0x5a0 ack of a set: non-zero status → error to client; else send
    /// the readback.
    set_ack,
    /// get_display_area sent after a set's ack: reply 9×f64 (the area the
    /// device actually holds) under the set's cmd_type, and persist it.
    set_readback,
    /// Reply with the raw TTP payload.
    raw,
    /// Stimulus points: reply decoded points + raw payload.
    stimulus,
};

const PendingEntry = struct {
    request_id: u32,
    client: Client,
    cmd_type: u8,
    kind: Kind,
    deadline_ms: i64,
};

const MAX_PENDING = 64;
var pending: [MAX_PENDING]?PendingEntry = [_]?PendingEntry{null} ** MAX_PENDING;
var pending_mutex: std.Thread.Mutex = .{};

fn addPending(e: PendingEntry) bool {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    for (&pending) |*slot| {
        if (slot.* == null) {
            slot.* = e;
            return true;
        }
    }
    log.warn("pending table full, dropping request_id={}", .{e.request_id});
    return false;
}

fn takePending(request_id: u32) ?PendingEntry {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    for (&pending) |*slot| {
        if (slot.*) |entry| {
            if (entry.request_id == request_id) {
                slot.* = null;
                return entry;
            }
        }
    }
    return null;
}

fn pendingCount() usize {
    pending_mutex.lock();
    defer pending_mutex.unlock();
    var n: usize = 0;
    for (pending) |slot| {
        if (slot != null) n += 1;
    }
    return n;
}

/// Expire requests the device never answered (main thread).
fn sweepPending() void {
    const now = std.time.milliTimestamp();
    var expired: [MAX_PENDING]PendingEntry = undefined;
    var n: usize = 0;
    {
        pending_mutex.lock();
        defer pending_mutex.unlock();
        for (&pending) |*slot| {
            if (slot.*) |e| {
                if (now > e.deadline_ms) {
                    expired[n] = e;
                    n += 1;
                    slot.* = null;
                }
            }
        }
    }
    for (expired[0..n]) |e| {
        log.warn("request_id={} (cmd=0x{x:0>2}, {s}) timed out", .{ e.request_id, e.cmd_type, @tagName(e.kind) });
        sendError(e.client, e.cmd_type, proto.Err.timeout);
    }
}

// ── Response queue: USB thread → main thread ────────────────────────

const RespMsg = struct {
    entry: PendingEntry,
    status: u32,
    len: u32,
    truncated: bool,
    data: [RESP_MAX]u8,
};

const RESP_QUEUE = 16;
var resp_queue: [RESP_QUEUE]RespMsg = undefined;
var resp_head: usize = 0; // next to pop
var resp_count: usize = 0;
var resp_mutex: std.Thread.Mutex = .{};

/// Response hook (USB thread, or a job thread's state machine restoring it).
fn onResponse(request_id: u32, payload_ptr: [*]const u8, payload_len: u32) void {
    const status = core.response_status();
    const entry = takePending(request_id) orelse {
        log.debug("response for unknown request_id={}, ignoring", .{request_id});
        return;
    };
    resp_mutex.lock();
    defer resp_mutex.unlock();
    if (resp_count == RESP_QUEUE) {
        log.warn("response queue full, dropping request_id={}", .{request_id});
        return; // client times out
    }
    const m = &resp_queue[(resp_head + resp_count) % RESP_QUEUE];
    const n = @min(payload_len, RESP_MAX);
    m.entry = entry;
    m.status = status;
    m.len = n;
    m.truncated = n < payload_len;
    @memcpy(m.data[0..n], payload_ptr[0..n]);
    resp_count += 1;
    notifyMain();
}

fn popResponse(out: *RespMsg) bool {
    resp_mutex.lock();
    defer resp_mutex.unlock();
    if (resp_count == 0) return false;
    out.* = resp_queue[resp_head];
    resp_head = (resp_head + 1) % RESP_QUEUE;
    resp_count -= 1;
    return true;
}

var resp_scratch: RespMsg = undefined; // main thread only

fn drainResponses() void {
    while (popResponse(&resp_scratch)) handleResponse(&resp_scratch);
}

fn decodeArea(payload: []const u8) ?config.Corners {
    var out: [9]f64 align(8) = undefined;
    if (core.decode_display_area(payload.ptr, payload.len, @ptrCast(&out)) == 0) return null;
    return out;
}

fn handleResponse(m: *const RespMsg) void {
    const e = m.entry;
    const payload = m.data[0..m.len];
    log.debug("response cmd=0x{x:0>2} kind={s} status=0x{x} len={} fd={}", .{
        e.cmd_type, @tagName(e.kind), m.status, m.len, e.client.fd,
    });

    if (m.status != 0) {
        log.warn("device rejected cmd=0x{x:0>2} ({s}): status 0x{x}", .{ e.cmd_type, @tagName(e.kind), m.status });
        sendError(e.client, e.cmd_type, m.status);
        return;
    }
    if (m.truncated) {
        sendError(e.client, e.cmd_type, proto.Err.too_large);
        return;
    }

    switch (e.kind) {
        .set_ack => _ = sendRequest(e.client, e.cmd_type, .set_readback, core.request_get_display_area()),
        .get_area, .set_readback => {
            const c = decodeArea(payload) orelse {
                log.warn("display area decode failed (len={})", .{payload.len});
                sendError(e.client, e.cmd_type, proto.Err.failed);
                return;
            };
            var out: [proto.DISPLAY_AREA_SIZE]u8 = undefined;
            proto.encodeDisplayArea(&out, c);
            sendReply(e.client, e.cmd_type, &out);
            if (e.kind == .set_readback) {
                log.info("display area set: TL=({d:.3},{d:.3},{d:.3}) TR=({d:.3},{d:.3},{d:.3}) BL=({d:.3},{d:.3},{d:.3})", .{
                    c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8],
                });
                cur_area = c;
                if (correction) |*cr| if (!corr_mod.areaMatches(cr.area, c)) deleteCorrection("the display area changed");
                updateCorrectionActive();
                config.saveDisplayArea(gpa, c) catch |err| {
                    log.err("failed to save display area to ~/{s}: {}", .{ config.CONFIG_REL_PATH, err });
                    return;
                };
                log.info("display area saved to ~/{s}", .{config.CONFIG_REL_PATH});
            }
        },
        .raw => sendReply(e.client, e.cmd_type, payload),
        .stimulus => sendStimulus(e.client, e.cmd_type, payload),
    }
}

// Stimulus reply: [u32 LE n][n × 8 f64 LE][raw TTP payload], each record
// x, y, status_L, a_L, b_L, status_R, a_R, b_R (see core.decode_cal_stimulus).
fn sendStimulus(c: Client, cmd_type: u8, payload: []const u8) void {
    const R = core.STIMULUS_RECORD_F64;
    var pts: [R * 32]f64 align(8) = undefined;
    const n = core.decode_cal_stimulus(payload.ptr, payload.len, @ptrCast(&pts), 32);
    log.info("calibration points: {} ({} raw bytes)", .{ n, payload.len });
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const r = pts[i * R ..][0..R];
        log.info("  [{}] ({d:.3}, {d:.3})  L {d:.0} ({d:.4}, {d:.4})  R {d:.0} ({d:.4}, {d:.4})", .{ i, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7] });
    }

    var buf: [4 + R * 32 * 8 + RESP_MAX]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], n, .little);
    var off: usize = 4;
    for (pts[0 .. R * n]) |v| {
        std.mem.writeInt(u64, buf[off..][0..8], @bitCast(v), .little);
        off += 8;
    }
    @memcpy(buf[off..][0..payload.len], payload);
    off += payload.len;
    sendReply(c, cmd_type, buf[0..off]);
}

// ── Calibration jobs (job thread) ───────────────────────────────────
//
// start/finish/apply drive multi-step state machines that own the USB
// transport (Tracker.beginCalibrating). They run one at a time on a job
// thread so the main loop keeps serving sockets. A queued job starts only
// once no single request is in flight (the state machines' response hooks
// don't filter by request_id).

const JobKind = enum { start_cal, cancel_cal, finish_cal, apply };

const Job = struct {
    kind: JobKind,
    client: Client = .{ .fd = -1, .is_ws = false },
    cmd_type: u8 = 0,
    /// apply: owned copy of the blob (freed on completion).
    blob: ?[]u8 = null,
};

var job_queued: ?Job = null; // main thread only
var job_current: Job = undefined; // owned by job thread while job_running
var job_running: bool = false; // main thread only
var job_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var job_ok: bool = false;
var job_started_ms: i64 = 0;
var job_queued_ms: i64 = 0;

fn deviceBusy() bool {
    return job_queued != null or job_running;
}

fn queueJob(j: Job) void {
    std.debug.assert(!deviceBusy());
    job_queued = j;
    job_queued_ms = std.time.milliTimestamp();
}

fn jobThreadFn() void {
    const j = job_current;
    core.clear_truncation(); // sticky flag; finish checks it for the blob
    job_ok = switch (j.kind) {
        .start_cal => tracker.startCalibration(),
        .cancel_cal => tracker.cancelCalibration(),
        .finish_cal => tracker.finishCalibration(),
        .apply => tracker.calApply(j.blob.?),
    };
    job_done.store(true, .release);
    notifyMain();
}

/// Start a queued job / complete a finished one (main thread, each loop).
fn serviceJobs() void {
    if (job_running and job_done.load(.acquire)) {
        job_running = false;
        job_done.store(false, .monotonic);
        completeJob(job_current, job_ok, std.time.milliTimestamp() - job_started_ms);
    }
    if (!job_running and dev_state.load(.acquire) == .up) {
        if (job_queued) |j| {
            // Wait for in-flight single requests to drain (they expire after
            // REQUEST_TIMEOUT_MS, so this can't stall forever).
            if (pendingCount() > 0 and std.time.milliTimestamp() - job_queued_ms < REQUEST_TIMEOUT_MS + 1000) return;
            job_queued = null;
            job_current = j;
            job_running = true;
            job_started_ms = std.time.milliTimestamp();
            log.info("job {s} started", .{@tagName(j.kind)});
            const t = std.Thread.spawn(.{}, jobThreadFn, .{}) catch |err| {
                log.err("failed to spawn job thread: {}", .{err});
                job_running = false;
                completeJob(j, false, 0);
                return;
            };
            t.detach();
        }
    }
}

fn completeJob(j: Job, ok: bool, elapsed_ms: i64) void {
    defer if (j.blob) |b| gpa.free(b);
    log.info("job {s} {s} in {d} ms", .{ @tagName(j.kind), if (ok) "succeeded" else "FAILED", elapsed_ms });

    switch (j.kind) {
        .start_cal, .cancel_cal, .apply => {
            if (ok) sendReply(j.client, j.cmd_type, &.{}) else sendError(j.client, j.cmd_type, proto.Err.failed);
            // start clears the device's calibration; apply installs `blob`.
            if (ok and j.kind == .start_cal) setAppliedSha(null);
            if (ok and j.kind == .apply) setAppliedSha(corr_mod.sha256Hex(j.blob.?));
        },
        .finish_cal => {
            if (!ok) {
                sendError(j.client, j.cmd_type, proto.Err.failed);
                return;
            }
            const blob = core.cal_finish_blob_ptr()[0..core.cal_finish_blob_len()];
            sendReply(j.client, j.cmd_type, blob);
            setAppliedSha(corr_mod.sha256Hex(blob));
            if (blob.len == 0 or core.had_truncation() != 0) {
                log.warn("finish_calibration: blob empty or truncated ({} bytes), not saving", .{blob.len});
                return;
            }
            var pbuf: [512]u8 = undefined;
            const path = config.calibrationPath(&pbuf) orelse return;
            config.writeFileAtomic(path, blob) catch |err| {
                log.err("failed to save calibration to {s}: {}", .{ path, err });
                return;
            };
            log.info("calibration saved to {s} ({} bytes)", .{ path, blob.len });
            if (correction != null) deleteCorrection("a new calibration was saved");
        },
    }
}

// ── Correction map ──────────────────────────────────────────────────

const Correction = struct {
    parsed: std.json.Parsed(corr_mod.File),
    text: []u8,
    grid: *corr_mod.Grid,
    sha: [64]u8,
    area: config.Corners,

    fn deinit(self: *Correction) void {
        self.parsed.deinit();
        gpa.free(self.text);
        gpa.destroy(self.grid);
    }
};

var correction: ?Correction = null; // main thread only
/// set_correction_enabled (global, runtime only).
var correction_enabled = true;
/// Display area the device holds (config at startup, then successful sets).
var cur_area: ?config.Corners = null;
var corr_active = false;
var corr_seen_gen: u32 = 0xffff_ffff;

// SHA-256 of the calibration blob the device runs, as far as the daemon
// knows. Written by the USB thread (restore) and the main thread (jobs).
var applied_sha_mutex: std.Thread.Mutex = .{};
var applied_sha: ?[64]u8 = null;
var applied_gen = std.atomic.Value(u32).init(0);

fn setAppliedSha(s: ?[64]u8) void {
    applied_sha_mutex.lock();
    applied_sha = s;
    applied_sha_mutex.unlock();
    _ = applied_gen.fetchAdd(1, .release);
}

fn getAppliedSha() ?[64]u8 {
    applied_sha_mutex.lock();
    defer applied_sha_mutex.unlock();
    return applied_sha;
}

/// Recompute whether the stored map applies (blob, area, enabled).
fn updateCorrectionActive() void {
    corr_seen_gen = applied_gen.load(.acquire);
    const was = corr_active;
    corr_active = false;
    var why: []const u8 = "no map";
    if (correction) |*c| {
        const a = getAppliedSha();
        if (!correction_enabled) {
            why = "disabled";
        } else if (a == null or !std.mem.eql(u8, &a.?, &c.sha)) {
            why = "the device runs another calibration";
        } else if (cur_area == null or !corr_mod.areaMatches(cur_area.?, c.area)) {
            why = "another display area";
        } else corr_active = true;
    }
    if (was != corr_active) {
        if (corr_active) log.info("correction map active", .{}) else log.info("correction map inactive ({s})", .{why});
    }
}

fn correctField(g: *const corr_mod.Grid, p: *[2]f64) bool {
    const d = g.sample(p[0], p[1]) orelse return false;
    p[0] -= d[0];
    p[1] -= d[1];
    return true;
}

/// Corrected copy of `s` into `out`; false if nothing was corrected.
fn correctSample(s: *const core.GazeSample, out: *core.GazeSample) bool {
    if (!corr_active) return false;
    const g = correction.?.grid;
    out.* = s.*;
    const l = s.validity_L == 0;
    const r = s.validity_R == 0;
    var any = false;
    if (l or r) {
        if (s.present_mask & core.GAZE_BIT_GAZE_2D != 0) any = correctField(g, &out.gaze_point_2d_norm) or any;
        if (s.present_mask & core.GAZE_BIT_GAZE_2D_UNFILTERED != 0) any = correctField(g, &out.gaze_point_2d_unfiltered) or any;
    }
    if (l and s.present_mask & core.GAZE_BIT_GAZE_2D_L != 0) any = correctField(g, &out.gaze_point_2d_L_norm) or any;
    if (r and s.present_mask & core.GAZE_BIT_GAZE_2D_R != 0) any = correctField(g, &out.gaze_point_2d_R_norm) or any;
    if (!any) return false;
    out.present_mask |= core.GAZE_BIT_CORRECTED;
    return true;
}

/// Parse + refit `text` (taken over) into a Correction.
fn makeCorrection(text: []u8) !Correction {
    errdefer gpa.free(text);
    const parsed = try corr_mod.parseFile(gpa, text);
    errdefer parsed.deinit();
    const m = try parsed.value.map();
    const grid = try gpa.create(corr_mod.Grid);
    grid.init(&m);
    var sha: [64]u8 = undefined;
    @memcpy(&sha, parsed.value.calibration_sha256[0..64]);
    return .{ .parsed = parsed, .text = text, .grid = grid, .sha = sha, .area = parsed.value.display_area };
}

fn installCorrection(c: Correction) void {
    if (correction) |*old| old.deinit();
    correction = c;
    const f = &c.parsed.value;
    log.info("correction map loaded: {} points, lambda {d}, cap {d:.0} mm, fade {d:.0} mm", .{ f.points.len, f.lambda, f.cap_mm, f.fade_mm });
    updateCorrectionActive();
}

fn deleteCorrection(reason: []const u8) void {
    var pbuf: [512]u8 = undefined;
    if (config.correctionPath(&pbuf)) |path| {
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("could not delete {s}: {}", .{ path, err }),
        };
    }
    if (correction) |*c| {
        c.deinit();
        correction = null;
    }
    log.info("correction map deleted: {s}", .{reason});
    updateCorrectionActive();
}

/// SHA-256 of the stored calibration blob, or null (any thread).
fn storedCalibrationSha() ?[64]u8 {
    var pbuf: [512]u8 = undefined;
    const path = config.calibrationPath(&pbuf) orelse return null;
    const blob = config.readFile(gpa, path, core.scratch_size() + 1) orelse return null;
    defer gpa.free(blob);
    return corr_mod.sha256Hex(blob);
}

/// Startup: load the stored map; delete it if it no longer matches the
/// stored calibration or the configured display area.
fn loadCorrection() void {
    var pbuf: [512]u8 = undefined;
    const path = config.correctionPath(&pbuf) orelse return;
    const text = config.readFile(gpa, path, 1 << 20) orelse return;
    const c = makeCorrection(text) catch |err| {
        log.warn("{s} unusable ({}), deleting it", .{ path, err });
        deleteCorrection("unreadable");
        return;
    };
    var cc = c;
    const stored = storedCalibrationSha();
    if (stored == null or !std.mem.eql(u8, &stored.?, &cc.sha)) {
        cc.deinit();
        deleteCorrection("made for another calibration");
        return;
    }
    if (cur_area == null or !corr_mod.areaMatches(cur_area.?, cc.area)) {
        cc.deinit();
        deleteCorrection("made for another display area");
        return;
    }
    installCorrection(cc);
}

fn setCorrection(c: Client, cmd_type: u8, payload: []const u8) void {
    const text = gpa.dupe(u8, payload) catch {
        sendError(c, cmd_type, proto.Err.failed);
        return;
    };
    var nc = makeCorrection(text) catch |err| {
        log.warn("set_correction: bad map ({})", .{err});
        sendError(c, cmd_type, proto.Err.bad_payload);
        return;
    };
    const stored = storedCalibrationSha();
    if (stored == null or !std.mem.eql(u8, &stored.?, &nc.sha)) {
        log.warn("set_correction: made for another calibration than the stored one", .{});
        nc.deinit();
        sendError(c, cmd_type, proto.Err.mismatch);
        return;
    }
    if (cur_area == null or !corr_mod.areaMatches(cur_area.?, nc.area)) {
        log.warn("set_correction: made for another display area", .{});
        nc.deinit();
        sendError(c, cmd_type, proto.Err.mismatch);
        return;
    }
    var pbuf: [512]u8 = undefined;
    const path = config.correctionPath(&pbuf) orelse {
        nc.deinit();
        sendError(c, cmd_type, proto.Err.failed);
        return;
    };
    config.writeFileAtomic(path, nc.text) catch |err| {
        log.err("failed to save {s}: {}", .{ path, err });
        nc.deinit();
        sendError(c, cmd_type, proto.Err.failed);
        return;
    };
    log.info("correction map saved to {s}", .{path});
    installCorrection(nc);
    sendReply(c, cmd_type, &.{});
}

fn getCorrection(c: Client, cmd_type: u8) void {
    const cr = correction orelse {
        sendReply(c, cmd_type, &.{0});
        return;
    };
    const buf = gpa.alloc(u8, 1 + cr.text.len) catch {
        sendError(c, cmd_type, proto.Err.failed);
        return;
    };
    defer gpa.free(buf);
    buf[0] = if (corr_active) 1 else 2;
    @memcpy(buf[1..], cr.text);
    sendReply(c, cmd_type, buf);
}

// ── Command forwarding: client → tracker ────────────────────────────

/// Called by server.zig and ws_server.zig for every command except
/// subscribe/disconnect.
fn forwardCommand(client_fd: std.posix.fd_t, cmd_type: u8, payload: []const u8, is_ws: bool) void {
    const c = Client{ .fd = client_fd, .is_ws = is_ws };
    const cmd = std.meta.intToEnum(proto.Cmd, cmd_type) catch {
        log.warn("unknown cmd 0x{x:0>2} from fd={}", .{ cmd_type, client_fd });
        sendError(c, cmd_type, proto.Err.unknown_cmd);
        return;
    };
    if (cmd == .subscribe or cmd == .disconnect or cmd == .set_gaze_raw) return; // handled by the servers

    // Correction map: answered by the daemon, whatever the device state.
    switch (cmd) {
        .set_correction => return setCorrection(c, cmd_type, payload),
        .get_correction => return getCorrection(c, cmd_type),
        .clear_correction => {
            deleteCorrection("cleared by a client");
            sendReply(c, cmd_type, &.{});
            return;
        },
        // --no-device (tests): the area the daemon knows (config).
        .get_display_area => if (opt_no_device) {
            if (cur_area) |ar| {
                var out: [proto.DISPLAY_AREA_SIZE]u8 = undefined;
                proto.encodeDisplayArea(&out, ar);
                sendReply(c, cmd_type, &out);
            } else sendError(c, cmd_type, proto.Err.no_device);
            return;
        },
        .set_correction_enabled => {
            correction_enabled = payload.len > 0 and payload[0] != 0;
            log.info("correction map {s} by a client", .{if (correction_enabled) "enabled" else "disabled"});
            updateCorrectionActive();
            sendReply(c, cmd_type, &.{});
            return;
        },
        else => {},
    }

    switch (dev_state.load(.acquire)) {
        .up => {},
        .lost => {
            sendError(c, cmd_type, proto.Err.no_device);
            return;
        },
        .restoring => {
            log.info("cmd=0x{x:0>2} from fd={} rejected: busy (restoring device state)", .{ cmd_type, client_fd });
            sendError(c, cmd_type, proto.Err.busy);
            return;
        },
    }
    if (deviceBusy()) {
        log.info("cmd=0x{x:0>2} from fd={} rejected: busy ({s})", .{
            cmd_type, client_fd, @tagName((job_queued orelse job_current).kind),
        });
        sendError(c, cmd_type, proto.Err.busy);
        return;
    }

    switch (cmd) {
        .subscribe, .disconnect, .set_gaze_raw => unreachable,
        .set_correction, .get_correction, .clear_correction, .set_correction_enabled => unreachable,

        .start_calibration => queueJob(.{ .kind = .start_cal, .client = c, .cmd_type = cmd_type }),
        .finish_calibration => queueJob(.{ .kind = .finish_cal, .client = c, .cmd_type = cmd_type }),
        .cancel_calibration => queueJob(.{ .kind = .cancel_cal, .client = c, .cmd_type = cmd_type }),
        .cal_apply => {
            log.debug("cal_apply: received payload_len={d} from fd={d}", .{ payload.len, client_fd });
            if (payload.len == 0 or payload.len > core.scratch_size()) {
                sendError(c, cmd_type, proto.Err.bad_payload);
                return;
            }
            const blob = gpa.dupe(u8, payload) catch {
                sendError(c, cmd_type, proto.Err.failed);
                return;
            };
            queueJob(.{ .kind = .apply, .client = c, .cmd_type = cmd_type, .blob = blob });
        },

        .get_display_area => {
            _ = sendRequest(c, cmd_type, .get_area, core.request_get_display_area());
        },
        .set_display_area, .set_display_area_corners => {
            const corners: ?config.Corners = if (cmd == .set_display_area) blk: {
                if (payload.len < 40) break :blk null;
                var f: [5]f64 = undefined;
                @memcpy(std.mem.asBytes(&f), payload[0..40]);
                break :blk config.rectToCorners(.{ .w_mm = f[0], .h_mm = f[1], .ox_mm = f[2], .oy_mm = f[3], .z_mm = f[4] });
            } else blk: {
                if (payload.len < proto.DISPLAY_AREA_SIZE) break :blk null;
                break :blk proto.decodeDisplayArea(payload[0..proto.DISPLAY_AREA_SIZE]);
            };
            setDisplayArea(c, cmd_type, corners orelse {
                sendError(c, cmd_type, proto.Err.bad_payload);
                return;
            });
        },
        .add_calibration_point => {
            if (payload.len < 16) {
                sendError(c, cmd_type, proto.Err.bad_payload);
                return;
            }
            var f: [2]f64 = undefined;
            @memcpy(std.mem.asBytes(&f), payload[0..16]);
            _ = sendRequest(c, cmd_type, .raw, core.request_cal_point_add2d(f[0], f[1], 3)); // eye_mask=3: both eyes
        },
        .get_calibration_stimulus => {
            _ = sendRequest(c, cmd_type, .stimulus, core.request_cal_stimulus());
        },
    }
}

/// Register + send the request the core just built into session_out.
fn sendRequest(c: Client, cmd_type: u8, kind: Kind, request_id: u32) bool {
    const out_len = core.session_out_len_();
    if (out_len == 0 or request_id == 0) {
        sendError(c, cmd_type, proto.Err.failed);
        return false;
    }
    // Register before sending: the response can arrive on the USB thread
    // before transport.send returns.
    if (!addPending(.{
        .request_id = request_id,
        .client = c,
        .cmd_type = cmd_type,
        .kind = kind,
        .deadline_ms = std.time.milliTimestamp() + REQUEST_TIMEOUT_MS,
    })) {
        sendError(c, cmd_type, proto.Err.busy);
        return false;
    }
    if (!transport.send(core.session_out_ptr()[0..out_len])) {
        log.err("USB send failed for cmd=0x{x:0>2}", .{cmd_type});
        _ = takePending(request_id);
        sendError(c, cmd_type, proto.Err.usb);
        return false;
    }
    log.debug("forwarded cmd=0x{x:0>2} ({s}) request_id={} for fd={}", .{ cmd_type, @tagName(kind), request_id, c.fd });
    return true;
}

/// set → ack (status checked) → get → reply with what the device holds.
/// The readback is only sent once the ack is in: the device answers a get
/// sent right behind a set *before* acking the set, with the old area.
fn setDisplayArea(c: Client, cmd_type: u8, a: config.Corners) void {
    log.info("set display area from fd={}: TL=({d:.3},{d:.3},{d:.3}) TR=({d:.3},{d:.3},{d:.3}) BL=({d:.3},{d:.3},{d:.3})", .{
        c.fd, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8],
    });
    _ = sendRequest(c, cmd_type, .set_ack, core.request_set_display_area_corners(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]));
}

// ── Device state / hotplug ──────────────────────────────────────────
//
// restoring: (re)connected, the USB thread is pushing the display area and
//            re-applying the stored calibration; device commands get busy.
// up:        normal operation.
// lost:      the tracker went away (unplug, power loss, de-authorisation);
//            device commands get no_device. The main thread fails in-flight
//            requests and waits for a running job to abort, then acks; the
//            USB thread then reopens the device every second, re-runs the
//            handshake and restores area + calibration.

const DevState = enum(u8) { restoring, up, lost };
var dev_state = std.atomic.Value(DevState).init(.restoring);
var lost_ack = std.atomic.Value(bool).init(false);
var opt_keep_device_area = false;
var opt_restore_calibration = true;
/// --no-device: never touch USB (tests of the daemon-side commands).
var opt_no_device = false;
/// --fake-gaze X,Y (with --no-device): synthetic gaze for tests.
var opt_fake_gaze: ?[2]f64 = null;

fn setState(st: DevState) void {
    dev_state.store(st, .release);
    notifyMain();
}

/// Main thread: on loss, fail what's in flight, then let the USB thread go.
fn serviceDeviceState() void {
    if (dev_state.load(.acquire) != .lost or lost_ack.load(.acquire)) return;
    var dropped: [MAX_PENDING]PendingEntry = undefined;
    var n: usize = 0;
    {
        pending_mutex.lock();
        defer pending_mutex.unlock();
        for (&pending) |*slot| {
            if (slot.*) |e| {
                dropped[n] = e;
                n += 1;
                slot.* = null;
            }
        }
    }
    for (dropped[0..n]) |e| sendError(e.client, e.cmd_type, proto.Err.no_device);
    if (job_queued) |j| {
        job_queued = null;
        if (j.blob) |b| gpa.free(b);
        sendError(j.client, j.cmd_type, proto.Err.no_device);
    }
    if (job_running) return; // aborts quickly (tracker.abort); completed by serviceJobs
    lost_ack.store(true, .release);
}

/// USB thread: stored calibration → device (startup and every reconnect).
fn restoreCalibration() void {
    if (!opt_restore_calibration) {
        log.info("--no-restore-calibration: not applying stored calibration", .{});
        return;
    }
    var pbuf: [512]u8 = undefined;
    const path = config.calibrationPath(&pbuf) orelse return;
    const blob = config.readFile(gpa, path, core.scratch_size() + 1) orelse {
        log.info("no stored calibration at {s}", .{path});
        setAppliedSha(null);
        return;
    };
    defer gpa.free(blob);
    if (blob.len == 0 or blob.len > core.scratch_size()) {
        log.warn("stored calibration {s} has bad size {}, ignoring", .{ path, blob.len });
        return;
    }
    log.info("applying stored calibration {s} ({} bytes); device commands answer busy until done", .{ path, blob.len });
    const t0 = std.time.milliTimestamp();
    const ok = tracker.calApply(blob);
    const dt = std.time.milliTimestamp() - t0;
    setAppliedSha(if (ok) corr_mod.sha256Hex(blob) else null);
    if (ok) {
        log.info("stored calibration applied in {d} ms", .{dt});
    } else {
        log.warn("stored calibration could not be applied ({d} ms); device keeps its current calibration", .{dt});
    }
}

/// USB thread: open the tracker, handshake, restore area + calibration.
/// Returns false if the device could not be brought up (caller retries).
fn connectDevice() bool {
    transport = LibusbTransport.open(true) catch return false;
    setState(.restoring);
    log.info("tracker found, connecting", .{});
    tracker = Tracker.init(.{
        .send_fn = &transportSend,
        .recv_fn = &transportRecv,
        .try_recv_fn = &transportTryRecv,
    }) catch |err| {
        log.err("handshake failed: {}", .{err});
        transport.deinit();
        return false;
    };
    tracker.onGaze(onGaze);
    applyStartupDisplayArea(config.loadDisplayArea(gpa), opt_keep_device_area);
    // The startup queries install their own capture hook; put ours back.
    core.set_hooks(onTtpFrame, null, onResponse, null, null);
    restoreCalibration();
    if (transport.isLost()) return false;
    return true;
}

fn reconnect() void {
    log.warn("tracker disconnected; waiting for it to come back", .{});
    tracker.abort.store(true, .release);
    lost_ack.store(false, .release);
    setState(.lost);
    while (!quit and !lost_ack.load(.acquire)) std.Thread.sleep(10_000_000);
    transport.deinit();
    const t0 = std.time.milliTimestamp();
    while (!quit) {
        std.Thread.sleep(1_000_000_000);
        if (connectDevice()) {
            log.info("tracker reconnected after {d} ms", .{std.time.milliTimestamp() - t0});
            setState(.up);
            return;
        }
        // Not there yet (or lost again mid-restore): back to lost.
        transport.deinit();
        dev_state.store(.lost, .release);
    }
}

// ── Startup display area ────────────────────────────────────────────

fn cornersOf(d: Tracker.DisplayCorners) config.Corners {
    return .{ d.tl_x, d.tl_y, d.tl_z, d.tr_x, d.tr_y, d.tr_z, d.bl_x, d.bl_y, d.bl_z };
}

fn trackerCorners(c: config.Corners) Tracker.DisplayCorners {
    return .{
        .tl_x = c[0], .tl_y = c[1], .tl_z = c[2],
        .tr_x = c[3], .tr_y = c[4], .tr_z = c[5],
        .bl_x = c[6], .bl_y = c[7], .bl_z = c[8],
    };
}

fn maxDiff(a: config.Corners, b: config.Corners) f64 {
    var m: f64 = 0;
    for (a, b) |x, y| m = @max(m, @abs(x - y));
    return m;
}

/// Before the USB thread starts: push the config's area if it differs from
/// the device's (or, with keep_device_area, only if the device looks reset).
fn applyStartupDisplayArea(cfg: ?config.Corners, keep_device_area: bool) void {
    const dev = cornersOf(tracker.display);
    const reset = tracker.display.isReset();
    const want: config.Corners = cfg orelse blk: {
        if (!reset) {
            log.info("no display area in ~/{s}; keeping the device's", .{config.CONFIG_REL_PATH});
            return;
        }
        log.info("no display area in ~/{s} and device looks reset; applying built-in default", .{config.CONFIG_REL_PATH});
        break :blk config.rectToCorners(.{});
    };
    if (keep_device_area and !reset) {
        log.info("--keep-device-area: device display area preserved", .{});
        return;
    }
    const d = maxDiff(want, dev);
    if (d < 0.01) {
        log.info("device display area matches config", .{});
        return;
    }
    log.info("applying config display area (differs from device by up to {d:.2} mm): TL=({d:.2},{d:.2},{d:.2}) TR=({d:.2},{d:.2},{d:.2}) BL=({d:.2},{d:.2},{d:.2})", .{
        d, want[0], want[1], want[2], want[3], want[4], want[5], want[6], want[7], want[8],
    });
    if (!tracker.setDisplayAreaCorners(trackerCorners(want))) {
        log.warn("failed to set display area from config", .{});
        return;
    }
    const got = cornersOf(tracker.display);
    if (maxDiff(want, got) > 0.01) {
        log.warn("device holds TL=({d:.2},{d:.2},{d:.2}) TR=({d:.2},{d:.2},{d:.2}) BL=({d:.2},{d:.2},{d:.2}) after set (rejected?)", .{
            got[0], got[1], got[2], got[3], got[4], got[5], got[6], got[7], got[8],
        });
    }
}

// ── Signal handling ─────────────────────────────────────────────────

fn handleSignal(_: c_int) callconv(.c) void {
    quit = true;
}

fn installSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

/// Debug: log every TTP response frame (magic 0x52) with its status word.
fn onTtpFrame(magic: u32, seq: u32, op: u32, payload_ptr: [*]const u8, payload_len: u32) void {
    if (magic != core.TTP_MAGIC_RSP) return;
    const n = @min(payload_len, 32);
    log.debug("ttp rsp seq={d} op=0x{x} status=0x{x} plen={d} head={x}", .{ seq, op, core.response_status(), payload_len, payload_ptr[0..n] });
}

// ── Main ────────────────────────────────────────────────────────────

fn usage() void {
    std.debug.print(
        \\usage: tobiifreed [--ws [addr:]port] [--keep-device-area] [--no-restore-calibration] [--init-config] [--no-device]
        \\
    , .{});
}

pub fn main() void {
    var ws_addr: u32 = std.mem.nativeToBig(u32, 0x7f000001); // 127.0.0.1
    var ws_port: u16 = 7081;
    var ws_enabled = false;
    var keep_device_area = false;
    var restore_calibration = true;

    var args = std.process.args();
    _ = args.next();
    var pending_arg: ?[]const u8 = null;
    while (pending_arg orelse args.next()) |arg| {
        pending_arg = null;
        if (std.mem.eql(u8, arg, "--init-config")) {
            initConfig();
            return;
        } else if (std.mem.eql(u8, arg, "--ws")) {
            ws_enabled = true;
            if (args.next()) |ws_arg| {
                if (ws_arg.len > 0 and ws_arg[0] == '-') {
                    pending_arg = ws_arg; // another flag, not a WS address
                } else {
                    parseWsArg(ws_arg, &ws_addr, &ws_port);
                }
            }
        } else if (std.mem.eql(u8, arg, "--keep-device-area")) {
            keep_device_area = true;
        } else if (std.mem.eql(u8, arg, "--no-restore-calibration")) {
            restore_calibration = false;
        } else if (std.mem.eql(u8, arg, "--no-device")) {
            opt_no_device = true;
        } else if (std.mem.eql(u8, arg, "--fake-gaze")) {
            const v = args.next() orelse "";
            var it = std.mem.splitScalar(u8, v, ',');
            const x = std.fmt.parseFloat(f64, it.next() orelse "") catch {
                usage();
                return;
            };
            const y = std.fmt.parseFloat(f64, it.next() orelse "") catch {
                usage();
                return;
            };
            opt_fake_gaze = .{ x, y };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        } else {
            log.err("unknown argument: {s}", .{arg});
            usage();
            return;
        }
    }

    const cfg_area = config.loadDisplayArea(gpa);
    if (cfg_area) |a| {
        log.info("config display area: TL=({d:.2},{d:.2},{d:.2}) TR=({d:.2},{d:.2},{d:.2}) BL=({d:.2},{d:.2},{d:.2})", .{
            a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8],
        });
    }

    cur_area = cfg_area;
    opt_keep_device_area = keep_device_area;
    opt_restore_calibration = restore_calibration;

    // Connect now if the tracker is there; otherwise start anyway and let
    // the USB thread wait for it (hotplug).
    var start_connected = false;
    if (opt_no_device) {
        log.warn("--no-device: not opening the tracker (testing mode)", .{});
    } else if (LibusbTransport.open(false)) |t| {
        transport = t;
        if (Tracker.init(.{
            .send_fn = &transportSend,
            .recv_fn = &transportRecv,
            .try_recv_fn = &transportTryRecv,
        })) |tr| {
            tracker = tr;
            start_connected = true;
        } else |err| {
            log.err("failed to connect: {}; will retry", .{err});
            transport.deinit();
        }
    } else |err| {
        log.warn("tracker not available ({}); waiting for it", .{err});
    }
    if (!start_connected) {
        transport = .{ .usb_ctx = null, .usb_handle = null };
        transport.lost.store(true, .monotonic);
        tracker = .{
            .send_fn = &transportSend,
            .recv_fn = &transportRecv,
            .try_recv_fn = &transportTryRecv,
            .connected = false,
            .gaze_cb = null,
            .display = .{},
        };
    }
    defer transport.deinit();
    defer tracker.deinit();

    if (start_connected) {
        applyStartupDisplayArea(cfg_area, keep_device_area);
        if (cur_area == null) cur_area = cornersOf(tracker.display);
        tracker.onGaze(onGaze);
    }
    loadCorrection();

    // Install hooks for command forwarding (after the synchronous startup
    // queries, which use their own capture hook).
    core.set_hooks(onTtpFrame, null, onResponse, null, null);

    server.init(&forwardCommand) catch |err| {
        log.err("failed to start server: {}", .{err});
        return;
    };
    defer server.deinit();

    if (ws_enabled) {
        ws = WsServer.init(ws_addr, ws_port, &forwardCommand) catch |err| {
            log.err("failed to start WebSocket server: {}", .{err});
            return;
        };
    }
    defer if (ws) |*w| w.deinit();

    notify_pipe = std.posix.pipe2(.{ .NONBLOCK = true }) catch |err| {
        log.err("failed to create pipe: {}", .{err});
        return;
    };
    defer {
        std.posix.close(notify_pipe[0]);
        std.posix.close(notify_pipe[1]);
    }

    installSignalHandlers();

    const usb_thread = std.Thread.spawn(.{}, usbThreadFn, .{}) catch |err| {
        log.err("failed to spawn USB thread: {}", .{err});
        return;
    };

    log.info("running", .{});

    while (!quit) {
        var drain_buf: [64]u8 = undefined;
        _ = std.posix.read(notify_pipe[0], &drain_buf) catch {};
        drainGaze();
        drainResponses();
        serviceJobs();
        serviceDeviceState();
        sweepPending();
        server.acceptClients();
        server.readCommands();
        if (ws) |*w| {
            w.acceptClients();
            w.readClients();
        }
        std.Thread.sleep(1_000_000); // 1ms
    }

    log.info("shutting down", .{});
    if (job_running) log.warn("a calibration job is still running; waiting for it", .{});
    while (job_running and !job_done.load(.acquire)) std.Thread.sleep(10_000_000);
    usb_thread.join();
}

// ── --init-config ──────────────────────────────────────────────────

fn initConfig() void {
    var path_buf: [512]u8 = undefined;
    const path = config.configPath(&path_buf) orelse {
        log.err("$HOME not set", .{});
        return;
    };
    if (std.fs.cwd().access(path, .{})) |_| {
        log.info("{s} already exists", .{path});
        return;
    } else |_| {}
    config.writeFileAtomic(path,
        \\{
        \\  "display_area": {
        \\    "w_mm": 800,
        \\    "h_mm": 340,
        \\    "z_mm": 0,
        \\    "tilt": 0,
        \\    "cx": 0,
        \\    "cy": "b - 10"
        \\  }
        \\}
        \\
    ) catch |err| {
        log.err("create config: {}", .{err});
        return;
    };
    log.info("created {s}", .{path});
}

// ── --ws argument parsing ──────────────────────────────────────────

fn parseWsArg(arg: []const u8, addr: *u32, port: *u16) void {
    // Check if arg contains ':' → addr:port
    if (std.mem.lastIndexOfScalar(u8, arg, ':')) |colon| {
        if (parseIpv4(arg[0..colon])) |a| addr.* = a;
        if (std.fmt.parseInt(u16, arg[colon + 1 ..], 10)) |p| port.* = p else |_| {}
    } else {
        // Just a port number.
        if (std.fmt.parseInt(u16, arg, 10)) |p| port.* = p else |_| {}
    }
}

fn parseIpv4(s: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (count >= 3) return null;
            octets[count] = std.fmt.parseInt(u8, s[start..i], 10) catch return null;
            count += 1;
            start = i + 1;
        }
    }
    if (count != 3) return null;
    octets[3] = std.fmt.parseInt(u8, s[start..], 10) catch return null;
    return @bitCast(octets);
}

// ── USB thread ─────────────────────────────────────────────────────

fn usbThreadFn() void {
    log.info("USB thread started", .{});
    if (opt_no_device) {
        dev_state.store(.lost, .release);
        if (opt_fake_gaze) |g| {
            // Pretend the stored calibration is on the device.
            if (storedCalibrationSha()) |sha| setAppliedSha(sha);
            var sample = std.mem.zeroes(core.GazeSample);
            sample.present_mask = core.GAZE_BIT_GAZE_2D | core.GAZE_BIT_GAZE_2D_L | core.GAZE_BIT_GAZE_2D_R | core.GAZE_BIT_GAZE_2D_UNFILTERED;
            sample.gaze_point_2d_norm = g;
            sample.gaze_point_2d_L_norm = g;
            sample.gaze_point_2d_R_norm = g;
            sample.gaze_point_2d_unfiltered = g;
            sample.eye_origin_L_mm = .{ -30, 0, 700 };
            sample.eye_origin_R_mm = .{ 30, 0, 700 };
            while (!quit) {
                sample.frame_counter +%= 1;
                onGaze(&sample);
                std.Thread.sleep(33_000_000);
            }
        }
        while (!quit) std.Thread.sleep(50_000_000);
        return;
    }
    if (transport.isLost()) {
        reconnect(); // started without the tracker
    } else {
        restoreCalibration();
        setState(.up);
    }
    while (!quit) {
        if (transport.isLost()) {
            reconnect();
            continue;
        }
        // While a calibration job owns the transport poll() returns at once;
        // don't spin.
        if (tracker.cal_pending.load(.acquire)) {
            std.Thread.sleep(2_000_000);
            continue;
        }
        tracker.poll();
    }
    log.info("USB thread stopped", .{});
}

// ── Transport bridge ────────────────────────────────────────────────

fn transportSend(data: []const u8) bool {
    return transport.send(data);
}

fn transportRecv(buf: []u8) ?usize {
    return transport.recv(buf);
}

fn transportTryRecv(buf: []u8) ?usize {
    return transport.tryRecv(buf);
}
