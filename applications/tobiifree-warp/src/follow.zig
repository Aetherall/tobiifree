// follow.zig — cursor-follows-gaze while a key is held: the gaze filter, the
// cursor easing and the session (start/stop/timeout) logic. Pure, no I/O.
//
// Filter: fixation-aware, not a generic low-pass. Gaze is a sequence of
// fixations (eye still, ~0.3–0.5° of tracker noise at 33 Hz) joined by
// saccades (the eye jumps in < 1–2 samples). A cursor should sit still
// during a fixation and land on the next one at once:
//   - a sample within `radius_deg` of the current fixation joins it; the
//     target is the median of the fixation's last `window` samples, so the
//     noise shrinks as the fixation lasts and a slow drift (smooth pursuit,
//     head motion) is followed; the target only moves once the median has
//     drifted more than `deadband_deg` from it, so the cursor sits still
//     instead of crawling with the noise of the median;
//   - a sample outside starts a candidate; the candidate becomes the new
//     fixation once `confirm` consecutive samples agree with each other (an
//     isolated noise spike or blink artefact is dropped, a saccade costs one
//     extra sample ≈ 30 ms);
//   - invalid samples are simply not fed: the cursor holds.
// A One-Euro filter would trade jitter for lag continuously; with 33 Hz
// samples and 1–2-sample saccades its speed estimate is too coarse to both
// kill fixation jitter and not lag a saccade, which is the case the person
// uses this for (jump to what I look at).
//
// Easing: the cursor eases toward the target in screen space with an
// exponential time constant (fixation updates: `fix_tau_ms`, a new fixation:
// `saccade_tau_ms`, default 0 = land at once; the very first move:
// `first_tau_ms`), stepped at ~120 Hz between samples.

const std = @import("std");
const select = @import("select.zig");

pub const FilterParams = struct {
    radius_deg: f64 = 1.5,
    deadband_deg: f64 = 0.4,
    confirm: usize = 2,
    window: usize = 12,
};

pub const MAX_WINDOW = 64;
const MAX_CONFIRM = 8;

pub const Kind = enum {
    /// Same fixation, refined target.
    update,
    /// A new fixation (after a saccade, or the first one).
    new_fixation,
    /// Sample kept as a candidate or ignored: target unchanged.
    held,
};

pub const Event = struct { kind: Kind, target: ?[2]f64 };

pub const Filter = struct {
    p: FilterParams,
    sel: select.Params,
    fix: [MAX_WINDOW]select.Sample = undefined,
    fix_n: usize = 0, // total pushed into the current fixation
    has_fix: bool = false,
    centre: [2]f64 = .{ 0, 0 },
    cand: [MAX_CONFIRM]select.Sample = undefined,
    cand_n: usize = 0,

    pub fn init(p: FilterParams, sel: select.Params) Filter {
        var q = p;
        q.window = std.math.clamp(q.window, 1, MAX_WINDOW);
        q.confirm = std.math.clamp(q.confirm, 1, MAX_CONFIRM);
        return .{ .p = q, .sel = sel };
    }

    pub fn reset(self: *Filter) void {
        self.has_fix = false;
        self.fix_n = 0;
        self.cand_n = 0;
    }

    /// Start with a known fixation (e.g. the stable run at follow start).
    pub fn seed(self: *Filter, samples: []const select.Sample) [2]f64 {
        self.reset();
        for (samples) |s| self.pushFix(s);
        self.has_fix = true;
        self.centre = self.median();
        return self.centre;
    }

    pub fn update(self: *Filter, s: select.Sample) Event {
        if (self.has_fix and self.angleTo(s, self.centre) <= self.p.radius_deg) {
            self.cand_n = 0; // whatever was pending was a spike
            self.pushFix(s);
            const c = self.median();
            const probe = select.Sample{ .t_ns = s.t_ns, .x = c[0], .y = c[1], .view_mm = s.view_mm };
            if (self.angleTo(probe, self.centre) <= self.p.deadband_deg) return .{ .kind = .held, .target = self.centre };
            self.centre = c;
            return .{ .kind = .update, .target = c };
        }
        // Outside the fixation (or none yet): candidate for a new one.
        if (self.cand_n > 0) {
            for (self.cand[0..self.cand_n]) |c| {
                if (select.angleDeg(self.sel, s, c) > self.p.radius_deg) {
                    self.cand_n = 0; // still moving: restart from here
                    break;
                }
            }
        }
        self.cand[self.cand_n] = s;
        self.cand_n += 1;
        if (self.cand_n < self.p.confirm) return .{ .kind = .held, .target = null };
        const n = self.cand_n;
        var tmp: [MAX_CONFIRM]select.Sample = undefined;
        @memcpy(tmp[0..n], self.cand[0..n]);
        return .{ .kind = .new_fixation, .target = self.seed(tmp[0..n]) };
    }

    fn pushFix(self: *Filter, s: select.Sample) void {
        self.fix[self.fix_n % self.p.window] = s;
        self.fix_n += 1;
    }

    fn median(self: *const Filter) [2]f64 {
        const n = @min(self.fix_n, self.p.window);
        var xs: [MAX_WINDOW]f64 = undefined;
        var ys: [MAX_WINDOW]f64 = undefined;
        for (self.fix[0..n], 0..) |f, i| {
            xs[i] = f.x;
            ys[i] = f.y;
        }
        return .{ select.median(xs[0..n]), select.median(ys[0..n]) };
    }

    fn angleTo(self: *const Filter, s: select.Sample, c: [2]f64) f64 {
        return select.angleDeg(self.sel, s, .{ .t_ns = s.t_ns, .x = c[0], .y = c[1], .view_mm = s.view_mm });
    }
};

