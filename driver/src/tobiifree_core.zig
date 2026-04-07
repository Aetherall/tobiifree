// tobiifree_core.zig — TTP framer + USB envelope, compiled for wasm32-freestanding.
//
// Protocol decoded from USB bulk transfer observation.
// Pure byte-pushing: no allocator, no syscalls, no libc.
//
// Outbound wire format (host → device):
//   [dir=0x00][0 0 0][len_LE:u32 = ttp_len][ttp_header:24 BE][payload]
//   (OUT envelope excludes itself from the length field)
//
// TTP header (24 bytes, big-endian):
//   [magic:u32][seqno:u32][flag:u32][op:u32][0:u32][plen:u32]

const std = @import("std");
const tlv = @import("tlv.zig");

// =====================================================================
// Constants
// =====================================================================

pub const TTP_HDR_SIZE: usize = 24;
pub const ENVELOPE_SIZE: usize = 8;

pub const TTP_MAGIC_REQ: u32 = 0x51;
pub const TTP_MAGIC_RSP: u32 = 0x52;
pub const TTP_MAGIC_NOTIFY: u32 = 0x53;

pub const TTP_OP_HELLO: u32 = 0x3e8;
pub const TTP_OP_SUBSCRIBE: u32 = 0x4c4;
pub const TTP_OP_SET_DISPLAY_AREA: u32 = 0x5a0;
pub const TTP_OP_GET_DISPLAY_AREA: u32 = 0x596;

// Calibration / realm ops
pub const TTP_OP_CAL_ADD_POINT: u32 = 0x408; // 1032 — add calibration point
pub const TTP_OP_CAL_COMPUTE: u32 = 0x42F; // 1071 — compute and apply calibration
pub const TTP_OP_CAL_RETRIEVE: u32 = 0x44C; // 1100 — retrieve calibration blob
pub const TTP_OP_CAL_APPLY: u32 = 0x456; // 1110 — apply calibration blob
pub const TTP_OP_CAL_STIMULUS: u32 = 0x460; // 1120 — get_calibration_stimulus_pts
pub const TTP_OP_QUERY_REALM: u32 = 0x640; // 1600 — query realm info
pub const TTP_OP_OPEN_REALM: u32 = 0x76C; // 1900 — open realm (challenge)
pub const TTP_OP_REALM_RESPONSE: u32 = 0x776; // 1910 — realm auth response
pub const TTP_OP_CLOSE_REALM: u32 = 0x77B; // 1915 — close realm

// =====================================================================
// Big-endian / little-endian writers
// =====================================================================

fn putBe32(p: [*]u8, v: u32) void {
    p[0] = @truncate(v >> 24);
    p[1] = @truncate(v >> 16);
    p[2] = @truncate(v >> 8);
    p[3] = @truncate(v);
}

fn putBe64(p: [*]u8, v: u64) void {
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        p[i] = @truncate(v >> (56 - @as(u6, i) * 8));
    }
}

fn putLe32(p: [*]u8, v: u32) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
    p[2] = @truncate(v >> 16);
    p[3] = @truncate(v >> 24);
}

// =====================================================================
// TLV encoders
// =====================================================================

// tag: type=5, size=4, body=tag u32 (BE)
fn tlvTag(p: [*]u8, tag: u32) usize {
    p[0] = 5;
    putBe32(p + 1, 4);
    putBe32(p + 5, tag);
    return 9;
}

// u32: type=2, size=4, body=v u32 (BE)
fn tlvU32(p: [*]u8, v: u32) usize {
    p[0] = 2;
    putBe32(p + 1, 4);
    putBe32(p + 5, v);
    return 9;
}

// f64 Q42: type=4, size=8, body=i64 = round(v * 2^42) (BE)
fn tlvF64Q42(p: [*]u8, v: f64) usize {
    p[0] = 4;
    putBe32(p + 1, 8);
    const scaled: i64 = @intFromFloat(@round(v * 4398046511104.0)); // 2^42
    putBe64(p + 5, @bitCast(scaled));
    return 13;
}

// point: tag(0x31f41) + f64(x) + f64(y) + f64(z) = 9 + 13*3 = 48 bytes
// point: tag=9 + 3*f64=39 → 48 bytes total.
fn tlvPoint(p: [*]u8, x: f64, y: f64, z: f64) usize {
    var n: usize = 0;
    n += tlvTag(p + n, 0x31f41);
    n += tlvF64Q42(p + n, x);
    n += tlvF64Q42(p + n, y);
    n += tlvF64Q42(p + n, z);
    return n;
}

// Raw blob: just copy bytes into payload (no TLV header).
fn tlvBlob(p: [*]u8, data: [*]const u8, len: usize) usize {
    var i: usize = 0;
    while (i < len) : (i += 1) p[i] = data[i];
    return len;
}

// =====================================================================
// MD5 — minimal implementation for HMAC-MD5 realm authentication.
// No allocator, no libc. Processes 64-byte blocks.
// =====================================================================

const MD5 = struct {
    state: [4]u32 = .{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 },
    count: u64 = 0,
    buf: [64]u8 = undefined,
    buf_len: usize = 0,

    const S: [64]u5 = .{
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    };

    const K: [64]u32 = .{
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    };

    fn getLe32M(data: [*]const u8) u32 {
        return @as(u32, data[0]) |
            (@as(u32, data[1]) << 8) |
            (@as(u32, data[2]) << 16) |
            (@as(u32, data[3]) << 24);
    }

    fn transform(self: *MD5, block: [*]const u8) void {
        var M: [16]u32 = undefined;
        var j: usize = 0;
        while (j < 16) : (j += 1) M[j] = getLe32M(block + j * 4);

        var a = self.state[0];
        var b = self.state[1];
        var c = self.state[2];
        var d = self.state[3];

        var i: usize = 0;
        while (i < 64) : (i += 1) {
            var f: u32 = undefined;
            var g: usize = undefined;
            if (i < 16) {
                f = (b & c) | (~b & d);
                g = i;
            } else if (i < 32) {
                f = (d & b) | (~d & c);
                g = (5 * i + 1) % 16;
            } else if (i < 48) {
                f = b ^ c ^ d;
                g = (3 * i + 5) % 16;
            } else {
                f = c ^ (b | ~d);
                g = (7 * i) % 16;
            }
            const tmp = d;
            d = c;
            c = b;
            const x = a +% f +% K[i] +% M[g];
            b = b +% std.math.rotl(u32, x, @as(u32, S[i]));
            a = tmp;
        }
        self.state[0] +%= a;
        self.state[1] +%= b;
        self.state[2] +%= c;
        self.state[3] +%= d;
    }

    fn update(self: *MD5, data: [*]const u8, len: usize) void {
        var off: usize = 0;
        self.count += len;
        // Fill partial buffer
        if (self.buf_len > 0) {
            const need = 64 - self.buf_len;
            const take = if (len < need) len else need;
            var i: usize = 0;
            while (i < take) : (i += 1) self.buf[self.buf_len + i] = data[i];
            self.buf_len += take;
            off = take;
            if (self.buf_len == 64) {
                self.transform(&self.buf);
                self.buf_len = 0;
            }
        }
        // Process full blocks
        while (off + 64 <= len) : (off += 64) {
            self.transform(data + off);
        }
        // Buffer remainder
        var i: usize = 0;
        while (off + i < len) : (i += 1) self.buf[i] = data[off + i];
        self.buf_len = i;
    }

    fn finalize(self: *MD5, out: *[16]u8) void {
        const bit_len = self.count * 8;
        // Pad: append 0x80, then zeros, then 8-byte LE bit-length
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;
        if (self.buf_len > 56) {
            // Need a second block
            var i: usize = self.buf_len;
            while (i < 64) : (i += 1) self.buf[i] = 0;
            self.transform(&self.buf);
            self.buf_len = 0;
        }
        var i: usize = self.buf_len;
        while (i < 56) : (i += 1) self.buf[i] = 0;
        // Append bit-length as 64-bit LE
        var bl = bit_len;
        var bi: usize = 0;
        while (bi < 8) : (bi += 1) {
            self.buf[56 + bi] = @truncate(bl);
            bl >>= 8;
        }
        self.transform(&self.buf);
        // Write digest as LE u32s
        bi = 0;
        while (bi < 4) : (bi += 1) {
            var v = self.state[bi];
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                out[bi * 4 + k] = @truncate(v);
                v >>= 8;
            }
        }
    }
};

/// HMAC-MD5(key, message) → 16-byte digest.
fn hmacMd5(key: [*]const u8, key_len: usize, msg: [*]const u8, msg_len: usize, out: *[16]u8) void {
    // If key > 64 bytes, hash it first (key is 32 bytes in our case, so this won't fire)
    var k_buf: [64]u8 = @splat(0);
    if (key_len > 64) {
        var h = MD5{};
        h.update(key, key_len);
        var hashed: [16]u8 = undefined;
        h.finalize(&hashed);
        var ki: usize = 0;
        while (ki < 16) : (ki += 1) k_buf[ki] = hashed[ki];
    } else {
        var ki: usize = 0;
        while (ki < key_len) : (ki += 1) k_buf[ki] = key[ki];
    }

    // ipad = key XOR 0x36, opad = key XOR 0x5c
    var ipad: [64]u8 = undefined;
    var opad: [64]u8 = undefined;
    var pi: usize = 0;
    while (pi < 64) : (pi += 1) {
        ipad[pi] = k_buf[pi] ^ 0x36;
        opad[pi] = k_buf[pi] ^ 0x5c;
    }

    // inner = MD5(ipad || message)
    var inner = MD5{};
    inner.update(&ipad, 64);
    inner.update(msg, msg_len);
    var inner_digest: [16]u8 = undefined;
    inner.finalize(&inner_digest);

    // outer = MD5(opad || inner_digest)
    var outer = MD5{};
    outer.update(&opad, 64);
    outer.update(&inner_digest, 16);
    outer.finalize(out);
}

// =====================================================================
// TTP frame builder
// =====================================================================

// Write a TTP frame into out: [24-byte BE header] + payload.
// Returns total bytes written = 24 + plen.
fn buildFrame(out: [*]u8, seq: u32, op: u32, payload: [*]const u8, plen: u32) usize {
    // zero header
    var i: usize = 0;
    while (i < TTP_HDR_SIZE) : (i += 1) out[i] = 0;
    putBe32(out + 0, TTP_MAGIC_REQ);
    putBe32(out + 4, seq);
    putBe32(out + 8, 0);
    putBe32(out + 12, op);
    putBe32(out + 16, 0);
    putBe32(out + 20, plen);
    i = 0;
    while (i < plen) : (i += 1) out[TTP_HDR_SIZE + i] = payload[i];
    return TTP_HDR_SIZE + @as(usize, plen);
}

// Wrap a TTP frame in the outbound USB envelope.
//   envelope[0] = 0x00 (dir=host-to-device)
//   envelope[1..4] = 0
//   envelope[4..8] = ttp_len (LE, excludes envelope)
//   envelope[8..] = ttp frame
fn wrapEnvelopeOut(out: [*]u8, ttp: [*]const u8, ttp_len: usize) usize {
    out[0] = 0x00;
    out[1] = 0;
    out[2] = 0;
    out[3] = 0;
    putLe32(out + 4, @intCast(ttp_len));
    var i: usize = 0;
    while (i < ttp_len) : (i += 1) out[ENVELOPE_SIZE + i] = ttp[i];
    return ENVELOPE_SIZE + ttp_len;
}

// =====================================================================
// WASM exports
// =====================================================================

pub export fn q42_encode(mm: f64) i64 {
    return @intFromFloat(@round(mm * 4398046511104.0));
}

// Fixed scratch buffer for outbound frame building. JS writes the
// returned pointer once at startup and passes it into build_* calls.
var out_scratch: [4096]u8 = undefined;

pub export fn scratch_ptr() [*]u8 {
    return &out_scratch;
}
pub export fn scratch_size() usize {
    return out_scratch.len;
}

