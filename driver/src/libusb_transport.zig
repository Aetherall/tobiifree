// libusb_transport.zig — USB transport for the Tobii ET5 via libusb.
//
// recv() blocks until the device sends data (kernel-woken, no polling).
// This is the equivalent of WebUSB's `await transferIn()`.
// Callers that need concurrency should run poll() on a dedicated thread.

const std = @import("std");
const c = @cImport({
    @cInclude("libusb.h");
});

const log = std.log.scoped(.usb);

pub const LibusbTransport = struct {
    usb_ctx: ?*c.libusb_context,
    usb_handle: ?*c.libusb_device_handle,

    const VID: u16 = 0x2104;
    const PID: u16 = 0x0313;
    const EP_IN: u8 = 0x83;
    const EP_OUT: u8 = 0x05;

    pub const Error = error{
        LibusbInit,
        DeviceNotFound,
        ClaimInterface,
        SessionOpen,
    };

    pub fn init() Error!LibusbTransport {
        var self = LibusbTransport{
            .usb_ctx = null,
            .usb_handle = null,
        };

        if (c.libusb_init(&self.usb_ctx) != 0) {
            log.err("libusb_init failed", .{});
            return error.LibusbInit;
        }

        self.usb_handle = c.libusb_open_device_with_vid_pid(self.usb_ctx, VID, PID);
        if (self.usb_handle == null) {
            log.err("device {x:0>4}:{x:0>4} not found", .{ VID, PID });
            c.libusb_exit(self.usb_ctx);
            return error.DeviceNotFound;
        }
        log.info("opened device {x:0>4}:{x:0>4}", .{ VID, PID });

        if (c.libusb_kernel_driver_active(self.usb_handle, 0) == 1) {
            log.debug("detaching kernel driver", .{});
            _ = c.libusb_detach_kernel_driver(self.usb_handle, 0);
        }

        if (c.libusb_claim_interface(self.usb_handle, 0) != 0) {
            log.err("claim_interface failed (device busy?)", .{});
            c.libusb_close(self.usb_handle);
            c.libusb_exit(self.usb_ctx);
            return error.ClaimInterface;
        }
        log.debug("claimed interface 0", .{});

        // Session-open: vendor control 0x41.
        if (c.libusb_control_transfer(self.usb_handle, 0x40 | 0x01, 0x41, 0, 0, null, 0, 1000) < 0) {
            log.err("session-open (ctrl 0x41) failed", .{});
            self.releaseAndClose();
            return error.SessionOpen;
        }
        log.info("session opened", .{});

        return self;
    }

    pub fn send(self: *LibusbTransport, data: []const u8) bool {
        var transferred: c_int = 0;
        const r = c.libusb_bulk_transfer(self.usb_handle, EP_OUT, @constCast(data.ptr), @intCast(data.len), &transferred, 1000);
        if (r != 0 or transferred != @as(c_int, @intCast(data.len))) {
            log.err("send failed: r={d} transferred={d}/{d}", .{ r, transferred, data.len });
            return false;
        }
        return true;
    }

    /// Blocking receive — blocks until the device sends data or timeout.
    /// The kernel wakes the thread when a USB packet arrives (no polling).
    /// Uses a short timeout so callers can check for shutdown.
    pub fn recv(self: *LibusbTransport, buf: []u8) ?usize {
        return self.recvTimeout(buf, 100);
    }

    /// Non-blocking receive — returns immediately if no data is available.
    pub fn tryRecv(self: *LibusbTransport, buf: []u8) ?usize {
        return self.recvTimeout(buf, 1);
    }

    fn recvTimeout(self: *LibusbTransport, buf: []u8, timeout_ms: c_uint) ?usize {
        var transferred: c_int = 0;
        const r = c.libusb_bulk_transfer(self.usb_handle, EP_IN, buf.ptr, @intCast(buf.len), &transferred, timeout_ms);
        if (r == 0 and transferred > 0) return @intCast(transferred);
        // LIBUSB_ERROR_TIMEOUT (-7) is expected, not an error.
        if (r != 0 and r != -7) {
            log.debug("recv error: {d}", .{r});
        }
        return null;
    }

    pub fn deinit(self: *LibusbTransport) void {
        // Session-close: vendor control 0x42.
        if (self.usb_handle) |h| {
            _ = c.libusb_control_transfer(h, 0x40 | 0x01, 0x42, 0, 0, null, 0, 500);
            log.info("session closed", .{});
        }
        self.releaseAndClose();
    }

    fn releaseAndClose(self: *LibusbTransport) void {
        if (self.usb_handle) |h| {
            _ = c.libusb_release_interface(h, 0);
            c.libusb_close(h);
            self.usb_handle = null;
        }
        if (self.usb_ctx) |ctx| {
            c.libusb_exit(ctx);
            self.usb_ctx = null;
        }
    }
};
