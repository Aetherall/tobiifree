// correction.zig — host-side residual correction map ("vector map").
//
// After the device calibration a systematic on-screen drift remains (some
// screen regions are consistently off by 10–20 mm). The setup tool measures
// it at the validation dots: for each dot the robust gaze position g (median
// of the fixation samples, normalised display coords) and the target t. The
// residual r = (g - t) in mm is interpolated over the screen by a smoothing
// thin-plate spline, fitted at the *gaze* positions, so that
//
//     corrected(g) = g - r(g)          (r in mm, converted with the area size)
//
// maps every measured gaze point back near its target.
//
// Model (per component x, y; coordinates in units of SCALE_MM):
//     f(p) = a0 + a1 x + a2 y + Σ w_i U(|p - p_i|),  U(r) = r² ln r
// smoothing: (K + n λ I) w + P a = v,  Pᵀ w = 0. λ is chosen by leave-one-out
// cross-validation on a fixed grid (LAMBDAS), never below LAMBDA_MIN, so one
// noisy dot cannot bend the field; λ → ∞ gives the least-squares plane.
//
// Safety: |correction| is capped (cap_mm), and the correction fades to zero
// (smoothstep) within fade_mm outside the convex hull of the control points:
// no extrapolation far from where it was measured (screen margins, off-screen
// gaze).
//
// The daemon samples a precomputed grid (Grid, bilinear) per gaze sample.
// The stored file (File, JSON) holds the control points, not the grid: both
// sides refit the same model from it (deterministic).
//
// No dependencies besides std (shared by tobiifreed and tobiifree-setup).

const std = @import("std");

pub const SCALE_MM = 100.0;
pub const MAX_POINTS = 64;
pub const MIN_POINTS = 6;

pub const DEFAULT_CAP_MM = 30.0;
pub const DEFAULT_FADE_MM = 60.0;

/// Candidate λ (coordinates in SCALE_MM units). LOOCV picks one.
pub const LAMBDAS = [_]f64{ 3e-3, 0.01, 0.03, 0.1, 0.3, 1, 3, 10, 100 };
pub const LAMBDA_MIN = 3e-3;

pub const FILE_VERSION = 1;

/// One measured dot, normalised display coordinates (origin top-left).
pub const Point = struct {
    tx: f64,
    ty: f64,
    gx: f64,
    gy: f64,
    n: u32 = 0,
};

pub const Params = struct {
    lambda: f64,
    cap_mm: f64 = DEFAULT_CAP_MM,
    fade_mm: f64 = DEFAULT_FADE_MM,
};

// ── Thin-plate spline ───────────────────────────────────────────────

fn kernel(r2: f64) f64 {
    return if (r2 <= 1e-300) 0 else 0.5 * r2 * @log(r2);
}

pub const Tps = struct {
    n: usize = 0,
    px: [MAX_POINTS]f64 = undefined,
    py: [MAX_POINTS]f64 = undefined,
    wx: [MAX_POINTS]f64 = undefined,
    wy: [MAX_POINTS]f64 = undefined,
    ax: [3]f64 = .{ 0, 0, 0 },
    ay: [3]f64 = .{ 0, 0, 0 },

    /// Value at (x, y) (SCALE_MM units) → (vx, vy).
    pub fn eval(self: *const Tps, x: f64, y: f64) [2]f64 {
        var vx = self.ax[0] + self.ax[1] * x + self.ax[2] * y;
        var vy = self.ay[0] + self.ay[1] * x + self.ay[2] * y;
        for (0..self.n) |i| {
            const dx = x - self.px[i];
            const dy = y - self.py[i];
            const u = kernel(dx * dx + dy * dy);
            vx += self.wx[i] * u;
            vy += self.wy[i] * u;
        }
        return .{ vx, vy };
    }
};

pub const FitError = error{ TooFewPoints, TooManyPoints, Singular };