// Build hello (op 0x3e8) with the 47-byte captured payload.
// Returns total envelope+frame length (8 + 24 + 47 = 79).
// out must be at least 79 bytes.
pub export fn build_hello(seq: u32, out: [*]u8) usize {
    const hello_payload = [_]u8{
        0x00, 0x00, 0x17, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x09,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x02,
        0x00, 0x01, 0x00, 0x03, 0x00, 0x01, 0x00, 0x04, 0x00, 0x01, 0x00, 0x05,
        0x00, 0x01, 0x00, 0x06, 0x00, 0x01, 0x00, 0x07, 0x00, 0x01, 0x00, 0x08,
    };
    var ttp_buf: [TTP_HDR_SIZE + hello_payload.len]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_HELLO, &hello_payload, hello_payload.len);
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// Build set_display_area (op 0x5a0). Display plane in mm.
//   w, h    : width/height
//   ox, oy  : x/y offset of bottom-left corner (tracker-relative)
//   z       : plane depth (typically 0)
// Returns total envelope+frame length. out must be at least 256 bytes.
pub export fn build_set_display_area(
    seq: u32,
    w_mm: f64,
    h_mm: f64,
    ox_mm: f64,
    oy_mm: f64,
    z_mm: f64,
    out: [*]u8,
) usize {
    var pay: [256]u8 = undefined;
    var n: usize = 0;
    pay[n] = 0x00;
    n += 1;
    pay[n] = 0x00;
    n += 1;
    const x0 = ox_mm;
    const x1 = ox_mm + w_mm;
    const y0 = oy_mm;
    const y1 = oy_mm + h_mm;
    n += tlvPoint(@ptrCast(&pay[n]), x0, y1, z_mm); // TL
    n += tlvPoint(@ptrCast(&pay[n]), x1, y1, z_mm); // TR
    n += tlvPoint(@ptrCast(&pay[n]), x0, y0, z_mm); // BL
    n += tlvTag(@ptrCast(&pay[n]), 0x10100);
    n += tlvU32(@ptrCast(&pay[n]), 0x3039);

    var ttp_buf: [TTP_HDR_SIZE + 256]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_SET_DISPLAY_AREA, @ptrCast(&pay), @intCast(n));
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// Build set_display_area from explicit corners (op 0x5a0). Each corner is
// a point in mm (tracker-relative). The BR corner is not sent on the wire
// — only TL/TR/BL are TLV-encoded, matching the 5-field builder above.
// Returns total envelope+frame length. out must be at least 256 bytes.
pub export fn build_set_display_area_corners(
    seq: u32,
    tl_x: f64, tl_y: f64, tl_z: f64,
    tr_x: f64, tr_y: f64, tr_z: f64,
    bl_x: f64, bl_y: f64, bl_z: f64,
    out: [*]u8,
) usize {
    var pay: [256]u8 = undefined;
    var n: usize = 0;
    pay[n] = 0x00;
    n += 1;
    pay[n] = 0x00;
    n += 1;
    n += tlvPoint(@ptrCast(&pay[n]), tl_x, tl_y, tl_z);
    n += tlvPoint(@ptrCast(&pay[n]), tr_x, tr_y, tr_z);
    n += tlvPoint(@ptrCast(&pay[n]), bl_x, bl_y, bl_z);
    n += tlvTag(@ptrCast(&pay[n]), 0x10100);
    n += tlvU32(@ptrCast(&pay[n]), 0x3039);

    var ttp_buf: [TTP_HDR_SIZE + 256]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_SET_DISPLAY_AREA, @ptrCast(&pay), @intCast(n));
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// Build get_display_area (op 0x596). Empty payload.
// Returns total envelope+frame length = 8 + 24 + 0 = 32.
pub export fn build_get_display_area(seq: u32, out: [*]u8) usize {
    var ttp_buf: [TTP_HDR_SIZE]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_GET_DISPLAY_AREA, @ptrCast(&ttp_buf[0]), 0);
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// Decode a get_display_area response payload. The payload matches the
// set wire format: [00 00][point TL][point TR][point BL][end marker].
// On success writes 9 f64 (x,y,z × 3 corners) to `out` and returns 1.
// Returns 0 if the payload doesn't parse.
pub export fn decode_display_area(src: [*]const u8, len: usize, out: [*]u8) u32 {
    if (len < 2) return 0;
    const slice = src[0..len];
    var r = tlv.Reader.init(slice);
    r.pos = 2;
    const tl = r.readPoint3d() catch return 0;
    const tr = r.readPoint3d() catch return 0;
    const bl = r.readPoint3d() catch return 0;
    const vals = [_]f64{ tl[0], tl[1], tl[2], tr[0], tr[1], tr[2], bl[0], bl[1], bl[2] };
    var i: usize = 0;
    while (i < vals.len) : (i += 1) {
        putF64(out + i * 8, vals[i]);
    }
    return 1;
}

// =====================================================================
// Calibration / realm frame builders
// =====================================================================

// Build query_realm (op 0x640). Empty payload — queries realm availability.
pub export fn build_query_realm(seq: u32, out: [*]u8) usize {
    var pay = [_]u8{ 0x00, 0x00 };
    var ttp_buf: [TTP_HDR_SIZE + 2]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_QUERY_REALM, &pay, pay.len);
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// Build open_realm (op 0x76C). Sends realm_type and a 1-byte choice (0).
pub export fn build_open_realm(seq: u32, realm_type: u32, out: [*]u8) usize {
    var pay: [64]u8 = undefined;
    var n: usize = 0;
    pay[n] = 0x00;
    n += 1;
    pay[n] = 0x00;
    n += 1;
    n += tlvU32(@ptrCast(&pay[n]), realm_type);
    // 1-byte choice=0 (raw, no TLV header)
    pay[n] = 0x00;
    n += 1;

    var ttp_buf: [TTP_HDR_SIZE + 64]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_OPEN_REALM, @ptrCast(&pay), @intCast(n));
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// Build realm_response (op 0x776). Sends realm_id, field_210, and
// the 16-byte HMAC-MD5 digest of the challenge.
pub export fn build_realm_response(
    seq: u32,
    realm_id: u32,
    field_210: u32,
    digest: [*]const u8, // 16 bytes
    out: [*]u8,
) usize {
    var pay: [64]u8 = undefined;
    var n: usize = 0;
    pay[n] = 0x00;
    n += 1;
    pay[n] = 0x00;
    n += 1;
    n += tlvU32(@ptrCast(&pay[n]), realm_id);
    n += tlvU32(@ptrCast(&pay[n]), field_210);
    n += tlvBlob(@ptrCast(&pay[n]), digest, 16);

    var ttp_buf: [TTP_HDR_SIZE + 64]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_REALM_RESPONSE, @ptrCast(&pay), @intCast(n));
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// Build close_realm (op 0x77B). Sends realm_id.
pub export fn build_close_realm(seq: u32, realm_id: u32, out: [*]u8) usize {
    var pay: [32]u8 = undefined;
    var n: usize = 0;
    pay[n] = 0x00;
    n += 1;
    pay[n] = 0x00;
    n += 1;
    n += tlvU32(@ptrCast(&pay[n]), realm_id);

    var ttp_buf: [TTP_HDR_SIZE + 32]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_CLOSE_REALM, @ptrCast(&pay), @intCast(n));
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// Build cal_add_point (op 0x408). x/y are normalized display coords,
// eye_choice: 0=both, 1=left, 2=right.
pub export fn build_cal_add_point(seq: u32, x: f64, y: f64, eye_choice: u32, out: [*]u8) usize {
    var pay: [64]u8 = undefined;
    var n: usize = 0;
    pay[n] = 0x00;
    n += 1;
    pay[n] = 0x00;
    n += 1;
    n += tlvF64Q42(@ptrCast(&pay[n]), x);
    n += tlvF64Q42(@ptrCast(&pay[n]), y);
    n += tlvU32(@ptrCast(&pay[n]), eye_choice);

    var ttp_buf: [TTP_HDR_SIZE + 64]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_CAL_ADD_POINT, @ptrCast(&pay), @intCast(n));
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// Build cal_compute_and_apply (op 0x42F). Empty payload.
pub export fn build_cal_compute(seq: u32, out: [*]u8) usize {
    var pay = [_]u8{ 0x00, 0x00 };
    var ttp_buf: [TTP_HDR_SIZE + 2]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_CAL_COMPUTE, &pay, pay.len);
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// Build cal_retrieve (op 0x44C). Empty payload — retrieves calibration blob.
pub export fn build_cal_retrieve(seq: u32, out: [*]u8) usize {
    var pay = [_]u8{ 0x00, 0x00 };
    var ttp_buf: [TTP_HDR_SIZE + 2]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_CAL_RETRIEVE, &pay, pay.len);
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// Build cal_apply (op 0x456). Sends the opaque calibration blob.
// The blob can be up to ~4KB; out must be large enough.
pub export fn build_cal_apply(seq: u32, blob: [*]const u8, blob_len: u32, out: [*]u8) usize {
    // Write payload: [00 00] [raw blob]
    const plen: u32 = 2 + blob_len;
    var ttp_buf: [TTP_HDR_SIZE]u8 = undefined;
    // Build header with plen, then write envelope + header + payload
    const total_ttp = TTP_HDR_SIZE + @as(usize, plen);

    // Envelope
    out[0] = 0x00;
    out[1] = 0;
    out[2] = 0;
    out[3] = 0;
    putLe32(out + 4, @intCast(total_ttp));

    // TTP header
    var i: usize = 0;
    while (i < TTP_HDR_SIZE) : (i += 1) ttp_buf[i] = 0;
    putBe32(&ttp_buf, TTP_MAGIC_REQ);
    putBe32(@ptrCast(&ttp_buf[4]), seq);
    putBe32(@ptrCast(&ttp_buf[12]), TTP_OP_CAL_APPLY);
    putBe32(@ptrCast(&ttp_buf[20]), plen);
    i = 0;
    while (i < TTP_HDR_SIZE) : (i += 1) out[ENVELOPE_SIZE + i] = ttp_buf[i];

    // Payload
    out[ENVELOPE_SIZE + TTP_HDR_SIZE] = 0x00;
    out[ENVELOPE_SIZE + TTP_HDR_SIZE + 1] = 0x00;
    i = 0;
    while (i < blob_len) : (i += 1) out[ENVELOPE_SIZE + TTP_HDR_SIZE + 2 + i] = blob[i];

    return ENVELOPE_SIZE + total_ttp;
}

// Build cal_stimulus (op 0x460). Empty payload — gets stimulus points.
pub export fn build_cal_stimulus(seq: u32, out: [*]u8) usize {
    var pay = [_]u8{ 0x00, 0x00 };
    var ttp_buf: [TTP_HDR_SIZE + 2]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_CAL_STIMULUS, &pay, pay.len);
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// Compute HMAC-MD5 for realm authentication.
// key_ptr/key_len: the HMAC key (typically 32 bytes "aaa...ddd")
// msg_ptr/msg_len: the challenge from the device
// out_ptr: 16-byte output buffer
pub export fn compute_hmac_md5(
    key_ptr: [*]const u8,
    key_len: u32,
    msg_ptr: [*]const u8,
    msg_len: u32,
    out_ptr: [*]u8,
) void {
    var digest: [16]u8 = undefined;
    hmacMd5(key_ptr, key_len, msg_ptr, msg_len, &digest);
    var i: usize = 0;
    while (i < 16) : (i += 1) out_ptr[i] = digest[i];
}

// Build subscribe (op 0x4c4) for a given stream_id.
// 20-byte subscribe payload, stream_id at bytes 9..10 BE.
pub export fn build_subscribe(seq: u32, stream_id: u16, out: [*]u8) usize {
    // 20-byte subscribe payload (observed from USB captures).
    var pay = [_]u8{
        0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
        0x00, 0x17, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00,
    };
    pay[9] = @truncate(stream_id >> 8);
    pay[10] = @truncate(stream_id);
    var ttp_buf: [TTP_HDR_SIZE + 20]u8 = undefined;
    const ttp_len = buildFrame(&ttp_buf, seq, TTP_OP_SUBSCRIBE, &pay, pay.len);
    return wrapEnvelopeOut(out, &ttp_buf, ttp_len);
}

