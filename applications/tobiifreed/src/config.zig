// config.zig — ~/.config/tobii.json and calibration blob persistence for tobiifreed.
//
// tobii.json "display_area" accepts two forms:
//
//   explicit corners (written by tobiifreed when a client sets the area):
//     "display_area": { "tl": [x,y,z], "tr": [x,y,z], "bl": [x,y,z], ... }
//
//   legacy rect form (hand-written, also read by tobiifree-overlay):
//     "display_area": { "w_mm": 800, "h_mm": 340, "z_mm": 0, "tilt": 0,
//                       "cx": 0, "cy": "b - 10" }
//
// Corners win when both are present. When tobiifreed writes the file it emits
// the corners *and* the equivalent legacy fields (numeric cx/cy), so readers
// that only know the legacy form (the overlay) keep working. Other top-level
// keys of an existing file are preserved.
//
// All coordinates are mm in the tracker frame (x right, y up, z toward user).

const std = @import("std");

pub const CONFIG_REL_PATH = ".config/tobii.json";

/// tl.xyz, tr.xyz, bl.xyz — same order as the daemon protocol's 9×f64.
pub const Corners = [9]f64;

/// Legacy rect parameterisation (matches Tracker.DisplayArea defaults).
pub const Rect = struct {
    w_mm: f64 = 1500,
    h_mm: f64 = 1000,
    ox_mm: f64 = -750,
    oy_mm: f64 = -500,
    z_mm: f64 = 0,
    tilt_deg: f64 = 0,
};

pub fn rectToCorners(d: Rect) Corners {
    const angle = d.tilt_deg * (std.math.pi / 180.0);
    const bl = [3]f64{ d.ox_mm, d.oy_mm, d.z_mm };
    const tl = [3]f64{ bl[0], bl[1] + d.h_mm * @cos(angle), bl[2] + d.h_mm * @sin(angle) };
    const tr = [3]f64{ d.ox_mm + d.w_mm, tl[1], tl[2] };
    return .{ tl[0], tl[1], tl[2], tr[0], tr[1], tr[2], bl[0], bl[1], bl[2] };
}

pub const Legacy = struct { w_mm: f64, h_mm: f64, z_mm: f64, tilt: f64, cx: f64, cy: f64 };

/// Legacy fields equivalent to `c` (exact for a rectangle with no yaw/roll).
pub fn cornersToLegacy(c: Corners) Legacy {
    const w = std.math.hypot(c[3] - c[0], std.math.hypot(c[4] - c[1], c[5] - c[2]));
    const dy = c[1] - c[7];
    const dz = c[2] - c[8];
    const h = std.math.hypot(c[0] - c[6], std.math.hypot(dy, dz));
    const tilt = std.math.atan2(dz, dy) * (180.0 / std.math.pi);
    return .{
        .w_mm = w,
        .h_mm = h,
        .z_mm = c[8],
        .tilt = tilt,
        .cx = -c[6] - w / 2.0,
        .cy = -c[7] - h / 2.0,
    };
}

// ── Parsing ─────────────────────────────────────────────────────────

/// Parse the display area out of tobii.json text. Null if absent/invalid.
pub fn parseDisplayArea(gpa: std.mem.Allocator, text: []const u8) ?Corners {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const da = switch (root.get("display_area") orelse return null) {
        .object => |o| o,
        else => return null,
    };

    // Explicit corners.
    if (getVec3(da, "tl")) |tl| if (getVec3(da, "tr")) |tr| if (getVec3(da, "bl")) |bl| {
        return .{ tl[0], tl[1], tl[2], tr[0], tr[1], tr[2], bl[0], bl[1], bl[2] };
    };

    // Legacy rect form. Require at least w/h so an unrelated object isn't
    // silently turned into the 1500×1000 default.
    var r = Rect{};
    r.w_mm = getFloat(da, "w_mm") orelse return null;
    r.h_mm = getFloat(da, "h_mm") orelse return null;
    if (getFloat(da, "z_mm")) |v| r.z_mm = v;
    if (getFloat(da, "tilt")) |v| r.tilt_deg = v;
    const half_w = r.w_mm / 2.0;
    const half_h = r.h_mm / 2.0;
    // cx/cy: where the screen centre is relative to the tracker (overlay semantics).
    if (da.get("cx")) |v| if (parsePositionExpr(v, half_w, false)) |cx| {
        r.ox_mm = -cx - half_w;
    };
    if (da.get("cy")) |v| if (parsePositionExpr(v, half_h, true)) |cy| {
        r.oy_mm = -cy - half_h;
    };
    return rectToCorners(r);
}