/// Smoothing TPS through (xs, ys) → (vx, vy).
pub fn fitTps(xs: []const f64, ys: []const f64, vx: []const f64, vy: []const f64, lambda: f64) FitError!Tps {
    const n = xs.len;
    if (n < 3) return error.TooFewPoints;
    if (n > MAX_POINTS) return error.TooManyPoints;
    const m = n + 3;
    // Augmented [M | bx by], row-major, m × (m + 2).
    var a: [(MAX_POINTS + 3) * (MAX_POINTS + 5)]f64 = undefined;
    const cols = m + 2;
    @memset(a[0 .. m * cols], 0);
    for (0..n) |i| {
        for (0..n) |j| {
            const dx = xs[i] - xs[j];
            const dy = ys[i] - ys[j];
            a[i * cols + j] = kernel(dx * dx + dy * dy);
        }
        a[i * cols + i] += @as(f64, @floatFromInt(n)) * lambda;
        a[i * cols + n] = 1;
        a[i * cols + n + 1] = xs[i];
        a[i * cols + n + 2] = ys[i];
        a[n * cols + i] = 1;
        a[(n + 1) * cols + i] = xs[i];
        a[(n + 2) * cols + i] = ys[i];
        a[i * cols + m] = vx[i];
        a[i * cols + m + 1] = vy[i];
    }
    // Gaussian elimination with partial pivoting.
    for (0..m) |k| {
        var piv = k;
        var best = @abs(a[k * cols + k]);
        for (k + 1..m) |r| {
            const v = @abs(a[r * cols + k]);
            if (v > best) {
                best = v;
                piv = r;
            }
        }
        if (best < 1e-12) return error.Singular;
        if (piv != k) for (0..cols) |c| std.mem.swap(f64, &a[k * cols + c], &a[piv * cols + c]);
        const d = a[k * cols + k];
        for (k + 1..m) |r| {
            const f = a[r * cols + k] / d;
            if (f == 0) continue;
            for (k..cols) |c| a[r * cols + c] -= f * a[k * cols + c];
        }
    }
    var sol: [MAX_POINTS + 3][2]f64 = undefined;
    var k = m;
    while (k > 0) {
        k -= 1;
        for (0..2) |rhs| {
            var s = a[k * cols + m + rhs];
            for (k + 1..m) |c| s -= a[k * cols + c] * sol[c][rhs];
            sol[k][rhs] = s / a[k * cols + k];
        }
    }
    var t = Tps{ .n = n };
    for (0..n) |i| {
        t.px[i] = xs[i];
        t.py[i] = ys[i];
        t.wx[i] = sol[i][0];
        t.wy[i] = sol[i][1];
    }
    t.ax = .{ sol[n][0], sol[n + 1][0], sol[n + 2][0] };
    t.ay = .{ sol[n][1], sol[n + 1][1], sol[n + 2][1] };
    return t;
}

/// Sum of squared leave-one-out prediction errors for one λ.
fn looScore(xs: []const f64, ys: []const f64, vx: []const f64, vy: []const f64, lambda: f64) ?f64 {
    const n = xs.len;
    var bx: [MAX_POINTS]f64 = undefined;
    var by: [MAX_POINTS]f64 = undefined;
    var bvx: [MAX_POINTS]f64 = undefined;
    var bvy: [MAX_POINTS]f64 = undefined;
    var sum: f64 = 0;
    for (0..n) |i| {
        var k: usize = 0;
        for (0..n) |j| {
            if (j == i) continue;
            bx[k] = xs[j];
            by[k] = ys[j];
            bvx[k] = vx[j];
            bvy[k] = vy[j];
            k += 1;
        }
        const t = fitTps(bx[0..k], by[0..k], bvx[0..k], bvy[0..k], lambda) catch return null;
        const p = t.eval(xs[i], ys[i]);
        sum += (p[0] - vx[i]) * (p[0] - vx[i]) + (p[1] - vy[i]) * (p[1] - vy[i]);
    }
    return sum;
}

/// λ from LAMBDAS minimising the leave-one-out error (ties → larger λ).
pub fn chooseLambda(xs: []const f64, ys: []const f64, vx: []const f64, vy: []const f64) f64 {
    var best: f64 = LAMBDAS[LAMBDAS.len - 1];
    var best_score = std.math.inf(f64);
    for (LAMBDAS) |l| {
        const s = looScore(xs, ys, vx, vy, l) orelse continue;
        if (s < best_score * (1 - 1e-9)) {
            best_score = s;
            best = l;
        }
    }
    return @max(best, LAMBDA_MIN);
}

// ── Convex hull (fade region) ───────────────────────────────────────

