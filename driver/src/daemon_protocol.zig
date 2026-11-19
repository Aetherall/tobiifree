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

/// Where the daemon listens and clients connect first:
/// $XDG_RUNTIME_DIR/tobiifreed/gaze.sock.
pub fn socketPath(buf: *[512]u8) ?[]const u8 {
    const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    return std.fmt.bufPrint(buf, "{s}/tobiifreed/gaze.sock", .{runtime_dir}) catch null;
}

/// Socket of a system-wide daemon (run with XDG_RUNTIME_DIR=/run). Clients
/// fall back to it when no per-user daemon answers.
pub const SYSTEM_SOCKET_PATH = "/run/tobiifreed/gaze.sock";

/// IR image socket, next to the command socket: $XDG_RUNTIME_DIR/tobiifreed/image.sock.
/// Only the daemon's own uid may connect (root for a system daemon). Every
/// client gets every frame as a Srv.stream_data message.
pub fn imageSocketPath(buf: *[512]u8) ?[]const u8 {
    const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    return std.fmt.bufPrint(buf, "{s}/tobiifreed/image.sock", .{runtime_dir}) catch null;
}

/// TTP stream of the 280×280 8-bit IR camera image (~78 KB per frame, 33 Hz).
pub const IMAGE_STREAM: u16 = 0x501;

// ── Daemon → Client message types ───────────────────────────────────

pub const Srv = enum(u8) {
    gaze = 0x01,
    response = 0x02,
    display_area = 0x03,
    /// Raw TTP notification of a device stream (image socket only):
    /// [u16 LE stream_id] [TTP payload].
    stream_data = 0x04,
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
    get_calibration_stimulus = 0x24,
    cancel_calibration = 0x25,
    // Correction map (host-side, see correction.zig). Not device commands:
    // answered by the daemon itself, also while the tracker is away.
    set_correction = 0x30, // payload: correction.json text; reply empty
    get_correction = 0x31, // reply: u8 state (0 none, 1 active, 2 inactive) + json
    clear_correction = 0x32, // reply empty; deletes the stored map
    set_correction_enabled = 0x33, // payload u8 (0/1), global, not persisted; reply empty
    set_gaze_raw = 0x34, // payload u8 (0/1): this client gets uncorrected gaze; reply empty
    disconnect = 0xFF,
};

// ── Error codes (Srv.err payload: [u8 cmd_type][u32 LE code]) ────────
//
// Codes below 0x100 are daemon-side. Anything else is the non-zero TTP
// status word the device answered with (e.g. 0x20000502 when a
// set_display_area is rejected), passed through unchanged.

pub const Err = struct {
    pub const failed: u32 = 0x01; // operation failed (state machine error / bad reply)
    pub const too_large: u32 = 0x02; // reply does not fit the transport (WS frame)
    pub const busy: u32 = 0x03; // a calibration operation owns the device; retry later
    pub const timeout: u32 = 0x04; // device did not answer in time
    pub const bad_payload: u32 = 0x05; // malformed command payload
    pub const unknown_cmd: u32 = 0x06;
    pub const usb: u32 = 0x07; // USB send failed
    pub const disconnected: u32 = 0x08; // client-side: daemon connection lost with the request outstanding
    pub const no_device: u32 = 0x09; // tracker unplugged; the daemon reconnects when it returns
    pub const mismatch: u32 = 0x0A; // correction map made for another calibration blob / display area
};

/// 9×f64 LE display area: TL.xyz, TR.xyz, BL.xyz (mm, tracker frame).
pub const DISPLAY_AREA_SIZE = 72;

pub fn encodeDisplayArea(out: *[DISPLAY_AREA_SIZE]u8, c: [9]f64) void {
    for (c, 0..) |v, i| std.mem.writeInt(u64, out[i * 8 ..][0..8], @bitCast(v), .little);
}

pub fn decodeDisplayArea(in: *const [DISPLAY_AREA_SIZE]u8) [9]f64 {
    var c: [9]f64 = undefined;
    for (&c, 0..) |*v, i| v.* = @bitCast(std.mem.readInt(u64, in[i * 8 ..][0..8], .little));
    return c;
}

// ── Encode helpers ──────────────────────────────────────────────────

pub fn encodeHeader(buf: *[HEADER_SIZE]u8, msg_type: u8, payload_len: u32) void {
    buf[0] = msg_type;
    std.mem.writeInt(u32, buf[1..5], payload_len, .little);
}

pub fn encodeGaze(buf: *[HEADER_SIZE + @sizeOf(GazeSample)]u8, sample: *const GazeSample) void {
    encodeHeader(buf[0..HEADER_SIZE], @intFromEnum(Srv.gaze), @sizeOf(GazeSample));
    @memcpy(buf[HEADER_SIZE..], std.mem.asBytes(sample));
}

/// Header + stream id of a Srv.stream_data message; the payload follows.
pub const STREAM_DATA_HEADER_SIZE = HEADER_SIZE + 2;

pub fn encodeStreamDataHeader(buf: *[STREAM_DATA_HEADER_SIZE]u8, stream_id: u16, payload_len: u32) void {
    encodeHeader(buf[0..HEADER_SIZE], @intFromEnum(Srv.stream_data), 2 + payload_len);
    std.mem.writeInt(u16, buf[HEADER_SIZE..][0..2], stream_id, .little);
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
/// Includes the originating cmd_type so clients can reject the matching
/// pending request instead of leaving it to time out.
pub fn encodeError(buf: *[HEADER_SIZE + 1 + 4]u8, cmd_type: u8, err_code: u32) void {
    encodeHeader(buf[0..HEADER_SIZE], @intFromEnum(Srv.err), 1 + 4);
    buf[HEADER_SIZE] = cmd_type;
    std.mem.writeInt(u32, buf[HEADER_SIZE + 1 ..][0..4], err_code, .little);
}