/// Exponential easing of the cursor (global logical px) toward a target.
pub const Easer = struct {
    pos: [2]f64,
    target: [2]f64,
    tau_ms: f64 = 0,

    pub fn init(pos: [2]f64) Easer {
        return .{ .pos = pos, .target = pos };
    }

    pub fn setTarget(self: *Easer, t: [2]f64, tau_ms: f64) void {
        self.target = t;
        self.tau_ms = tau_ms;
    }

    /// Advance by dt; true when at the target.
    pub fn step(self: *Easer, dt_ms: f64) bool {
        if (self.tau_ms <= 0) {
            self.pos = self.target;
        } else {
            const a = 1 - @exp(-@max(0, dt_ms) / self.tau_ms);
            for (0..2) |i| self.pos[i] += (self.target[i] - self.pos[i]) * a;
        }
        const dx = self.target[0] - self.pos[0];
        const dy = self.target[1] - self.pos[1];
        if (dx * dx + dy * dy < 0.25) { // within half a pixel: snap
            self.pos = self.target;
            return true;
        }
        return false;
    }

    pub fn done(self: *const Easer) bool {
        return self.pos[0] == self.target[0] and self.pos[1] == self.target[1];
    }

    /// Whole-pixel position to send.
    pub fn pixel(self: *const Easer) [2]f64 {
        return .{ @round(self.pos[0]), @round(self.pos[1]) };
    }
};

pub const EaseParams = struct {
    fix_tau_ms: f64 = 80,
    saccade_tau_ms: f64 = 0,
    first_tau_ms: f64 = 60,
    /// Interpolation step while easing.
    tick_ms: i64 = 8,
};

pub const StopReason = enum { release, timeout, daemon_lost, move_failed, superseded, exiting };

