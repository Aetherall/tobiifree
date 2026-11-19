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
    /// Dots of this run used for the summaries (measured, not fallback).
    n_fit: usize = 0,
    /// Control points of the new map (positions in the pool).
    n_pooled: usize = 0,
    /// Validation runs in the pool.
    runs: usize = 1,
    map: ?corr.Map = null,
    decision: Decision = .none,
};

/// `dots`: the run just measured (raw). `pooled`: the per-target pool of all
/// runs on this calibration, this one included (corr.pool), or empty to use
/// this run alone. Errors are reported for this run's dots; the leave-one-out
/// for a dot leaves its *position* out of the pool (all runs), so the new map
/// is judged on a place it has never seen.
pub fn analyse(dots: []const ?Dot, pooled: []const corr.Point, runs: usize, area: [9]f64, active: ?*const corr.Map) Analysis {
    var an = Analysis{ .runs = runs };
    const size = geo.areaSize(area);

    // The fit set: the pool, or this run's usable dots.
    var own: [corr.MAX_POINTS]corr.Point = undefined;
    var n_own: usize = 0;
    for (dots) |od| {
        const d = od orelse continue;
        if (d.fallback or n_own == corr.MAX_POINTS) continue;
        own[n_own] = .{ .tx = d.tx, .ty = d.ty, .gx = d.gx, .gy = d.gy, .n = d.n };
        n_own += 1;
    }
    const fit: []const corr.Point = if (pooled.len > 0) pooled else own[0..n_own];
    an.n_pooled = fit.len;

    var raw_e: [MAX_DOTS]?geo.PointError = .{null} ** MAX_DOTS;
    var act_e: [MAX_DOTS]?geo.PointError = .{null} ** MAX_DOTS;
    var loo_e: [MAX_DOTS]?geo.PointError = .{null} ** MAX_DOTS;
    var n_eval: usize = 0;
    var loo_all = fit.len >= corr.MIN_POINTS + 1;
    var others: [corr.MAX_POINTS]corr.Point = undefined;
    for (dots, 0..) |od, i| {
        const d = od orelse continue;
        var r = DotResult{ .raw = geo.pointError(d.tx, d.ty, d.gx, d.gy, d.z_mm, area, d.n) };
        if (active) |m| {
            const cg = m.correct(d.gx, d.gy);
            r.active = geo.pointError(d.tx, d.ty, cg[0], cg[1], d.z_mm, area, d.n);
        }
        if (!d.fallback and fit.len >= corr.MIN_POINTS + 1) {
            // Leave this position out of the pool.
            var k: usize = 0;
            for (fit) |q| {
                if (@abs(q.tx - d.tx) < 1e-4 and @abs(q.ty - d.ty) < 1e-4) continue;
                others[k] = q;
                k += 1;
            }
            if (corr.Map.build(others[0..k], size[0], size[1], corr.DEFAULT_CAP_MM, corr.DEFAULT_FADE_MM, fit)) |m| {
                const pred = m.residualMm(d.gx, d.gy);
                r.loo = geo.pointError(d.tx, d.ty, d.gx - pred[0] / size[0], d.gy - pred[1] / size[1], d.z_mm, area, d.n);
            } else |_| loo_all = false;
        }
        an.results[i] = r;
        if (!d.fallback) {
            raw_e[n_eval] = r.raw;
            act_e[n_eval] = r.active;
            loo_e[n_eval] = r.loo;
            n_eval += 1;
        }
    }
    an.n_fit = n_eval;
    an.raw = geo.summarize(raw_e[0..n_eval]);
    if (active != null) an.active = geo.summarize(act_e[0..n_eval]);
    if (loo_all and fit.len >= corr.MIN_POINTS + 1 and n_eval > 0) {
        an.loo = geo.summarize(loo_e[0..n_eval]);
        an.map = corr.Map.build(fit, size[0], size[1], corr.DEFAULT_CAP_MM, corr.DEFAULT_FADE_MM, null) catch null;
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

/// correction.json for the analysis' new map (control points: `fit`, the
/// pool or this run's usable dots as given to analyse). Caller frees.
pub fn fileJson(gpa: std.mem.Allocator, an: *const Analysis, fit: []const corr.Point, area: [9]f64, calibration_sha256: []const u8, now_unix: i64) ![]u8 {
    const m = an.map orelse return error.NoMap;
    var pts: [corr.MAX_POINTS]corr.FilePoint = undefined;
    const n = @min(fit.len, corr.MAX_POINTS);
    for (fit[0..n], 0..) |p, i| pts[i] = .{ .target = .{ p.tx, p.ty }, .gaze = .{ p.gx, p.gy }, .n = p.n };
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
            .runs = @intCast(an.runs),
        },
        .created_unix = now_unix,
    };
    return f.stringify(gpa);
}