// =====================================================================
// Inbound parser: envelope reassembly + TTP frame extraction
// =====================================================================
//
// Device → host byte stream arrives as a sequence of USB bulk chunks.
// Each chunk contains part of (or multiple) length-prefixed envelopes:
//   [dir=0x01][0 0 0][len_LE:u32][ttp_header:24][payload]
// IN envelope length field INCLUDES the 8-byte envelope (asymmetric).
//
// The parser keeps an accumulator; feed_usb_in appends bytes and drains
// any complete frames, calling the JS-imported event hooks for each.
//
// We export a single global parser instance — the JS side is single-
// threaded and only needs one device at a time.

const ACC_CAP: usize = 1 << 21; // 2 MiB reassembly buffer
var acc_buf: [ACC_CAP]u8 = undefined;
var acc_len: usize = 0;

// Hooks — event callbacks invoked by the parser.
//
// On wasm32 these are `extern "env"` resolved by the JS host.
// On native they are settable function pointers — any Zig (or C)
// consumer can register handlers at runtime via `set_hooks()`.
const builtin = @import("builtin");
const is_wasm = builtin.target.cpu.arch == .wasm32;

const TestEvent = struct { magic: u32, seq: u32, op: u32, plen: u32, first: u8 };
var test_events: [16]TestEvent = undefined;
var test_event_count: usize = 0;
var test_error_count: usize = 0;
var test_last_error: u32 = 0;

// ── Hook function pointer types (public for native consumers) ───────
pub const HookFn_ttp_frame = *const fn (u32, u32, u32, [*]const u8, u32) void;
pub const HookFn_parse_error = *const fn (u32) void;
pub const HookFn_response = *const fn (u32, [*]const u8, u32) void;
pub const HookFn_gaze = *const fn ([*]const u8) void;
pub const HookFn_raw_columns = *const fn ([*]const u8, u32) void;

fn noop_ttp_frame(_: u32, _: u32, _: u32, _: [*]const u8, _: u32) void {}
fn noop_parse_error(_: u32) void {}
fn noop_response(_: u32, _: [*]const u8, _: u32) void {}
fn noop_gaze(_: [*]const u8) void {}
fn noop_raw_columns(_: [*]const u8, _: u32) void {}

var hook_ttp_frame: HookFn_ttp_frame = noop_ttp_frame;
var hook_parse_error: HookFn_parse_error = noop_parse_error;
var hook_response: HookFn_response = noop_response;
var hook_gaze: HookFn_gaze = noop_gaze;
var hook_raw_columns: HookFn_raw_columns = noop_raw_columns;

/// Register native event hooks. Null fields keep the current handler.
pub fn set_hooks(
    f_ttp_frame: ?HookFn_ttp_frame,
    f_parse_error: ?HookFn_parse_error,
    f_response: ?HookFn_response,
    f_gaze: ?HookFn_gaze,
    f_raw_columns: ?HookFn_raw_columns,
) void {
    if (f_ttp_frame) |f| hook_ttp_frame = f;
    if (f_parse_error) |f| hook_parse_error = f;
    if (f_response) |f| hook_response = f;
    if (f_gaze) |f| hook_gaze = f;
    if (f_raw_columns) |f| hook_raw_columns = f;
}

const wasm_hooks = struct {
    extern "env" fn on_ttp_frame(magic: u32, seq: u32, op: u32, payload_ptr: [*]const u8, payload_len: u32) void;
    extern "env" fn on_parse_error(code: u32) void;
    extern "env" fn on_response(request_id: u32, payload_ptr: [*]const u8, payload_len: u32) void;
    extern "env" fn on_gaze(sample_ptr: [*]const u8) void;
    extern "env" fn on_raw_columns(records_ptr: [*]const u8, n: u32) void;
};

fn on_ttp_frame(magic: u32, seq: u32, op: u32, payload_ptr: [*]const u8, payload_len: u32) void {
    if (is_wasm) wasm_hooks.on_ttp_frame(magic, seq, op, payload_ptr, payload_len) else hook_ttp_frame(magic, seq, op, payload_ptr, payload_len);
}
fn on_parse_error(code: u32) void {
    if (is_wasm) wasm_hooks.on_parse_error(code) else hook_parse_error(code);
}
fn on_response(request_id: u32, payload_ptr: [*]const u8, payload_len: u32) void {
    if (is_wasm) {
        // Call the native hook first (handshake state machine needs this to advance).
        hook_response(request_id, payload_ptr, payload_len);
        // Then notify JS.
        wasm_hooks.on_response(request_id, payload_ptr, payload_len);
    } else {
        hook_response(request_id, payload_ptr, payload_len);
    }
}
fn on_gaze(sample_ptr: [*]const u8) void {
    if (is_wasm) wasm_hooks.on_gaze(sample_ptr) else hook_gaze(sample_ptr);
}
fn on_raw_columns(records_ptr: [*]const u8, n: u32) void {
    if (is_wasm) wasm_hooks.on_raw_columns(records_ptr, n) else hook_raw_columns(records_ptr, n);
}

const ERR_BAD_DIR: u32 = 1;
const ERR_BAD_LEN: u32 = 2;
const ERR_OVERFLOW: u32 = 3;

fn getLe32(p: [*]const u8) u32 {
    return @as(u32, p[0]) |
        (@as(u32, p[1]) << 8) |
        (@as(u32, p[2]) << 16) |
        (@as(u32, p[3]) << 24);
}

fn getBe32(p: [*]const u8) u32 {
    return (@as(u32, p[0]) << 24) |
        (@as(u32, p[1]) << 16) |
        (@as(u32, p[2]) << 8) |
        @as(u32, p[3]);
}

// Returns bytes consumed (0 = need more), or error-sentinel via callback.
// On framing error, resets the accumulator and returns special value.
fn drainFrame() ?usize {
    if (acc_len < ENVELOPE_SIZE) return 0;
    if (acc_buf[0] != 0x01) {
        on_parse_error(ERR_BAD_DIR);
        return null;
    }
    const env_len = getLe32(@ptrCast(&acc_buf[4]));
    // The first USB transfer always contains at least envelope + TTP header.
    // An env_len smaller than that is always invalid.
    if (env_len < ENVELOPE_SIZE + TTP_HDR_SIZE) {
        on_parse_error(ERR_BAD_LEN);
        return null;
    }
    if (acc_len < ENVELOPE_SIZE + TTP_HDR_SIZE) return 0;
    // Parse TTP header
    const ttp: [*]const u8 = @ptrCast(&acc_buf[ENVELOPE_SIZE]);
    const magic = getBe32(ttp + 0);
    const seq = getBe32(ttp + 4);
    const op = getBe32(ttp + 12);
    const plen = getBe32(ttp + 20);
    // True frame size = envelope + TTP header + payload.
    // For normal frames, env_len == frame_size. For large/fragmented
    // responses the device may set env_len to the first chunk's size
    // while plen covers the full payload. Use the larger value.
    const frame_size = ENVELOPE_SIZE + TTP_HDR_SIZE + @as(usize, plen);
    if (frame_size > ACC_CAP) {
        on_parse_error(ERR_BAD_LEN);
        return null;
    }
    if (acc_len < frame_size) return 0; // need more data
    dispatchFrame(magic, seq, op, ttp + TTP_HDR_SIZE, plen);
    return frame_size;
}

// Append `len` bytes from `src` into the accumulator and drain any
// complete frames. On framing error, accumulator is reset.
//
// USB fragmentation: large TTP responses arrive split across multiple USB
// transfers. The first transfer has a normal envelope+TTP header. Continuation
// transfers each have their own 8-byte USB envelope header (dir=0x01, len_LE)
// wrapping raw payload bytes — no TTP header. We must strip those intermediate
// envelope headers so the accumulator contains a clean [env][ttp_hdr][payload].
pub export fn feed_usb_in(src: [*]const u8, len: usize) void {
    // Determine how many payload bytes we still need for an in-progress frame.
    // If we already have envelope+TTP header, we know the expected frame size.
    var data_ptr = src;
    var data_len = len;

    if (acc_len >= ENVELOPE_SIZE + TTP_HDR_SIZE) {
        // We have a TTP header — check if frame is still incomplete.
        const ttp: [*]const u8 = @ptrCast(&acc_buf[ENVELOPE_SIZE]);
        const plen = getBe32(ttp + 20);
        const frame_size = ENVELOPE_SIZE + TTP_HDR_SIZE + @as(usize, plen);
        if (acc_len < frame_size) {
            // Frame incomplete — this chunk is a continuation. Strip its
            // USB envelope header if present. IN envelopes always start
            // with [01 00 00 00] (dir=device-to-host + 3 zero pad bytes).
            if (data_len >= ENVELOPE_SIZE and src[0] == 0x01 and src[1] == 0x00 and src[2] == 0x00 and src[3] == 0x00) {
                data_ptr = src + ENVELOPE_SIZE;
                data_len = len - ENVELOPE_SIZE;
            }
        }
    }

    if (acc_len + data_len > ACC_CAP) {
        on_parse_error(ERR_OVERFLOW);
        acc_len = 0;
        return;
    }
    var i: usize = 0;
    while (i < data_len) : (i += 1) acc_buf[acc_len + i] = data_ptr[i];
    acc_len += data_len;

    // Drain frames from head
    var off: usize = 0;
    while (true) {
        // Shift first if we've consumed anything
        if (off > 0) {
            var j: usize = 0;
            while (j < acc_len - off) : (j += 1) acc_buf[j] = acc_buf[off + j];
            acc_len -= off;
            off = 0;
        }
        const maybe = drainFrame();
        if (maybe == null) {
            // parse error — reset
            acc_len = 0;
            return;
        }
        const consumed = maybe.?;
        if (consumed == 0) break; // need more
        off = consumed;
    }
    if (off > 0) {
        var j: usize = 0;
        while (j < acc_len - off) : (j += 1) acc_buf[j] = acc_buf[off + j];
        acc_len -= off;
    }
}

// Reset the accumulator (e.g. after reconnect).
pub export fn reset_parser() void {
    acc_len = 0;
}

// =====================================================================
// Gaze payload decoder — WASM export
// =====================================================================
//
// `decode_gaze_payload` parses a 0x500 notification payload and writes
// the decoded columns into an output buffer as a flat array of records:
//
//   record: [col_id:u32 LE][kind:u32 LE][v0:f64][v1:f64][v2:f64]
//           total = 4 + 4 + 24 = 32 bytes
//
// kind values: 0=s64, 1=u32, 2=point2d, 3=point3d, 4=fixed16x16
// For s64/u32/fixed16x16 only v0 is meaningful.
// For point2d v0,v1. For point3d v0,v1,v2.
//
// Returns the number of columns written. On error returns 0.

const KIND_S64: u32 = 0;
const KIND_U32: u32 = 1;
const KIND_POINT2D: u32 = 2;
const KIND_POINT3D: u32 = 3;
const KIND_FIXED16X16: u32 = 4;