fn getFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    return toFloat(obj.get(key) orelse return null);
}

fn toFloat(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn getVec3(obj: std.json.ObjectMap, key: []const u8) ?[3]f64 {
    const arr = switch (obj.get(key) orelse return null) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len != 3) return null;
    return .{
        toFloat(arr.items[0]) orelse return null,
        toFloat(arr.items[1]) orelse return null,
        toFloat(arr.items[2]) orelse return null,
    };
}

fn parsePositionExpr(val: std.json.Value, half: f64, is_vertical: bool) ?f64 {
    return switch (val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .string => |s| evalAnchorExpr(s, half, is_vertical),
        else => null,
    };
}

/// "t + 10", "b - 10", "l", "c + 3" … anchors: t/b vertical, l/r horizontal, c both.
fn evalAnchorExpr(expr: []const u8, half: f64, is_vertical: bool) ?f64 {
    const e = std.mem.trim(u8, expr, " ");
    if (e.len == 0) return null;
    const anchor: f64 = switch (e[0]) {
        't' => if (is_vertical) half else return null,
        'b' => if (is_vertical) -half else return null,
        'l' => if (!is_vertical) -half else return null,
        'r' => if (!is_vertical) half else return null,
        'c' => 0,
        else => return null,
    };
    const rest = std.mem.trim(u8, e[1..], " ");
    if (rest.len == 0) return anchor;
    const sign: f64 = switch (rest[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    const num_s = std.mem.trim(u8, rest[1..], " ");
    const num = std.fmt.parseFloat(f64, num_s) catch return null;
    return anchor + sign * num;
}

// ── Rendering ───────────────────────────────────────────────────────

/// Render tobii.json with `c` as display_area, keeping the other top-level
/// keys of `existing` (if it parses as an object). Caller frees.
pub fn render(gpa: std.mem.Allocator, existing: ?[]const u8, c: Corners) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    const lg = cornersToLegacy(c);
    try w.writeAll("{\n");
    try w.print(
        \\  "display_area": {{
        \\    "tl": [{d:.3}, {d:.3}, {d:.3}],
        \\    "tr": [{d:.3}, {d:.3}, {d:.3}],
        \\    "bl": [{d:.3}, {d:.3}, {d:.3}],
        \\    "w_mm": {d:.3},
        \\    "h_mm": {d:.3},
        \\    "z_mm": {d:.3},
        \\    "tilt": {d:.3},
        \\    "cx": {d:.3},
        \\    "cy": {d:.3}
        \\  }}
    , .{
        c[0],     c[1],     c[2],     c[3],    c[4],  c[5], c[6], c[7], c[8],
        lg.w_mm, lg.h_mm, lg.z_mm, lg.tilt, lg.cx, lg.cy,
    });

    if (existing) |text| {
        if (std.json.parseFromSlice(std.json.Value, gpa, text, .{})) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                var it = parsed.value.object.iterator();
                while (it.next()) |kv| {
                    if (std.mem.eql(u8, kv.key_ptr.*, "display_area")) continue;
                    try w.print(",\n  {f}: {f}", .{
                        std.json.fmt(kv.key_ptr.*, .{}),
                        std.json.fmt(kv.value_ptr.*, .{}),
                    });
                }
            }
        } else |_| {}
    }
    try w.writeAll("\n}\n");
    return out.toOwnedSlice();
}

// ── File I/O ────────────────────────────────────────────────────────

pub fn configPath(buf: []u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, CONFIG_REL_PATH }) catch null;
}

/// $XDG_STATE_HOME/tobiifree/calibration.bin (default ~/.local/state/…).
pub fn calibrationPath(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |s| if (s.len > 0) {
        return std.fmt.bufPrint(buf, "{s}/tobiifree/calibration.bin", .{s}) catch null;
    };
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/tobiifree/calibration.bin", .{home}) catch null;
}

/// $XDG_STATE_HOME/tobiifree/correction.json (default ~/.local/state/…).
pub fn correctionPath(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |s| if (s.len > 0) {
        return std.fmt.bufPrint(buf, "{s}/tobiifree/correction.json", .{s}) catch null;
    };
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/tobiifree/correction.json", .{home}) catch null;
}