/// Follow session bookkeeping: the safety timeout for a missed release.
pub const Session = struct {
    started_ns: i64,
    timeout_ms: i64,
    dry: bool,
    moves: usize = 0,
    move_ns_sum: i64 = 0,
    move_ns_max: i64 = 0,
    /// Sample arrival → move done, summed over sample-triggered moves.
    lag_ns_sum: i64 = 0,
    lag_n: usize = 0,
    first_move_ns: ?i64 = null,

    pub fn deadline(self: Session) i64 {
        return self.started_ns + self.timeout_ms * std.time.ns_per_ms;
    }

    pub fn expired(self: Session, now_ns: i64) bool {
        return now_ns >= self.deadline();
    }

    pub fn recordMove(self: *Session, t0: i64, t1: i64) void {
        self.moves += 1;
        self.move_ns_sum += t1 - t0;
        self.move_ns_max = @max(self.move_ns_max, t1 - t0);
        if (self.first_move_ns == null) self.first_move_ns = t1;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const MS: i64 = 1_000_000;

fn sm(t_ms: i64, x: f64, y: f64) select.Sample {
    return .{ .t_ns = t_ms * MS, .x = x, .y = y, .view_mm = 650 };
}

// 1° at 650 mm on a 531 mm-wide screen ≈ 0.0214 in x.
const DEG_X = 11.346 / 531.0;

fn noise(rng: std.Random, deg: f64) f64 {
    return (rng.float(f64) * 2 - 1) * deg * DEG_X;
}

test "fixation with noise: target stays put, converges to the true point" {
    var f = Filter.init(.{ .deadband_deg = 0 }, .{});
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();
    var last: ?[2]f64 = null;
    var max_step: f64 = 0;
    var t: i64 = 0;
    for (0..60) |_| {
        // ±0.5° uniform noise around (0.4, 0.6).
        const e = f.update(sm(t, 0.4 + noise(rng, 0.5), 0.6 + noise(rng, 0.5) * 531.0 / 299.0));
        t += 30;
        if (e.target) |c| {
            if (last) |l| max_step = @max(max_step, @abs(c[0] - l[0]));
            last = c;
        }
    }
    // Only one fixation; final target within 0.15° of the truth.
    try testing.expect(f.has_fix);
    try testing.expectApproxEqAbs(@as(f64, 0.4), last.?[0], 0.15 * DEG_X);
    // Once settled the target barely moves between samples (< 0.2° ≈ 4 px on DP-1).
    try testing.expect(max_step < 0.3 * DEG_X);
}

test "first fixation needs confirmation; then saccade lands after one extra sample" {
    var f = Filter.init(.{}, .{});
    try testing.expectEqual(Kind.held, f.update(sm(0, 0.2, 0.2)).kind);
    const e1 = f.update(sm(30, 0.201, 0.2));
    try testing.expectEqual(Kind.new_fixation, e1.kind);
    try testing.expectApproxEqAbs(@as(f64, 0.2005), e1.target.?[0], 1e-9);
    _ = f.update(sm(60, 0.2, 0.2));
    // Saccade to (0.8, 0.5): in flight, landed, confirmed.
    try testing.expectEqual(Kind.held, f.update(sm(90, 0.5, 0.35)).kind);
    try testing.expectEqual(Kind.held, f.update(sm(120, 0.8, 0.5)).kind);
    const e2 = f.update(sm(150, 0.801, 0.5));
    try testing.expectEqual(Kind.new_fixation, e2.kind);
    try testing.expectApproxEqAbs(@as(f64, 0.8005), e2.target.?[0], 1e-9);
}

test "isolated spike is ignored" {
    var f = Filter.init(.{}, .{});
    _ = f.seed(&.{ sm(0, 0.5, 0.5), sm(30, 0.5, 0.5) });
    try testing.expectEqual(Kind.held, f.update(sm(60, 0.9, 0.1)).kind);
    const e = f.update(sm(90, 0.5, 0.5));
    try testing.expect(e.kind != .new_fixation);
    try testing.expectEqual(@as(f64, 0.5), e.target.?[0]);
    try testing.expectEqual(@as(usize, 0), f.cand_n);
}

test "slow drift is followed without a new fixation" {
    var f = Filter.init(.{ .window = 6, .deadband_deg = 0 }, .{});
    _ = f.seed(&.{ sm(0, 0.3, 0.5), sm(30, 0.3, 0.5) });
    var x: f64 = 0.3;
    var t: i64 = 60;
    var last: [2]f64 = .{ 0, 0 };
    for (0..40) |_| {
        x += 0.1 * DEG_X; // 0.1° per sample ≈ 3.3°/s
        const e = f.update(sm(t, x, 0.5));
        t += 30;
        try testing.expect(e.kind != .new_fixation);
        last = e.target.?;
    }
    // Lags by about half the window, i.e. ~0.3°.
    try testing.expect(x - last[0] < 0.5 * DEG_X);
}

test "deadband: noisy fixation moves the target rarely, drift still followed in steps" {
    var f = Filter.init(.{}, .{});
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    var changes: usize = 0;
    var last: ?[2]f64 = null;
    var t: i64 = 0;
    for (0..100) |i| {
        const e = f.update(sm(t, 0.4 + noise(rng, 0.5), 0.6 + noise(rng, 0.5) * 531.0 / 299.0));
        t += 30;
        if (e.target) |c| {
            if (last) |l| if (i >= 15 and (c[0] != l[0] or c[1] != l[1])) {
                changes += 1;
            };
            last = c;
        }
    }
    // 3 s of ±0.5° noise: (almost) still after the first 450 ms.
    try testing.expect(changes <= 4);
    // Drift of 1° over 1 s: followed (within the deadband plus half a window).
    var x: f64 = 0.4;
    for (0..33) |_| {
        x += 1.0 / 33.0 * DEG_X;
        last = f.update(sm(t, x, 0.6)).target orelse last;
        t += 30;
    }
    try testing.expect(@abs(x - last.?[0]) < 0.6 * DEG_X);
    try testing.expect(last.?[0] > 0.4 + 0.3 * DEG_X);
}

test "confirm = 1 jumps on the first sample outside" {
    var f = Filter.init(.{ .confirm = 1 }, .{});
    try testing.expectEqual(Kind.new_fixation, f.update(sm(0, 0.2, 0.2)).kind);
    try testing.expectEqual(Kind.new_fixation, f.update(sm(30, 0.7, 0.2)).kind);
}

test "easer: exponential approach, instant with tau 0, snaps within half a pixel" {
    var e = Easer.init(.{ 0, 0 });
    e.setTarget(.{ 100, 0 }, 80);
    try testing.expect(!e.step(80));
    try testing.expectApproxEqAbs(@as(f64, 100 * (1 - @exp(-1.0))), e.pos[0], 1e-9);
    var n: usize = 0;
    while (!e.step(8)) n += 1;
    try testing.expectEqual([2]f64{ 100, 0 }, e.pos);
    try testing.expect(n < 60);
    e.setTarget(.{ 500, 300 }, 0);
    try testing.expect(e.step(0));
    try testing.expectEqual([2]f64{ 500, 300 }, e.pixel());
}

test "session timeout and stats" {
    var s = Session{ .started_ns = 1000 * MS, .timeout_ms = 10_000, .dry = false };
    try testing.expect(!s.expired(5000 * MS));
    try testing.expect(!s.expired(10_999 * MS));
    try testing.expect(s.expired(11_000 * MS));
    s.recordMove(0, 100_000);
    s.recordMove(0, 300_000);
    try testing.expectEqual(@as(usize, 2), s.moves);
    try testing.expectEqual(@as(i64, 300_000), s.move_ns_max);
    try testing.expectEqual(@as(?i64, 100_000), s.first_move_ns);
}
