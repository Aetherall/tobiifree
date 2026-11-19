// image_server.zig — IR image socket of tobiifreed.
//
// $XDG_RUNTIME_DIR/tobiifreed/image.sock: every client gets every IR frame
// (TTP stream 0x501) as a Srv.stream_data message; nothing is read from
// clients but their EOF. The socket is 0600 and only peers with the
// daemon's own uid are accepted, so for a system daemon only root can read
// the camera, and nobody else can pose as the daemon in its root-owned
// directory.
//
// Writes never block the main loop: the part of a frame a client could not
// take is kept and sent first; frames arriving meanwhile are dropped for that
// client. Single-threaded, non-blocking, fixed-size (no allocator).

const std = @import("std");
const proto = @import("daemon_protocol");

const log = std.log.scoped(.image_server);

const MAX_CLIENTS = 4;

/// Max TTP payload of a frame (280×280 8-bit frames are ~78 KB).
pub const FRAME_MAX = 128 * 1024;

const Client = struct {
    fd: std.posix.fd_t,
    out: [proto.STREAM_DATA_HEADER_SIZE + FRAME_MAX]u8,
    out_pos: usize,
    out_len: usize,

    /// Send what is left of the current frame. False if the client is gone.
    fn flush(self: *Client) bool {
        while (self.out_pos < self.out_len) {
            const n = std.posix.send(self.fd, self.out[self.out_pos..self.out_len], std.posix.MSG.NOSIGNAL) catch |err| {
                return err == error.WouldBlock;
            };
            self.out_pos += n;
        }
        return true;
    }
};

pub const ImageServer = struct {
    listen_fd: std.posix.fd_t,
    clients: [MAX_CLIENTS]?Client,
    n_clients: usize,
    socket_path: [512]u8,
    socket_path_len: usize,

    /// Initialise in place: `self` must not be on the stack (~0.5 MB).
    pub fn init(self: *ImageServer) !void {
        var path_buf: [512]u8 = undefined;
        const path = proto.imageSocketPath(&path_buf) orelse return error.NoSocketPath;
        if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
        std.fs.cwd().deleteFile(path) catch {};

        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
        errdefer std.posix.close(fd);
        var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
        @memset(&addr.path, 0);
        if (path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);
        try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
        errdefer std.fs.cwd().deleteFile(path) catch {};
        try std.posix.fchmodat(std.posix.AT.FDCWD, path, 0o600, 0);
        try std.posix.listen(fd, 4);

        self.listen_fd = fd;
        self.n_clients = 0;
        self.socket_path_len = path.len;
        @memcpy(self.socket_path[0..path.len], path);
        for (&self.clients) |*slot| slot.* = null;
        log.info("IR images on {s} (uid {d} only)", .{ path, std.os.linux.geteuid() });
    }

    pub fn acceptClients(self: *ImageServer) void {
        while (true) {
            const fd = std.posix.accept(self.listen_fd, null, null, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC) catch break;
            var cred: extern struct { pid: i32, uid: u32, gid: u32 } = undefined;
            std.posix.getsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.PEERCRED, std.mem.asBytes(&cred)) catch {
                std.posix.close(fd);
                continue;
            };
            if (cred.uid != std.os.linux.geteuid()) {
                log.warn("rejected image client pid {d} uid {d}", .{ cred.pid, cred.uid });
                std.posix.close(fd);
                continue;
            }
            for (&self.clients) |*slot| {
                if (slot.* != null) continue;
                slot.* = .{ .fd = fd, .out = undefined, .out_pos = 0, .out_len = 0 };
                self.n_clients += 1;
                log.info("image client pid {d} connected (total: {d})", .{ cred.pid, self.n_clients });
                break;
            } else {
                log.warn("max image clients, rejecting pid {d}", .{cred.pid});
                std.posix.close(fd);
            }
        }
    }

    /// Drop clients that hung up; continue partly sent frames.
    pub fn service(self: *ImageServer) void {
        for (&self.clients) |*slot| {
            const client = &(slot.* orelse continue);
            var buf: [256]u8 = undefined;
            const gone = if (std.posix.read(client.fd, &buf)) |n| n == 0 else |err| err != error.WouldBlock;
            if (gone or !client.flush()) self.removeClient(slot);
        }
    }

    pub fn broadcast(self: *ImageServer, stream_id: u16, payload: []const u8) void {
        if (payload.len > FRAME_MAX) return;
        for (&self.clients) |*slot| {
            const client = &(slot.* orelse continue);
            if (client.out_pos < client.out_len) continue; // still sending the previous frame
            proto.encodeStreamDataHeader(client.out[0..proto.STREAM_DATA_HEADER_SIZE], stream_id, @intCast(payload.len));
            @memcpy(client.out[proto.STREAM_DATA_HEADER_SIZE..][0..payload.len], payload);
            client.out_pos = 0;
            client.out_len = proto.STREAM_DATA_HEADER_SIZE + payload.len;
            if (!client.flush()) self.removeClient(slot);
        }
    }

    fn removeClient(self: *ImageServer, slot: *?Client) void {
        const client = slot.* orelse return;
        std.posix.close(client.fd);
        slot.* = null;
        self.n_clients -= 1;
        log.info("image client disconnected (total: {d})", .{self.n_clients});
    }

    pub fn deinit(self: *ImageServer) void {
        for (&self.clients) |*slot| if (slot.* != null) self.removeClient(slot);
        std.posix.close(self.listen_fd);
        std.fs.cwd().deleteFile(self.socket_path[0..self.socket_path_len]) catch {};
    }
};