pub const Hull = struct {
    n: usize = 0,
    x: [MAX_POINTS]f64 = undefined,
    y: [MAX_POINTS]f64 = undefined,

    /// Andrew's monotone chain, counter-clockwise (y up or down: only the
    /// orientation sign matters and is handled in `outside`).
    pub fn of(xs: []const f64, ys: []const f64) Hull {
        var idx: [MAX_POINTS]usize = undefined;
        const n = @min(xs.len, MAX_POINTS);
        for (0..n) |i| idx[i] = i;
        const Ctx = struct {
            xs: []const f64,
            ys: []const f64,
            fn lt(c: @This(), a: usize, b: usize) bool {
                return c.xs[a] < c.xs[b] or (c.xs[a] == c.xs[b] and c.ys[a] < c.ys[b]);
            }
        };
        std.mem.sort(usize, idx[0..n], Ctx{ .xs = xs, .ys = ys }, Ctx.lt);
        var h: [2 * MAX_POINTS]usize = undefined;
        var k: usize = 0;
        for (0..n) |ii| {
            const i = idx[ii];
            while (k >= 2 and cross(xs, ys, h[k - 2], h[k - 1], i) <= 0) k -= 1;
            h[k] = i;
            k += 1;
        }
        const lower = k + 1;
        var ii = n;
        while (ii > 1) {
            ii -= 1;
            const i = idx[ii - 1];
            while (k >= lower and cross(xs, ys, h[k - 2], h[k - 1], i) <= 0) k -= 1;
            h[k] = i;
            k += 1;
        }
        var out = Hull{};
        out.n = if (k > 1) k - 1 else k;
        for (0..out.n) |i| {
            out.x[i] = xs[h[i]];
            out.y[i] = ys[h[i]];
        }
        return out;
    }

    fn cross(xs: []const f64, ys: []const f64, o: usize, a: usize, b: usize) f64 {
        return (xs[a] - xs[o]) * (ys[b] - ys[o]) - (ys[a] - ys[o]) * (xs[b] - xs[o]);
    }

    /// Distance from (x, y) to the hull, 0 inside.
    pub fn outside(self: *const Hull, x: f64, y: f64) f64 {
        if (self.n < 3) return 0;
        var inside = true;
        var dmin = std.math.inf(f64);
        for (0..self.n) |i| {
            const j = (i + 1) % self.n;
            const ex = self.x[j] - self.x[i];
            const ey = self.y[j] - self.y[i];
            const c = ex * (y - self.y[i]) - ey * (x - self.x[i]);
            if (c < 0) inside = false;
            const l2 = ex * ex + ey * ey;
            const t = if (l2 > 0) std.math.clamp(((x - self.x[i]) * ex + (y - self.y[i]) * ey) / l2, 0, 1) else 0;
            dmin = @min(dmin, std.math.hypot(x - (self.x[i] + t * ex), y - (self.y[i] + t * ey)));
        }
        return if (inside) 0 else dmin;
    }
};

// ── Map ─────────────────────────────────────────────────────────────

pub const Map = struct {
    w_mm: f64,
    h_mm: f64,
    params: Params,
    tps: Tps,
    hull: Hull, // in mm

    /// Fit on `points` (residual at the gaze positions). `params.lambda` is
    /// used as given (see chooseLambda / build). `hull_points`, if given,
    /// defines the fade region instead of `points` (leave-one-out uses the
    /// hull of the whole design so that a left-out edge dot is not faded).
    pub fn fit(points: []const Point, w_mm: f64, h_mm: f64, params: Params, hull_points: ?[]const Point) FitError!Map {
        if (points.len < MIN_POINTS) return error.TooFewPoints;
        if (points.len > MAX_POINTS) return error.TooManyPoints;
        var xs: [MAX_POINTS]f64 = undefined;
        var ys: [MAX_POINTS]f64 = undefined;
        var vx: [MAX_POINTS]f64 = undefined;
        var vy: [MAX_POINTS]f64 = undefined;
        const n = toArrays(points, w_mm, h_mm, &xs, &ys, &vx, &vy);
        const tps = try fitTps(xs[0..n], ys[0..n], vx[0..n], vy[0..n], params.lambda);
        const hp = hull_points orelse points;
        var hx: [MAX_POINTS]f64 = undefined;
        var hy: [MAX_POINTS]f64 = undefined;
        const hn = @min(hp.len, MAX_POINTS);
        for (hp[0..hn], 0..) |p, i| {
            hx[i] = p.gx * w_mm;
            hy[i] = p.gy * h_mm;
        }
        return .{ .w_mm = w_mm, .h_mm = h_mm, .params = params, .tps = tps, .hull = Hull.of(hx[0..hn], hy[0..hn]) };
    }

    /// Fit with λ chosen by leave-one-out cross-validation.
    pub fn build(points: []const Point, w_mm: f64, h_mm: f64, cap_mm: f64, fade_mm: f64, hull_points: ?[]const Point) FitError!Map {
        if (points.len < MIN_POINTS) return error.TooFewPoints;
        if (points.len > MAX_POINTS) return error.TooManyPoints;
        var xs: [MAX_POINTS]f64 = undefined;
        var ys: [MAX_POINTS]f64 = undefined;
        var vx: [MAX_POINTS]f64 = undefined;
        var vy: [MAX_POINTS]f64 = undefined;
        const n = toArrays(points, w_mm, h_mm, &xs, &ys, &vx, &vy);
        const l = chooseLambda(xs[0..n], ys[0..n], vx[0..n], vy[0..n]);
        return fit(points, w_mm, h_mm, .{ .lambda = l, .cap_mm = cap_mm, .fade_mm = fade_mm }, hull_points);
    }

    /// Estimated residual (mm, gaze - target) at gaze (gx, gy), capped and
    /// faded outside the hull.
    pub fn residualMm(self: *const Map, gx: f64, gy: f64) [2]f64 {
        const xm = gx * self.w_mm;
        const ym = gy * self.h_mm;
        var r = self.tps.eval(xm / SCALE_MM, ym / SCALE_MM);
        const mag = std.math.hypot(r[0], r[1]);
        if (mag > self.params.cap_mm and mag > 0) {
            r[0] *= self.params.cap_mm / mag;
            r[1] *= self.params.cap_mm / mag;
        }
        const d = self.hull.outside(xm, ym);
        if (d > 0) {
            const t = std.math.clamp(1 - d / self.params.fade_mm, 0, 1);
            const wgt = t * t * (3 - 2 * t);
            r[0] *= wgt;
            r[1] *= wgt;
        }
        return r;
    }

    /// Corrected normalised gaze.
    pub fn correct(self: *const Map, gx: f64, gy: f64) [2]f64 {
        const r = self.residualMm(gx, gy);
        return .{ gx - r[0] / self.w_mm, gy - r[1] / self.h_mm };
    }
};

