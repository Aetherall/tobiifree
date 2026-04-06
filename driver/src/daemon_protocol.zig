// daemon_protocol.zig — wire format for tobiifreed unix socket IPC.
//
// Framing:  [u8 msg_type] [u32 LE payload_len] [payload...]
//
// Used by both socket_source.zig (client) and tobiifreed/server.zig (daemon).

const std = @import("std");
const core = @import("tobiifree_core");

pub const GazeSample = core.GazeSample;

pub const HEADER_SIZE = 5; // 1 byte type + 4 bytes length

// ── Socket path ─────────────────────────────────────────────────────

pub fn socketPath(buf: *[512]u8) ?[]const u8 {
    const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    return std.fmt.bufPrint(buf, "{s}/tobiifreed/gaze.sock", .{runtime_dir}) catch null;
}

// ── Daemon → Client message types ───────────────────────────────────

pub const Srv = enum(u8) {
    gaze = 0x01,
    response = 0x02,
    display_area = 0x03,
    err = 0xFF,
};

// ── Client → Daemon message types ───────────────────────────────────

pub const Cmd = enum(u8) {
    subscribe = 0x01,
    get_display_area = 0x02,
    set_display_area = 0x03,
    set_display_area_corners = 0x04,
    start_calibration = 0x20,
    add_calibration_point = 0x21,
    finish_calibration = 0x22,
    cal_apply = 0x23,
    disconnect = 0xFF,
};

// ── Encode helpers ──────────────────────────────────────────────────

pub fn encodeHeader(buf: *[HEADER_SIZE]u8, msg_type: u8, payload_len: u32) void {
    buf[0] = msg_type;
    std.mem.writeInt(u32, buf[1..5], payload_len, .little);
}

pub fn encodeGaze(buf: *[HEADER_SIZE + @sizeOf(GazeSample)]u8, sample: *const GazeSample) void {
    encodeHeader(buf[0..HEADER_SIZE], @intFromEnum(Srv.gaze), @sizeOf(GazeSample));
    @memcpy(buf[HEADER_SIZE..], std.mem.asBytes(sample));
}

pub fn encodeCmd(buf: []u8, cmd: Cmd, payload: []const u8) usize {
    const plen: u32 = @intCast(payload.len);
    encodeHeader(buf[0..HEADER_SIZE], @intFromEnum(cmd), plen);
    if (payload.len > 0) {
        @memcpy(buf[HEADER_SIZE .. HEADER_SIZE + payload.len], payload);
    }
    return HEADER_SIZE + payload.len;
}

// ── Decode helpers ──────────────────────────────────────────────────

pub const Header = struct {
    msg_type: u8,
    payload_len: u32,
};

pub fn decodeHeader(buf: *const [HEADER_SIZE]u8) Header {
    return .{
        .msg_type = buf[0],
        .payload_len = std.mem.readInt(u32, buf[1..5], .little),
    };
}

pub fn decodeGazeSample(payload: *const [@sizeOf(GazeSample)]u8) *const GazeSample {
    return @ptrCast(@alignCast(payload));
}

/// Encode a response message: [u8 Srv.response] [u32 LE payload_len] [u8 cmd_type] [payload...]
/// The first byte of the response payload is the original command type so the client
/// knows which request this response belongs to.
pub fn encodeResponse(buf: []u8, cmd_type: u8, payload: []const u8) usize {
    const total_payload: u32 = @intCast(1 + payload.len);
    encodeHeader(buf[0..HEADER_SIZE], @intFromEnum(Srv.response), total_payload);
    buf[HEADER_SIZE] = cmd_type;
    if (payload.len > 0) {
        @memcpy(buf[HEADER_SIZE + 1 ..][0..payload.len], payload);
    }
    return HEADER_SIZE + 1 + payload.len;
}

/// Encode an error response.
pub fn encodeError(buf: *[HEADER_SIZE + 4]u8, err_code: u32) void {
    encodeHeader(buf[0..HEADER_SIZE], @intFromEnum(Srv.err), 4);
    std.mem.writeInt(u32, buf[HEADER_SIZE..][0..4], err_code, .little);
}
