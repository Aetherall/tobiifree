// geometry.zig — display-area maths of the setup tool (no GTK, unit-tested).
//
// Frame (UCS of the tracker): origin front centre of the ET5, x right, y up,
// z toward the user, mm. Corners are TL.xyz, TR.xyz, BL.xyz (daemon order).
//
// Step 1: the person drags two vertical lines onto the two marks printed on
// the ET5 (MARK_SPACING_MM apart, centred on the tracker). Lines sit on pixel
// columns of the output (physical pixels); a line on column i is centred at
// i + 0.5.
//   p  = MARK_SPACING_MM / d_px           mm per physical pixel
//   W  = width_px * p,  H = height_px * p
//   xc = centre of the two lines (px)     tracker centre on screen
//   TL = (-xc*p, g+H, 0)  TR = ((width_px-xc)*p, g+H, 0)  BL = (-xc*p, g, 0)
// g: y of the screen's bottom edge in the tracker frame (mm). Not a ruler
// distance to the camera: 10 mm validated best on an ET5 (see the README).

const std = @import("std");

pub const MARK_SPACING_MM: f64 = 184.5;
pub const DEFAULT_GAP_MM: f64 = 10.0;

pub const Corners = [9]f64;

pub const Area = struct {
    corners: Corners,
    mm_per_px: f64,
    w_mm: f64,
    h_mm: f64,
    /// Tracker centre on screen (physical px, from the left edge).
    xc_px: f64,
    d_px: f64,
};

/// Display area from the two line columns (any order).
pub fn areaFromMarkers(a: i32, b: i32, width_px: u32, height_px: u32, gap_mm: f64) ?Area {
    const xl: f64 = @floatFromInt(@min(a, b));
    const xr: f64 = @floatFromInt(@max(a, b));
    const d = xr - xl;
    if (d < 1) return null;
    const p = MARK_SPACING_MM / d;
    const wpx: f64 = @floatFromInt(width_px);
    const hpx: f64 = @floatFromInt(height_px);
    const xc = (xl + xr) / 2.0 + 0.5;
    const w = wpx * p;
    const h = hpx * p;
    return .{
        .corners = .{ -xc * p, gap_mm + h, 0, (wpx - xc) * p, gap_mm + h, 0, -xc * p, gap_mm, 0 },
        .mm_per_px = p,
        .w_mm = w,
        .h_mm = h,
        .xc_px = xc,
        .d_px = d,
    };
}

/// Line columns that reproduce `c` on an output `width_px` wide, or null if
/// the area does not look like one made for this screen (aspect ratio of
/// another output, tracker outside it, absurd pitch).
pub fn markersFromArea(c: Corners, width_px: u32, height_px: u32) ?[2]i32 {
    const w_mm = c[3] - c[0];
    if (!(w_mm > 50 and w_mm < 3000)) return null;
    const aspect_px = @as(f64, @floatFromInt(height_px)) / @as(f64, @floatFromInt(width_px));
    const aspect_mm = areaSize(c)[1] / areaSize(c)[0];
    if (@abs(aspect_mm / aspect_px - 1) > 0.02) return null;
    if (!(c[0] < 0 and c[3] > 0)) return null;
    const wpx: f64 = @floatFromInt(width_px);
    const p = w_mm / wpx;
    const xc = -c[0] / p;
    const d = MARK_SPACING_MM / p;
    if (d < 20 or d > wpx) return null;
    return .{
        @intFromFloat(@round(xc - d / 2.0 - 0.5)),
        @intFromFloat(@round(xc + d / 2.0 - 0.5)),
    };
}

/// Width and height (mm) of an area given as corners.
pub fn areaSize(c: Corners) [2]f64 {
    const w = std.math.hypot(c[3] - c[0], c[4] - c[1]);
    const h = std.math.hypot(c[0] - c[6], c[1] - c[7]);
    return .{ w, h };
}

// ── Validation statistics ───────────────────────────────────────────

pub const PointError = struct {
    /// Target and mean gaze, normalised display coords (origin top-left).
    tx: f64,
    ty: f64,
    gx: f64,
    gy: f64,
    /// Gaze - target on the screen, mm (x right, y down).
    dx_mm: f64,
    dy_mm: f64,
    err_mm: f64,
    /// Angle seen from the eye (atan(err_mm / eye distance)).
    err_deg: f64,
    eye_z_mm: f64,
    samples: u32,
};

