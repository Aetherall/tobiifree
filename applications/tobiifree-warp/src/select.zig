// select.zig — choose the gaze point for a jump from the recent samples.
//
// The ring holds the last samples as they arrived (host monotonic time, ns).
// For a jump at time `now`:
//   1. keep the valid samples of the last `window_ms`; if the newest valid
//      sample is older than `stale_ms`, there is no gaze (.stale);
//   2. walk back from the newest sample and grow the run while every pair of
//      samples in it stays within `max_dispersion_deg` (visual angle at the
//      eye's distance from the screen): the most recent stable run;
//   3. fewer than `min_samples` in that run means the eye is mid-saccade (or
//      the fixation just started): .unstable — the caller may wait for the
//      next samples;
//   4. otherwise the target is the per-axis median of the run.
//
// Pure logic, no I/O; unit tested below.

const std = @import("std");

pub const Sample = struct {
    /// Host CLOCK_MONOTONIC receive time, ns.
    t_ns: i64,
    /// Gaze on the display area, normalised (0..1, origin top-left).
    x: f64,
    y: f64,
    /// Eye distance from the screen plane, mm (0 = unknown).
    view_mm: f64 = 0,
};

pub const CAP = 64; // ~2 s at 33 Hz, far more than any window

pub const Ring = struct {
    buf: [CAP]Sample = undefined,
    /// Total samples pushed; the newest is buf[(n-1) % CAP].
    n: usize = 0,

    pub fn push(self: *Ring, s: Sample) void {
        self.buf[self.n % CAP] = s;
        self.n += 1;
    }

    pub fn len(self: *const Ring) usize {
        return @min(self.n, CAP);
    }

    /// i = 0 is the newest sample.
    pub fn back(self: *const Ring, i: usize) Sample {
        return self.buf[(self.n - 1 - i) % CAP];
    }

    pub fn clear(self: *Ring) void {
        self.n = 0;
    }
};

pub const Params = struct {
    window_ms: f64 = 150,
    stale_ms: f64 = 300,
    max_dispersion_deg: f64 = 1.5,
    min_samples: usize = 2,
    /// Physical size of the display area (mm), to turn norm distances into mm.
    width_mm: f64 = 531,
    height_mm: f64 = 299,
    /// Viewing distance used when the samples carry none.
    default_view_mm: f64 = 650,
};

pub const Pick = struct {
    x: f64,
    y: f64,
    /// Samples in the stable run used for the median.
    n: usize,
    /// Valid samples in the window.
    n_window: usize,
    /// Max pairwise distance in the run, degrees.
    dispersion_deg: f64,
    /// Age of the newest sample of the run at `now`, ms.
    age_ms: f64,
};

pub const Result = union(enum) {
    ok: Pick,
    /// No valid sample within stale_ms (eyes lost, tracker away, daemon down).
    stale: struct { age_ms: ?f64 },
    /// Valid samples, but the latest stable run is too short (saccade).
    unstable: struct { n_window: usize, run: usize, dispersion_deg: f64 },
};

const MAX_RUN = CAP;

/// Visual angle between two samples (degrees).
pub fn angleDeg(p: Params, a: Sample, b: Sample) f64 {
    const dx = (a.x - b.x) * p.width_mm;
    const dy = (a.y - b.y) * p.height_mm;
    var view = (viewOf(p, a) + viewOf(p, b)) / 2;
    if (view <= 0) view = p.default_view_mm;
    return std.math.radiansToDegrees(std.math.atan2(@sqrt(dx * dx + dy * dy), view));
}

fn viewOf(p: Params, s: Sample) f64 {
    return if (s.view_mm > 0) s.view_mm else p.default_view_mm;
}

