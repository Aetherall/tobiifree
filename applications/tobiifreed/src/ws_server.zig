// ws_server.zig — WebSocket server for tobiifreed.
//
// Accepts browser clients over TCP, performs the HTTP upgrade handshake,
// and broadcasts gaze samples as binary WebSocket frames.
// Also receives daemon-protocol commands from clients and forwards them.
// Single-threaded, non-blocking. Fixed-size client array (no allocator).

const std = @import("std");
const core = @import("tobiifree_core");
const proto = @import("daemon_protocol");

const log = std.log.scoped(.ws);

const MAX_CLIENTS = 16;
const WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

const ClientState = enum { handshake, open };

const WsClient = struct {
    fd: std.posix.fd_t,
    state: ClientState,
    buf: [4096]u8,
    buf_len: usize,
    subscribed: bool,
};

pub const ForwardFn = *const fn (client_fd: std.posix.fd_t, cmd_type: u8, payload: []const u8, is_ws: bool) void;

pub const WsServer = struct {
    listen_fd: std.posix.fd_t,
    clients: [MAX_CLIENTS]?WsClient,
    n_clients: usize,
    forward_fn: ForwardFn,

    pub fn init(addr: u32, port: u16, forward_fn: ForwardFn) !WsServer {
        const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0);
        errdefer std.posix.close(fd);

        // Allow address reuse.
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};

        const sock_addr = std.posix.sockaddr.in{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = addr,
        };
        try std.posix.bind(fd, @ptrCast(&sock_addr), @sizeOf(std.posix.sockaddr.in));
        try std.posix.listen(fd, 8);

        const addr_bytes: [4]u8 = @bitCast(addr);
        log.info("listening on {d}.{d}.{d}.{d}:{d}", .{ addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3], port });

        return .{
            .listen_fd = fd,
            .clients = [_]?WsClient{null} ** MAX_CLIENTS,
            .n_clients = 0,
            .forward_fn = forward_fn,
        };
    }

    pub fn deinit(self: *WsServer) void {
        for (&self.clients) |*slot| {
            if (slot.*) |client| {
                std.posix.close(client.fd);
                slot.* = null;
            }
        }
        self.n_clients = 0;
        std.posix.close(self.listen_fd);
        log.info("stopped", .{});
    }

    /// Accept new TCP connections (non-blocking).
    pub fn acceptClients(self: *WsServer) void {
        while (true) {
            const fd = std.posix.accept(self.listen_fd, null, null, std.posix.SOCK.NONBLOCK) catch break;

            var placed = false;
            for (&self.clients) |*slot| {
                if (slot.* == null) {
                    slot.* = .{
                        .fd = fd,
                        .state = .handshake,
                        .buf = undefined,
                        .buf_len = 0,
                        .subscribed = false,
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

    /// Read from all clients: drive handshakes and handle WebSocket frames.
    pub fn readClients(self: *WsServer) void {
        for (&self.clients) |*slot| {
            const client = &(slot.* orelse continue);
            const space = client.buf.len - client.buf_len;
            if (space == 0) {
                // Buffer full without completing handshake or frame — drop.
                self.removeClient(slot);
                continue;
            }
            const n = std.posix.read(client.fd, client.buf[client.buf_len..]) catch |err| {
                if (err == error.WouldBlock) continue;
                log.debug("read error on fd={}: {}", .{ client.fd, err });
                self.removeClient(slot);
                continue;
            };
            if (n == 0) {
                log.debug("EOF on fd={} (state={s})", .{ client.fd, @tagName(client.state) });
                self.removeClient(slot);
                continue;
            }
            client.buf_len += n;

            switch (client.state) {
                .handshake => self.tryHandshake(client, slot),
                .open => self.handleWsFrames(client, slot),
            }
        }
    }

    /// Broadcast a gaze sample as a binary WebSocket frame to all subscribed open clients.
    pub fn broadcastGaze(self: *WsServer, sample: *const core.GazeSample) void {
        // Wrap in daemon protocol framing first, then in a WebSocket binary frame.
        var msg: [proto.HEADER_SIZE + @sizeOf(core.GazeSample)]u8 = undefined;
        proto.encodeGaze(&msg, sample);

        var frame: [4 + msg.len]u8 = undefined;
        const frame_len = encodeWsFrame(&frame, &msg);

        for (&self.clients) |*slot| {
            const client = &(slot.* orelse continue);
            if (client.state != .open or !client.subscribed) continue;
            _ = std.posix.write(client.fd, frame[0..frame_len]) catch {
                self.removeClient(slot);
            };
        }
    }

    /// Send a daemon-protocol message to a specific client by fd (wrapped in a WS binary frame).
    /// Called by main.zig to route command responses back.
    pub fn sendToClient(self: *WsServer, target_fd: std.posix.fd_t, data: []const u8) void {
        // Wrap in a WebSocket binary frame.
        var frame: [4 + 8192]u8 = undefined;
        const frame_len = encodeWsFrame(&frame, data);

        for (&self.clients) |*slot| {
            const client = &(slot.* orelse continue);
            if (client.fd == target_fd and client.state == .open) {
                _ = std.posix.write(client.fd, frame[0..frame_len]) catch {
                    self.removeClient(slot);
                };
                return;
            }
        }
    }

    // ── WebSocket handshake ──────────────────────────────────────────

    fn tryHandshake(self: *WsServer, client: *WsClient, slot: *?WsClient) void {
        const data = client.buf[0..client.buf_len];

        // Wait for complete HTTP headers.
        const header_end = findHeaderEnd(data) orelse return;

        // Extract Sec-WebSocket-Key.
        const key = extractWsKey(data[0..header_end]) orelse {
            log.warn("missing Sec-WebSocket-Key, dropping client", .{});
            self.removeClient(slot);
            return;
        };

        // Compute accept hash: SHA1(key ++ WS_MAGIC) → base64.
        var sha_input: [64 + WS_MAGIC.len]u8 = undefined;
        @memcpy(sha_input[0..key.len], key);
        @memcpy(sha_input[key.len..][0..WS_MAGIC.len], WS_MAGIC);
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(sha_input[0 .. key.len + WS_MAGIC.len], &digest, .{});
        var accept: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept, &digest);

        log.debug("ws key=[{s}] accept=[{s}]", .{ key, accept });

        // Send 101 response.
        const response = "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: ";
        const suffix = "\r\n\r\n";

        var resp_buf: [response.len + accept.len + suffix.len]u8 = undefined;
        @memcpy(resp_buf[0..response.len], response);
        @memcpy(resp_buf[response.len..][0..accept.len], &accept);
        @memcpy(resp_buf[response.len + accept.len ..][0..suffix.len], suffix);

        const written = std.posix.write(client.fd, &resp_buf) catch |err| {
            log.err("handshake write failed: {}", .{err});
            self.removeClient(slot);
            return;
        };
        log.debug("handshake response: wrote {}/{} bytes", .{ written, resp_buf.len });

        client.state = .open;
        // Preserve any data after the HTTP headers (WebSocket frames sent in same TCP segment).
        const after = client.buf_len - header_end;
        if (after > 0) {
            std.mem.copyForwards(u8, client.buf[0..after], client.buf[header_end..client.buf_len]);
        }
        client.buf_len = after;
        log.info("client upgraded to WebSocket (trailing={} bytes)", .{after});
    }

    fn findHeaderEnd(data: []const u8) ?usize {
        if (data.len < 4) return null;
        for (0..data.len - 3) |i| {
            if (data[i] == '\r' and data[i + 1] == '\n' and data[i + 2] == '\r' and data[i + 3] == '\n') {
                return i + 4;
            }
        }
        return null;
    }

    fn extractWsKey(headers: []const u8) ?[]const u8 {
        const needle = "Sec-WebSocket-Key: ";
        for (0..headers.len) |i| {
            if (i + needle.len > headers.len) break;
            if (eqlIgnoreCase(headers[i..][0..needle.len], needle)) {
                const start = i + needle.len;
                const end = std.mem.indexOfScalarPos(u8, headers, start, '\r') orelse headers.len;
                const trimmed = std.mem.trim(u8, headers[start..end], " ");
                if (trimmed.len > 0 and trimmed.len <= 64) return trimmed;
                return null;
            }
        }
        return null;
    }

    fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
            const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
            if (la != lb) return false;
        }
        return true;
    }

    // ── WebSocket frame handling ─────────────────────────────────────

    fn handleWsFrames(self: *WsServer, client: *WsClient, slot: *?WsClient) void {
        var pos: usize = 0;
        while (pos < client.buf_len) {
            const remaining = client.buf_len - pos;
            if (remaining < 2) break;

            const b0 = client.buf[pos];
            const b1 = client.buf[pos + 1];
            const opcode = b0 & 0x0F;
            const masked = (b1 & 0x80) != 0;
            var payload_len: usize = b1 & 0x7F;
            var header_len: usize = 2;

            if (payload_len == 126) {
                if (remaining < 4) break;
                payload_len = std.mem.readInt(u16, client.buf[pos + 2 ..][0..2], .big);
                header_len = 4;
            } else if (payload_len == 127) {
                if (remaining < 10) break;
                const len64 = std.mem.readInt(u64, client.buf[pos + 2 ..][0..8], .big);
                if (len64 > 65536) {
                    self.removeClient(slot);
                    return;
                }
                payload_len = @intCast(len64);
                header_len = 10;
            }

            const mask_len: usize = if (masked) 4 else 0;
            const total = header_len + mask_len + payload_len;
            if (remaining < total) break;

            if (opcode == 0x8) {
                // Close frame — send close back.
                const close_frame = [_]u8{ 0x88, 0x00 };
                _ = std.posix.write(client.fd, &close_frame) catch {};
                self.removeClient(slot);
                return;
            } else if (opcode == 0x9) {
                // Ping — respond with pong.
                self.sendPong(client, client.buf[pos + header_len + mask_len ..][0..payload_len], if (masked) client.buf[pos + header_len ..][0..4] else null);
            } else if (opcode == 0x2) {
                // Binary frame — daemon protocol message.
                var unmasked: [4096]u8 = undefined;
                const payload_data = client.buf[pos + header_len + mask_len ..][0..payload_len];
                if (masked) {
                    const mask = client.buf[pos + header_len ..][0..4];
                    for (0..payload_len) |i| {
                        unmasked[i] = payload_data[i] ^ mask[i % 4];
                    }
                    self.dispatchDaemonMsg(client, unmasked[0..payload_len]);
                } else {
                    self.dispatchDaemonMsg(client, payload_data);
                }
            }
            // Ignore text frames, pong frames.

            pos += total;
        }

        // Shift remaining.
        if (pos > 0) {
            const remain = client.buf_len - pos;
            if (remain > 0) {
                std.mem.copyForwards(u8, client.buf[0..remain], client.buf[pos .. pos + remain]);
            }
            client.buf_len = remain;
        }
    }

    /// Dispatch a daemon-protocol message received from a WebSocket client.
    fn dispatchDaemonMsg(self: *WsServer, client: *WsClient, data: []const u8) void {
        if (data.len < proto.HEADER_SIZE) return;

        const hdr = proto.decodeHeader(data[0..proto.HEADER_SIZE]);
        const payload_end = proto.HEADER_SIZE + hdr.payload_len;
        if (data.len < payload_end) return;

        const payload = data[proto.HEADER_SIZE..payload_end];

        if (hdr.msg_type == @intFromEnum(proto.Cmd.subscribe)) {
            client.subscribed = true;
            log.info("ws client subscribed to gaze", .{});
            return;
        }
        if (hdr.msg_type == @intFromEnum(proto.Cmd.disconnect)) {
            return;
        }
        // Forward to tracker via USB.
        self.forward_fn(client.fd, hdr.msg_type, payload, true);
    }

    fn sendPong(_: *WsServer, client: *WsClient, payload: []const u8, mask: ?[]const u8) void {
        // Unmask if needed, build pong frame.
        var pong_buf: [130]u8 = undefined; // 2 + max 125 payload
        pong_buf[0] = 0x8A; // FIN + pong
        const len = @min(payload.len, 125);
        pong_buf[1] = @intCast(len);
        if (mask) |m| {
            for (0..len) |i| {
                pong_buf[2 + i] = payload[i] ^ m[i % 4];
            }
        } else {
            @memcpy(pong_buf[2..][0..len], payload[0..len]);
        }
        _ = std.posix.write(client.fd, pong_buf[0 .. 2 + len]) catch return;
    }

    // ── Frame encoding (server → client, unmasked) ───────────────────

    fn encodeWsFrame(buf: []u8, payload: []const u8) usize {
        buf[0] = 0x82; // FIN + binary opcode
        if (payload.len < 126) {
            buf[1] = @intCast(payload.len);
            @memcpy(buf[2..][0..payload.len], payload);
            return 2 + payload.len;
        } else {
            buf[1] = 126;
            std.mem.writeInt(u16, buf[2..4], @intCast(payload.len), .big);
            @memcpy(buf[4..][0..payload.len], payload);
            return 4 + payload.len;
        }
    }

    fn removeClient(self: *WsServer, slot: *?WsClient) void {
        if (slot.*) |client| {
            std.posix.close(client.fd);
            slot.* = null;
            self.n_clients -= 1;
            log.info("client disconnected (total: {})", .{self.n_clients});
        }
    }
};