/// Error of one validation point from the mean gaze `gx, gy` and the mean eye
/// distance `eye_z_mm` (z of eye_origin, as the probe measured it).
pub fn pointError(tx: f64, ty: f64, gx: f64, gy: f64, eye_z_mm: f64, area: Corners, samples: u32) PointError {
    const size = areaSize(area);
    const dx = (gx - tx) * size[0];
    const dy = (gy - ty) * size[1];
    const e = std.math.hypot(dx, dy);
    const deg = std.math.radiansToDegrees(std.math.atan2(e, eye_z_mm));
    return .{ .tx = tx, .ty = ty, .gx = gx, .gy = gy, .dx_mm = dx, .dy_mm = dy, .err_mm = e, .err_deg = deg, .eye_z_mm = eye_z_mm, .samples = samples };
}

pub const Summary = struct {
    n: u32 = 0,
    mean_deg: f64 = 0,
    max_deg: f64 = 0,
    mean_mm: f64 = 0,
    max_mm: f64 = 0,
    mean_eye_z_mm: f64 = 0,
};

pub fn summarize(points: []const ?PointError) Summary {
    var s = Summary{};
    for (points) |op| {
        const p = op orelse continue;
        s.n += 1;
        s.mean_deg += p.err_deg;
        s.mean_mm += p.err_mm;
        s.mean_eye_z_mm += p.eye_z_mm;
        s.max_deg = @max(s.max_deg, p.err_deg);
        s.max_mm = @max(s.max_mm, p.err_mm);
    }
    if (s.n > 0) {
        const n: f64 = @floatFromInt(s.n);
        s.mean_deg /= n;
        s.mean_mm /= n;
        s.mean_eye_z_mm /= n;
    }
    return s;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "area from markers matches the probe's run-3 area" {
    // Run 3 of the live session: lines 709 px apart, tracker at x = 863.5 px.
    const a = areaFromMarkers(509, 1218, 1920, 1080, 10).?;
    try testing.expectApproxEqAbs(@as(f64, 709), a.d_px, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 864), a.xc_px, 1e-9);
    try testing.expectApproxEqAbs(184.5 / 709.0, a.mm_per_px, 1e-12);
    try testing.expectApproxEqAbs(a.corners[0], a.corners[6], 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 10), a.corners[7], 1e-12);
    try testing.expectApproxEqAbs(a.w_mm, a.corners[3] - a.corners[0], 1e-9);
    try testing.expectApproxEqAbs(a.h_mm + 10, a.corners[1], 1e-9);
    // Order of the lines does not matter.
    try testing.expectEqual(a.corners, areaFromMarkers(1218, 509, 1920, 1080, 10).?.corners);
    try testing.expect(areaFromMarkers(10, 10, 1920, 1080, 10) == null);
}

test "markers round-trip through the area" {
    const stored: Corners = .{ -224.705, 291.044, 0, 274.928, 291.044, 0, -224.705, 10, 0 };
    const m = markersFromArea(stored, 1920, 1080).?;
    const a = areaFromMarkers(m[0], m[1], 1920, 1080, 10).?;
    for (stored, a.corners) |e, g| try testing.expectApproxEqAbs(e, g, 1.0);
    // A reset area with the tracker outside gives no lines.
    try testing.expect(markersFromArea(.{ 600, 800, 0, 1200, 800, 0, 600, -21.5, 0 }, 1920, 1080) == null);
    // Made for a 16:9 output: not reused on a 16:10 one.
    try testing.expect(markersFromArea(stored, 3200, 2000) == null);
}

test "validation error" {
    const area: Corners = .{ -250, 291, 0, 250, 291, 0, -250, 10, 0 };
    // 0.01 of 500 mm = 5 mm right, nothing vertical, at 600 mm.
    const e = pointError(0.5, 0.5, 0.51, 0.5, 600, area, 30);
    try testing.expectApproxEqAbs(@as(f64, 5), e.err_mm, 1e-9);
    try testing.expectApproxEqAbs(std.math.radiansToDegrees(std.math.atan2(@as(f64, 5), 600)), e.err_deg, 1e-12);
    const pts = [_]?PointError{ e, null, pointError(0.1, 0.1, 0.1, 0.1 + 10.0 / 281.0, 600, area, 30) };
    const s = summarize(&pts);
    try testing.expectEqual(@as(u32, 2), s.n);
    try testing.expectApproxEqAbs(@as(f64, 7.5), s.mean_mm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), s.max_mm, 1e-9);
}
