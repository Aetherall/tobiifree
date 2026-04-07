// tobiifree_decode.zig — native CLI: read gaze_sample.bin and dump TLV fields.
//
// Usage:
//   zig build tobiifree-decode -- path/to/gaze_sample.bin

const std = @import("std");
const tlv = @import("tlv.zig");
const print = std.debug.print;

fn dumpFirst(buf: []const u8, n: usize, prefix: []const u8) void {
    const m = @min(n, buf.len);
    print("{s}", .{prefix});
    for (buf[0..m]) |b| print(" {x:0>2}", .{b});
    if (buf.len > m) print(" ... (+{d})", .{buf.len - m});
    print("\n", .{});
}

const ColType = enum { s64, u32, point2d, point3d, fixed16x16, skip };

fn columnType(col: u32) ColType {
    return switch (col) {
        1 => .s64,
        2, 3, 4, 8, 9, 10, 0x17, 0x18 => .point3d,
        5, 0xb, 0x1c => .point2d,
        6, 0xc => .fixed16x16,
        7, 0xd, 0xe, 0x11, 0x14, 0x15, 0x16, 0x1b => .u32,
        else => .skip,
    };
}

// Field-name labels derived from data-driven analysis of live gaze
// captures (web/zig/src/tobiifree_decode.zig + 60-frame streams).
// L/R = left/right eye; z≈510mm clusters matched physical distance.
fn columnLabel(col: u32) []const u8 {
    return switch (col) {
        0x01 => "timestamp_us",
        0x02 => "eye_origin_L_mm",
        0x03 => "trackbox_eye_pos_L",
        0x04 => "gaze_point_3d_L_mm",
        0x05 => "gaze_point_2d_L_norm",
        0x06 => "pupil_diameter_L_mm",
        0x07 => "validity_L",
        0x08 => "eye_origin_R_mm",
        0x09 => "trackbox_eye_pos_R",
        0x0a => "gaze_point_3d_R_mm",
        0x0b => "gaze_point_2d_R_norm",
        0x0c => "pupil_diameter_R_mm",
        0x0d => "validity_R",
        0x0e => "status_0e",
        0x11 => "status_11",
        0x14 => "frame_counter",
        0x15 => "status_15",
        0x16 => "status_16",
        0x17 => "eye_origin_L_mm_dup",
        0x18 => "eye_origin_R_mm_dup",
        0x19 => "point2d_19_unused",
        0x1a => "point2d_1a_unused",
        0x1b => "status_1b",
        0x1c => "gaze_point_2d_norm",
        0x1d => "status_1d",
        0x1e => "status_1e",
        0x1f => "status_1f",
        0x20 => "gaze_point_2d_norm_dup",
        0x21 => "status_21",
        0x22 => "eye_origin_L_display_mm",
        0x23 => "status_23",
        0x24 => "eye_origin_R_display_mm",
        0x25 => "gaze_direction_25",
        0x26 => "status_26",
        0x27 => "gaze_direction_27",
        0x28 => "status_28",
        0x29 => "scalar_29_unused",
        0x2a => "status_2a",
        0x2b => "scalar_2b_unused",
        0x2c => "status_2c",
        else => "?",
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 2) {
        print("usage: {s} <gaze_sample.bin>\n", .{args[0]});
        return;
    }

    const file = try std.fs.cwd().openFile(args[1], .{});
    defer file.close();
    const data = try file.readToEndAlloc(alloc, 1 << 20);
    defer alloc.free(data);

    print("file: {s}  size: {d}B\n", .{ args[1], data.len });
    if (data.len < 24) {
        print("too short for TTP header\n", .{});
        return;
    }

    // Default: decode the first frame. If --all, walk every frame in the file.
    // If --frame=N, decode the Nth (0-indexed) frame only.
    var decode_all = false;
    var only_frame: ?usize = null;
    var summarize = false;
    for (args[2..]) |a| {
        if (std.mem.eql(u8, a, "--all")) decode_all = true
        else if (std.mem.eql(u8, a, "--summary")) summarize = true
        else if (std.mem.startsWith(u8, a, "--frame=")) {
            only_frame = std.fmt.parseInt(usize, a[8..], 10) catch null;
        }
    }

    if (summarize) {
        try summarizeFrames(data);
        return;
    }

    var off: usize = 0;
    var frame_idx: usize = 0;
    while (off + 24 <= data.len) : (frame_idx += 1) {
        const magic = std.mem.readInt(u32, data[off..][0..4], .big);
        const seq = std.mem.readInt(u32, data[off + 4 ..][0..4], .big);
        const flag = std.mem.readInt(u32, data[off + 8 ..][0..4], .big);
        const op = std.mem.readInt(u32, data[off + 12 ..][0..4], .big);
        const plen = std.mem.readInt(u32, data[off + 20 ..][0..4], .big);
        if (off + 24 + plen > data.len) {
            print("truncated frame at offset {d}\n", .{off});
            return;
        }
        const do_decode = decode_all or only_frame == null or only_frame.? == frame_idx;
        if (!do_decode) {
            off += 24 + plen;
            continue;
        }
        print("\n=== frame[{d}] @offset {d} ===\n", .{ frame_idx, off });
        print("ttp hdr: magic=0x{x} seq={d} flag=0x{x} op=0x{x} plen={d}\n", .{ magic, seq, flag, op, plen });
        const payload = data[off + 24 .. off + 24 + plen];
        dumpFirst(payload, 32, "payload:");
        decodeOne(payload);
        off += 24 + plen;
        if (only_frame) |_| break;
        if (!decode_all) break;
    }
    print("\n", .{});
    return;
}