pub fn select(ring: *const Ring, now_ns: i64, p: Params) Result {
    const window_ns: i64 = @intFromFloat(p.window_ms * 1e6);
    const stale_ns: i64 = @intFromFloat(p.stale_ms * 1e6);

    // Valid samples of the window, newest first. Samples from the future
    // (clock skew between receive and `now`) count as age 0.
    var win: [MAX_RUN]Sample = undefined;
    var nw: usize = 0;
    var newest_age: ?i64 = null;
    var i: usize = 0;
    while (i < ring.len()) : (i += 1) {
        const s = ring.back(i);
        const age = @max(0, now_ns - s.t_ns);
        if (newest_age == null) newest_age = age;
        if (age > window_ns) break;
        win[nw] = s;
        nw += 1;
    }
    const newest = newest_age orelse return .{ .stale = .{ .age_ms = null } };
    if (newest > stale_ns) return .{ .stale = .{ .age_ms = ms(newest) } };
    if (nw == 0) return .{ .stale = .{ .age_ms = ms(newest) } };

    // Most recent stable run: grow while all pairs stay within the threshold.
    var run: usize = 1;
    var disp: f64 = 0;
    grow: while (run < nw) {
        const cand = win[run];
        var worst = disp;
        for (win[0..run]) |s| {
            const d = angleDeg(p, cand, s);
            if (d > p.max_dispersion_deg) break :grow;
            worst = @max(worst, d);
        }
        disp = worst;
        run += 1;
    }
    if (run < p.min_samples) {
        // Report the dispersion that broke the run (what the eye just did).
        const jump = if (nw > run) angleDeg(p, win[0], win[run]) else 0;
        return .{ .unstable = .{ .n_window = nw, .run = run, .dispersion_deg = jump } };
    }

    var xs: [MAX_RUN]f64 = undefined;
    var ys: [MAX_RUN]f64 = undefined;
    for (win[0..run], 0..) |s, k| {
        xs[k] = s.x;
        ys[k] = s.y;
    }
    return .{ .ok = .{
        .x = median(xs[0..run]),
        .y = median(ys[0..run]),
        .n = run,
        .n_window = nw,
        .dispersion_deg = disp,
        .age_ms = ms(newest),
    } };
}

fn ms(ns: i64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

/// Median (sorts `v` in place). Even length: mean of the two middle values.
pub fn median(v: []f64) f64 {
    std.mem.sort(f64, v, {}, std.sort.asc(f64));
    const m = v.len / 2;
    return if (v.len % 2 == 1) v[m] else (v[m - 1] + v[m]) / 2;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const MS: i64 = 1_000_000;

fn fill(ring: *Ring, pts: []const [3]f64) void {
    // [t_ms, x, y]
    for (pts) |q| ring.push(.{ .t_ns = @as(i64, @intFromFloat(q[0])) * MS, .x = q[1], .y = q[2], .view_mm = 650 });
}

test "median odd/even" {
    var a = [_]f64{ 3, 1, 2 };
    try testing.expectEqual(@as(f64, 2), median(&a));
    var b = [_]f64{ 4, 1, 3, 2 };
    try testing.expectEqual(@as(f64, 2.5), median(&b));
}

test "angle: 1 degree at 650 mm is ~11.3 mm" {
    const p = Params{ .width_mm = 500, .height_mm = 300 };
    const a = Sample{ .t_ns = 0, .x = 0.5, .y = 0.5, .view_mm = 650 };
    const b = Sample{ .t_ns = 0, .x = 0.5 + 11.346 / 500.0, .y = 0.5, .view_mm = 650 };
    try testing.expectApproxEqAbs(@as(f64, 1.0), angleDeg(p, a, b), 1e-3);
}

test "stable fixation: median of the window, outlier-robust" {
    var r = Ring{};
    // 33 Hz samples around (0.30, 0.40), one noisy sample within 1.5°.
    fill(&r, &.{
        .{ 1000, 0.300, 0.400 },
        .{ 1030, 0.302, 0.401 },
        .{ 1060, 0.330, 0.400 }, // ~0.8° off in x
        .{ 1090, 0.301, 0.399 },
        .{ 1120, 0.299, 0.402 },
    });
    const res = select(&r, 1125 * MS, .{});
    try testing.expect(res == .ok);
    try testing.expectEqual(@as(usize, 5), res.ok.n);
    try testing.expectApproxEqAbs(@as(f64, 0.301), res.ok.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.400), res.ok.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5), res.ok.age_ms, 1e-9);
}

test "window excludes old samples" {
    var r = Ring{};
    fill(&r, &.{
        .{ 700, 0.9, 0.9 }, // outside the 150 ms window
        .{ 1000, 0.2, 0.2 },
        .{ 1030, 0.2, 0.2 },
    });
    const res = select(&r, 1040 * MS, .{});
    try testing.expectEqual(@as(usize, 2), res.ok.n);
    try testing.expectEqual(@as(usize, 2), res.ok.n_window);
    try testing.expectApproxEqAbs(@as(f64, 0.2), res.ok.x, 1e-9);
}

