// gaze.zig — turn a daemon GazeSample into a selection Sample.

const std = @import("std");
const core = @import("tobiifree_core");
const select = @import("select.zig");

fn plausible(p: [2]f64) bool {
    // Invalid points come as (-1, -1) or (0, 0) with validity 4; allow some
    // overshoot past the edges (clamped later).
    for (p) |v| if (!std.math.isFinite(v) or v < -0.5 or v > 1.5) return false;
    return true;
}

/// Which combined point comes first.
pub const Prefer = enum {
    /// Before the device's temporal filter (jump and the fixation filter do
    /// their own filtering).
    unfiltered,
    /// The device-filtered point, as tobiifree-overlay draws it (follow's
    /// default `device` mode).
    filtered,
};

/// Gaze point of a sample if at least one eye is valid: the combined,
/// unfiltered point (we filter ourselves), else the device-filtered combined
/// one, else the valid eye's own point. All three are what the daemon
/// corrected (unless the client asked for raw gaze; we never do).
pub fn toSample(s: *const core.GazeSample, t_ns: i64) ?select.Sample {
    return toSampleP(s, t_ns, .unfiltered);
}

/// toSample with the order of the two combined points chosen by `prefer`.
pub fn toSampleP(s: *const core.GazeSample, t_ns: i64, prefer: Prefer) ?select.Sample {
    const l = s.present_mask & core.GAZE_BIT_VALIDITY_L != 0 and s.validity_L == 0;
    const r = s.present_mask & core.GAZE_BIT_VALIDITY_R != 0 and s.validity_R == 0;
    if (!l and !r) return null;
    const m = s.present_mask;
    const unf_ok = m & core.GAZE_BIT_GAZE_2D_UNFILTERED != 0 and plausible(s.gaze_point_2d_unfiltered);
    const filt_ok = m & core.GAZE_BIT_GAZE_2D != 0 and plausible(s.gaze_point_2d_norm);
    const p: [2]f64 = if (prefer == .unfiltered and unf_ok)
        s.gaze_point_2d_unfiltered
    else if (filt_ok)
        s.gaze_point_2d_norm
    else if (unf_ok)
        s.gaze_point_2d_unfiltered
    else if (l and m & core.GAZE_BIT_GAZE_2D_L != 0 and plausible(s.gaze_point_2d_L_norm))
        s.gaze_point_2d_L_norm
    else if (r and m & core.GAZE_BIT_GAZE_2D_R != 0 and plausible(s.gaze_point_2d_R_norm))
        s.gaze_point_2d_R_norm
    else
        return null;

    // Eye distance from the screen: z of the eye origin (tracker frame, the
    // tracker sits in the screen plane; display tilt is 0 in our setups).
    var z: f64 = 0;
    var nz: f64 = 0;
    if (l and m & core.GAZE_BIT_EYE_ORIGIN_L != 0 and s.eye_origin_L_mm[2] > 100) {
        z += s.eye_origin_L_mm[2];
        nz += 1;
    }
    if (r and m & core.GAZE_BIT_EYE_ORIGIN_R != 0 and s.eye_origin_R_mm[2] > 100) {
        z += s.eye_origin_R_mm[2];
        nz += 1;
    }
    return .{ .t_ns = t_ns, .x = p[0], .y = p[1], .view_mm = if (nz > 0) z / nz else 0 };
}

const testing = std.testing;

fn blank() core.GazeSample {
    var s: core.GazeSample = std.mem.zeroes(core.GazeSample);
    s.present_mask = 0x3fffff;
    return s;
}

test "both eyes valid: unfiltered combined point, mean eye z" {
    var s = blank();
    s.gaze_point_2d_norm = .{ 0.4, 0.5 };
    s.gaze_point_2d_unfiltered = .{ 0.41, 0.52 };
    s.eye_origin_L_mm = .{ -30, 0, 700 };
    s.eye_origin_R_mm = .{ 30, 0, 720 };
    const g = toSample(&s, 7).?;
    try testing.expectEqual(@as(f64, 0.41), g.x);
    try testing.expectEqual(@as(f64, 0.52), g.y);
    try testing.expectEqual(@as(f64, 710), g.view_mm);
    try testing.expectEqual(@as(i64, 7), g.t_ns);
}

test "no eye valid: nothing" {
    var s = blank();
    s.validity_L = 4;
    s.validity_R = 4;
    s.gaze_point_2d_norm = .{ -1, -1 };
    s.gaze_point_2d_unfiltered = .{ -1, -1 };
    try testing.expectEqual(@as(?select.Sample, null), toSample(&s, 0));
}

test "one eye valid, combined missing: that eye's point" {
    var s = blank();
    s.validity_L = 4;
    s.gaze_point_2d_norm = .{ -1, -1 };
    s.gaze_point_2d_unfiltered = .{ -1, -1 };
    s.gaze_point_2d_R_norm = .{ 0.7, 0.2 };
    s.eye_origin_R_mm = .{ 30, 0, 650 };
    const g = toSample(&s, 0).?;
    try testing.expectEqual(@as(f64, 0.7), g.x);
    try testing.expectEqual(@as(f64, 650), g.view_mm);
}

test "prefer filtered (follow device mode): the overlay's point, same fallbacks" {
    var s = blank();
    s.gaze_point_2d_norm = .{ 0.4, 0.5 };
    s.gaze_point_2d_unfiltered = .{ 0.41, 0.52 };
    try testing.expectEqual(@as(f64, 0.4), toSampleP(&s, 0, .filtered).?.x);
    try testing.expectEqual(@as(f64, 0.41), toSampleP(&s, 0, .unfiltered).?.x);
    // Filtered combined invalid: unfiltered, then the valid eye.
    s.gaze_point_2d_norm = .{ -1, -1 };
    try testing.expectEqual(@as(f64, 0.41), toSampleP(&s, 0, .filtered).?.x);
    s.gaze_point_2d_unfiltered = .{ -1, -1 };
    s.validity_L = 4;
    s.gaze_point_2d_R_norm = .{ 0.7, 0.2 };
    try testing.expectEqual(@as(f64, 0.7), toSampleP(&s, 0, .filtered).?.x);
    // No eye valid: hold (nothing).
    s.validity_R = 4;
    try testing.expectEqual(@as(?select.Sample, null), toSampleP(&s, 0, .filtered));
}

test "filtered combined used when unfiltered is absent" {
    var s = blank();
    s.present_mask &= ~core.GAZE_BIT_GAZE_2D_UNFILTERED;
    s.gaze_point_2d_norm = .{ 0.25, 0.75 };
    const g = toSample(&s, 0).?;
    try testing.expectEqual(@as(f64, 0.25), g.x);
    try testing.expectEqual(@as(f64, 0), g.view_mm); // eye z 0 → unknown
}