/// Map a 0x500 gaze column ID to its TLV data kind.
///
/// Column layout — the gaze pipeline exposes three coordinate spaces:
///   tracker-space: origin at the IR sensor array.
///   display-space: tracker-space shifted by the display_area offset.
///   normalized 2D: ray→plane intersection on display_area, [0,1]².
///
/// Eye origins:
///   0x17/0x18  raw (pre-calibration) eye position from pupil/glint detection
///   0x02/0x08  calibrated eye position (post onboard model, ~1-5mm correction)
///   0x22/0x24  calibrated eye position in display_area frame
///
/// "Gaze directions" — misleading column name: NOT direction vectors.
///   These encode the eye's normalized position in the track box
///   (d ≈ linear_transform(eye_origin), reconstruction error ~4mm):
///   0x03/0x09  normalized track-box eye position (per-eye scaling)
///   0x25/0x27  same in display-space (observed as zeros on tested firmware)
///
/// 3D intersection:
///   0x04/0x0a  ray–plane hit in tracker-space (mm)
///
/// 2D projection:
///   0x05/0x0b  per-eye projection on display_area [0,1]²
///   0x20       combined binocular 2D before temporal filtering
///   0x1c       combined binocular 2D after temporal smoothing (final output)
///   0x19/0x1a  unused slots (always -1,-1)
///
/// Scalars:
///   0x06/0x0c  pupil diameter (mm), -1 when invalid
///   0x29/0x2b  unused (always -1)
///
/// Flags (u32):
///   0x07/0x0d  validity (0=valid, 4=not detected)
///   0x15/0x16  eye present (1=detected, 0=absent)
///   0x1b       binocular flag (1=both eyes, 0=mono/none)
///   0x1d-0x1f  per-output 2D validity (1=valid)
///   0x21       unfiltered 2D validity
///   0x23/0x26/0x28  display-space data validity
///   0x11       tracking mode (always 4)
///   0x0e       unknown status
///   0x2a/0x2c  unused scalar validity (always 0)
fn columnKind(col: u32) ?u32 {
    return switch (col) {
        0x01 => KIND_S64, // timestamp_us
        0x02, 0x03, 0x04, // L: calibrated origin, gaze dir (eye-model coords), 3D hit
        0x08, 0x09, 0x0a, // R: calibrated origin, gaze dir (eye-model coords), 3D hit
        0x17, 0x18,       // L/R: raw (pre-calibration) eye origin
        0x22, 0x24,       // L/R: calibrated eye origin (display-space)
        0x25, 0x27,       // L/R: gaze direction (display-space)
        => KIND_POINT3D,
        0x05, 0x0b,       // L/R: per-eye 2D projection
        0x1c,             // combined 2D filtered (final output)
        0x20,             // combined 2D unfiltered
        0x19, 0x1a,       // unused 2D slots
        => KIND_POINT2D,
        0x06, 0x0c,       // L/R: pupil diameter
        0x29, 0x2b,       // unused scalars
        => KIND_FIXED16X16,
        0x07, 0x0d,       // L/R: validity
        0x0e, 0x11,       // tracking status/mode
        0x14,             // frame counter
        0x15, 0x16,       // L/R: eye present flag
        0x1b,             // binocular flag
        0x1d, 0x1e, 0x1f, // 2D validity flags
        0x21,             // unfiltered 2D validity
        0x23, 0x26, 0x28, // display-space validity
        0x2a, 0x2c,       // unused scalar validity
        => KIND_U32,
        else => null,
    };
}

fn putF64(p: [*]u8, v: f64) void {
    const bits: u64 = @bitCast(v);
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        p[i] = @truncate(bits >> (@as(u6, i) * 8));
    }
}

fn putLe32u(p: [*]u8, v: u32) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
    p[2] = @truncate(v >> 16);
    p[3] = @truncate(v >> 24);
}

pub export fn decode_gaze_payload(src: [*]const u8, len: usize, out: [*]u8, out_cap: usize) u32 {
    if (len < 2) return 0;
    const slice = src[0..len];
    var r = tlv.Reader.init(slice);
    r.pos = 2; // skip 2-byte mystery prefix

    const n_cols = r.readXdsRow() catch return 0;
    var written: u32 = 0;
    var i: u32 = 0;
    while (i < n_cols and r.remaining() > 0) : (i += 1) {
        const col_id = r.readXdsColumn() catch return written;
        const maybe_kind = columnKind(col_id);
        if (maybe_kind == null) return written; // unknown column — stop
        const kind = maybe_kind.?;

        var v0: f64 = 0;
        var v1: f64 = 0;
        var v2: f64 = 0;
        switch (kind) {
            KIND_S64 => {
                const v = r.readS64() catch return written;
                v0 = @floatFromInt(v);
            },
            KIND_U32 => {
                const v = r.readU32() catch return written;
                v0 = @floatFromInt(v);
            },
            KIND_FIXED16X16 => {
                v0 = r.readFixed16x16() catch return written;
            },
            KIND_POINT2D => {
                const v = r.readPoint2d() catch return written;
                v0 = v[0];
                v1 = v[1];
            },
            KIND_POINT3D => {
                const v = r.readPoint3d() catch return written;
                v0 = v[0];
                v1 = v[1];
                v2 = v[2];
            },
            else => return written,
        }

        const off = @as(usize, written) * 32;
        if (off + 32 > out_cap) return written;
        putLe32u(out + off, col_id);
        putLe32u(out + off + 4, kind);
        putF64(out + off + 8, v0);
        putF64(out + off + 16, v1);
        putF64(out + off + 24, v2);
        written += 1;
    }
    return written;
}

// =====================================================================
// Session layer — owns seq counter, request-id map, frame dispatch,
// and typed GazeSample assembly. Public "thin SDK" surface.
// =====================================================================
//
// Model:
//   - Each request_* fn increments next_seq, records (seq → req_id) in a
//     small table, builds the outbound frame into a dedicated session
//     out buffer, and returns the req_id to JS.
//   - JS sends the bytes over USB (via take_session_out).
//   - When a TTP_MAGIC_RSP frame arrives whose seq matches the table,
//     we fire on_response(req_id, payload). Otherwise nothing.
//   - 0x500 notifications are decoded into a fixed-layout GazeSample
//     and on_gaze(&sample) is fired.
//   - on_ttp_frame still fires for every frame (raw capture).

const MAX_PENDING: usize = 32;
const PendingSlot = struct { used: bool, seq: u32, req_id: u32 };
var pending: [MAX_PENDING]PendingSlot = @splat(.{ .used = false, .seq = 0, .req_id = 0 });
var next_seq: u32 = 1;
var next_req_id: u32 = 1;

// Dedicated out buffer so request_* returns only a length; JS copies it
// via take_session_out (or reads directly at session_out_ptr).
var session_out: [512]u8 = undefined;
var session_out_len: usize = 0;

fn pendingInsert(seq: u32, req_id: u32) void {
    var i: usize = 0;
    while (i < MAX_PENDING) : (i += 1) {
        if (!pending[i].used) {
            pending[i] = .{ .used = true, .seq = seq, .req_id = req_id };
            return;
        }
    }
    // Table full — oldest slot is evicted (simple: use slot 0).
    pending[0] = .{ .used = true, .seq = seq, .req_id = req_id };
}

fn pendingTake(seq: u32) ?u32 {
    var i: usize = 0;
    while (i < MAX_PENDING) : (i += 1) {
        if (pending[i].used and pending[i].seq == seq) {
            pending[i].used = false;
            return pending[i].req_id;
        }
    }
    return null;
}

// ---------- GazeSample — fixed extern layout, read directly from JS ----------

// Present-mask bits (one per field).
pub const GAZE_BIT_TIMESTAMP: u32            = 1 << 0;
pub const GAZE_BIT_FRAME_COUNTER: u32        = 1 << 1;
pub const GAZE_BIT_VALIDITY_L: u32           = 1 << 2;
pub const GAZE_BIT_VALIDITY_R: u32           = 1 << 3;
pub const GAZE_BIT_PUPIL_L: u32              = 1 << 4;
pub const GAZE_BIT_PUPIL_R: u32              = 1 << 5;
pub const GAZE_BIT_GAZE_2D: u32              = 1 << 6;
pub const GAZE_BIT_GAZE_2D_L: u32            = 1 << 7;
pub const GAZE_BIT_GAZE_2D_R: u32            = 1 << 8;
pub const GAZE_BIT_EYE_ORIGIN_L: u32         = 1 << 9;
pub const GAZE_BIT_EYE_ORIGIN_R: u32         = 1 << 10;
pub const GAZE_BIT_GAZE_DIR_L: u32           = 1 << 11;
pub const GAZE_BIT_GAZE_DIR_R: u32           = 1 << 12;
pub const GAZE_BIT_GAZE_3D_L: u32            = 1 << 13;
pub const GAZE_BIT_GAZE_3D_R: u32            = 1 << 14;
pub const GAZE_BIT_EYE_ORIGIN_L_DISP: u32    = 1 << 15;
pub const GAZE_BIT_EYE_ORIGIN_R_DISP: u32    = 1 << 16;
pub const GAZE_BIT_TRACKBOX_L_DISP: u32      = 1 << 17;
pub const GAZE_BIT_TRACKBOX_R_DISP: u32      = 1 << 18;

/// Decoded gaze frame — extern layout read directly from JS via gaze_view.ts.
/// Field offsets MUST be kept in sync with the TS reader.
///
/// Coordinate spaces:
///   tracker-space: origin at the IR sensor array (mm).
///   display-space: tracker-space shifted by display_area offset.
///   normalized 2D: ray→plane intersection on display_area, [0,1]².
///
/// The onboard calibration model applies a ~1-5mm correction to eye
/// origins (raw → calibrated). The fields here are post-calibration.
pub const GazeSample = extern struct {
    present_mask: u32,             // bitmask of GAZE_BIT_* flags
    frame_counter: u32,            // monotonic frame index
    validity_L: u32,               // 0=valid, 4=not detected
    validity_R: u32,               // 0=valid, 4=not detected
    timestamp_us: i64,             // device µs clock
    pupil_L_mm: f64,               // pupil diameter; -1 when invalid
    pupil_R_mm: f64,               // pupil diameter; -1 when invalid
    gaze_point_2d_norm: [2]f64,    // combined binocular 2D, temporally filtered
    gaze_point_2d_L_norm: [2]f64,  // left per-eye 2D projection [0,1]²
    gaze_point_2d_R_norm: [2]f64,  // right per-eye 2D projection [0,1]²
    eye_origin_L_mm: [3]f64,       // calibrated left eye position (tracker-space)
    eye_origin_R_mm: [3]f64,       // calibrated right eye position (tracker-space)
    trackbox_eye_pos_L: [3]f64, // left "gaze direction" — actually normalized track-box position
    trackbox_eye_pos_R: [3]f64, // right "gaze direction" — same (per-eye scaling)
    gaze_point_3d_L_mm: [3]f64,    // left ray–plane intersection (tracker-space)
    gaze_point_3d_R_mm: [3]f64,    // right ray–plane intersection (tracker-space)
    eye_origin_L_display_mm: [3]f64, // calibrated left eye position (display-space)
    eye_origin_R_display_mm: [3]f64, // calibrated right eye position (display-space)
    trackbox_eye_pos_L_display: [3]f64, // normalized track-box position (display-space)
    trackbox_eye_pos_R_display: [3]f64, // normalized track-box position (display-space)
};

var gaze_sample: GazeSample = undefined;

// Raw-columns output: 32B/record, 64 max (plenty for 39 known cols).
var raw_columns_out: [64 * 32]u8 = undefined;
var raw_columns_enabled: bool = false;

pub export fn raw_columns_enable(on: u32) void {
    raw_columns_enabled = on != 0;
}
pub export fn raw_columns_ptr() [*]const u8 {
    return &raw_columns_out;
}

pub export fn gaze_sample_ptr() [*]const u8 {
    return @ptrCast(&gaze_sample);
}
pub export fn gaze_sample_size() usize {
    return @sizeOf(GazeSample);
}
pub export fn session_out_ptr() [*]const u8 {
    return &session_out;
}

fn clearSample() void {
    @memset(@as([*]u8, @ptrCast(&gaze_sample))[0..@sizeOf(GazeSample)], 0);
}