test "landed after a saccade: only the new fixation counts" {
    var r = Ring{};
    fill(&r, &.{
        .{ 1000, 0.10, 0.10 },
        .{ 1030, 0.10, 0.10 },
        .{ 1060, 0.45, 0.30 }, // in flight
        .{ 1090, 0.80, 0.60 },
        .{ 1120, 0.80, 0.61 },
    });
    const res = select(&r, 1125 * MS, .{});
    try testing.expectEqual(@as(usize, 2), res.ok.n);
    try testing.expectApproxEqAbs(@as(f64, 0.80), res.ok.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.605), res.ok.y, 1e-9);
}

test "mid-saccade is rejected" {
    var r = Ring{};
    fill(&r, &.{
        .{ 1000, 0.10, 0.10 },
        .{ 1030, 0.10, 0.10 },
        .{ 1060, 0.40, 0.30 },
        .{ 1090, 0.70, 0.50 }, // newest, still moving
    });
    const res = select(&r, 1095 * MS, .{});
    try testing.expect(res == .unstable);
    try testing.expectEqual(@as(usize, 1), res.unstable.run);
    try testing.expect(res.unstable.dispersion_deg > 10);
}

test "threshold is in degrees: farther viewer tolerates more mm" {
    var r = Ring{};
    // 20 mm apart on a 531 mm wide screen: 1.76° at 650 mm, 1.15° at 1000 mm.
    const dx = 20.0 / 531.0;
    r.push(.{ .t_ns = 1000 * MS, .x = 0.5, .y = 0.5, .view_mm = 650 });
    r.push(.{ .t_ns = 1030 * MS, .x = 0.5 + dx, .y = 0.5, .view_mm = 650 });
    try testing.expect(select(&r, 1035 * MS, .{}) == .unstable);
    r.clear();
    r.push(.{ .t_ns = 1000 * MS, .x = 0.5, .y = 0.5, .view_mm = 1000 });
    r.push(.{ .t_ns = 1030 * MS, .x = 0.5 + dx, .y = 0.5, .view_mm = 1000 });
    try testing.expect(select(&r, 1035 * MS, .{}) == .ok);
    // Unknown distance falls back to default_view_mm (650): unstable.
    r.clear();
    r.push(.{ .t_ns = 1000 * MS, .x = 0.5, .y = 0.5 });
    r.push(.{ .t_ns = 1030 * MS, .x = 0.5 + dx, .y = 0.5 });
    try testing.expect(select(&r, 1035 * MS, .{}) == .unstable);
}

test "stale data does nothing" {
    var r = Ring{};
    try testing.expect(select(&r, 1000 * MS, .{}) == .stale);
    try testing.expectEqual(@as(?f64, null), select(&r, 1000 * MS, .{}).stale.age_ms);
    fill(&r, &.{ .{ 1000, 0.5, 0.5 }, .{ 1030, 0.5, 0.5 } });
    // 400 ms later: newest is beyond stale_ms (300).
    const res = select(&r, 1430 * MS, .{});
    try testing.expect(res == .stale);
    try testing.expectApproxEqAbs(@as(f64, 400), res.stale.age_ms.?, 1e-9);
    // 200 ms later: not stale, but nothing in the 150 ms window.
    const res2 = select(&r, 1230 * MS, .{});
    try testing.expect(res2 == .stale);
    // Longer window accepts them.
    const res3 = select(&r, 1230 * MS, .{ .window_ms = 250 });
    try testing.expect(res3 == .ok);
}

test "single fresh sample is not enough (min_samples)" {
    var r = Ring{};
    fill(&r, &.{.{ 1000, 0.5, 0.5 }});
    try testing.expect(select(&r, 1010 * MS, .{}) == .unstable);
    try testing.expect(select(&r, 1010 * MS, .{ .min_samples = 1 }) == .ok);
}

test "ring wraps" {
    var r = Ring{};
    var k: usize = 0;
    while (k < CAP * 3 + 5) : (k += 1) {
        const t: f64 = @floatFromInt(k * 30);
        r.push(.{ .t_ns = @as(i64, @intFromFloat(t)) * MS, .x = if (k % 2 == 0) 0.6 else 0.61, .y = 0.3, .view_mm = 650 });
    }
    // 10 ms after the newest sample: ages 10, 40, 70, 100, 130 ms are in the window.
    const now: i64 = (@as(i64, @intCast((CAP * 3 + 4) * 30)) + 10) * MS;
    const res = select(&r, now, .{});
    try testing.expectEqual(@as(usize, 5), res.ok.n);
    try testing.expectApproxEqAbs(@as(f64, 0.6), res.ok.x, 1e-9); // 3×0.6 (even k) vs 2×0.61
}