// ColStats captures the range of values seen for one column across frames.
const ColStats = struct {
    col_id: u32 = 0,
    kind: ColType = .skip,
    count: u32 = 0,
    // Up to 3 channels (point3d).
    min: [3]f64 = .{ std.math.floatMax(f64), std.math.floatMax(f64), std.math.floatMax(f64) },
    max: [3]f64 = .{ -std.math.floatMax(f64), -std.math.floatMax(f64), -std.math.floatMax(f64) },
    sum: [3]f64 = .{ 0, 0, 0 },
    // First and last values seen, for "moving?" check.
    first: [3]f64 = .{ 0, 0, 0 },
    last: [3]f64 = .{ 0, 0, 0 },
    nchan: u8 = 1,

    fn update(self: *ColStats, vs: [3]f64, nchan: u8) void {
        self.nchan = nchan;
        if (self.count == 0) self.first = vs;
        self.last = vs;
        var i: u8 = 0;
        while (i < nchan) : (i += 1) {
            if (vs[i] < self.min[i]) self.min[i] = vs[i];
            if (vs[i] > self.max[i]) self.max[i] = vs[i];
            self.sum[i] += vs[i];
        }
        self.count += 1;
    }
};

fn summarizeFrames(data: []const u8) !void {
    var stats = std.AutoHashMap(u32, ColStats).init(std.heap.page_allocator);
    defer stats.deinit();

    var off: usize = 0;
    var n_frames: usize = 0;
    while (off + 24 <= data.len) : (n_frames += 1) {
        const plen = std.mem.readInt(u32, data[off + 20 ..][0..4], .big);
        if (off + 24 + plen > data.len) break;
        const payload = data[off + 24 .. off + 24 + plen];
        off += 24 + plen;

        var r = tlv.Reader.init(payload);
        r.pos = 2;
        const n_cols = r.readXdsRow() catch continue;
        var i: u32 = 0;
        while (i < n_cols and r.remaining() > 0) : (i += 1) {
            const col_id = r.readXdsColumn() catch break;
            var ct = columnType(col_id);
            if (ct == .skip) {
                const h = r.peekHeader() catch break;
                ct = switch (h.type_byte) {
                    2 => .u32,
                    3 => .fixed16x16,
                    5 => blk: {
                        if (r.remaining() >= 9) {
                            const tag = std.mem.readInt(u32, r.buf[r.pos + 5 ..][0..4], .big);
                            break :blk switch (tag) {
                                0x021f40 => .point2d,
                                0x031f41 => .point3d,
                                else => .skip,
                            };
                        }
                        break :blk .skip;
                    },
                    6 => .s64,
                    else => .skip,
                };
            }
            var vs: [3]f64 = .{ 0, 0, 0 };
            var nchan: u8 = 1;
            switch (ct) {
                .s64 => {
                    const v = r.readS64() catch break;
                    vs[0] = @floatFromInt(v);
                },
                .u32 => {
                    const v = r.readU32() catch break;
                    vs[0] = @floatFromInt(v);
                },
                .fixed16x16 => { vs[0] = r.readFixed16x16() catch break; },
                .point2d => { const v = r.readPoint2d() catch break; vs[0] = v[0]; vs[1] = v[1]; nchan = 2; },
                .point3d => { const v = r.readPoint3d() catch break; vs[0] = v[0]; vs[1] = v[1]; vs[2] = v[2]; nchan = 3; },
                .skip => break,
            }

            const gop = try stats.getOrPut(col_id);
            if (!gop.found_existing) gop.value_ptr.* = .{ .col_id = col_id, .kind = ct };
            gop.value_ptr.update(vs, nchan);
        }
    }

    print("summarized {d} frames, {d} unique columns\n", .{ n_frames, stats.count() });
    print("\n{s:>4} {s:<24} {s:>6} {s:>6}  {s:>12} {s:>12} {s:>12}  {s}\n", .{ "col", "label", "type", "count", "min", "max", "mean", "moving?" });
    print("---- ------------------------ ------ ------  ------------ ------------ ------------  -------\n", .{});

    // Sort by col_id for stable output.
    var ids: std.ArrayList(u32) = .{};
    defer ids.deinit(std.heap.page_allocator);
    var it = stats.keyIterator();
    while (it.next()) |k| try ids.append(std.heap.page_allocator, k.*);
    std.mem.sort(u32, ids.items, {}, std.sort.asc(u32));

    for (ids.items) |id| {
        const s = stats.get(id).?;
        const moving = for (0..s.nchan) |i| {
            if (s.max[i] - s.min[i] > 1e-9) break "yes";
        } else "no";
        const mean0 = s.sum[0] / @as(f64, @floatFromInt(s.count));
        print("0x{x:0>2} {s:<24} {s:>6} {d:>6}  {d:>12.4} {d:>12.4} {d:>12.4}  {s}", .{ id, columnLabel(id), @tagName(s.kind), s.count, s.min[0], s.max[0], mean0, moving });
        if (s.nchan >= 2) {
            const mean1 = s.sum[1] / @as(f64, @floatFromInt(s.count));
            print("\n                                              [y]  {d:>12.4} {d:>12.4} {d:>12.4}", .{ s.min[1], s.max[1], mean1 });
        }
        if (s.nchan >= 3) {
            const mean2 = s.sum[2] / @as(f64, @floatFromInt(s.count));
            print("\n                                              [z]  {d:>12.4} {d:>12.4} {d:>12.4}", .{ s.min[2], s.max[2], mean2 });
        }
        print("\n", .{});
    }
}

