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
        // All USB OUT transfers use the per-transfer envelope format:
        //   [00 00 00 00][data_len: u32 LE][data_len bytes]
        // where data_len = bytes in THIS transfer after the 8-byte header.
        //
        // For small frames (data.len ≤ 8192) wrapEnvelopeOut already writes
        // ttp_len at bytes 4-7, and ttp_len == data.len − 8 == data_len, so
        // no patching is needed.
        //
        // For large frames the first chunk's bytes 4-7 hold the full ttp_len
        // (total TTP frame length) which is wrong for a fragmented transfer;
        // it must be overwritten with CONT_DATA (8184 = 8192 − 8) before
        // sending.  The device learns the total expected payload length from
        // the plen field inside the TTP header (bytes 8-31), not from the
        // USB envelope.
        const CHUNK: usize = 8192;
        const CONT_HDR: usize = 8;
        const CONT_DATA: usize = CHUNK - CONT_HDR; // 8184

        // ── Small frame: fits in one transfer, send as-is ──────────────────
        if (data.len <= CHUNK) {
            var xfr: c_int = 0;
            const r = c.libusb_bulk_transfer(
                self.usb_handle, EP_OUT,
                @constCast(data.ptr), @intCast(data.len),
                &xfr, 2000,
            );
            if (r != 0 or xfr != @as(c_int, @intCast(data.len))) {
                log.err("send failed: r={d} transferred={d}/{d}", .{ r, xfr, data.len });
                return false;
            }
            return true;
        }

        // ── Large frame: first chunk with bytes 4-7 patched to CONT_DATA ──
        var first_buf: [CHUNK]u8 = undefined;
        @memcpy(&first_buf, data[0..CHUNK]);
        // Overwrite ttp_len with the data length in this transfer only.
        first_buf[4] = @as(u8, @truncate(CONT_DATA));
        first_buf[5] = @as(u8, @truncate(CONT_DATA >> 8));
        first_buf[6] = @as(u8, @truncate(CONT_DATA >> 16));
        first_buf[7] = @as(u8, @truncate(CONT_DATA >> 24));
        {
            var xfr: c_int = 0;
            const r = c.libusb_bulk_transfer(
                self.usb_handle, EP_OUT,
                &first_buf, @intCast(CHUNK),
                &xfr, 2000,
            );
            if (r != 0 or xfr != @as(c_int, @intCast(CHUNK))) {
                log.err("send first chunk failed: r={d} transferred={d}/{d}", .{ r, xfr, CHUNK });
                return false;
            }
        }

        // ── Continuation chunks ────────────────────────────────────────────
        var cont_buf: [CHUNK]u8 = undefined;
        var offset: usize = CHUNK;
        while (offset < data.len) {
            const data_end = @min(offset + CONT_DATA, data.len);
            const data_len = data_end - offset;

            // Continuation envelope: [00 00 00 00][data_len: u32 LE]
            cont_buf[0] = 0x00; cont_buf[1] = 0x00;
            cont_buf[2] = 0x00; cont_buf[3] = 0x00;
            cont_buf[4] = @as(u8, @truncate(data_len));
            cont_buf[5] = @as(u8, @truncate(data_len >> 8));
            cont_buf[6] = @as(u8, @truncate(data_len >> 16));
            cont_buf[7] = @as(u8, @truncate(data_len >> 24));
            @memcpy(cont_buf[CONT_HDR..][0..data_len], data[offset..data_end]);

            const chunk_total = CONT_HDR + data_len;
            var xfr: c_int = 0;
            const r = c.libusb_bulk_transfer(
                self.usb_handle, EP_OUT,
                &cont_buf, @intCast(chunk_total),
                &xfr, 2000,
            );
            if (r != 0 or xfr != @as(c_int, @intCast(chunk_total))) {
                log.err("send continuation at offset={d} failed: r={d} transferred={d}/{d}",
                    .{ offset, r, xfr, chunk_total });
                return false;
            }
            offset = data_end;
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
