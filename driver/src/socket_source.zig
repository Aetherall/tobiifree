// socket_source.zig — GazeSource backend that connects to tobiifreed over a unix socket.
//
// Receives gaze samples broadcast by the daemon. Sends commands for
// display area, realm, calibration, etc.

const std = @import("std");
const proto = @import("daemon_protocol");
const gs = @import("gaze_source");

const log = std.log.scoped(.socket);

pub const SocketSource = struct {
    fd: std.posix.fd_t,
    gaze_cb: ?gs.GazeFn,
    // Read buffer: accumulates partial messages.
    buf: [8192]u8,
    buf_len: usize,

    pub fn init() !SocketSource {
        var path_buf: [512]u8 = undefined;
        const path = proto.socketPath(&path_buf) orelse {
            log.warn("no socket path (XDG_RUNTIME_DIR not set?)", .{});
            return error.NoSocketPath;
        };

        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0);
        errdefer std.posix.close(fd);

        var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
        @memset(&addr.path, 0);
        // Copy path into sockaddr.
        if (path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;

        log.info("connecting to {s}", .{path});
        std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch |err| {
            return switch (err) {
                error.ConnectionRefused => {
                    log.info("daemon not running (connection refused)", .{});
                    return error.NoDaemon;
                },
                error.FileNotFound => {
                    log.info("daemon not running (socket not found)", .{});
                    return error.NoDaemon;
                },
                else => err,
            };
        };

        // Send subscribe command immediately.
        var cmd_buf: [proto.HEADER_SIZE + 4]u8 = undefined;
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, 0x500, .little); // STREAM_GAZE
        const n = proto.encodeCmd(&cmd_buf, .subscribe, &payload);
        _ = std.posix.write(fd, cmd_buf[0..n]) catch {};

        log.info("connected to tobiifreed", .{});
        return .{
            .fd = fd,
            .gaze_cb = null,
            .buf = undefined,
            .buf_len = 0,
        };
    }

    pub fn gazeSource(self: *SocketSource) gs.GazeSource {
        return .{ .socket = self };
    }

    pub fn onGaze(self: *SocketSource, cb: gs.GazeFn) void {
        self.gaze_cb = cb;
    }

    pub fn poll(self: *SocketSource) void {
        // Non-blocking read from socket, parse framed messages.
        while (true) {
            const space = self.buf.len - self.buf_len;
            if (space == 0) {
                // Buffer full with no complete message — reset (shouldn't happen).
                self.buf_len = 0;
                break;
            }
            const n = std.posix.read(self.fd, self.buf[self.buf_len..]) catch break;
            if (n == 0) break; // EOF
            self.buf_len += n;

            // Process complete messages.
            self.processMessages();
        }
    }

    fn processMessages(self: *SocketSource) void {
        var pos: usize = 0;
        while (pos + proto.HEADER_SIZE <= self.buf_len) {
            const hdr = proto.decodeHeader(self.buf[pos..][0..proto.HEADER_SIZE]);
            const msg_end = pos + proto.HEADER_SIZE + hdr.payload_len;
            if (msg_end > self.buf_len) break; // incomplete message

            const payload = self.buf[pos + proto.HEADER_SIZE .. msg_end];
            self.dispatchMessage(hdr.msg_type, payload);
            pos = msg_end;
        }

        // Shift remaining bytes to front.
        if (pos > 0) {
            const remaining = self.buf_len - pos;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[pos .. pos + remaining]);
            }
            self.buf_len = remaining;
        }
    }

    fn dispatchMessage(self: *SocketSource, msg_type: u8, payload: []const u8) void {
        if (msg_type == @intFromEnum(proto.Srv.gaze)) {
            if (payload.len >= @sizeOf(proto.GazeSample)) {
                if (self.gaze_cb) |cb| {
                    // Copy into aligned local — payload slice from read buffer has no alignment guarantee.
                    var sample: proto.GazeSample = undefined;
                    @memcpy(std.mem.asBytes(&sample), payload[0..@sizeOf(proto.GazeSample)]);
                    cb(&sample);
                }
            }
        }
        // Future: handle response, display_area, error messages.
    }

    pub fn deinit(self: *SocketSource) void {
        log.info("disconnecting", .{});
        // Send disconnect.
        var cmd_buf: [proto.HEADER_SIZE]u8 = undefined;
        proto.encodeHeader(&cmd_buf, @intFromEnum(proto.Cmd.disconnect), 0);
        _ = std.posix.write(self.fd, &cmd_buf) catch {};
        std.posix.close(self.fd);
    }
};