fn decodeOne(payload: []const u8) void {

    // Skip 2 mystery prefix bytes. TODO: figure out what these are.
    var r = tlv.Reader.init(payload);
    r.pos = 2;
    print("(skipping 2 prefix bytes: {x:0>2} {x:0>2})\n", .{ payload[0], payload[1] });

    const row_pos_before = r.pos;
    const n_cols = r.readXdsRow() catch |err| {
        print("\nxds_row read failed: {s} (at offset {d})\n", .{ @errorName(err), row_pos_before });
        const start = row_pos_before;
        const end = @min(start + 16, payload.len);
        print("  bytes @{d}:", .{start});
        for (payload[start..end]) |b| print(" {x:0>2}", .{b});
        print("\n", .{});
        return;
    };
    print("\nxds_row: count={d} (at offset {d})\n", .{ n_cols, row_pos_before });

    var i: u32 = 0;
    while (i < n_cols and r.remaining() > 0) : (i += 1) {
        const col_pos = r.pos;
        const col_id = r.readXdsColumn() catch |err| {
            print("  [{d}] xds_column failed: {s} @ offset {d}\n", .{ i, @errorName(err), col_pos });
            dumpFirst(payload[col_pos..], 16, "       bytes:");
            return;
        };

        var ct = columnType(col_id);
        // Fallback: peek the next field header and infer type from the type byte.
        if (ct == .skip) {
            const h = r.peekHeader() catch |err| {
                print("  col[{d}] id=0x{x} peek FAIL {s}\n", .{ i, col_id, @errorName(err) });
                return;
            };
            ct = switch (h.type_byte) {
                2 => .u32,
                3 => .fixed16x16,
                5 => blk: {
                    // prolog — struct. Heuristic: tag tells us which struct.
                    if (r.remaining() >= 9) {
                        const tag = std.mem.readInt(u32, r.buf[r.pos + 5 ..][0..4], .big);
                        break :blk switch (tag) {
                            0x021f40 => .point2d,
                            0x031f41 => .point3d,
                            else => .skip,
                        };
                    }
                    break :blk .skip;
                },
                6 => .s64,
                else => .skip,
            };
            print("  col[{d}] id=0x{x:0>2} {s:<24} type={s} (inferred)", .{ i, col_id, columnLabel(col_id), @tagName(ct) });
        } else {
            print("  col[{d}] id=0x{x:0>2} {s:<24} type={s}", .{ i, col_id, columnLabel(col_id), @tagName(ct) });
        }

        switch (ct) {
            .s64 => {
                const v = r.readS64() catch |err| {
                    print(" FAIL {s}\n", .{@errorName(err)});
                    return;
                };
                print(" = {d}\n", .{v});
            },
            .u32 => {
                const v = r.readU32() catch |err| {
                    print(" FAIL {s}\n", .{@errorName(err)});
                    return;
                };
                print(" = {d} (0x{x})\n", .{ v, v });
            },
            .fixed16x16 => {
                const v = r.readFixed16x16() catch |err| {
                    print(" FAIL {s}\n", .{@errorName(err)});
                    return;
                };
                print(" = {d:.6}\n", .{v});
            },
            .point2d => {
                const v = r.readPoint2d() catch |err| {
                    print(" FAIL {s}\n", .{@errorName(err)});
                    return;
                };
                print(" = ({d:.4}, {d:.4})\n", .{ v[0], v[1] });
            },
            .point3d => {
                const v = r.readPoint3d() catch |err| {
                    print(" FAIL {s}\n", .{@errorName(err)});
                    return;
                };
                print(" = ({d:.4}, {d:.4}, {d:.4})\n", .{ v[0], v[1], v[2] });
            },
            .skip => {
                print(" (unknown col id)\n", .{});
                dumpFirst(payload[r.pos..], 16, "       next:");
                return;
            },
        }
    }

    print("\nremaining: {d}B unparsed\n", .{r.remaining()});
    if (r.remaining() > 0) dumpFirst(payload[r.pos..], 32, "  tail:");
}