fn toArrays(points: []const Point, w_mm: f64, h_mm: f64, xs: *[MAX_POINTS]f64, ys: *[MAX_POINTS]f64, vx: *[MAX_POINTS]f64, vy: *[MAX_POINTS]f64) usize {
    for (points, 0..) |p, i| {
        xs[i] = p.gx * w_mm / SCALE_MM;
        ys[i] = p.gy * h_mm / SCALE_MM;
        vx[i] = (p.gx - p.tx) * w_mm;
        vy[i] = (p.gy - p.ty) * h_mm;
    }
    return points.len;
}

/// Leave-one-out: for each point, the residual (mm) predicted at its gaze
/// position by a map fitted on all the others (λ chosen on those others too),
/// with the fade region of the whole set. out[i] = null if that fit failed.
pub fn leaveOneOut(points: []const Point, w_mm: f64, h_mm: f64, cap_mm: f64, fade_mm: f64, out: []?[2]f64) void {
    var others: [MAX_POINTS]Point = undefined;
    for (points, 0..) |p, i| {
        var k: usize = 0;
        for (points, 0..) |q, j| {
            if (j == i) continue;
            others[k] = q;
            k += 1;
        }
        const m = Map.build(others[0..k], w_mm, h_mm, cap_mm, fade_mm, points) catch {
            out[i] = null;
            continue;
        };
        out[i] = m.residualMm(p.gx, p.gy);
    }
}

// ── Grid (daemon, per sample) ───────────────────────────────────────

pub const GRID_NX = 72;
pub const GRID_NY = 48;
pub const GRID_MIN = -0.2;
pub const GRID_MAX = 1.2;

/// Correction (normalised delta to subtract) on a regular grid over
/// [GRID_MIN, GRID_MAX]² of normalised gaze, bilinear sampled.
pub const Grid = struct {
    dx: [GRID_NX * GRID_NY]f32,
    dy: [GRID_NX * GRID_NY]f32,

    pub fn init(self: *Grid, map: *const Map) void {
        const step_x = (GRID_MAX - GRID_MIN) / @as(f64, GRID_NX - 1);
        const step_y = (GRID_MAX - GRID_MIN) / @as(f64, GRID_NY - 1);
        for (0..GRID_NY) |j| {
            for (0..GRID_NX) |i| {
                const gx = GRID_MIN + step_x * @as(f64, @floatFromInt(i));
                const gy = GRID_MIN + step_y * @as(f64, @floatFromInt(j));
                const r = map.residualMm(gx, gy);
                self.dx[j * GRID_NX + i] = @floatCast(r[0] / map.w_mm);
                self.dy[j * GRID_NX + i] = @floatCast(r[1] / map.h_mm);
            }
        }
    }

    /// Normalised delta at (gx, gy) (to subtract), or null outside the grid
    /// or for non-finite input.
    pub fn sample(self: *const Grid, gx: f64, gy: f64) ?[2]f64 {
        if (!std.math.isFinite(gx) or !std.math.isFinite(gy)) return null;
        const fx = (gx - GRID_MIN) / (GRID_MAX - GRID_MIN) * @as(f64, GRID_NX - 1);
        const fy = (gy - GRID_MIN) / (GRID_MAX - GRID_MIN) * @as(f64, GRID_NY - 1);
        if (fx < 0 or fy < 0 or fx > GRID_NX - 1 or fy > GRID_NY - 1) return null;
        const i: usize = @min(@as(usize, @intFromFloat(fx)), GRID_NX - 2);
        const j: usize = @min(@as(usize, @intFromFloat(fy)), GRID_NY - 2);
        const u = fx - @as(f64, @floatFromInt(i));
        const v = fy - @as(f64, @floatFromInt(j));
        const k = j * GRID_NX + i;
        const bil = struct {
            fn f(a: []const f32, kk: usize, uu: f64, vv: f64) f64 {
                const a00: f64 = a[kk];
                const a10: f64 = a[kk + 1];
                const a01: f64 = a[kk + GRID_NX];
                const a11: f64 = a[kk + GRID_NX + 1];
                return (a00 * (1 - uu) + a10 * uu) * (1 - vv) + (a01 * (1 - uu) + a11 * uu) * vv;
            }
        }.f;
        return .{ bil(&self.dx, k, u, v), bil(&self.dy, k, u, v) };
    }
};

