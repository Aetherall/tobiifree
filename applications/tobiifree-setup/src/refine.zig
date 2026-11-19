// refine.zig — turn a validation into a correction map (pure logic, tested).
//
// The validation dots (4×4) give, per dot, the robust raw gaze position
// (median of the fixation samples, collected with the daemon's correction
// off) and the eye distance. From them:
//
//   raw     error of the uncorrected gaze (what the device calibration gives)
//   active  error after the map the daemon currently holds, if any (measured
//           on fresh data, so an honest number)
//   loo     leave-one-out: each dot corrected by a map fitted on the other
//           dots (λ chosen on those too) — an honest estimate of what a new
//           map does on gaze it was not fitted on
//
// The new map (fitted on all usable dots) is kept only if its LOO mean beats
// both the raw mean and the active map's mean; an active map that does worse
// than no map is offered for removal. Dots measured in fallback (no fixation
// near the dot) are reported but not used for the map nor the decision.

const std = @import("std");
const corr = @import("correction");
const geo = @import("geometry.zig");

pub const MAX_DOTS = 32;
/// The new map must beat the alternatives' mean by at least this much.
pub const MIN_GAIN_DEG = 0.02;

pub const Dot = struct {
    tx: f64,
    ty: f64,
    /// Median raw gaze (normalised).
    gx: f64,
    gy: f64,
    z_mm: f64,
    n: u32,
    fallback: bool = false,
};

pub const DotResult = struct {
    raw: geo.PointError,
    active: ?geo.PointError = null,
    loo: ?geo.PointError = null,
};

pub const Decision = enum {
    /// Save the new map (it beats no map and the current one).
    keep_new,
    /// The current map stays (it does better than the new one would).
    keep_active,
    /// The current map makes things worse than no map: remove it.
    clear_active,
    /// No map, and the new one would not help.
    none,
};

pub const Analysis = struct {
    results: [MAX_DOTS]?DotResult = .{null} ** MAX_DOTS,
    /// Summaries over the dots used for the map (measured, not fallback).
    raw: geo.Summary = .{},
    active: ?geo.Summary = null,
    loo: ?geo.Summary = null,
    n_fit: usize = 0,
    map: ?corr.Map = null,
    decision: Decision = .none,
};

pub fn analyse(dots: []const ?Dot, area: [9]f64, active: ?*const corr.Map) Analysis {
    var an = Analysis{};
    const size = geo.areaSize(area);
    var fit_pts: [corr.MAX_POINTS]corr.Point = undefined;
    var fit_idx: [corr.MAX_POINTS]usize = undefined;
    var n_fit: usize = 0;
    for (dots, 0..) |od, i| {
        const d = od orelse continue;
        var r = DotResult{ .raw = geo.pointError(d.tx, d.ty, d.gx, d.gy, d.z_mm, area, d.n) };
        if (active) |m| {
            const cg = m.correct(d.gx, d.gy);
            r.active = geo.pointError(d.tx, d.ty, cg[0], cg[1], d.z_mm, area, d.n);
        }
        an.results[i] = r;
        if (!d.fallback and n_fit < corr.MAX_POINTS) {
            fit_pts[n_fit] = .{ .tx = d.tx, .ty = d.ty, .gx = d.gx, .gy = d.gy, .n = d.n };
            fit_idx[n_fit] = i;
            n_fit += 1;
        }
    }
    an.n_fit = n_fit;

    var raw_e: [MAX_DOTS]?geo.PointError = .{null} ** MAX_DOTS;
    var act_e: [MAX_DOTS]?geo.PointError = .{null} ** MAX_DOTS;
    for (fit_idx[0..n_fit], 0..) |i, k| {
        raw_e[k] = an.results[i].?.raw;
        act_e[k] = an.results[i].?.active;
    }
    an.raw = geo.summarize(raw_e[0..n_fit]);
    if (active != null) an.active = geo.summarize(act_e[0..n_fit]);

    if (n_fit >= corr.MIN_POINTS + 1) {
        var loo: [corr.MAX_POINTS]?[2]f64 = undefined;
        corr.leaveOneOut(fit_pts[0..n_fit], size[0], size[1], corr.DEFAULT_CAP_MM, corr.DEFAULT_FADE_MM, loo[0..n_fit]);
        var loo_e: [MAX_DOTS]?geo.PointError = .{null} ** MAX_DOTS;
        var all = true;
        for (fit_idx[0..n_fit], 0..) |i, k| {
            const pred = loo[k] orelse {
                all = false;
                continue;
            };
            const d = dots[i].?;
            const e = geo.pointError(d.tx, d.ty, d.gx - pred[0] / size[0], d.gy - pred[1] / size[1], d.z_mm, area, d.n);
            an.results[i].?.loo = e;
            loo_e[k] = e;
        }
        if (all) {
            an.loo = geo.summarize(loo_e[0..n_fit]);
            an.map = corr.Map.build(fit_pts[0..n_fit], size[0], size[1], corr.DEFAULT_CAP_MM, corr.DEFAULT_FADE_MM, null) catch null;
        }
    }

    const raw_mean = an.raw.mean_deg;
    const act_mean: ?f64 = if (an.active) |s| s.mean_deg else null;
    const best_other = if (act_mean) |am| @min(raw_mean, am) else raw_mean;
    if (an.loo != null and an.map != null and an.loo.?.mean_deg + MIN_GAIN_DEG <= best_other) {
        an.decision = .keep_new;
    } else if (act_mean) |am| {
        an.decision = if (am <= raw_mean) .keep_active else .clear_active;
    } else an.decision = .none;
    return an;
}