// Fill gaze_sample from a 0x500 payload. Returns true on success.
fn decodeGazeSample(payload: [*]const u8, len: u32) bool {
    if (len < 2) return false;
    clearSample();
    const slice = payload[0..len];
    var r = tlv.Reader.init(slice);
    r.pos = 2;

    const n_cols = r.readXdsRow() catch return false;
    var i: u32 = 0;
    while (i < n_cols and r.remaining() > 0) : (i += 1) {
        const col_id = r.readXdsColumn() catch return true;
        switch (col_id) {
            0x01 => { // timestamp_us — device µs clock
                gaze_sample.timestamp_us = r.readS64() catch return true;
                gaze_sample.present_mask |= GAZE_BIT_TIMESTAMP;
            },
            0x02 => { // eye_origin_L — calibrated left eye position (mm, tracker-space)
                const v = r.readPoint3d() catch return true;
                gaze_sample.eye_origin_L_mm = .{ v[0], v[1], v[2] };
                gaze_sample.present_mask |= GAZE_BIT_EYE_ORIGIN_L;
            },
            0x03 => { // gaze_direction_L — normalized track-box position (not a gaze direction)
                const v = r.readPoint3d() catch return true;
                gaze_sample.trackbox_eye_pos_L = .{ v[0], v[1], v[2] };
                gaze_sample.present_mask |= GAZE_BIT_GAZE_DIR_L;
            },
            0x04 => { // gaze_point_3d_L — left ray–plane intersection (mm, tracker-space)
                const v = r.readPoint3d() catch return true;
                gaze_sample.gaze_point_3d_L_mm = .{ v[0], v[1], v[2] };
                gaze_sample.present_mask |= GAZE_BIT_GAZE_3D_L;
            },
            0x05 => { // gaze_point_2d_L — left per-eye projection on display_area [0,1]²
                const v = r.readPoint2d() catch return true;
                gaze_sample.gaze_point_2d_L_norm = .{ v[0], v[1] };
                gaze_sample.present_mask |= GAZE_BIT_GAZE_2D_L;
            },
            0x06 => { // pupil_diameter_L — mm, -1 when invalid
                gaze_sample.pupil_L_mm = r.readFixed16x16() catch return true;
                gaze_sample.present_mask |= GAZE_BIT_PUPIL_L;
            },
            0x07 => { // validity_L — 0=valid, 4=not detected
                gaze_sample.validity_L = r.readU32() catch return true;
                gaze_sample.present_mask |= GAZE_BIT_VALIDITY_L;
            },
            0x08 => { // eye_origin_R — calibrated right eye position (mm, tracker-space)
                const v = r.readPoint3d() catch return true;
                gaze_sample.eye_origin_R_mm = .{ v[0], v[1], v[2] };
                gaze_sample.present_mask |= GAZE_BIT_EYE_ORIGIN_R;
            },
            0x09 => { // gaze_direction_R — normalized track-box position (not a gaze direction)
                const v = r.readPoint3d() catch return true;
                gaze_sample.trackbox_eye_pos_R = .{ v[0], v[1], v[2] };
                gaze_sample.present_mask |= GAZE_BIT_GAZE_DIR_R;
            },
            0x0a => { // gaze_point_3d_R — right ray–plane intersection (mm, tracker-space)
                const v = r.readPoint3d() catch return true;
                gaze_sample.gaze_point_3d_R_mm = .{ v[0], v[1], v[2] };
                gaze_sample.present_mask |= GAZE_BIT_GAZE_3D_R;
            },
            0x0b => { // gaze_point_2d_R — right per-eye projection on display_area [0,1]²
                const v = r.readPoint2d() catch return true;
                gaze_sample.gaze_point_2d_R_norm = .{ v[0], v[1] };
                gaze_sample.present_mask |= GAZE_BIT_GAZE_2D_R;
            },
            0x0c => { // pupil_diameter_R — mm, -1 when invalid
                gaze_sample.pupil_R_mm = r.readFixed16x16() catch return true;
                gaze_sample.present_mask |= GAZE_BIT_PUPIL_R;
            },
            0x0d => { // validity_R — 0=valid, 4=not detected
                gaze_sample.validity_R = r.readU32() catch return true;
                gaze_sample.present_mask |= GAZE_BIT_VALIDITY_R;
            },
            0x14 => { // frame_counter — monotonic frame index
                gaze_sample.frame_counter = r.readU32() catch return true;
                gaze_sample.present_mask |= GAZE_BIT_FRAME_COUNTER;
            },
            0x22 => { // eye_origin_L_display — calibrated left eye (display-space mm)
                const v = r.readPoint3d() catch return true;
                gaze_sample.eye_origin_L_display_mm = .{ v[0], v[1], v[2] };
                gaze_sample.present_mask |= GAZE_BIT_EYE_ORIGIN_L_DISP;
            },
            0x24 => { // eye_origin_R_display — calibrated right eye (display-space mm)
                const v = r.readPoint3d() catch return true;
                gaze_sample.eye_origin_R_display_mm = .{ v[0], v[1], v[2] };
                gaze_sample.present_mask |= GAZE_BIT_EYE_ORIGIN_R_DISP;
            },
            0x25 => { // trackbox_eye_pos_L_display — normalized track-box position (display-space)
                const v = r.readPoint3d() catch return true;
                gaze_sample.trackbox_eye_pos_L_display = .{ v[0], v[1], v[2] };
                gaze_sample.present_mask |= GAZE_BIT_TRACKBOX_L_DISP;
            },
            0x27 => { // trackbox_eye_pos_R_display — normalized track-box position (display-space)
                const v = r.readPoint3d() catch return true;
                gaze_sample.trackbox_eye_pos_R_display = .{ v[0], v[1], v[2] };
                gaze_sample.present_mask |= GAZE_BIT_TRACKBOX_R_DISP;
            },
            0x1c => { // gaze_point_2d — combined binocular 2D, temporally filtered (final)
                const v = r.readPoint2d() catch return true;
                gaze_sample.gaze_point_2d_norm = .{ v[0], v[1] };
                gaze_sample.present_mask |= GAZE_BIT_GAZE_2D;
            },
            else => {
                // Skip unknown columns by reading their kind-based width.
                const kind = columnKind(col_id) orelse return true;
                switch (kind) {
                    KIND_S64 => { _ = r.readS64() catch return true; },
                    KIND_U32 => { _ = r.readU32() catch return true; },
                    KIND_FIXED16X16 => { _ = r.readFixed16x16() catch return true; },
                    KIND_POINT2D => { _ = r.readPoint2d() catch return true; },
                    KIND_POINT3D => { _ = r.readPoint3d() catch return true; },
                    else => return true,
                }
            },
        }
    }
    return true;
}

// Central frame dispatch — called from drainFrame() for every complete
// TTP frame. Always emits raw on_ttp_frame; additionally routes to
// on_response / on_gaze.
fn dispatchFrame(magic: u32, seq: u32, op: u32, payload: [*]const u8, plen: u32) void {
    on_ttp_frame(magic, seq, op, payload, plen);
    if (magic == TTP_MAGIC_RSP) {
        if (pendingTake(seq)) |req_id| on_response(req_id, payload, plen);
    } else if (magic == TTP_MAGIC_NOTIFY and op == 0x500) {
        if (decodeGazeSample(payload, plen)) {
            on_gaze(@ptrCast(&gaze_sample));
        }
        if (raw_columns_enabled) {
            const n = decode_gaze_payload(payload, plen, &raw_columns_out, raw_columns_out.len);
            if (n > 0) on_raw_columns(&raw_columns_out, n);
        }
    }
}

// ---------- Public session API ----------

pub export fn session_reset() void {
    next_seq = 1;
    next_req_id = 1;
    var i: usize = 0;
    while (i < MAX_PENDING) : (i += 1) pending[i].used = false;
    session_out_len = 0;
    acc_len = 0;
}

fn takeReqId() u32 {
    const id = next_req_id;
    next_req_id +%= 1;
    if (next_req_id == 0) next_req_id = 1;
    return id;
}

fn takeSeq() u32 {
    const s = next_seq;
    next_seq +%= 1;
    if (next_seq == 0) next_seq = 1;
    return s;
}

pub export fn session_out_len_() usize {
    return session_out_len;
}

/// Build hello. Response is expected; returns request_id.
pub export fn request_hello() u32 {
    const req_id = takeReqId();
    const seq = takeSeq();
    session_out_len = build_hello(seq, &session_out);
    pendingInsert(seq, req_id);
    return req_id;
}

/// Subscribe to a TTP stream. No response expected; returns 0.
/// The frame is placed in session_out.
pub export fn request_subscribe(stream_id: u16) u32 {
    const seq = takeSeq();
    session_out_len = build_subscribe(seq, stream_id, &session_out);
    return 0;
}

/// Query display_area. Returns request_id.
pub export fn request_get_display_area() u32 {
    const req_id = takeReqId();
    const seq = takeSeq();
    session_out_len = build_get_display_area(seq, &session_out);
    pendingInsert(seq, req_id);
    return req_id;
}

/// Set display_area (fire-and-forget; no response). Returns 0.
pub export fn request_set_display_area(w_mm: f64, h_mm: f64, ox_mm: f64, oy_mm: f64, z_mm: f64) u32 {
    const seq = takeSeq();
    session_out_len = build_set_display_area(seq, w_mm, h_mm, ox_mm, oy_mm, z_mm, &session_out);
    return 0;
}

/// Set display_area from 9 corner coordinates (tl/tr/bl × xyz). Returns 0.
pub export fn request_set_display_area_corners(
    tl_x: f64, tl_y: f64, tl_z: f64,
    tr_x: f64, tr_y: f64, tr_z: f64,
    bl_x: f64, bl_y: f64, bl_z: f64,
) u32 {
    const seq = takeSeq();
    session_out_len = build_set_display_area_corners(
        seq, tl_x, tl_y, tl_z, tr_x, tr_y, tr_z, bl_x, bl_y, bl_z, &session_out,
    );
    return 0;
}

// ---------- Calibration / realm session API ----------

/// Query realm info. Returns request_id.
pub export fn request_query_realm() u32 {
    const req_id = takeReqId();
    const seq = takeSeq();
    session_out_len = build_query_realm(seq, &session_out);
    pendingInsert(seq, req_id);
    return req_id;
}

/// Open realm. Returns request_id (response contains challenge).
pub export fn request_open_realm(realm_type: u32) u32 {
    const req_id = takeReqId();
    const seq = takeSeq();
    session_out_len = build_open_realm(seq, realm_type, &session_out);
    pendingInsert(seq, req_id);
    return req_id;
}

/// Send realm auth response (after computing HMAC-MD5). Returns request_id.
pub export fn request_realm_response(realm_id: u32, field_210: u32, digest: [*]const u8) u32 {
    const req_id = takeReqId();
    const seq = takeSeq();
    session_out_len = build_realm_response(seq, realm_id, field_210, digest, &session_out);
    pendingInsert(seq, req_id);
    return req_id;
}

/// Close realm. Returns request_id.
pub export fn request_close_realm(realm_id: u32) u32 {
    const req_id = takeReqId();
    const seq = takeSeq();
    session_out_len = build_close_realm(seq, realm_id, &session_out);
    pendingInsert(seq, req_id);
    return req_id;
}

/// Get calibration stimulus points. Returns request_id.
pub export fn request_cal_stimulus() u32 {
    const req_id = takeReqId();
    const seq = takeSeq();
    session_out_len = build_cal_stimulus(seq, &session_out);
    pendingInsert(seq, req_id);
    return req_id;
}

/// Add calibration point. Returns request_id.
pub export fn request_cal_add_point(x: f64, y: f64, eye_choice: u32) u32 {
    const req_id = takeReqId();
    const seq = takeSeq();
    session_out_len = build_cal_add_point(seq, x, y, eye_choice, &session_out);
    pendingInsert(seq, req_id);
    return req_id;
}

/// Compute and apply calibration. Returns request_id.
pub export fn request_cal_compute() u32 {
    const req_id = takeReqId();
    const seq = takeSeq();
    session_out_len = build_cal_compute(seq, &session_out);
    pendingInsert(seq, req_id);
    return req_id;
}

/// Retrieve calibration blob. Returns request_id.
pub export fn request_cal_retrieve() u32 {
    const req_id = takeReqId();
    const seq = takeSeq();
    session_out_len = build_cal_retrieve(seq, &session_out);
    pendingInsert(seq, req_id);
    return req_id;
}

/// Apply calibration blob. The blob is read from the scratch buffer
/// (JS writes it there first). Returns request_id.
/// blob_len: number of bytes in out_scratch.
pub export fn request_cal_apply(blob_len: u32) u32 {
    const req_id = takeReqId();
    const seq = takeSeq();
    // Use out_scratch as source, write to session_out.
    session_out_len = build_cal_apply(seq, &out_scratch, blob_len, &session_out);
    pendingInsert(seq, req_id);
    return req_id;
}

// =====================================================================
// Handshake state machine
// =====================================================================
//
// Step-based handshake that works identically from Zig (synchronous poll)
// and from JS/wasm (async/await). The transport layer drives the loop:
//
//   handshake_init(display area params)
//   loop:
//     action = handshake_poll()
//     if action == .send       → transport.send(session_out)
//     if action == .recv       → transport.recv() → feed_usb_in()  → goto loop
//     if action == .done       → break
//     if action == .err        → abort