/// This run's usable dots as a history run (caller frees `dots`).
pub fn toRun(gpa: std.mem.Allocator, dots: []const ?Dot, now_unix: i64) !corr.Run {
    var list: std.ArrayList(corr.FilePoint) = .empty;
    errdefer list.deinit(gpa);
    for (dots) |od| {
        const d = od orelse continue;
        if (d.fallback) continue;
        try list.append(gpa, .{ .target = .{ d.tx, d.ty }, .gaze = .{ d.gx, d.gy }, .n = d.n });
    }
    return .{ .created_unix = now_unix, .dots = try list.toOwnedSlice(gpa) };
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
    const an = analyse(&dots, &.{}, 1, AREA, null);
    try testing.expectEqual(@as(usize, 16), an.n_fit);
    try testing.expectEqual(Decision.keep_new, an.decision);
    try testing.expect(an.loo.?.mean_deg < an.raw.mean_deg * 0.8);
    var own: [16]corr.Point = undefined;
    for (dots, 0..) |d, i| own[i] = .{ .tx = d.?.tx, .ty = d.?.ty, .gx = d.?.gx, .gy = d.?.gy, .n = d.?.n };
    const json = try fileJson(testing.allocator, &an, &own, AREA, &corr.sha256Hex("blob"), 0);
    defer testing.allocator.free(json);
    const p = try corr.parseFile(testing.allocator, json);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 16), p.value.points.len);
}

test "pure noise: the map is discarded" {
    const dots = validation(noDrift, 3.0, 12);
    const an = analyse(&dots, &.{}, 1, AREA, null);
    try testing.expectEqual(Decision.none, an.decision);
}

test "an active map that hurts is offered for removal" {
    // Map fitted on a drift that is not there any more.
    const old = validation(drift, 0, 13);
    const old_an = analyse(&old, &.{}, 1, AREA, null);
    const m = old_an.map.?;
    const now_dots = validation(noDrift, 1.0, 14);
    const an = analyse(&now_dots, &.{}, 1, AREA, &m);
    try testing.expect(an.active.?.mean_deg > an.raw.mean_deg);
    // Either drop it, or replace it by the new map (which beats it).
    try testing.expect(an.decision == .clear_active or an.decision == .keep_new);
}

test "an active map that works is kept against a noisy new one" {
    const old = validation(drift, 0, 15);
    const m = analyse(&old, &.{}, 1, AREA, null).map.?;
    const dots = validation(drift, 2.0, 16);
    const an = analyse(&dots, &.{}, 1, AREA, &m);
    try testing.expect(an.active.?.mean_deg < an.raw.mean_deg);
    try testing.expect(an.decision == .keep_active or an.decision == .keep_new);
}

test "fallback dots and missing dots are not fitted" {
    var dots = validation(drift, 1.0, 17);
    dots[3].?.fallback = true;
    dots[7] = null;
    const an = analyse(&dots, &.{}, 1, AREA, null);
    try testing.expectEqual(@as(usize, 14), an.n_fit);
    try testing.expect(an.results[3].?.loo == null);
    try testing.expect(an.results[7] == null);
}

fn poolOf(runs: []const [16]?Dot, out: []corr.Point) usize {
    var rbuf: [8]corr.Run = undefined;
    var dbuf: [8][16]corr.FilePoint = undefined;
    for (runs, 0..) |r, k| {
        var n: usize = 0;
        for (r) |od| if (od) |d| {
            dbuf[k][n] = .{ .target = .{ d.tx, d.ty }, .gaze = .{ d.gx, d.gy }, .n = d.n };
            n += 1;
        };
        rbuf[k] = .{ .dots = dbuf[k][0..n] };
    }
    return corr.pool(rbuf[0..runs.len], out);
}

test "pooling runs: the leave-one-out estimate improves" {
    // Same drift, noisy runs; judged on the last run.
    var single: f64 = 0;
    var pooled: f64 = 0;
    for (0..4) |trial| {
        const seed: u64 = 100 + trial * 10;
        const runs = [_][16]?Dot{ validation(drift, 4.0, seed), validation(drift, 4.0, seed + 1), validation(drift, 4.0, seed + 2) };
        var pts: [16]corr.Point = undefined;
        const n = poolOf(&runs, &pts);
        try testing.expectEqual(@as(usize, 16), n);
        single += analyse(&runs[2], &.{}, 1, AREA, null).loo.?.mean_deg;
        const an = analyse(&runs[2], pts[0..n], 3, AREA, null);
        try testing.expectEqual(@as(usize, 3), an.runs);
        pooled += an.loo.?.mean_deg;
    }
    try testing.expect(pooled < single);
}

fn bumpAt5(x: f64, y: f64) [2]f64 {
    // A residual only at one dot position (0.3667, 0.3667).
    return if (@abs(x - 0.3667) < 1e-3 and @abs(y - 0.3667) < 1e-3) .{ 0, 20 } else .{ 0, 0 };
}

test "leave-one-out leaves the position out of every run" {
    const runs = [_][16]?Dot{ validation(bumpAt5, 0.3, 21), validation(bumpAt5, 0.3, 22) };
    var pts: [16]corr.Point = undefined;
    const n = poolOf(&runs, &pts);
    const an = analyse(&runs[1], pts[0..n], 2, AREA, null);
    const r = an.results[5].?;
    // If its own (pooled) value leaked into its prediction it would be ~0.
    try testing.expect(r.loo.?.err_mm > 0.7 * r.raw.err_mm);
}

test "median" {
    var a = [_]f64{ 5, 1, 4, 2, 100 };
    try testing.expectEqual(@as(f64, 4), median(&a));
    var b = [_]f64{ 1, 2, 3, 4 };
    try testing.expectEqual(@as(f64, 2.5), median(&b));
}