/// Read a whole file (caller frees). Null if missing/unreadable.
pub fn readFile(gpa: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    return std.fs.cwd().readFileAlloc(gpa, path, max) catch null;
}

/// Write `data` to `path` atomically (tmp file + rename), creating parent dirs.
pub fn writeFileAtomic(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    var tmp_buf: [600]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    {
        const f = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer f.close();
        try f.writeAll(data);
    }
    try std.fs.cwd().rename(tmp, path);
}

/// Load the display area from ~/.config/tobii.json.
pub fn loadDisplayArea(gpa: std.mem.Allocator) ?Corners {
    var pbuf: [512]u8 = undefined;
    const path = configPath(&pbuf) orelse return null;
    const text = readFile(gpa, path, 1 << 20) orelse return null;
    defer gpa.free(text);
    return parseDisplayArea(gpa, text);
}

/// Persist `c` into ~/.config/tobii.json (preserving other keys).
pub fn saveDisplayArea(gpa: std.mem.Allocator, c: Corners) !void {
    var pbuf: [512]u8 = undefined;
    const path = configPath(&pbuf) orelse return error.NoHome;
    const existing = readFile(gpa, path, 1 << 20);
    defer if (existing) |e| gpa.free(e);
    const text = try render(gpa, existing, c);
    defer gpa.free(text);
    try writeFileAtomic(path, text);
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

fn expectCorners(expected: Corners, got: Corners) !void {
    for (expected, got) |e, g| try testing.expectApproxEqAbs(e, g, 1e-6);
}

test "legacy rect form" {
    const text =
        \\{ "display_area": { "w_mm": 800, "h_mm": 340, "z_mm": 0, "tilt": 0, "cx": 0, "cy": "b - 10" } }
    ;
    const c = parseDisplayArea(testing.allocator, text).?;
    // cy = "b - 10" = -170 - 10 = -180 → oy = 180 - 170 = 10
    try expectCorners(.{ -400, 350, 0, 400, 350, 0, -400, 10, 0 }, c);
}

test "explicit corners win" {
    const text =
        \\{ "display_area": { "tl": [-265.68, 308.89, 0], "tr": [265.68, 308.89, 0], "bl": [-265.68, 10, 0],
        \\                    "w_mm": 1, "h_mm": 1 } }
    ;
    const c = parseDisplayArea(testing.allocator, text).?;
    try expectCorners(.{ -265.68, 308.89, 0, 265.68, 308.89, 0, -265.68, 10, 0 }, c);
}

test "missing or invalid display_area" {
    try testing.expect(parseDisplayArea(testing.allocator, "{}") == null);
    try testing.expect(parseDisplayArea(testing.allocator, "not json") == null);
    try testing.expect(parseDisplayArea(testing.allocator,
        \\{ "display_area": { "tl": [1, 2] } }
    ) == null);
}

test "render round-trips and keeps legacy readers consistent" {
    const c: Corners = .{ -265.68, 308.89, 0, 265.68, 308.89, 0, -265.68, 10, 0 };
    const existing =
        \\{ "display_area": { "w_mm": 800, "h_mm": 340 }, "other": { "k": [1, "x"] } }
    ;
    const text = try render(testing.allocator, existing, c);
    defer testing.allocator.free(text);
    try expectCorners(c, parseDisplayArea(testing.allocator, text).?);
    try testing.expect(std.mem.indexOf(u8, text, "\"other\": {\"k\":[1,\"x\"]}") != null);

    // Strip the corners: the legacy fields alone must describe the same area.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    var da = parsed.value.object.getPtr("display_area").?.object;
    _ = da.orderedRemove("tl");
    _ = da.orderedRemove("tr");
    _ = da.orderedRemove("bl");
    const legacy_text = try std.fmt.allocPrint(testing.allocator, "{{\"display_area\": {f}}}", .{std.json.fmt(std.json.Value{ .object = da }, .{})});
    defer testing.allocator.free(legacy_text);
    try expectCorners(c, parseDisplayArea(testing.allocator, legacy_text).?);
}

test "tilted legacy conversion" {
    const c = rectToCorners(.{ .w_mm = 500, .h_mm = 300, .ox_mm = -250, .oy_mm = 10, .z_mm = 0, .tilt_deg = -12 });
    const lg = cornersToLegacy(c);
    try testing.expectApproxEqAbs(@as(f64, 500), lg.w_mm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 300), lg.h_mm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -12), lg.tilt, 1e-9);
}