// ── File (JSON) ─────────────────────────────────────────────────────

pub const FilePoint = struct {
    target: [2]f64,
    gaze: [2]f64,
    n: u32 = 0,
};

pub const Stats = struct {
    dots: u32 = 0,
    mean_raw_deg: f64 = 0,
    max_raw_deg: f64 = 0,
    mean_loo_deg: f64 = 0,
    max_loo_deg: f64 = 0,
    /// Validation runs pooled into the control points.
    runs: u32 = 1,
};

/// $XDG_STATE_HOME/tobiifree/correction.json
pub const File = struct {
    version: u32 = FILE_VERSION,
    /// SHA-256 (hex) of the calibration blob the residuals were measured with.
    calibration_sha256: []const u8,
    /// Display area (TL, TR, BL corners, mm) the residuals were measured with.
    display_area: [9]f64,
    lambda: f64,
    cap_mm: f64 = DEFAULT_CAP_MM,
    fade_mm: f64 = DEFAULT_FADE_MM,
    points: []const FilePoint,
    stats: ?Stats = null,
    created_unix: i64 = 0,

    pub fn areaSize(self: *const File) [2]f64 {
        const c = self.display_area;
        return .{ std.math.hypot(c[3] - c[0], c[4] - c[1]), std.math.hypot(c[0] - c[6], c[1] - c[7]) };
    }

    /// Refit the model described by the file.
    pub fn map(self: *const File) FitError!Map {
        var pts: [MAX_POINTS]Point = undefined;
        if (self.points.len > MAX_POINTS) return error.TooManyPoints;
        for (self.points, 0..) |p, i| pts[i] = .{ .tx = p.target[0], .ty = p.target[1], .gx = p.gaze[0], .gy = p.gaze[1], .n = p.n };
        const s = self.areaSize();
        return Map.fit(pts[0..self.points.len], s[0], s[1], .{ .lambda = self.lambda, .cap_mm = self.cap_mm, .fade_mm = self.fade_mm }, null);
    }

    pub fn stringify(self: *const File, gpa: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(gpa, self.*, .{ .whitespace = .indent_1 });
    }
};

