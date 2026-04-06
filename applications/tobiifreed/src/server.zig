// server.zig — unix socket server for tobiifreed.
//
// Accepts client connections, broadcasts gaze samples, dispatches commands.
// Single-threaded, non-blocking. Fixed-size client array (no allocator).

const std = @import("std");
const proto = @import("daemon_protocol");
const core = @import("tobiifree_core");

const log = std.log.scoped(.server);

const MAX_CLIENTS = 16;

const Client = struct {
    fd: std.posix.fd_t,
    subscribed: bool,
    // Per-client read buffer for incoming commands.
    buf: [4096]u8,
    buf_len: usize,
};

pub const ForwardFn = *const fn (client_fd: std.posix.fd_t, cmd_type: u8, payload: []const u8, is_ws: bool) void;

pub const Server = struct {
    listen_fd: std.posix.fd_t,
    clients: [MAX_CLIENTS]?Client,
    n_clients: usize,
    socket_path: [512]u8,
    socket_path_len: usize,
    forward_fn: ForwardFn,

    pub fn init(forward_fn: ForwardFn) !Server {
        var path_buf: [512]u8 = undefined;
        const path = proto.socketPath(&path_buf) orelse return error.NoSocketPath;

        // Ensure parent directory exists.
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
            const dir = path[0..sep];
            std.fs.cwd().makePath(dir) catch {};
        }

        // Remove stale socket.
        std.fs.cwd().deleteFile(path) catch {};

        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0);
        errdefer std.posix.close(fd);

        var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..path.len], path);

        try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
        try std.posix.listen(fd, 8);

        var self = Server{
            .listen_fd = fd,
            .clients = [_]?Client{null} ** MAX_CLIENTS,
            .n_clients = 0,
            .socket_path = undefined,
            .socket_path_len = path.len,
            .forward_fn = forward_fn,
        };
        @memcpy(self.socket_path[0..path.len], path);

        log.info("listening on {s}", .{path});
        return self;
    }

    /// Accept new clients (non-blocking).
    pub fn acceptClients(self: *Server) void {
        while (true) {
            const fd = std.posix.accept(self.listen_fd, null, null, std.posix.SOCK.NONBLOCK) catch break;

            // Find empty slot.
            var placed = false;
            for (&self.clients) |*slot| {
                if (slot.* == null) {
                    slot.* = .{
                        .fd = fd,
                        .subscribed = false,
                        .buf = undefined,
                        .buf_len = 0,
                    };
                    self.n_clients += 1;
                    placed = true;
                    log.info("client connected (total: {})", .{self.n_clients});
                    break;
                }
            }
            if (!placed) {
                log.warn("max clients reached, rejecting", .{});
                std.posix.close(fd);
            }
        }
    }

    /// Read and dispatch commands from all clients.
    pub fn readCommands(self: *Server) void {
        for (&self.clients) |*slot| {
            const client = &(slot.* orelse continue);
            const space = client.buf.len - client.buf_len;
            if (space == 0) {
                client.buf_len = 0;
                continue;
            }
            const n = std.posix.read(client.fd, client.buf[client.buf_len..]) catch |err| {
                if (err == error.WouldBlock) continue;
                // Client disconnected.
                self.removeClient(slot);
                continue;
            };
            if (n == 0) {
                // EOF.
                self.removeClient(slot);
                continue;
            }
            client.buf_len += n;

            // Process complete messages.
            var pos: usize = 0;
            while (pos + proto.HEADER_SIZE <= client.buf_len) {
                const hdr = proto.decodeHeader(client.buf[pos..][0..proto.HEADER_SIZE]);
                const msg_end = pos + proto.HEADER_SIZE + hdr.payload_len;
                if (msg_end > client.buf_len) break;

                self.dispatchCmd(client, hdr.msg_type, client.buf[pos + proto.HEADER_SIZE .. msg_end]);
                pos = msg_end;
            }

            // Shift remaining.
            if (pos > 0) {
                const remaining = client.buf_len - pos;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, client.buf[0..remaining], client.buf[pos .. pos + remaining]);
                }
                client.buf_len = remaining;
            }
        }
    }

    fn dispatchCmd(self: *Server, client: *Client, msg_type: u8, payload: []const u8) void {
        if (msg_type == @intFromEnum(proto.Cmd.subscribe)) {
            client.subscribed = true;
            log.info("client subscribed to gaze", .{});
            return;
        }
        if (msg_type == @intFromEnum(proto.Cmd.disconnect)) {
            return;
        }
        // Forward all other commands to the tracker via USB.
        self.forward_fn(client.fd, msg_type, payload, false);
    }

    /// Broadcast a gaze sample to all subscribed clients.
    pub fn broadcastGaze(self: *Server, sample: *const core.GazeSample) void {
        var msg: [proto.HEADER_SIZE + @sizeOf(core.GazeSample)]u8 = undefined;
        proto.encodeGaze(&msg, sample);

        for (&self.clients) |*slot| {
            const client = &(slot.* orelse continue);
            if (!client.subscribed) continue;
            _ = std.posix.write(client.fd, &msg) catch {
                self.removeClient(slot);
            };
        }
    }

    fn removeClient(self: *Server, slot: *?Client) void {
        if (slot.*) |client| {
            std.posix.close(client.fd);
            slot.* = null;
            self.n_clients -= 1;
            log.info("client disconnected (total: {})", .{self.n_clients});
        }
    }

    pub fn deinit(self: *Server) void {
        // Close all clients.
        for (&self.clients) |*slot| {
            if (slot.*) |client| {
                std.posix.close(client.fd);
                slot.* = null;
            }
        }
        self.n_clients = 0;

        // Close listen socket.
        std.posix.close(self.listen_fd);

        // Unlink socket file.
        const path = self.socket_path[0..self.socket_path_len];
        std.fs.cwd().deleteFile(path) catch {};
        log.info("socket removed", .{});
    }
};