const REALM_KEY = "IS2LJC6GIRBBEK2K\x00";

pub const HandshakeAction = enum(u8) {
    /// session_out contains bytes to send, then call handshake_poll() again.
    send = 1,
    /// Need inbound data. Call feed_usb_in() then handshake_poll() again.
    recv = 2,
    /// Handshake complete.
    done = 3,
    /// Handshake failed.
    err = 4,
};

const HandshakeState = enum {
    idle,
    // Hello
    build_hello,
    await_hello,
    // Realm
    build_query_realm,
    await_query_realm,
    build_open_realm,
    await_open_realm,
    build_realm_auth,
    await_realm_auth,
    // Subscribe
    build_subscribe,
    // Terminal
    done,
    failed,
};

var hs_state: HandshakeState = .idle;

// Handshake response capture (reused across steps).
var hs_resp_ready: bool = false;
var hs_resp_buf: [4096]u8 = undefined;
var hs_resp_len: u32 = 0;

// Realm state captured during handshake.
var hs_realm_type: u32 = 0;
var hs_realm_id: u32 = 0;
var hs_field_210: u32 = 0;

// Subscribe stream id.
var hs_stream_id: u16 = 0x500;

fn hsResponseHook(request_id: u32, payload_ptr: [*]const u8, payload_len: u32) void {
    _ = request_id;
    const n: usize = @min(payload_len, hs_resp_buf.len);
    @memcpy(hs_resp_buf[0..n], payload_ptr[0..n]);
    hs_resp_len = @intCast(n);
    hs_resp_ready = true;
}

/// Initialize handshake. Call before handshake_poll().
/// stream_id is the gaze stream to subscribe to (typically 0x500).
pub export fn handshake_init(stream_id: u16) void {
    hs_stream_id = stream_id;

    hs_state = .build_hello;
    hs_resp_ready = false;
    hs_resp_len = 0;
    hs_realm_type = 0;
    hs_realm_id = 0;
    hs_field_210 = 0;

    session_reset();

    // Install handshake response hook (captures responses for the state machine).
    // The original hook is restored when handshake completes.
    hs_prev_response_hook = hook_response;
    hook_response = hsResponseHook;
}

var hs_prev_response_hook: HookFn_response = noop_response;

/// Drive the handshake one step. Returns the action the transport must take.
/// After .send: transport sends session_out bytes, then calls handshake_poll() again.
/// After .recv: transport receives data into feed_usb_in(), then calls handshake_poll() again.
/// After .done/.err: handshake is complete.
pub export fn handshake_poll() u8 {
    const action = handshakePollInner();
    return @intFromEnum(action);
}

fn handshakePollInner() HandshakeAction {
    switch (hs_state) {
        .idle => return .done,

        // ── Hello ──────────────────────────────────────────
        .build_hello => {
            _ = request_hello();
            hs_resp_ready = false;
            hs_state = .await_hello;
            return .send;
        },
        .await_hello => {
            if (hs_resp_ready) {
                hs_state = .build_query_realm;
                return handshakePollInner(); // immediately advance
            }
            return .recv;
        },

        // ── Query realm ────────────────────────────────────
        .build_query_realm => {
            _ = request_query_realm();
            hs_resp_ready = false;
            hs_state = .await_query_realm;
            return .send;
        },
        .await_query_realm => {
            if (hs_resp_ready) {
                // Parse realm_type from response TLV.
                hs_realm_type = if (hs_resp_len >= 6)
                    hsTlvFirstU32(hs_resp_buf[0..hs_resp_len])
                else
                    0;
                hs_state = .build_open_realm;
                return handshakePollInner();
            }
            return .recv;
        },

        // ── Open realm ─────────────────────────────────────
        .build_open_realm => {
            _ = request_open_realm(hs_realm_type);
            hs_resp_ready = false;
            hs_state = .await_open_realm;
            return .send;
        },
        .await_open_realm => {
            if (hs_resp_ready) {
                if (hs_realm_type == 0) {
                    // No auth needed.
                    hs_state = .build_subscribe;
                    return handshakePollInner();
                }
                if (hs_resp_len < 12) {
                    hs_state = .failed;
                    return .err;
                }
                // Parse realm_id, field_210, challenge.
                hs_realm_id = hsTlvU32At(hs_resp_buf[0..hs_resp_len], 0);
                hs_field_210 = hsTlvU32At(hs_resp_buf[0..hs_resp_len], 1);
                hs_state = .build_realm_auth;
                return handshakePollInner();
            }
            return .recv;
        },

        // ── Realm auth (HMAC-MD5) ──────────────────────────
        .build_realm_auth => {
            const challenge = hsTlvExtractChallenge(hs_resp_buf[0..hs_resp_len]) orelse {
                hs_state = .failed;
                return .err;
            };
            var digest: [16]u8 = undefined;
            compute_hmac_md5(REALM_KEY.ptr, REALM_KEY.len, challenge.ptr, @intCast(challenge.len), &digest);
            _ = request_realm_response(hs_realm_id, hs_field_210, &digest);
            hs_resp_ready = false;
            hs_state = .await_realm_auth;
            return .send;
        },
        .await_realm_auth => {
            if (hs_resp_ready) {
                hs_state = .build_subscribe;
                return handshakePollInner();
            }
            return .recv;
        },

        // ── Subscribe ──────────────────────────────────────
        .build_subscribe => {
            _ = request_subscribe(hs_stream_id);
            hs_state = .done;
            return .send;
        },

        .done => {
            hook_response = hs_prev_response_hook;
            return .done;
        },
        .failed => {
            hook_response = hs_prev_response_hook;
            return .err;
        },
    }
}

// =====================================================================
// Calibration realm unlock — step-based state machine.
//
// Same pattern as the handshake: init, poll, done.
//
//   cal_start_init()
//   loop:
//     action = cal_start_poll()
//     if .send → transport.send(session_out)
//     if .recv → transport.recv() → feed_usb_in() → goto loop
//     if .done → realm_id = cal_start_realm_id()
//     if .err  → abort
//
//   ... calibration operations ...
//
//   request_close_realm(realm_id)
// =====================================================================

const CalStartState = enum {
    idle,
    build_query_realm,
    await_query_realm,
    build_open_realm,
    await_open_realm,
    build_realm_auth,
    await_realm_auth,
    done,
    failed,
};

var cs_state: CalStartState = .idle;
var cs_realm_type: u32 = 0;
var cs_realm_id: u32 = 0;
var cs_field_210: u32 = 0;
var cs_prev_response_hook: HookFn_response = noop_response;

fn csResponseHook(request_id: u32, payload_ptr: [*]const u8, payload_len: u32) void {
    _ = request_id;
    const n: usize = @min(payload_len, hs_resp_buf.len);
    @memcpy(hs_resp_buf[0..n], payload_ptr[0..n]);
    hs_resp_len = @intCast(n);
    hs_resp_ready = true;
}

/// Initialize the calibration realm unlock. Call before cal_start_poll().
pub export fn cal_start_init() void {
    cs_state = .build_query_realm;
    cs_realm_type = 0;
    cs_realm_id = 0;
    cs_field_210 = 0;
    hs_resp_ready = false;
    hs_resp_len = 0;
    cs_prev_response_hook = hook_response;
    hook_response = csResponseHook;
}

/// Drive the realm unlock one step. Same action codes as handshake_poll.
pub export fn cal_start_poll() u8 {
    return @intFromEnum(calStartPollInner());
}

/// After cal_start_poll returns .done, this holds the realm_id to pass to close_realm.
pub export fn cal_start_realm_id() u32 {
    return cs_realm_id;
}

fn calStartPollInner() HandshakeAction {
    switch (cs_state) {
        .idle => return .done,

        .build_query_realm => {
            _ = request_query_realm();
            hs_resp_ready = false;
            cs_state = .await_query_realm;
            return .send;
        },
        .await_query_realm => {
            if (hs_resp_ready) {
                cs_realm_type = if (hs_resp_len >= 6)
                    hsTlvFirstU32(hs_resp_buf[0..hs_resp_len])
                else
                    0;
                cs_state = .build_open_realm;
                return calStartPollInner();
            }
            return .recv;
        },

        .build_open_realm => {
            _ = request_open_realm(cs_realm_type);
            hs_resp_ready = false;
            cs_state = .await_open_realm;
            return .send;
        },
        .await_open_realm => {
            if (hs_resp_ready) {
                if (cs_realm_type == 0) {
                    cs_realm_id = if (hs_resp_len >= 6)
                        hsTlvFirstU32(hs_resp_buf[0..hs_resp_len])
                    else
                        0;
                    cs_state = .done;
                    return calStartPollInner();
                }
                if (hs_resp_len < 12) {
                    cs_state = .failed;
                    return .err;
                }
                cs_realm_id = hsTlvU32At(hs_resp_buf[0..hs_resp_len], 0);
                cs_field_210 = hsTlvU32At(hs_resp_buf[0..hs_resp_len], 1);
                cs_state = .build_realm_auth;
                return calStartPollInner();
            }
            return .recv;
        },

        .build_realm_auth => {
            const challenge = hsTlvExtractChallenge(hs_resp_buf[0..hs_resp_len]) orelse {
                cs_state = .failed;
                return .err;
            };
            var digest: [16]u8 = undefined;
            compute_hmac_md5(REALM_KEY.ptr, REALM_KEY.len, challenge.ptr, @intCast(challenge.len), &digest);
            _ = request_realm_response(cs_realm_id, cs_field_210, &digest);
            hs_resp_ready = false;
            cs_state = .await_realm_auth;
            return .send;
        },
        .await_realm_auth => {
            if (hs_resp_ready) {
                cs_state = .done;
                return calStartPollInner();
            }
            return .recv;
        },

        .done => {
            hook_response = cs_prev_response_hook;
            return .done;
        },
        .failed => {
            hook_response = cs_prev_response_hook;
            return .err;
        },
    }
}

// =====================================================================
// Calibration finish — step-based state machine.
//
// Wraps: compute_and_apply → retrieve → close_realm.
// The retrieved calibration blob is stored internally and exposed via
// cal_finish_blob_ptr / cal_finish_blob_len.
//
//   cal_finish_init()
//   loop:
//     action = cal_finish_poll()
//     if .send → transport.send(session_out)
//     if .recv → transport.recv() → feed_usb_in() → goto loop
//     if .done → blob = cal_finish_blob_ptr()[0..cal_finish_blob_len()]
//     if .err  → abort
// =====================================================================

const CalFinishState = enum {
    idle,
    build_compute,
    await_compute,
    build_retrieve,
    await_retrieve,
    build_close_realm,
    await_close_realm,
    done,
    failed,
};

var cf_state: CalFinishState = .idle;
var cf_prev_response_hook: HookFn_response = noop_response;
var cf_blob_len: u32 = 0;
// The retrieved blob is stored in out_scratch (up to 4096 bytes).

fn cfResponseHook(request_id: u32, payload_ptr: [*]const u8, payload_len: u32) void {
    _ = request_id;
    const n: usize = @min(payload_len, hs_resp_buf.len);
    @memcpy(hs_resp_buf[0..n], payload_ptr[0..n]);
    hs_resp_len = @intCast(n);
    hs_resp_ready = true;
}

/// Initialize the calibration finish sequence. Call before cal_finish_poll().
/// realm_id is the value from cal_start_realm_id().
pub export fn cal_finish_init() void {
    cf_state = .build_compute;
    cf_blob_len = 0;
    hs_resp_ready = false;
    hs_resp_len = 0;
    cf_prev_response_hook = hook_response;
    hook_response = cfResponseHook;
}

/// Drive the finish sequence one step. Same action codes as handshake_poll.
pub export fn cal_finish_poll() u8 {
    return @intFromEnum(calFinishPollInner());
}

/// After cal_finish_poll returns .done, pointer to the retrieved calibration blob.
pub export fn cal_finish_blob_ptr() [*]const u8 {
    return &out_scratch;
}

/// Length of the retrieved calibration blob.
pub export fn cal_finish_blob_len() u32 {
    return cf_blob_len;
}

