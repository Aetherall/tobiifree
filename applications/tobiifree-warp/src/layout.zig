// layout.zig — monitors in the compositor's global logical layout, and the
// mapping from normalised gaze (on the display area = the whole output) to a
// global cursor position.

const std = @import("std");

pub const Monitor = struct {
    name: []const u8,
    /// Make, model and serial as the compositor describes the monitor
    /// (identity; connector names can swap across reboots).
    desc: []const u8 = "",
    /// Global logical position of the top-left corner.
    x: f64,
    y: f64,
    /// Mode size in physical pixels, before transform.
    width: f64,
    height: f64,
    scale: f64 = 1,
    /// wl_output transform 0..7; odd values rotate by 90/270 degrees.
    transform: u8 = 0,

    /// Size in global logical coordinates (what the cursor moves over).
    pub fn logicalSize(self: Monitor) [2]f64 {
        const rotated = self.transform % 2 == 1;
        const w = if (rotated) self.height else self.width;
        const h = if (rotated) self.width else self.height;
        const s = if (self.scale > 0) self.scale else 1;
        return .{ w / s, h / s };
    }
};

/// Global logical point for gaze (nx, ny) on `m`, clamped to the output.
/// Rounded to whole logical pixels; the far edge is the last pixel inside
/// the output (fractional sizes: ceil(size) - 1 still lies within it).
pub fn mapNorm(m: Monitor, nx: f64, ny: f64) [2]f64 {
    const size = m.logicalSize();
    return .{ axis(m.x, size[0], nx), axis(m.y, size[1], ny) };
}

fn axis(origin: f64, size: f64, n: f64) f64 {
    const v = if (std.math.isFinite(n)) @round(origin + n * size) else origin + @floor(size / 2);
    const hi = origin + @max(0, @ceil(size) - 1);
    return std.math.clamp(v, origin, hi);
}

