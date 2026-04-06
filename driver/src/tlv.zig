// tlv.zig — TLV field decoder for the ET5 wire protocol.
//
// Wire format (observed from USB bulk transfers):
//
//   Every field starts with a 1-byte TYPE followed by a 4-byte big-endian SIZE.
//   The body is SIZE bytes, interpretation depends on TYPE.
//
//   type | name            | body
//   -----|-----------------|-------------------------------
//    2   | u32             | 4B BE u32
//    3   | fixed16x16      | 4B BE signed, scale = /2^16
//    4   | fixed22x42 (Q42)| 8B BE signed, scale = /2^42
//    5   | prolog (tag)    | 4B BE tag — marks start of a struct
//    6   | s64             | 8B BE signed
//    7   | u64             | 8B BE unsigned
//    (other) | skip        | read SIZE bytes, advance
//
// Known struct tags (found after a type=5 prolog):
//    0x020bb8 = xds_row       — count packed in high 12 bits: (tag>>16)&0xfff
//    0x020bb9 = xds_column    — followed by u32 column_id
//    0x021f40 = point2d       — 2× Q42
//    0x021f43 = point2d_f     — 2× fixed16x16
//    0x031f41 = point3d       — 3× Q42
//    0x031f42 = point3d_f     — 3× fixed16x16

const std = @import("std");

pub const Error = error{
    ShortRead,
    WrongType,
    WrongSize,
    WrongTag,
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }

    fn readU8(self: *Reader) !u8 {
        if (self.remaining() < 1) return Error.ShortRead;
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }

    fn readU32Be(self: *Reader) !u32 {
        if (self.remaining() < 4) return Error.ShortRead;
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    fn readI64Be(self: *Reader) !i64 {
        if (self.remaining() < 8) return Error.ShortRead;
        const v = std.mem.readInt(i64, self.buf[self.pos..][0..8], .big);
        self.pos += 8;
        return v;
    }

    fn readU64Be(self: *Reader) !u64 {
        if (self.remaining() < 8) return Error.ShortRead;
        const v = std.mem.readInt(u64, self.buf[self.pos..][0..8], .big);
        self.pos += 8;
        return v;
    }

    fn readI32Be(self: *Reader) !i32 {
        if (self.remaining() < 4) return Error.ShortRead;
        const v = std.mem.readInt(i32, self.buf[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    /// Peek the next field header without advancing.
    pub fn peekHeader(self: *const Reader) !struct { type_byte: u8, size: u32 } {
        if (self.remaining() < 5) return Error.ShortRead;
        const t = self.buf[self.pos];
        const s = std.mem.readInt(u32, self.buf[self.pos + 1 ..][0..4], .big);
        return .{ .type_byte = t, .size = s };
    }

    /// Read [type=5][size=4][tag:u32]. Returns the tag.
    pub fn readPrologTag(self: *Reader) !u32 {
        const t = try self.readU8();
        const s = try self.readU32Be();
        if (t != 5) return Error.WrongType;
        if (s != 4) return Error.WrongSize;
        return try self.readU32Be();
    }

    pub fn readU32(self: *Reader) !u32 {
        const t = try self.readU8();
        const s = try self.readU32Be();
        if (t != 2) return Error.WrongType;
        if (s != 4) return Error.WrongSize;
        return try self.readU32Be();
    }

    pub fn readFixed16x16(self: *Reader) !f64 {
        const t = try self.readU8();
        const s = try self.readU32Be();
        if (t != 3) return Error.WrongType;
        if (s != 4) return Error.WrongSize;
        const raw = try self.readI32Be();
        return @as(f64, @floatFromInt(raw)) / 65536.0;
    }

    pub fn readFixed22x42(self: *Reader) !f64 {
        const t = try self.readU8();
        const s = try self.readU32Be();
        if (t != 4) return Error.WrongType;
        if (s != 8) return Error.WrongSize;
        const raw = try self.readI64Be();
        return @as(f64, @floatFromInt(raw)) / 4398046511104.0; // 2^42
    }

    pub fn readS64(self: *Reader) !i64 {
        const t = try self.readU8();
        const s = try self.readU32Be();
        if (t != 6) return Error.WrongType;
        if (s != 8) return Error.WrongSize;
        return try self.readI64Be();
    }

    pub fn readU64(self: *Reader) !u64 {
        const t = try self.readU8();
        const s = try self.readU32Be();
        if (t != 7) return Error.WrongType;
        if (s != 8) return Error.WrongSize;
        return try self.readU64Be();
    }

    /// Consume an xds_row field ([prolog tag with count packed in]).
    /// Returns the count (number of columns that follow).
    pub fn readXdsRow(self: *Reader) !u32 {
        const tag = try self.readPrologTag();
        if (tag & 0xffff != 0x0bb8) return Error.WrongTag; // 3000
        return (tag >> 16) & 0xfff;
    }

    /// Consume an xds_column field (prolog + u32).
    /// Returns the column id.
    pub fn readXdsColumn(self: *Reader) !u32 {
        const tag = try self.readPrologTag();
        if (tag != 0x020bb9) return Error.WrongTag;
        return try self.readU32();
    }

    /// point3d: prolog(0x031f41) + 3× Q42
    pub fn readPoint3d(self: *Reader) ![3]f64 {
        const tag = try self.readPrologTag();
        if (tag != 0x031f41) return Error.WrongTag;
        return .{
            try self.readFixed22x42(),
            try self.readFixed22x42(),
            try self.readFixed22x42(),
        };
    }

    /// point2d: prolog(0x021f40) + 2× Q42
    pub fn readPoint2d(self: *Reader) ![2]f64 {
        const tag = try self.readPrologTag();
        if (tag != 0x021f40) return Error.WrongTag;
        return .{
            try self.readFixed22x42(),
            try self.readFixed22x42(),
        };
    }

    /// Skip the next field by reading its header and advancing SIZE bytes.
    /// For type=5 fields (prolog), this descends: reads the inner tag's
    /// children until it has skipped the whole sub-tree. For now we
    /// implement the simple variant used by tree_skip_next: advance SIZE bytes.
    pub fn skipNext(self: *Reader) !void {
        const h = try self.peekHeader();
        self.pos += 1 + 4; // header
        if (h.type_byte == 5) {
            // Prolog — no body length, just the 4B tag then contents.
            // We need recursive tree skipping. Caller should handle
            // structured fields by hand; bail with WrongType for now.
            return Error.WrongType;
        }
        if (self.remaining() < h.size) return Error.ShortRead;
        self.pos += h.size;
    }
};