pub fn parseFile(gpa: std.mem.Allocator, text: []const u8) !std.json.Parsed(File) {
    const p = try std.json.parseFromSlice(File, gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer p.deinit();
    if (p.value.version != FILE_VERSION) return error.UnsupportedVersion;
    if (p.value.calibration_sha256.len != 64) return error.BadHash;
    const s = p.value.areaSize();
    if (!(s[0] > 10 and s[1] > 10)) return error.BadArea;
    if (!(p.value.lambda > 0) or !(p.value.cap_mm > 0) or !(p.value.fade_mm > 0)) return error.BadParams;
    return p;
}

// ── Validation history (runs pooled into one map) ───────────────────
//
// $XDG_STATE_HOME/tobiifree/correction_runs.json, written by the setup tool
// after every validation: the per-dot raw medians of each run made with one
// calibration blob on one display area. The map is fitted on the per-target
// pool of all runs (pool()). tobiifreed deletes the file whenever it deletes
// a map for a blob / area change; a history for another blob or area is
// ignored (and replaced) by the tool.

pub const HISTORY_VERSION = 1;
pub const MAX_RUNS = 20;

pub const Run = struct {
    created_unix: i64 = 0,
    /// Usable dots of the run (fixation near the dot): target, median gaze.
    dots: []const FilePoint,
};

pub const History = struct {
    version: u32 = HISTORY_VERSION,
    calibration_sha256: []const u8,
    display_area: [9]f64,
    runs: []const Run,

    pub fn stringify(self: *const History, gpa: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(gpa, self.*, .{ .whitespace = .indent_1 });
    }

    /// Made with this blob on this area?
    pub fn matches(self: *const History, calibration_sha256: []const u8, area: [9]f64) bool {
        return std.mem.eql(u8, self.calibration_sha256, calibration_sha256) and areaMatches(self.display_area, area);
    }
};

pub fn parseHistory(gpa: std.mem.Allocator, text: []const u8) !std.json.Parsed(History) {
    const p = try std.json.parseFromSlice(History, gpa, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer p.deinit();
    if (p.value.version != HISTORY_VERSION) return error.UnsupportedVersion;
    if (p.value.calibration_sha256.len != 64) return error.BadHash;
    return p;
}

fn sameTarget(a: [2]f64, b: [2]f64) bool {
    return @abs(a[0] - b[0]) < 1e-4 and @abs(a[1] - b[1]) < 1e-4;
}

/// Robust mean: median for 3+ values, mean otherwise. Reorders `xs`.
fn robustMean(xs: []f64) f64 {
    if (xs.len == 0) return 0;
    if (xs.len < 3) {
        var s: f64 = 0;
        for (xs) |x| s += x;
        return s / @as(f64, @floatFromInt(xs.len));
    }
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    const m = xs.len / 2;
    return if (xs.len % 2 == 1) xs[m] else (xs[m - 1] + xs[m]) / 2;
}

/// Per-target pool of the runs: one Point per distinct target, gaze = robust
/// mean of the runs' median gaze (x and y separately), n = total samples.
/// Returns the number of points written to `out`.
pub fn pool(runs: []const Run, out: []Point) usize {
    var n: usize = 0;
    var gx: [MAX_RUNS * 4]f64 = undefined;
    var gy: [MAX_RUNS * 4]f64 = undefined;
    for (runs) |run| for (run.dots) |d| {
        var seen = false;
        for (out[0..n]) |q| if (sameTarget(.{ q.tx, q.ty }, d.target)) {
            seen = true;
        };
        if (seen or n == out.len) continue;
        var k: usize = 0;
        var samples: u32 = 0;
        for (runs) |r2| for (r2.dots) |d2| {
            if (!sameTarget(d.target, d2.target) or k == gx.len) continue;
            gx[k] = d2.gaze[0];
            gy[k] = d2.gaze[1];
            samples += d2.n;
            k += 1;
        };
        out[n] = .{ .tx = d.target[0], .ty = d.target[1], .gx = robustMean(gx[0..k]), .gy = robustMean(gy[0..k]), .n = samples };
        n += 1;
    };
    return n;
}

pub fn sha256Hex(data: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// Same display area (within 0.01 mm per coordinate).
pub fn areaMatches(a: [9]f64, b: [9]f64) bool {
    for (a, b) |x, y| if (@abs(x - y) > 0.01) return false;
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const W = 531.0;
const H = 299.0;

const GRID4 = [_]f64{ 0.1, 0.3667, 0.6333, 0.9 };

/// 4×4 validation design with gaze = target + field(target) (mm) + noise.
fn design(field: *const fn (f64, f64) [2]f64, noise_mm: f64, seed: u64) [16]Point {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var pts: [16]Point = undefined;
    for (GRID4, 0..) |ty, j| for (GRID4, 0..) |tx, i| {
        const r = field(tx * W, ty * H);
        pts[j * 4 + i] = .{
            .tx = tx,
            .ty = ty,
            .gx = tx + (r[0] + noise_mm * rnd.floatNorm(f64)) / W,
            .gy = ty + (r[1] + noise_mm * rnd.floatNorm(f64)) / H,
        };
    };
    return pts;
}

/// Mean error (mm) after correction at fresh (off-design) targets.
fn heldOutError(m: *const Map, field: *const fn (f64, f64) [2]f64) f64 {
    var sum: f64 = 0;
    var n: f64 = 0;
    for ([_]f64{ 0.2, 0.5, 0.8 }) |ty| for ([_]f64{ 0.2, 0.5, 0.8 }) |tx| {
        const r = field(tx * W, ty * H);
        const g = [2]f64{ tx + r[0] / W, ty + r[1] / H };
        const cg = m.correct(g[0], g[1]);
        sum += std.math.hypot((cg[0] - tx) * W, (cg[1] - ty) * H);
        n += 1;
    };
    return sum / n;
}

fn constField(_: f64, _: f64) [2]f64 {
    return .{ 6, -9 };
}
fn linearField(x: f64, y: f64) [2]f64 {
    return .{ 0.02 * x - 5, -0.03 * y + 4 };
}
fn bumpField(x: f64, y: f64) [2]f64 {
    // Smooth 15 mm downward bump around the upper-right region.
    const dx = (x - 0.85 * W) / 150;
    const dy = (y - 0.15 * H) / 100;
    return .{ 0, 15 * @exp(-(dx * dx + dy * dy)) };
}
fn zeroField(_: f64, _: f64) [2]f64 {
    return .{ 0, 0 };
}

test "tps reproduces an affine field exactly" {
    const pts = design(linearField, 0, 1);
    const m = try Map.build(&pts, W, H, 100, DEFAULT_FADE_MM, null);
    for (pts) |p| {
        const c = m.correct(p.gx, p.gy);
        try testing.expectApproxEqAbs(p.tx, c[0], 0.002);
        try testing.expectApproxEqAbs(p.ty, c[1], 0.002);
    }
    try testing.expect(heldOutError(&m, linearField) < 1.0);
}

test "constant offset is removed" {
    const pts = design(constField, 0, 2);
    const m = try Map.build(&pts, W, H, DEFAULT_CAP_MM, DEFAULT_FADE_MM, null);
    try testing.expect(heldOutError(&m, constField) < 0.05);
}

test "local bump is followed, noise is not" {
    const pts = design(bumpField, 0.5, 3);
    const m = try Map.build(&pts, W, H, DEFAULT_CAP_MM, DEFAULT_FADE_MM, null);
    // Uncorrected mean error at the held-out points vs corrected.
    const raw = blk: {
        var sum: f64 = 0;
        for ([_]f64{ 0.2, 0.5, 0.8 }) |ty| for ([_]f64{ 0.2, 0.5, 0.8 }) |tx| {
            const r = bumpField(tx * W, ty * H);
            sum += std.math.hypot(r[0], r[1]);
        };
        break :blk sum / 9;
    };
    try testing.expect(heldOutError(&m, bumpField) < raw * 0.6);
    // At the bump centre the correction is substantial.
    const r = m.residualMm(0.85, 0.15 + 15.0 / H);
    try testing.expect(r[1] > 8);
}

test "one noisy dot does not bend the map" {
    var pts = design(zeroField, 0, 4);
    pts[5].gy += 20.0 / H; // one outlier, 20 mm, inner dot
    const m = try Map.build(&pts, W, H, DEFAULT_CAP_MM, DEFAULT_FADE_MM, null);
    // Large λ chosen: correction at the outlier and its neighbours stays small.
    try testing.expect(m.params.lambda >= 0.3);
    try testing.expect(@abs(m.residualMm(pts[5].gx, pts[5].gy)[1]) < 6);
    try testing.expect(@abs(m.residualMm(pts[6].gx, pts[6].gy)[1]) < 4);
}

test "pure noise: leave-one-out does not claim an improvement" {
    const pts = design(zeroField, 3, 5);
    var loo: [16]?[2]f64 = undefined;
    leaveOneOut(&pts, W, H, DEFAULT_CAP_MM, DEFAULT_FADE_MM, &loo);
    var raw: f64 = 0;
    var cor: f64 = 0;
    for (pts, loo) |p, l| {
        const rx = (p.gx - p.tx) * W;
        const ry = (p.gy - p.ty) * H;
        raw += std.math.hypot(rx, ry);
        cor += std.math.hypot(rx - l.?[0], ry - l.?[1]);
    }
    try testing.expect(cor > raw * 0.95);
}

test "systematic field: leave-one-out shows the improvement" {
    const pts = design(linearField, 1.0, 6);
    var loo: [16]?[2]f64 = undefined;
    leaveOneOut(&pts, W, H, DEFAULT_CAP_MM, DEFAULT_FADE_MM, &loo);
    var raw: f64 = 0;
    var cor: f64 = 0;
    for (pts, loo) |p, l| {
        const rx = (p.gx - p.tx) * W;
        const ry = (p.gy - p.ty) * H;
        raw += std.math.hypot(rx, ry);
        cor += std.math.hypot(rx - l.?[0], ry - l.?[1]);
    }
    try testing.expect(cor < raw * 0.4);
}

test "cap and fade" {
    var pts = design(constField, 0, 7);
    for (&pts) |*p| p.gy = p.ty + 80.0 / H; // 80 mm offset everywhere
    const m = try Map.build(&pts, W, H, 30, 60, null);
    const in = m.residualMm(0.5, 0.5 + 80.0 / H);
    try testing.expectApproxEqAbs(@as(f64, 30), std.math.hypot(in[0], in[1]), 1e-6);
    // Far outside the hull (off screen): no correction.
    const out = m.residualMm(1.5, 0.5);
    try testing.expectEqual(@as(f64, 0), std.math.hypot(out[0], out[1]));
    // Half way into the fade band: partial.
    const hx = (0.9 * W + 30) / W;
    const half = m.residualMm(hx, 0.5 + 80.0 / H);
    const mag = std.math.hypot(half[0], half[1]);
    try testing.expect(mag > 5 and mag < 25);
}

test "grid matches the map" {
    const pts = design(bumpField, 0, 8);
    const m = try Map.build(&pts, W, H, DEFAULT_CAP_MM, DEFAULT_FADE_MM, null);
    const g = try testing.allocator.create(Grid);
    defer testing.allocator.destroy(g);
    g.init(&m);
    for ([_][2]f64{ .{ 0.5, 0.5 }, .{ 0.83, 0.2 }, .{ 0.12, 0.88 }, .{ 0.95, 0.05 } }) |q| {
        const s = g.sample(q[0], q[1]).?;
        const r = m.residualMm(q[0], q[1]);
        try testing.expectApproxEqAbs(r[0], s[0] * W, 0.6);
        try testing.expectApproxEqAbs(r[1], s[1] * H, 0.6);
    }
    try testing.expect(g.sample(-0.5, 0.5) == null);
    try testing.expect(g.sample(std.math.nan(f64), 0.5) == null);
}

test "file round trip and refit" {
    const pts = design(bumpField, 0.5, 9);
    const m = try Map.build(&pts, W, H, DEFAULT_CAP_MM, DEFAULT_FADE_MM, null);
    var fps: [16]FilePoint = undefined;
    for (pts, 0..) |p, i| fps[i] = .{ .target = .{ p.tx, p.ty }, .gaze = .{ p.gx, p.gy }, .n = 30 };
    const hash = sha256Hex("blob");
    const f = File{
        .calibration_sha256 = &hash,
        .display_area = .{ -233.184, 308.741, 0, 297.911, 308.741, 0, -233.184, 10, 0 },
        .lambda = m.params.lambda,
        .points = &fps,
        .stats = .{ .dots = 16, .mean_raw_deg = 0.6, .mean_loo_deg = 0.4 },
    };
    const text = try f.stringify(testing.allocator);
    defer testing.allocator.free(text);
    const p = try parseFile(testing.allocator, text);
    defer p.deinit();
    try testing.expectEqualStrings(&hash, p.value.calibration_sha256);
    try testing.expect(areaMatches(f.display_area, p.value.display_area));
    const m2 = try p.value.map();
    const a = m.residualMm(0.8, 0.2);
    const b = m2.residualMm(0.8, 0.2);
    // Area size from the corners (531.095 × 298.741) vs W×H here: close.
    try testing.expectApproxEqAbs(a[1], b[1], 0.5);
    try testing.expectError(error.BadHash, parseFile(testing.allocator,
        \\{"calibration_sha256":"ab","display_area":[0,300,0,500,300,0,0,10,0],"lambda":1,"points":[]}
    ));
}

test "history: pool per target, robust to one bad run" {
    const a = [_]FilePoint{ .{ .target = .{ 0.1, 0.1 }, .gaze = .{ 0.11, 0.12 }, .n = 30 }, .{ .target = .{ 0.9, 0.9 }, .gaze = .{ 0.9, 0.95 }, .n = 30 } };
    const b = [_]FilePoint{ .{ .target = .{ 0.1, 0.1 }, .gaze = .{ 0.13, 0.12 }, .n = 30 }, .{ .target = .{ 0.9, 0.9 }, .gaze = .{ 0.9, 0.93 }, .n = 30 } };
    const bad = [_]FilePoint{.{ .target = .{ 0.1, 0.1 }, .gaze = .{ 0.5, 0.5 }, .n = 30 }};
    var out: [8]Point = undefined;
    // Two runs: mean.
    const runs2 = [_]Run{ .{ .dots = &a }, .{ .dots = &b } };
    try testing.expectEqual(@as(usize, 2), pool(&runs2, &out));
    try testing.expectApproxEqAbs(@as(f64, 0.12), out[0].gx, 1e-12);
    try testing.expectEqual(@as(u32, 60), out[0].n);
    try testing.expectApproxEqAbs(@as(f64, 0.94), out[1].gy, 1e-12);
    // Three runs, one wild: median ignores it.
    const runs3 = [_]Run{ .{ .dots = &a }, .{ .dots = &b }, .{ .dots = &bad } };
    try testing.expectEqual(@as(usize, 2), pool(&runs3, &out));
    try testing.expectApproxEqAbs(@as(f64, 0.13), out[0].gx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.12), out[0].gy, 1e-12);
    // A target only some runs have still pools.
    try testing.expectApproxEqAbs(@as(f64, 0.94), out[1].gy, 1e-12);
}

test "history round trip and matching" {
    const a = [_]FilePoint{.{ .target = .{ 0.1, 0.1 }, .gaze = .{ 0.11, 0.12 }, .n = 30 }};
    const runs = [_]Run{ .{ .created_unix = 1, .dots = &a }, .{ .created_unix = 2, .dots = &a } };
    const hash = sha256Hex("blob");
    const area: [9]f64 = .{ -233.184, 308.741, 0, 297.911, 308.741, 0, -233.184, 10, 0 };
    const h = History{ .calibration_sha256 = &hash, .display_area = area, .runs = &runs };
    const text = try h.stringify(testing.allocator);
    defer testing.allocator.free(text);
    const p = try parseHistory(testing.allocator, text);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.value.runs.len);
    try testing.expect(p.value.matches(&hash, area));
    try testing.expect(!p.value.matches(&sha256Hex("other"), area));
    var area2 = area;
    area2[7] = 30;
    try testing.expect(!p.value.matches(&hash, area2));
}

test "invalidation helpers" {
    const a: [9]f64 = .{ -233.184, 308.741, 0, 297.911, 308.741, 0, -233.184, 10, 0 };
    var b = a;
    try testing.expect(areaMatches(a, b));
    b[7] = 30; // gap changed
    try testing.expect(!areaMatches(a, b));
    try testing.expect(!std.mem.eql(u8, &sha256Hex("blob A"), &sha256Hex("blob B")));
    try testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &sha256Hex(""));
}