pub fn find(monitors: []const Monitor, name: []const u8) ?Monitor {
    for (monitors) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

// ── Hyprland `j/monitors` ───────────────────────────────────────────

const HyprMonitor = struct {
    name: []const u8,
    description: []const u8 = "",
    width: f64,
    height: f64,
    x: f64,
    y: f64,
    scale: f64 = 1,
    transform: u8 = 0,
    focused: bool = false,
    disabled: bool = false,
};

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    monitors: []Monitor,
    focused: ?usize,
    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// Parse Hyprland's `j/monitors` reply (disabled outputs dropped).
pub fn parseHyprMonitors(gpa: std.mem.Allocator, json: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const list = try std.json.parseFromSliceLeaky([]HyprMonitor, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    var out = try a.alloc(Monitor, list.len);
    var n: usize = 0;
    var focused: ?usize = null;
    for (list) |h| {
        if (h.disabled) continue;
        if (h.focused) focused = n;
        out[n] = .{ .name = h.name, .desc = h.description, .x = h.x, .y = h.y, .width = h.width, .height = h.height, .scale = h.scale, .transform = h.transform };
        n += 1;
    }
    return .{ .arena = arena, .monitors = out[0..n], .focused = focused };
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

// The person's layout.
const dp1 = Monitor{ .name = "DP-1", .x = 1080, .y = 565, .width = 1920, .height = 1080, .scale = 1 };
const edp1 = Monitor{ .name = "eDP-1", .x = 3000, .y = 645, .width = 3200, .height = 2000, .scale = 2 };
const dp2 = Monitor{ .name = "DP-2", .x = 0, .y = 0, .width = 1920, .height = 1080, .scale = 1, .transform = 1 };

fn expectPt(want: [2]f64, got: [2]f64) !void {
    try testing.expectEqual(want[0], got[0]);
    try testing.expectEqual(want[1], got[1]);
}

test "DP-1 (scale 1) corners and centre" {
    try expectPt(.{ 1080, 565 }, mapNorm(dp1, 0, 0));
    try expectPt(.{ 2040, 1105 }, mapNorm(dp1, 0.5, 0.5));
    try expectPt(.{ 2999, 1644 }, mapNorm(dp1, 1, 1)); // last pixel, not eDP-1's first
    try expectPt(.{ 1080 + 576, 565 + 756 }, mapNorm(dp1, 0.3, 0.7));
}

test "clamped to the output" {
    try expectPt(.{ 1080, 565 }, mapNorm(dp1, -0.2, -3));
    try expectPt(.{ 2999, 1644 }, mapNorm(dp1, 1.4, 1.01));
    try expectPt(.{ 2040, 1105 }, mapNorm(dp1, std.math.nan(f64), std.math.inf(f64)));
}

test "eDP-1 scale 2: logical 1600x1000" {
    try testing.expectEqual([2]f64{ 1600, 1000 }, edp1.logicalSize());
    try expectPt(.{ 3000, 645 }, mapNorm(edp1, 0, 0));
    try expectPt(.{ 3800, 1145 }, mapNorm(edp1, 0.5, 0.5));
    try expectPt(.{ 4599, 1644 }, mapNorm(edp1, 1, 1));
}

test "DP-2 portrait (transform 1): 1080x1920" {
    try testing.expectEqual([2]f64{ 1080, 1920 }, dp2.logicalSize());
    try expectPt(.{ 540, 960 }, mapNorm(dp2, 0.5, 0.5));
    try expectPt(.{ 1079, 1919 }, mapNorm(dp2, 1, 1));
    try expectPt(.{ 108, 1728 }, mapNorm(dp2, 0.1, 0.9));
}

test "fractional scales" {
    // 2560x1440 @1.5 → 1706.67x960; last x pixel inside is 1706.
    const m = Monitor{ .name = "X", .x = 100, .y = -200, .width = 2560, .height = 1440, .scale = 1.5 };
    try expectPt(.{ 100 + 853, -200 + 480 }, mapNorm(m, 0.5, 0.5));
    try expectPt(.{ 100 + 1706, -200 + 959 }, mapNorm(m, 1, 1));
    // 2880x1800 @1.25 → 2304x1440, portrait-flipped (transform 3) → 1440x2304.
    const r = Monitor{ .name = "Y", .x = 0, .y = 0, .width = 2880, .height = 1800, .scale = 1.25, .transform = 3 };
    try testing.expectEqual([2]f64{ 1440, 2304 }, r.logicalSize());
    try expectPt(.{ 360, 1152 }, mapNorm(r, 0.25, 0.5));
    // Flips without rotation (4) keep the size.
    const f = Monitor{ .name = "Z", .x = 0, .y = 0, .width = 1920, .height = 1080, .scale = 1, .transform = 4 };
    try testing.expectEqual([2]f64{ 1920, 1080 }, f.logicalSize());
}

test "parse Hyprland monitors JSON" {
    const json =
        \\[{"id":0,"name":"eDP-1","width":3200,"height":2000,"x":3000,"y":645,"scale":2.00,"transform":0,"focused":false,"disabled":false,"reserved":[0,38,0,0],"activeWorkspace":{"id":1,"name":"1"}},
        \\ {"id":1,"name":"DP-1","description":"BNQ BenQ XL2430T R9F02179SL0","width":1920,"height":1080,"x":1080,"y":565,"scale":1.00,"transform":0,"focused":true,"disabled":false},
        \\ {"id":2,"name":"DP-2","width":1920,"height":1080,"x":0,"y":0,"scale":1.00,"transform":1,"focused":false,"disabled":false},
        \\ {"id":3,"name":"HDMI-A-1","width":1920,"height":1080,"x":0,"y":0,"scale":1,"transform":0,"focused":false,"disabled":true}]
    ;
    var p = try parseHyprMonitors(testing.allocator, json);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.monitors.len);
    try testing.expectEqual(@as(?usize, 1), p.focused);
    const m = find(p.monitors, "DP-1").?;
    try testing.expectEqualStrings("BNQ BenQ XL2430T R9F02179SL0", m.desc);
    try testing.expectEqualStrings("", find(p.monitors, "DP-2").?.desc);
    try expectPt(.{ 2040, 1105 }, mapNorm(m, 0.5, 0.5));
    try expectPt(.{ 540, 960 }, mapNorm(find(p.monitors, "DP-2").?, 0.5, 0.5));
    try testing.expectEqual(@as(?Monitor, null), find(p.monitors, "HDMI-A-1"));
}
