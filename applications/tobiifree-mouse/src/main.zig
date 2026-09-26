const std = @import("std");
const core = @import("tobiifree_core");
const protocol = @import("daemon_protocol");

const c = @cImport({
    @cInclude("linux/uinput.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
});

var is_paused = std.atomic.Value(bool).init(false);

fn handleSigusr1(sig: c_int) callconv(.c) void {
    _ = sig;
    const current = is_paused.load(.seq_cst);
    is_paused.store(!current, .seq_cst);
}

const DwellClicker = struct {
    enabled: bool = false,
    click_radius: f64 = 0.05, // Normalized coordinates (0.0 to 1.0)
    dwell_time_ms: i64 = 1000,
    
    last_click_ts_ms: i64 = 0,
    locked_x: ?f64 = null,
    locked_y: ?f64 = null,
    lock_start_ts_ms: i64 = 0,

    const Action = struct { x: i32, y: i32, click: bool };

    pub fn processGaze(self: *DwellClicker, gaze_x: f64, gaze_y: f64, screen_w: i32, screen_h: i32) ?Action {
        const abs_x: i32 = @intFromFloat(gaze_x * @as(f64, @floatFromInt(screen_w)));
        const abs_y: i32 = @intFromFloat(gaze_y * @as(f64, @floatFromInt(screen_h)));
        const action = Action{ .x = abs_x, .y = abs_y, .click = false };

        if (!self.enabled) {
            return action;
        }

        const now = std.time.milliTimestamp();
        
        // Cooldown after click
        if (now - self.last_click_ts_ms < self.dwell_time_ms) {
            return action;
        }

        if (self.locked_x) |lx| {
            if (self.locked_y) |ly| {
                const dx = gaze_x - lx;
                const dy = gaze_y - ly;
                const dist_sq = dx * dx + dy * dy;

                if (dist_sq <= self.click_radius * self.click_radius) {
                    if (now - self.lock_start_ts_ms >= self.dwell_time_ms) {
                        // Click!
                        self.last_click_ts_ms = now;
                        self.locked_x = null;
                        self.locked_y = null;
                        const click_abs_x: i32 = @intFromFloat(lx * @as(f64, @floatFromInt(screen_w)));
                        const click_abs_y: i32 = @intFromFloat(ly * @as(f64, @floatFromInt(screen_h)));
                        return Action{ .x = click_abs_x, .y = click_abs_y, .click = true };
                    }
                } else {
                    // Reset lock
                    self.locked_x = gaze_x;
                    self.locked_y = gaze_y;
                    self.lock_start_ts_ms = now;
                }
            }
        } else {
            self.locked_x = gaze_x;
            self.locked_y = gaze_y;
            self.lock_start_ts_ms = now;
        }
        
        return action;
    }
};

fn setupUinput(width: i32, height: i32) !i32 {
    const uinput_fd = c.open("/dev/uinput", c.O_WRONLY | c.O_NONBLOCK);
    if (uinput_fd < 0) {
        std.log.err("Failed to open /dev/uinput - Do you have the right udev permissions?", .{});
        return error.UinputOpenFailed;
    }

    // Enable key events (for buttons)
    if (c.ioctl(uinput_fd, c.UI_SET_EVBIT, c.EV_KEY) < 0) return error.UinputIoctlFailed;
    if (c.ioctl(uinput_fd, c.UI_SET_KEYBIT, c.BTN_LEFT) < 0) return error.UinputIoctlFailed;
    
    // Enable absolute positioning (for mouse coords)
    if (c.ioctl(uinput_fd, c.UI_SET_EVBIT, c.EV_ABS) < 0) return error.UinputIoctlFailed;
    if (c.ioctl(uinput_fd, c.UI_SET_ABSBIT, c.ABS_X) < 0) return error.UinputIoctlFailed;
    if (c.ioctl(uinput_fd, c.UI_SET_ABSBIT, c.ABS_Y) < 0) return error.UinputIoctlFailed;

    var usetup: c.uinput_setup = std.mem.zeroes(c.uinput_setup);
    usetup.id.bustype = c.BUS_USB;
    usetup.id.vendor = 0x1234;
    usetup.id.product = 0x5678;
    std.mem.copyForwards(u8, &usetup.name, "Tobii Free Virtual Mouse");

    if (c.ioctl(uinput_fd, c.UI_DEV_SETUP, &usetup) < 0) return error.UinputSetupFailed;

    var abs_setup_x: c.uinput_abs_setup = std.mem.zeroes(c.uinput_abs_setup);
    abs_setup_x.code = c.ABS_X;
    abs_setup_x.absinfo.minimum = 0;
    abs_setup_x.absinfo.maximum = width;
    if (c.ioctl(uinput_fd, c.UI_ABS_SETUP, &abs_setup_x) < 0) return error.UinputAbsSetupFailed;

    var abs_setup_y: c.uinput_abs_setup = std.mem.zeroes(c.uinput_abs_setup);
    abs_setup_y.code = c.ABS_Y;
    abs_setup_y.absinfo.minimum = 0;
    abs_setup_y.absinfo.maximum = height;
    if (c.ioctl(uinput_fd, c.UI_ABS_SETUP, &abs_setup_y) < 0) return error.UinputAbsSetupFailed;

    if (c.ioctl(uinput_fd, c.UI_DEV_CREATE) < 0) return error.UinputCreateFailed;

    return uinput_fd;
}

fn emitEvent(fd: i32, type_: u16, code: u16, value: i32) !void {
    var ev: c.input_event = std.mem.zeroes(c.input_event);
    ev.type = type_;
    ev.code = code;
    ev.value = value;
    
    // std.time.gettimeofday is unavailable, zeroed timeval is fine for uinput

    const bytes = std.mem.asBytes(&ev);
    const written = c.write(fd, bytes.ptr, bytes.len);
    if (written < 0 or written != bytes.len) {
        return error.UinputWriteFailed;
    }
}

fn emitSync(fd: i32) !void {
    try emitEvent(fd, c.EV_SYN, c.SYN_REPORT, 0);
}

// Global toggle for pausing/resuming the mouse via SIGUSR1
// removed duplicate handler and global variable

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    // Register SIGUSR1 signal handler for toggling pause
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSigusr1 },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.USR1, &act, null);

    var arg_it = try std.process.argsWithAllocator(gpa.allocator());
    defer arg_it.deinit();
    _ = arg_it.skip(); // skip program name

    var clicker = DwellClicker{};
    var arg_idx: usize = 1;
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--click")) {
            clicker.enabled = true;
        } else if (std.mem.eql(u8, arg, "--click-radius")) {
            if (arg_it.next()) |val_str| {
                clicker.click_radius = std.fmt.parseFloat(f64, val_str) catch {
                    std.log.err("Invalid click radius: {s}", .{val_str});
                    return error.InvalidArgument;
                };
            }
        } else if (std.mem.eql(u8, arg, "--click-dwell-ms")) {
            if (arg_it.next()) |val_str| {
                clicker.dwell_time_ms = std.fmt.parseInt(i64, val_str, 10) catch {
                    std.log.err("Invalid dwell time ms: {s}", .{val_str});
                    return error.InvalidArgument;
                };
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: tobiifree-mouse [options]
                \\
                \\Options:
                \\  --click                 Enable dwell clicking (disabled by default)
                \\  --click-radius <float>  Normalized radius for dwell bounding box (default: 0.05)
                \\  --click-dwell-ms <int>  Time in ms gaze must remain in radius to click (default: 1000)
                \\
            , .{});
            return;
        } else {
            std.log.warn("Unknown argument: {s}", .{arg});
        }
        arg_idx += 1;
    }
    
    // WARNING: Hardcoded resolution for demo purposes.
    // In a real app, you might want to configure this or read from X11/Wayland (if possible)
    const screen_w: i32 = 1920;
    const screen_h: i32 = 1200;

    std.log.info("Starting virtual mouse ({}x{}), dwell clicking: {}", .{screen_w, screen_h, clicker.enabled});

    // Register SIGUSR1 signal handler for hotkey pausing
    var sigaction: c.struct_sigaction = std.mem.zeroes(c.struct_sigaction);
    sigaction.__sigaction_handler.sa_handler = handleSigusr1;
    _ = c.sigaction(c.SIGUSR1, &sigaction, null);
    std.log.info("Registered SIGUSR1 listener. Send 'kill -SIGUSR1 {}' or 'pkill -SIGUSR1 tobiifree-mouse' to toggle pause.", .{std.posix.system.getpid()});

    const fd = try setupUinput(screen_w, screen_h);
    defer _ = c.ioctl(fd, c.UI_DEV_DESTROY);
    defer _ = c.close(fd);
    
    std.log.info("Virtual mouse created. Connecting to tobiifreed...", .{});

    var socket_buf: [512]u8 = undefined;
    const sock_path = protocol.socketPath(&socket_buf) orelse return error.PathTooLong;

    const stream = try std.net.connectUnixSocket(sock_path);
    defer stream.close();

    std.log.info("Connected to daemon socket.", .{});

    // Subscribe to gaze data
    var sub_buf: [protocol.HEADER_SIZE]u8 = undefined;
    const n = protocol.encodeCmd(&sub_buf, .subscribe, &.{});
    
    var w_idx: usize = 0;
    while (w_idx < n) {
        const w_res = try std.posix.write(stream.handle, sub_buf[w_idx..n]);
        if (w_res == 0) break;
        w_idx += w_res;
    }

    var buf: [1024]u8 align(8) = undefined;
    while (true) {
        var h_read: usize = 0;
        while (h_read < protocol.HEADER_SIZE) {
            const rx = try std.posix.read(stream.handle, buf[h_read..protocol.HEADER_SIZE]);
            if (rx == 0) break;
            h_read += rx;
        }
        if (h_read != protocol.HEADER_SIZE) break;

        const hdr = protocol.decodeHeader(buf[0..protocol.HEADER_SIZE]);
        if (hdr.payload_len > buf.len - protocol.HEADER_SIZE) {
            std.log.warn("Payload {} too large, skipping", .{hdr.payload_len});
            // We'll just read into dummy buffer or ignore the rest of the message for simplicity
            // In standard IO, stream.reader().skipBytes wouldn't be available here. Let's just break for simplicity on this error handling.
            break;
        }

        var p_read: usize = 0;
        const p_target = protocol.HEADER_SIZE + hdr.payload_len;
        while (p_read < hdr.payload_len) {
            const current = protocol.HEADER_SIZE + p_read;
            const rx = try std.posix.read(stream.handle, buf[current..p_target]);
            if (rx == 0) break;
            p_read += rx;
        }
        if (p_read != hdr.payload_len) break;

        if (hdr.msg_type == @intFromEnum(protocol.Srv.gaze)) {
            var gaze: core.GazeSample = undefined;
            @memcpy(std.mem.asBytes(&gaze), buf[protocol.HEADER_SIZE..][0..@sizeOf(core.GazeSample)]);

            // Gaze validity works on individual eyes: 0 = valid, 4 = not detected.
            // But we can also check if we have a valid 2D normalized gaze point:
            const left_valid = gaze.validity_L == 0;
            const right_valid = gaze.validity_R == 0;
            
            // Skip processing if paused via hotkey
            if (is_paused.load(.seq_cst)) {
                // Return to normal
                clicker.locked_x = null;
                clicker.locked_y = null;
                continue;
            }

            // Wait for both or either eye to be valid
            if (left_valid or right_valid) {
                // `gaze_point_2d_norm` is combined/filtered for both eyes
                const gaze_x: f64 = gaze.gaze_point_2d_norm[0];
                const gaze_y: f64 = gaze.gaze_point_2d_norm[1];

                // Ensure it's inside the bounds [0, 1]
                if (gaze_x >= 0.0 and gaze_x <= 1.0 and gaze_y >= 0.0 and gaze_y <= 1.0) {
                    if (clicker.processGaze(gaze_x, gaze_y, screen_w, screen_h)) |action| {
                        try emitEvent(fd, c.EV_ABS, c.ABS_X, action.x);
                        try emitEvent(fd, c.EV_ABS, c.ABS_Y, action.y);
                        
                        if (action.click) {
                            try emitEvent(fd, c.EV_KEY, c.BTN_LEFT, 1); // down
                            try emitSync(fd);
                            try emitEvent(fd, c.EV_KEY, c.BTN_LEFT, 0); // up
                        }
                        try emitSync(fd);
                    }
                }
            }
        }
    }
}