fn calFinishPollInner() HandshakeAction {
    switch (cf_state) {
        .idle => return .done,

        .build_compute => {
            _ = request_cal_compute();
            hs_resp_ready = false;
            cf_state = .await_compute;
            return .send;
        },
        .await_compute => {
            if (hs_resp_ready) {
                cf_state = .build_retrieve;
                return calFinishPollInner();
            }
            return .recv;
        },

        .build_retrieve => {
            _ = request_cal_retrieve();
            hs_resp_ready = false;
            cf_state = .await_retrieve;
            return .send;
        },
        .await_retrieve => {
            if (hs_resp_ready) {
                // Store the blob in out_scratch for the caller.
                const n: usize = @min(hs_resp_len, out_scratch.len);
                @memcpy(out_scratch[0..n], hs_resp_buf[0..n]);
                cf_blob_len = @intCast(n);
                cf_state = .build_close_realm;
                return calFinishPollInner();
            }
            return .recv;
        },

        .build_close_realm => {
            _ = request_close_realm(cs_realm_id);
            hs_resp_ready = false;
            cf_state = .await_close_realm;
            return .send;
        },
        .await_close_realm => {
            if (hs_resp_ready) {
                cf_state = .done;
                return calFinishPollInner();
            }
            return .recv;
        },

        .done => {
            hook_response = cf_prev_response_hook;
            return .done;
        },
        .failed => {
            hook_response = cf_prev_response_hook;
            return .err;
        },
    }
}

// =====================================================================
// Calibration apply — step-based state machine.
//
// Wraps: cal_start (realm unlock) → apply blob → close_realm.
// The blob must be written to out_scratch before calling cal_apply_init.
//
//   // write blob to scratch_ptr()[0..blob_len]
//   cal_apply_init(blob_len)
//   loop:
//     action = cal_apply_poll()
//     if .send → transport.send(session_out)
//     if .recv → transport.recv() → feed_usb_in() → goto loop
//     if .done → success
//     if .err  → abort
// =====================================================================

const CalApplyState = enum {
    idle,
    realm_unlock,    // drives cal_start sub-machine
    build_apply,
    await_apply,
    build_close_realm,
    await_close_realm,
    done,
    failed,
};

var ca_state: CalApplyState = .idle;
var ca_blob_len: u32 = 0;
var ca_prev_response_hook: HookFn_response = noop_response;

fn caResponseHook(request_id: u32, payload_ptr: [*]const u8, payload_len: u32) void {
    _ = request_id;
    const n: usize = @min(payload_len, hs_resp_buf.len);
    @memcpy(hs_resp_buf[0..n], payload_ptr[0..n]);
    hs_resp_len = @intCast(n);
    hs_resp_ready = true;
}

/// Initialize the cal_apply sequence. Blob must already be in scratch_ptr()[0..blob_len].
pub export fn cal_apply_init(blob_len: u32) void {
    ca_state = .realm_unlock;
    ca_blob_len = blob_len;
    // Start the realm unlock sub-machine.
    cal_start_init();
}

/// Drive the cal_apply sequence one step.
pub export fn cal_apply_poll() u8 {
    return @intFromEnum(calApplyPollInner());
}

fn calApplyPollInner() HandshakeAction {
    switch (ca_state) {
        .idle => return .done,

        .realm_unlock => {
            // Drive the cal_start sub-machine.
            const action: HandshakeAction = @enumFromInt(cal_start_poll());
            switch (action) {
                .done => {
                    // Realm unlocked, now apply the blob.
                    ca_state = .build_apply;
                    // Install our own response hook (cal_start restored the previous one).
                    ca_prev_response_hook = hook_response;
                    hook_response = caResponseHook;
                    return calApplyPollInner();
                },
                .err => {
                    ca_state = .failed;
                    return .err;
                },
                .send, .recv => return action,
            }
        },

        .build_apply => {
            _ = request_cal_apply(ca_blob_len);
            hs_resp_ready = false;
            ca_state = .await_apply;
            return .send;
        },
        .await_apply => {
            if (hs_resp_ready) {
                ca_state = .build_close_realm;
                return calApplyPollInner();
            }
            return .recv;
        },

        .build_close_realm => {
            _ = request_close_realm(cs_realm_id);
            hs_resp_ready = false;
            ca_state = .await_close_realm;
            return .send;
        },
        .await_close_realm => {
            if (hs_resp_ready) {
                ca_state = .done;
                return calApplyPollInner();
            }
            return .recv;
        },

        .done => {
            hook_response = ca_prev_response_hook;
            return .done;
        },
        .failed => {
            hook_response = ca_prev_response_hook;
            return .err;
        },
    }
}

// ── TLV response helpers (used by handshake + cal_start) ────────────

fn hsTlvFirstU32(data: []const u8) u32 {
    var pos: usize = 2; // skip 2-byte prefix
    while (pos + 4 <= data.len) {
        const size = std.mem.readInt(u16, data[pos + 2 ..][0..2], .big);
        pos += 4;
        if (size == 4 and pos + 4 <= data.len) {
            return std.mem.readInt(u32, data[pos..][0..4], .big);
        }
        pos += size;
    }
    return 0;
}

fn hsTlvU32At(data: []const u8, index: usize) u32 {
    var pos: usize = 2;
    var found: usize = 0;
    while (pos + 4 <= data.len) {
        const size = std.mem.readInt(u16, data[pos + 2 ..][0..2], .big);
        pos += 4;
        if (size == 4 and pos + 4 <= data.len) {
            if (found == index) {
                return std.mem.readInt(u32, data[pos..][0..4], .big);
            }
            found += 1;
        }
        pos += size;
    }
    return 0;
}

fn hsTlvExtractChallenge(data: []const u8) ?[]const u8 {
    var pos: usize = 2;
    while (pos + 4 <= data.len) {
        const size = std.mem.readInt(u16, data[pos + 2 ..][0..2], .big);
        pos += 4;
        if (size > 4 and pos + size <= data.len) {
            return data[pos .. pos + size];
        }
        pos += size;
    }
    return null;
}

// =====================================================================
// Native tests (not exported to wasm; built via `zig build test`)
// =====================================================================

test "q42 encode matches C" {
    try std.testing.expectEqual(@as(i64, 879609302220800), q42_encode(200.0));
    try std.testing.expectEqual(@as(i64, 0), q42_encode(0.0));
    try std.testing.expectEqual(@as(i64, -879609302220800), q42_encode(-200.0));
}

test "hello frame is well-formed" {
    var buf: [256]u8 = undefined;
    const n = build_hello(1, &buf);
    // envelope(8) + header(24) + payload(47) = 79
    try std.testing.expectEqual(@as(usize, 79), n);
    // envelope
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
    // LE length = 24 + 47 = 71
    try std.testing.expectEqual(@as(u8, 71), buf[4]);
    try std.testing.expectEqual(@as(u8, 0), buf[5]);
    // TTP header: magic BE = 0x51
    try std.testing.expectEqual(@as(u8, 0), buf[8]);
    try std.testing.expectEqual(@as(u8, 0), buf[9]);
    try std.testing.expectEqual(@as(u8, 0), buf[10]);
    try std.testing.expectEqual(@as(u8, 0x51), buf[11]);
    // seq BE = 1
    try std.testing.expectEqual(@as(u8, 0), buf[12]);
    try std.testing.expectEqual(@as(u8, 0), buf[13]);
    try std.testing.expectEqual(@as(u8, 0), buf[14]);
    try std.testing.expectEqual(@as(u8, 1), buf[15]);
    // op BE = 0x3e8
    try std.testing.expectEqual(@as(u8, 0), buf[20]);
    try std.testing.expectEqual(@as(u8, 0), buf[21]);
    try std.testing.expectEqual(@as(u8, 0x03), buf[22]);
    try std.testing.expectEqual(@as(u8, 0xe8), buf[23]);
    // plen BE = 47
    try std.testing.expectEqual(@as(u8, 0), buf[28]);
    try std.testing.expectEqual(@as(u8, 0), buf[29]);
    try std.testing.expectEqual(@as(u8, 0), buf[30]);
    try std.testing.expectEqual(@as(u8, 47), buf[31]);
    // payload first byte
    try std.testing.expectEqual(@as(u8, 0x00), buf[32]);
}

test "set_display_area frame structure" {
    var buf: [512]u8 = undefined;
    // Typical display area parameters
    const n = build_set_display_area(2, 400.0, 300.0, -200.0, 0.0, 0.0, &buf);
    // envelope(8) + header(24) + payload(2 + 3*48 + 9 + 9) = 8 + 24 + 164 = 196
    try std.testing.expectEqual(@as(usize, 196), n);
    // op = 0x5a0 at bytes 20..23 BE
    try std.testing.expectEqual(@as(u8, 0), buf[20]);
    try std.testing.expectEqual(@as(u8, 0), buf[21]);
    try std.testing.expectEqual(@as(u8, 0x05), buf[22]);
    try std.testing.expectEqual(@as(u8, 0xa0), buf[23]);
}

fn testHook_ttp_frame(magic: u32, seq: u32, op: u32, payload_ptr: [*]const u8, payload_len: u32) void {
    if (test_event_count < test_events.len) {
        test_events[test_event_count] = .{
            .magic = magic,
            .seq = seq,
            .op = op,
            .plen = payload_len,
            .first = if (payload_len > 0) payload_ptr[0] else 0,
        };
        test_event_count += 1;
    }
}
fn testHook_parse_error(code: u32) void {
    test_error_count += 1;
    test_last_error = code;
}

fn resetTestState() void {
    acc_len = 0;
    test_event_count = 0;
    test_error_count = 0;
    test_last_error = 0;
    set_hooks(testHook_ttp_frame, testHook_parse_error, null, null, null);
}

// Build a fake inbound envelope: [01 00 00 00][len_LE:4][ttp_hdr:24][payload]
fn fakeInbound(out: [*]u8, magic: u32, seq: u32, op: u32, payload: []const u8) usize {
    out[0] = 0x01;
    out[1] = 0;
    out[2] = 0;
    out[3] = 0;
    const total: u32 = @intCast(ENVELOPE_SIZE + TTP_HDR_SIZE + payload.len);
    putLe32(out + 4, total);
    // TTP header
    var i: usize = 0;
    while (i < TTP_HDR_SIZE) : (i += 1) out[ENVELOPE_SIZE + i] = 0;
    putBe32(out + ENVELOPE_SIZE + 0, magic);
    putBe32(out + ENVELOPE_SIZE + 4, seq);
    putBe32(out + ENVELOPE_SIZE + 12, op);
    putBe32(out + ENVELOPE_SIZE + 20, @intCast(payload.len));
    i = 0;
    while (i < payload.len) : (i += 1) out[ENVELOPE_SIZE + TTP_HDR_SIZE + i] = payload[i];
    return total;
}

test "parse single complete frame" {
    resetTestState();
    var buf: [128]u8 = undefined;
    const payload = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const n = fakeInbound(&buf, TTP_MAGIC_RSP, 42, 0x3e8, &payload);
    feed_usb_in(&buf, n);
    try std.testing.expectEqual(@as(usize, 1), test_event_count);
    try std.testing.expectEqual(@as(u32, TTP_MAGIC_RSP), test_events[0].magic);
    try std.testing.expectEqual(@as(u32, 42), test_events[0].seq);
    try std.testing.expectEqual(@as(u32, 0x3e8), test_events[0].op);
    try std.testing.expectEqual(@as(u32, 4), test_events[0].plen);
    try std.testing.expectEqual(@as(u8, 0xde), test_events[0].first);
    try std.testing.expectEqual(@as(usize, 0), test_error_count);
    try std.testing.expectEqual(@as(usize, 0), acc_len);
}

test "parse two frames concatenated" {
    resetTestState();
    var buf: [256]u8 = undefined;
    const p1 = [_]u8{0x11};
    const p2 = [_]u8{ 0x22, 0x23 };
    const n1 = fakeInbound(&buf, TTP_MAGIC_RSP, 1, 0x100, &p1);
    const n2 = fakeInbound(@ptrCast(&buf[n1]), TTP_MAGIC_NOTIFY, 0, 0x500, &p2);
    feed_usb_in(&buf, n1 + n2);
    try std.testing.expectEqual(@as(usize, 2), test_event_count);
    try std.testing.expectEqual(@as(u32, 0x500), test_events[1].op);
    try std.testing.expectEqual(@as(u8, 0x22), test_events[1].first);
}

