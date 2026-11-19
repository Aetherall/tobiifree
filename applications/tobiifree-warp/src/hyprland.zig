// hyprland.zig — cursor backend talking to Hyprland's IPC socket directly
// ($XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock): one
// connection per request, as hyprctl does, ~0.1–0.5 ms each.
//
// Cursor move: this Hyprland's `dispatch` takes Lua
//   dispatch hl.dsp.cursor.move({x = X, y = Y})
// (global logical coordinates). Older, non-Lua Hyprland takes
//   dispatch movecursor X Y
// The Lua form is tried first; on an error reply the legacy form is tried
// and whichever worked is remembered.

const std = @import("std");
const layout = @import("layout.zig");

const log = std.log.scoped(.hyprland);

pub const Hyprland = struct {
    gpa: std.mem.Allocator,
    path_buf: [512]u8 = undefined,
    /// Resolved socket path is path_buf[0..path_len] (0 = not resolved). A
    /// length, not a slice: the struct gets copied.
    path_len: usize = 0,
    dialect: enum { unknown, lua, legacy } = .unknown,

    pub fn init(gpa: std.mem.Allocator) Hyprland {
        return .{ .gpa = gpa };
    }

    /// Socket of the running instance: $HYPRLAND_INSTANCE_SIGNATURE if set,
    /// else the most recently started instance under $XDG_RUNTIME_DIR/hypr
    /// (services started by systemd may lack the variable).
    fn resolve(self: *Hyprland) ![]const u8 {
        if (self.path_len > 0) return self.path_buf[0..self.path_len];
        const rt = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDir;
        if (std.posix.getenv("HYPRLAND_INSTANCE_SIGNATURE")) |sig| {
            const p = try std.fmt.bufPrint(&self.path_buf, "{s}/hypr/{s}/.socket.sock", .{ rt, sig });
            if (std.fs.cwd().access(p, .{})) |_| {
                self.path_len = p.len;
                return p;
            } else |_| {}
        }
        var dir_buf: [512]u8 = undefined;
        const hypr = try std.fmt.bufPrint(&dir_buf, "{s}/hypr", .{rt});
        var dir = std.fs.cwd().openDir(hypr, .{ .iterate = true }) catch return error.NoHyprland;
        defer dir.close();
        var best_mtime: i128 = std.math.minInt(i128);
        var it = dir.iterate();
        while (try it.next()) |e| {
            if (e.kind != .directory) continue;
            var sub_buf: [512]u8 = undefined;
            const sock = std.fmt.bufPrint(&sub_buf, "{s}/.socket.sock", .{e.name}) catch continue;
            const st = dir.statFile(sock) catch continue;
            if (st.mtime > best_mtime) {
                best_mtime = st.mtime;
                const p = std.fmt.bufPrint(&self.path_buf, "{s}/{s}", .{ hypr, sock }) catch continue;
                self.path_len = p.len;
            }
        }
        if (self.path_len == 0) return error.NoHyprland;
        return self.path_buf[0..self.path_len];
    }

    /// Send one request, return the whole reply (caller frees).
    pub fn request(self: *Hyprland, msg: []const u8) ![]u8 {
        return self.requestOnce(msg) catch |err| {
            // Hyprland restarted (new signature)? Re-resolve once.
            self.path_len = 0;
            if (err == error.NoHyprland) return err;
            return self.requestOnce(msg);
        };
    }

    fn requestOnce(self: *Hyprland, msg: []const u8) ![]u8 {
        const path = try self.resolve();
        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
        defer std.posix.close(fd);
        // Never hang on a stuck compositor.
        const tv = std.posix.timeval{ .sec = 1, .usec = 0 };
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
        var addr: std.posix.sockaddr.un = .{ .path = undefined, .family = std.posix.AF.UNIX };
        @memset(&addr.path, 0);
        if (path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);
        try std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
        var rest = msg;
        while (rest.len > 0) rest = rest[try std.posix.write(fd, rest)..];

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = try std.posix.read(fd, &buf);
            if (n == 0) break;
            try out.appendSlice(self.gpa, buf[0..n]);
        }
        return out.toOwnedSlice(self.gpa);
    }

    pub fn monitors(self: *Hyprland) !layout.Parsed {
        const r = try self.request("j/monitors");
        defer self.gpa.free(r);
        return layout.parseHyprMonitors(self.gpa, r);
    }

    pub fn cursorPos(self: *Hyprland) ![2]f64 {
        const r = try self.request("j/cursorpos");
        defer self.gpa.free(r);
        const P = struct { x: f64, y: f64 };
        const p = try std.json.parseFromSlice(P, self.gpa, r, .{ .ignore_unknown_fields = true });
        defer p.deinit();
        return .{ p.value.x, p.value.y };
    }

    pub fn moveCursor(self: *Hyprland, x: f64, y: f64) !void {
        const xi: i64 = @intFromFloat(@round(x));
        const yi: i64 = @intFromFloat(@round(y));
        var buf: [128]u8 = undefined;
        if (self.dialect != .legacy) {
            const msg = try std.fmt.bufPrint(&buf, "dispatch hl.dsp.cursor.move({{x = {d}, y = {d}}})", .{ xi, yi });
            if (try self.ok(msg)) {
                self.dialect = .lua;
                return;
            }
            if (self.dialect == .lua) return error.DispatchFailed;
        }
        const msg = try std.fmt.bufPrint(&buf, "dispatch movecursor {d} {d}", .{ xi, yi });
        if (try self.ok(msg)) {
            self.dialect = .legacy;
            return;
        }
        return error.DispatchFailed;
    }

    fn ok(self: *Hyprland, msg: []const u8) !bool {
        const r = try self.request(msg);
        defer self.gpa.free(r);
        const t = std.mem.trim(u8, r, " \r\n");
        if (std.mem.eql(u8, t, "ok")) return true;
        log.warn("'{s}' -> {s}", .{ msg, t[0..@min(t.len, 200)] });
        return false;
    }
};