/// correction.json for the analysis' new map. Caller frees.
pub fn fileJson(gpa: std.mem.Allocator, an: *const Analysis, dots: []const ?Dot, area: [9]f64, calibration_sha256: []const u8, now_unix: i64) ![]u8 {
    const m = an.map orelse return error.NoMap;
    var pts: [corr.MAX_POINTS]corr.FilePoint = undefined;
    var n: usize = 0;
    for (dots) |od| {
        const d = od orelse continue;
        if (d.fallback or n == corr.MAX_POINTS) continue;
        pts[n] = .{ .target = .{ d.tx, d.ty }, .gaze = .{ d.gx, d.gy }, .n = d.n };
        n += 1;
    }
    const f = corr.File{
        .calibration_sha256 = calibration_sha256,
        .display_area = area,
        .lambda = m.params.lambda,
        .cap_mm = m.params.cap_mm,
        .fade_mm = m.params.fade_mm,
        .points = pts[0..n],
        .stats = .{
            .dots = @intCast(n),
            .mean_raw_deg = an.raw.mean_deg,
            .max_raw_deg = an.raw.max_deg,
            .mean_loo_deg = if (an.loo) |s| s.mean_deg else 0,
            .max_loo_deg = if (an.loo) |s| s.max_deg else 0,
        },
        .created_unix = now_unix,
    };
    return f.stringify(gpa);
}

/// Median of `xs` (reordered in place). 0 for an empty slice.
pub fn median(xs: []f64) f64 {
    if (xs.len == 0) return 0;
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    const m = xs.len / 2;
    return if (xs.len % 2 == 1) xs[m] else (xs[m - 1] + xs[m]) / 2;
}

// ── Tests (synthetic validations) ───────────────────────────────────

const testing = std.testing;
const AREA: [9]f64 = .{ -233.184, 308.741, 0, 297.911, 308.741, 0, -233.184, 10, 0 };
const G4 = [_]f64{ 0.1, 0.3667, 0.6333, 0.9 };

fn validation(field: *const fn (f64, f64) [2]f64, noise_mm: f64, seed: u64) [16]?Dot {
    const size = geo.areaSize(AREA);
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var dots: [16]?Dot = undefined;
    for (G4, 0..) |ty, j| for (G4, 0..) |tx, i| {
        const r = field(tx, ty);
        dots[j * 4 + i] = .{
            .tx = tx,
            .ty = ty,
            .gx = tx + (r[0] + noise_mm * rnd.floatNorm(f64)) / size[0],
            .gy = ty + (r[1] + noise_mm * rnd.floatNorm(f64)) / size[1],
            .z_mm = 720,
            .n = 34,
        };
    };
    return dots;
}

/// Like the person's runs: upper-right region ~15–20 mm low, left middle a
/// bit off, plus a small global shift.
fn drift(x: f64, y: f64) [2]f64 {
    const dx = (x - 0.9) / 0.3;
    const dy = (y - 0.1) / 0.3;
    const b = @exp(-(dx * dx + dy * dy));
    return .{ 3 - 4 * b, 2 + 17 * b };
}
fn noDrift(_: f64, _: f64) [2]f64 {
    return .{ 0, 0 };
}

test "systematic drift: the new map is kept and LOO improves" {
    const dots = validation(drift, 2.0, 11);
    const an = analyse(&dots, AREA, null);
    try testing.expectEqual(@as(usize, 16), an.n_fit);
    try testing.expectEqual(Decision.keep_new, an.decision);
    try testing.expect(an.loo.?.mean_deg < an.raw.mean_deg * 0.8);
    const json = try fileJson(testing.allocator, &an, &dots, AREA, &corr.sha256Hex("blob"), 0);
    defer testing.allocator.free(json);
    const p = try corr.parseFile(testing.allocator, json);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 16), p.value.points.len);
}

test "pure noise: the map is discarded" {
    const dots = validation(noDrift, 3.0, 12);
    const an = analyse(&dots, AREA, null);
    try testing.expectEqual(Decision.none, an.decision);
}

test "an active map that hurts is offered for removal" {
    // Map fitted on a drift that is not there any more.
    const old = validation(drift, 0, 13);
    const old_an = analyse(&old, AREA, null);
    const m = old_an.map.?;
    const now_dots = validation(noDrift, 1.0, 14);
    const an = analyse(&now_dots, AREA, &m);
    try testing.expect(an.active.?.mean_deg > an.raw.mean_deg);
    // Either drop it, or replace it by the new map (which beats it).
    try testing.expect(an.decision == .clear_active or an.decision == .keep_new);
}

test "an active map that works is kept against a noisy new one" {
    const old = validation(drift, 0, 15);
    const m = analyse(&old, AREA, null).map.?;
    const dots = validation(drift, 2.0, 16);
    const an = analyse(&dots, AREA, &m);
    try testing.expect(an.active.?.mean_deg < an.raw.mean_deg);
    try testing.expect(an.decision == .keep_active or an.decision == .keep_new);
}

test "fallback dots and missing dots are not fitted" {
    var dots = validation(drift, 1.0, 17);
    dots[3].?.fallback = true;
    dots[7] = null;
    const an = analyse(&dots, AREA, null);
    try testing.expectEqual(@as(usize, 14), an.n_fit);
    try testing.expect(an.results[3].?.loo == null);
    try testing.expect(an.results[7] == null);
}

test "median" {
    var a = [_]f64{ 5, 1, 4, 2, 100 };
    try testing.expectEqual(@as(f64, 4), median(&a));
    var b = [_]f64{ 1, 2, 3, 4 };
    try testing.expectEqual(@as(f64, 2.5), median(&b));
}