test "parse frame split across two chunks" {
    resetTestState();
    var buf: [128]u8 = undefined;
    const payload = [_]u8{ 0xa1, 0xa2, 0xa3, 0xa4 };
    const n = fakeInbound(&buf, TTP_MAGIC_RSP, 7, 0x200, &payload);
    // Feed first 20 bytes (partial header)
    feed_usb_in(&buf, 20);
    try std.testing.expectEqual(@as(usize, 0), test_event_count);
    try std.testing.expectEqual(@as(usize, 20), acc_len);
    // Feed remainder
    feed_usb_in(@ptrCast(&buf[20]), n - 20);
    try std.testing.expectEqual(@as(usize, 1), test_event_count);
    try std.testing.expectEqual(@as(u32, 7), test_events[0].seq);
    try std.testing.expectEqual(@as(usize, 0), acc_len);
}

test "parser rejects bad dir byte" {
    resetTestState();
    var buf = [_]u8{ 0x02, 0, 0, 0, 0x20, 0, 0, 0 };
    feed_usb_in(&buf, buf.len);
    try std.testing.expectEqual(@as(usize, 0), test_event_count);
    try std.testing.expectEqual(@as(usize, 1), test_error_count);
    try std.testing.expectEqual(ERR_BAD_DIR, test_last_error);
    try std.testing.expectEqual(@as(usize, 0), acc_len); // reset after error
}

test "parser rejects impossibly small length" {
    resetTestState();
    var buf = [_]u8{ 0x01, 0, 0, 0, 10, 0, 0, 0 }; // len=10 < 8+24
    feed_usb_in(&buf, buf.len);
    try std.testing.expectEqual(@as(usize, 1), test_error_count);
    try std.testing.expectEqual(ERR_BAD_LEN, test_last_error);
}

test "subscribe frame carries stream_id" {
    var buf: [128]u8 = undefined;
    const n = build_subscribe(3, 0x500, &buf);
    // envelope(8) + header(24) + payload(20) = 52
    try std.testing.expectEqual(@as(usize, 52), n);
    // op = 0x4c4
    try std.testing.expectEqual(@as(u8, 0x04), buf[22]);
    try std.testing.expectEqual(@as(u8, 0xc4), buf[23]);
    // stream_id at payload bytes 9..10 (= frame bytes 32+9, 32+10)
    try std.testing.expectEqual(@as(u8, 0x05), buf[41]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[42]);
}

// =====================================================================
// Calibration / realm tests
// =====================================================================

test "MD5 of empty string" {
    // MD5("") = d41d8cd98f00b204e9800998ecf8427e
    var md5 = MD5{};
    md5.update(@as([*]const u8, @ptrCast("")), 0);
    var digest: [16]u8 = undefined;
    md5.finalize(&digest);
    const expected = [_]u8{
        0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04,
        0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "MD5 of 'abc'" {
    // MD5("abc") = 900150983cd24fb0d6963f7d28e17f72
    var md5 = MD5{};
    const msg = "abc";
    md5.update(msg, msg.len);
    var digest: [16]u8 = undefined;
    md5.finalize(&digest);
    const expected = [_]u8{
        0x90, 0x01, 0x50, 0x98, 0x3c, 0xd2, 0x4f, 0xb0,
        0xd6, 0x96, 0x3f, 0x7d, 0x28, 0xe1, 0x7f, 0x72,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "HMAC-MD5 RFC 2202 test vector 1" {
    // Key = 0x0b repeated 16 times, Data = "Hi There"
    // HMAC-MD5 = 9294727a3638bb1c13f48ef8158bfc9d
    const key = [_]u8{0x0b} ** 16;
    const data = "Hi There";
    var digest: [16]u8 = undefined;
    hmacMd5(&key, 16, data, data.len, &digest);
    const expected = [_]u8{
        0x92, 0x94, 0x72, 0x7a, 0x36, 0x38, 0xbb, 0x1c,
        0x13, 0xf4, 0x8e, 0xf8, 0x15, 0x8b, 0xfc, 0x9d,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "HMAC-MD5 RFC 2202 test vector 2" {
    // Key = "Jefe", Data = "what do ya want for nothing?"
    // HMAC-MD5 = 750c783e6ab0b503eaa86e310a5db738
    const key = "Jefe";
    const data = "what do ya want for nothing?";
    var digest: [16]u8 = undefined;
    hmacMd5(key, key.len, data, data.len, &digest);
    const expected = [_]u8{
        0x75, 0x0c, 0x78, 0x3e, 0x6a, 0xb0, 0xb5, 0x03,
        0xea, 0xa8, 0x6e, 0x31, 0x0a, 0x5d, 0xb7, 0x38,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "query_realm frame" {
    var buf: [128]u8 = undefined;
    const n = build_query_realm(5, &buf);
    // envelope(8) + header(24) + payload(2) = 34
    try std.testing.expectEqual(@as(usize, 34), n);
    // op = 0x640
    try std.testing.expectEqual(@as(u8, 0x06), buf[22]);
    try std.testing.expectEqual(@as(u8, 0x40), buf[23]);
}

test "open_realm frame" {
    var buf: [128]u8 = undefined;
    const n = build_open_realm(5, 1, &buf);
    // envelope(8) + header(24) + payload(2 + 9 + 1) = 44
    try std.testing.expectEqual(@as(usize, 44), n);
    // op = 0x76C
    try std.testing.expectEqual(@as(u8, 0x07), buf[22]);
    try std.testing.expectEqual(@as(u8, 0x6c), buf[23]);
    // payload starts at 32: [00 00 02 00000004 00000001 00]
    try std.testing.expectEqual(@as(u8, 0x00), buf[32]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[33]);
    try std.testing.expectEqual(@as(u8, 0x02), buf[34]); // TLV type=2
    try std.testing.expectEqual(@as(u8, 0x01), buf[42]); // realm_type=1
    try std.testing.expectEqual(@as(u8, 0x00), buf[43]); // choice=0
}

test "cal_add_point frame" {
    var buf: [128]u8 = undefined;
    const n = build_cal_add_point(5, 0.5, 0.5, 0, &buf);
    // envelope(8) + header(24) + payload(2 + 13 + 13 + 9) = 69
    try std.testing.expectEqual(@as(usize, 69), n);
    // op = 0x408
    try std.testing.expectEqual(@as(u8, 0x04), buf[22]);
    try std.testing.expectEqual(@as(u8, 0x08), buf[23]);
}

test "realm_response frame" {
    var buf: [128]u8 = undefined;
    var digest = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const n = build_realm_response(5, 42, 7, &digest, &buf);
    // envelope(8) + header(24) + payload(2 + 9 + 9 + 16) = 68
    try std.testing.expectEqual(@as(usize, 68), n);
    // op = 0x776
    try std.testing.expectEqual(@as(u8, 0x07), buf[22]);
    try std.testing.expectEqual(@as(u8, 0x76), buf[23]);
    // Digest should appear at payload offset 2 + 9 + 9 = 20 → frame offset 32 + 20 = 52
    try std.testing.expectEqual(@as(u8, 1), buf[52]);
    try std.testing.expectEqual(@as(u8, 16), buf[67]);
}

test "close_realm frame" {
    var buf: [128]u8 = undefined;
    const n = build_close_realm(5, 42, &buf);
    // envelope(8) + header(24) + payload(2 + 9) = 43
    try std.testing.expectEqual(@as(usize, 43), n);
    // op = 0x77B
    try std.testing.expectEqual(@as(u8, 0x07), buf[22]);
    try std.testing.expectEqual(@as(u8, 0x7b), buf[23]);
}

test "cal_compute frame" {
    var buf: [128]u8 = undefined;
    const n = build_cal_compute(5, &buf);
    try std.testing.expectEqual(@as(usize, 34), n);
    try std.testing.expectEqual(@as(u8, 0x04), buf[22]);
    try std.testing.expectEqual(@as(u8, 0x2f), buf[23]);
}

test "cal_retrieve frame" {
    var buf: [128]u8 = undefined;
    const n = build_cal_retrieve(5, &buf);
    try std.testing.expectEqual(@as(usize, 34), n);
    try std.testing.expectEqual(@as(u8, 0x04), buf[22]);
    try std.testing.expectEqual(@as(u8, 0x4c), buf[23]);
}

test "cal_stimulus frame" {
    var buf: [128]u8 = undefined;
    const n = build_cal_stimulus(5, &buf);
    try std.testing.expectEqual(@as(usize, 34), n);
    try std.testing.expectEqual(@as(u8, 0x04), buf[22]);
    try std.testing.expectEqual(@as(u8, 0x60), buf[23]);
}

test "parse fragmented multi-envelope response" {
    // Simulates a large TTP response split across 3 USB transfers:
    //   Chunk 1: [envelope_8][ttp_hdr_24][partial_payload_11]  = 43 bytes
    //   Chunk 2: [envelope_8][continuation_92]                 = 100 bytes
    //   Chunk 3: [raw_continuation_97]                         = 97 bytes  (no envelope)
    // Total payload = 11 + 92 + 97 = 200 bytes
    resetTestState();

    const payload_len: usize = 200;
    var full_payload: [payload_len]u8 = undefined;
    var i: usize = 0;
    while (i < payload_len) : (i += 1) full_payload[i] = @truncate(i);

    // --- Chunk 1: envelope + TTP header + first 11 bytes of payload ---
    var chunk1: [43]u8 = undefined;
    const c1: [*]u8 = &chunk1;
    c1[0] = 0x01; c1[1] = 0; c1[2] = 0; c1[3] = 0;
    putLe32(c1 + 4, 43);
    // TTP header at offset 8
    i = 0;
    while (i < TTP_HDR_SIZE) : (i += 1) c1[ENVELOPE_SIZE + i] = 0;
    putBe32(c1 + ENVELOPE_SIZE + 0, TTP_MAGIC_RSP);
    putBe32(c1 + ENVELOPE_SIZE + 4, 99); // seq
    putBe32(c1 + ENVELOPE_SIZE + 12, 0x44C); // op = cal_retrieve
    putBe32(c1 + ENVELOPE_SIZE + 20, @intCast(payload_len)); // plen = 200
    // First 11 bytes of payload
    i = 0;
    while (i < 11) : (i += 1) c1[ENVELOPE_SIZE + TTP_HDR_SIZE + i] = full_payload[i];

    feed_usb_in(c1, 43);
    try std.testing.expectEqual(@as(usize, 0), test_event_count); // not complete yet

    // --- Chunk 2: continuation envelope + 92 bytes payload ---
    var chunk2: [100]u8 = undefined;
    const c2: [*]u8 = &chunk2;
    c2[0] = 0x01; c2[1] = 0; c2[2] = 0; c2[3] = 0;
    putLe32(c2 + 4, 100);
    i = 0;
    while (i < 92) : (i += 1) c2[ENVELOPE_SIZE + i] = full_payload[11 + i];

    feed_usb_in(c2, 100);
    try std.testing.expectEqual(@as(usize, 0), test_event_count); // still not complete

    // --- Chunk 3: raw continuation, no envelope header, 97 bytes ---
    var chunk3: [97]u8 = undefined;
    i = 0;
    while (i < 97) : (i += 1) chunk3[i] = full_payload[11 + 92 + i];

    feed_usb_in(&chunk3, 97);
    // Now we should have the complete frame
    try std.testing.expectEqual(@as(usize, 1), test_event_count);
    try std.testing.expectEqual(@as(u32, 99), test_events[0].seq);
    try std.testing.expectEqual(@as(u32, 0x44C), test_events[0].op);
    try std.testing.expectEqual(@as(u32, payload_len), test_events[0].plen);
    try std.testing.expectEqual(@as(u8, 0), test_events[0].first); // full_payload[0] = 0
    try std.testing.expectEqual(@as(usize, 0), test_error_count);
    try std.testing.expectEqual(@as(usize, 0), acc_len);
}
