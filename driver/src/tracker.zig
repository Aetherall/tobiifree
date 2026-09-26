// tracker.zig — transport-agnostic Tracker for Zig consumers.
//
// Drives the tobiifree_core handshake state machine and exposes a poll-based
// API. Transport (USB, socket, etc.) is injected via function pointers.
//
//   var transport = try LibusbTransport.init();
//   var tracker = try Tracker.init(.{
//       .send_fn = transport.sendFn(),
//       .recv_fn = transport.recvFn(),
//       .display = my_display_area,
//   });
//   defer tracker.deinit();
//   tracker.onGaze(myCallback);
//   // in your event loop:
//   tracker.poll();

const std = @import("std");
const core = @import("tobiifree_core");

const log = std.log.scoped(.tracker);

pub const Tracker = struct {
    send_fn: SendFn,
    recv_fn: RecvFn,
    try_recv_fn: RecvFn,
    connected: bool,
    gaze_cb: ?GazeFn,
    display: DisplayCorners,
    /// Tracks which side owns the transport, so poll() and the calibration state
    /// machines never call recv_fn/feed_usb_in concurrently (which would corrupt
    /// the core parser). A plain bool + fixed sleep isn't enough here: recv_fn can
    /// block for up to ~100ms, so the transition to `.calibrating` is done with a
    /// CAS loop that only succeeds once poll() has observed `.idle` and is not
    /// mid-read. A mutex is avoided because poll() would hold it across a
    /// blocking read, which can deadlock.
    usb_owner: std.atomic.Value(UsbOwner) = std.atomic.Value(UsbOwner).init(.idle),
    /// Set while a calibration section wants the transport. poll() checks this
    /// before even attempting the idle->busy CAS, so the USB thread stops
    /// re-claiming ownership;
    cal_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub const SendFn = *const fn (data: []const u8) bool;
    pub const RecvFn = *const fn (buf: []u8) ?usize;
    pub const GazeFn = *const fn (*const core.GazeSample) void;

    pub const UsbOwner = enum(u8) { idle, busy, calibrating };

    /// Three-corner display area as reported by the device.
    pub const DisplayCorners = struct {
        tl_x: f64 = 0, tl_y: f64 = 0, tl_z: f64 = 0,
        tr_x: f64 = 0, tr_y: f64 = 0, tr_z: f64 = 0,
        bl_x: f64 = 0, bl_y: f64 = 0, bl_z: f64 = 0,

        /// True if the device area looks like a power-cycle reset (tiny dimensions).
        pub fn isReset(self: DisplayCorners) bool {
            const w = @abs(self.tr_x - self.tl_x);
            const h = @abs(self.tl_y - self.bl_y);
            return w < 50 or h < 50;
        }
    };

    /// Rect+tilt parameterisation used by config files. Converted to corners
    /// for the handshake set_display_area command.
    pub const DisplayArea = struct {
        w_mm: f64 = 1500,
        h_mm: f64 = 1000,
        ox_mm: f64 = -750,
        oy_mm: f64 = -500,
        z_mm: f64 = 0,
        /// Screen tilt in degrees: 0 = flush, negative = tilted toward user, positive = tilted away.
        tilt_deg: f64 = 0,
    };

    pub const InitOptions = struct {
        send_fn: SendFn,
        recv_fn: RecvFn,
        try_recv_fn: ?RecvFn = null,
    };

    pub const Error = error{
        HandshakeFailed,
        SendFailed,
    };

    // ── Module-level state (bridges core hooks to the instance) ──────

    pub var active: ?*Tracker = null;

    fn gazeTrampoline(sample_ptr: [*]const u8) void {
        if (active) |t| {
            if (t.gaze_cb) |cb| {
                cb(@ptrCast(@alignCast(sample_ptr)));
            }
        }
    }

    // ── Public API ──────────────────────────────────────────────────

    pub fn init(opts: InitOptions) Error!Tracker {
        var self = Tracker{
            .send_fn = opts.send_fn,
            .recv_fn = opts.recv_fn,
            .try_recv_fn = opts.try_recv_fn orelse opts.recv_fn,
            .connected = false,
            .gaze_cb = null,
            .display = .{},
        };

        // Wire up gaze hook. Note: active is set in poll(), not here,
        // because init() returns self by value (self would be a dangling stack ref).
        core.set_hooks(null, null, null, gazeTrampoline, null);

        // Run handshake state machine.
        core.handshake_init(0x500);
        if (!self.driveHandshake()) return error.HandshakeFailed;

        self.connected = true;

        // Read the display area back from the device (device is source of truth).
        self.display = self.queryDisplayArea() orelse .{};
        log.info("device display: TL=({d:.0},{d:.0},{d:.0}) TR=({d:.0},{d:.0},{d:.0}) BL=({d:.0},{d:.0},{d:.0})", .{
            self.display.tl_x, self.display.tl_y, self.display.tl_z,
            self.display.tr_x, self.display.tr_y, self.display.tr_z,
            self.display.bl_x, self.display.bl_y, self.display.bl_z,
        });

        log.info("connected, streaming gaze", .{});
        return self;
    }

    /// Set display area from rect+tilt config. Sends to device and reads back.
    pub fn setDisplayArea(self: *Tracker, d: DisplayArea) bool {
        const angle = d.tilt_deg * (std.math.pi / 180.0);
        const cos_a = @cos(angle);
        const sin_a = @sin(angle);
        const bl_x = d.ox_mm;
        const bl_y = d.oy_mm;
        const bl_z = d.z_mm;
        const tl_x = bl_x;
        const tl_y = bl_y + d.h_mm * cos_a;
        const tl_z = bl_z + d.h_mm * sin_a;
        const tr_x = d.ox_mm + d.w_mm;
        const tr_y = tl_y;
        const tr_z = tl_z;

        _ = core.request_set_display_area_corners(tl_x, tl_y, tl_z, tr_x, tr_y, tr_z, bl_x, bl_y, bl_z);
        const out_len = core.session_out_len_();
        if (out_len == 0) return false;
        if (!self.send_fn(core.session_out_ptr()[0..out_len])) return false;

        // Read back from device.
        self.display = self.queryDisplayArea() orelse self.display;
        return true;
    }

    /// Register a gaze callback. Called from the poll() context.
    pub fn onGaze(self: *Tracker, cb: GazeFn) void {
        self.gaze_cb = cb;
    }

    /// Poll for USB data. First read blocks until data arrives (device-paced).
    /// Subsequent reads are non-blocking to drain any buffered packets.
    /// Returns immediately (no reads) while a calibration state machine owns
    /// (or is claiming) the transport, so the main thread has USB I/O exclusively.
    pub fn poll(self: *Tracker) void {
        if (!self.connected) return;
        if (self.cal_pending.load(.acquire)) return;
        if (self.usb_owner.cmpxchgStrong(.idle, .busy, .acquire, .monotonic) != null) return;
        defer self.usb_owner.store(.idle, .release);
        active = self;

        var buf: [16384]u8 = undefined;
        // First read: blocking (waits for device to send data).
        if (self.recv_fn(&buf)) |n| {
            core.feed_usb_in(buf[0..n].ptr, n);
        } else return;
        // Drain any additional buffered packets (non-blocking).
        var reads: u32 = 1;
        while (reads < 8) : (reads += 1) {
            if (self.try_recv_fn(&buf)) |n| {
                core.feed_usb_in(buf[0..n].ptr, n);
            } else break;
        }
    }

    pub fn deinit(self: *Tracker) void {
        log.info("deinit", .{});
        active = null;
        self.connected = false;
    }

    // ── Display area query ────────────────────────────────────────────

    /// Module-level state for capturing a single response during queryDisplayArea.
    var captured_payload: ?[]const u8 = null;
    var captured_request_id: u32 = 0;

    fn captureResponse(request_id: u32, payload_ptr: [*]const u8, payload_len: u32) void {
        if (request_id == captured_request_id) {
            // Store pointer+length; valid until next feed_usb_in.
            captured_payload = payload_ptr[0..payload_len];
        }
    }

    /// Send get_display_area and wait for the response. Returns decoded corners.
    fn queryDisplayArea(self: *Tracker) ?DisplayCorners {
        // Install temporary response hook to capture the reply.
        // During init(), no caller hook is set yet (it's the default noop).
        core.set_hooks(null, null, captureResponse, null, null);

        const req_id = core.request_get_display_area();
        captured_request_id = req_id;
        captured_payload = null;

        const out_len = core.session_out_len_();
        if (out_len == 0) return null;
        if (!self.send_fn(core.session_out_ptr()[0..out_len])) {
            log.err("queryDisplayArea: send failed", .{});
            return null;
        }

        // Wait for response (up to ~20 reads).
        self.drainReads(20);

        const payload = captured_payload orelse {
            log.warn("queryDisplayArea: no response", .{});
            return null;
        };

        // Decode: 9 x f64 (tl, tr, bl corners).
        var out: [9]f64 align(8) = undefined;
        if (core.decode_display_area(payload.ptr, payload.len, @ptrCast(&out)) == 0) {
            log.warn("queryDisplayArea: decode failed (plen={})", .{payload.len});
            return null;
        }

        return .{
            .tl_x = out[0], .tl_y = out[1], .tl_z = out[2],
            .tr_x = out[3], .tr_y = out[4], .tr_z = out[5],
            .bl_x = out[6], .bl_y = out[7], .bl_z = out[8],
        };
    }

    // ── Calibration ─────────────────────────────────────────────────

    /// Wait for poll() to be outside (or not about to enter) a read, then claim
    /// the transport exclusively. Loops rather than sleeping a fixed duration
    /// because recv_fn's blocking read can take arbitrarily long.
    fn beginCalibrating(self: *Tracker) void {
        // Tell poll() to stop contending for ownership; 
        self.cal_pending.store(true, .release);
        while (self.usb_owner.cmpxchgWeak(.idle, .calibrating, .acquire, .monotonic) != null) {
            std.Thread.sleep(1_000_000); // 1 ms
        }
    }

    fn endCalibrating(self: *Tracker) void {
        self.usb_owner.store(.idle, .release);
        self.cal_pending.store(false, .release);
    }

    pub fn startCalibration(self: *Tracker) bool {
        self.beginCalibrating();
        defer self.endCalibrating();
        // Step 1: unlock the calibration realm.
        core.cal_start_init();
        if (!self.driveStateMachine(&core.cal_start_poll, "cal_realm")) return false;

        // Step 2: open a calibration session (CALIBRATE_START).
        // Without this the device acks every added point and discards it,
        // so the flow completes with no errors while leaving the calibration unchanged.
        if (!self.sendAndAwait(core.request_cal_start, "cal_start")) return false;

        // Step 3: drop any previously collected points (ok if the device rejects it).
        _ = self.sendAndAwait(core.request_cal_clear, "cal_clear");

        return true;
    }

    pub fn finishCalibration(self: *Tracker) bool {
        self.beginCalibrating();
        defer self.endCalibrating();
        core.cal_finish_init();
        return self.driveStateMachine(&core.cal_finish_poll, "cal_finish");
    }

    pub fn calApply(self: *Tracker, blob: []const u8) bool {
        self.beginCalibrating();
        defer self.endCalibrating();
        if (blob.len > core.scratch_size()) return false;
        const scratch = core.scratch_ptr();
        @memcpy(scratch[0..blob.len], blob);
        core.cal_apply_init(@intCast(blob.len));
        // 120 s: realm unlock + large blob send + device processing + close realm
        return self.driveStateMachineMs(&core.cal_apply_poll, "cal_apply", 120_000);
    }

    // ── State machine driver ─────────────────────────────────────────

    fn driveHandshake(self: *Tracker) bool {
        return self.driveStateMachine(&core.handshake_poll, "handshake");
    }

    /// Send a single TTP request and wait for its response.
    /// Returns true if a response was received, false on send failure or timeout.
    fn sendAndAwait(self: *Tracker, build_fn: *const fn () callconv(.c) u32, label: [*:0]const u8) bool {
        // Save and restore the active response hook so that hooks installed by
        // the caller (e.g. the daemon's onResponse for command forwarding) are
        // not permanently overwritten by the temporary captureResponse hook.
        const saved_hook = core.get_response_hook();
        core.set_hooks(null, null, captureResponse, null, null);
        defer core.set_hooks(null, null, saved_hook, null, null);
        const req_id = build_fn();
        captured_request_id = req_id;
        captured_payload = null;
        const out_len = core.session_out_len_();
        if (out_len == 0) {
            log.err("{s}: empty output", .{label});
            return false;
        }
        if (!self.send_fn(core.session_out_ptr()[0..out_len])) {
            log.err("{s}: send failed", .{label});
            return false;
        }
        self.drainReads(30);
        if (captured_payload == null) {
            log.warn("{s}: no response", .{label});
            return false;
        }
        log.debug("{s}: ok ({} bytes)", .{ label, captured_payload.?.len });
        return true;
    }

    fn driveStateMachine(self: *Tracker, poll_fn: *const fn () callconv(.c) u8, label: [*:0]const u8) bool {
        return self.driveStateMachineMs(poll_fn, label, 150_000);
    }

    fn driveStateMachineMs(self: *Tracker, poll_fn: *const fn () callconv(.c) u8, label: [*:0]const u8, timeout_ms: i64) bool {
        var steps: u32 = 0;
        const start_ms = std.time.milliTimestamp();
        while (std.time.milliTimestamp() - start_ms < timeout_ms) : (steps += 1) {
            const action: core.HandshakeAction = @enumFromInt(poll_fn());
            switch (action) {
                .send => {
                    const len = core.session_out_len_();
                    log.debug("{s} step {d}: send {d} bytes", .{ label, steps, len });
                    if (len > 0) {
                        if (!self.send_fn(core.session_out_ptr()[0..len])) {
                            log.err("{s}: send failed at step {d}", .{ label, steps });
                            return false;
                        }
                    }
                    self.drainReads(10);
                },
                .recv => {
                    // Only log intermittently to avoid spam
                    if (steps % 100 == 0) log.debug("{s} step {d}: recv", .{ label, steps });
                    self.drainReads(5);
                },
                .done => {
                    log.info("{s} complete in {d} steps", .{ label, steps });
                    return true;
                },
                .err => {
                    log.err("{s} failed at step {d}", .{ label, steps });
                    return false;
                },
            }
        }
        log.err("{s} timed out after {}ms ({} steps)", .{label, timeout_ms, steps});
        return false;
    }

    fn drainReads(self: *Tracker, max: u32) void {
        var buf: [16384]u8 = undefined;
        // First read: blocking (wait for device response).
        if (self.recv_fn(&buf)) |n| {
            core.feed_usb_in(buf[0..n].ptr, n);
        } else return;
        // Drain additional buffered packets (non-blocking).
        var i: u32 = 1;
        while (i < max) : (i += 1) {
            if (self.try_recv_fn(&buf)) |n| {
                core.feed_usb_in(buf[0..n].ptr, n);
            } else break;
        }
    }
};
