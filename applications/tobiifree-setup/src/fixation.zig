// fixation.zig — dispersion-based (I-DT) fixation detection on the gaze
// stream, for the gaze-contingent calibration and validation dots.
//
// Samples are gaze points on the screen in mm (x right, y down) with a host
// timestamp. A fixation is reported when the run of valid samples covers the
// whole window, the newest sample is fresh and the dispersion
// (x range + y range) of the samples in the window is small enough. An
// invalid sample (blink, eyes lost) ends the run.

const std = @import("std");

pub const CAP = 256; // ~7 s at 33 Hz; older samples are dropped

pub const Fixation = struct {
    /// Centroid of the window (mm).
    x: f64,
    y: f64,
    /// x range + y range (mm).
    dispersion: f64,
    n: usize,
};

pub const Detector = struct {
    t: [CAP]i64 = undefined,
    x: [CAP]f64 = undefined,
    y: [CAP]f64 = undefined,
    len: usize = 0,
    /// First sample of the current valid run (kept when old samples are dropped).
    run_start: i64 = 0,

    pub fn reset(self: *Detector) void {
        self.len = 0;
    }

    pub fn add(self: *Detector, t_us: i64, x_mm: f64, y_mm: f64) void {
        if (self.len == 0) self.run_start = t_us;
        if (self.len == CAP) {
            const keep = CAP / 2;
            std.mem.copyForwards(i64, self.t[0..keep], self.t[CAP - keep ..]);
            std.mem.copyForwards(f64, self.x[0..keep], self.x[CAP - keep ..]);
            std.mem.copyForwards(f64, self.y[0..keep], self.y[CAP - keep ..]);
            self.len = keep;
        }
        self.t[self.len] = t_us;
        self.x[self.len] = x_mm;
        self.y[self.len] = y_mm;
        self.len += 1;
    }

    /// Fixation over the last `window_us`, or null.
    pub fn fixation(self: *const Detector, now_us: i64, window_us: i64, max_dispersion_mm: f64, max_age_us: i64) ?Fixation {
        if (self.len == 0) return null;
        if (now_us - self.t[self.len - 1] > max_age_us) return null;
        // The valid run must reach back to the start of the window.
        const from = now_us - window_us;
        if (self.run_start > from) return null;
        var minx = std.math.inf(f64);
        var maxx = -std.math.inf(f64);
        var miny = std.math.inf(f64);
        var maxy = -std.math.inf(f64);
        var sx: f64 = 0;
        var sy: f64 = 0;
        var n: usize = 0;
        var i = self.len;
        while (i > 0) {
            i -= 1;
            if (self.t[i] < from) break;
            minx = @min(minx, self.x[i]);
            maxx = @max(maxx, self.x[i]);
            miny = @min(miny, self.y[i]);
            maxy = @max(maxy, self.y[i]);
            sx += self.x[i];
            sy += self.y[i];
            n += 1;
        }
        if (n < 3) return null;
        const d = (maxx - minx) + (maxy - miny);
        if (d > max_dispersion_mm) return null;
        const nf: f64 = @floatFromInt(n);
        return .{ .x = sx / nf, .y = sy / nf, .dispersion = d, .n = n };
    }
};

/// Size on the screen (mm) of a visual angle seen from `dist_mm`.
pub fn degToMm(deg: f64, dist_mm: f64) f64 {
    return dist_mm * @tan(std.math.degreesToRadians(deg));
}

/// Visual angle (deg) of a length on the screen seen from `dist_mm`.
pub fn mmToDeg(mm: f64, dist_mm: f64) f64 {
    return std.math.radiansToDegrees(std.math.atan2(mm, dist_mm));
}

const testing = std.testing;

test "stable gaze is a fixation, a saccade or a gap is not" {
    var d = Detector{};
    const ms: i64 = 1000;
    // 400 ms of samples at 30 ms around (100, 50) with ±1 mm jitter.
    var t: i64 = 0;
    while (t <= 400 * ms) : (t += 30 * ms) {
        const j: f64 = if (@mod(@divTrunc(t, 30 * ms), 2) == 0) 1 else -1;
        d.add(t, 100 + j, 50 - j);
    }
    const now = 400 * ms;
    const f = d.fixation(now, 300 * ms, 13, 150 * ms).?;
    try testing.expectApproxEqAbs(@as(f64, 100), f.x, 1.1);
    try testing.expect(f.dispersion <= 4.01);
    // Stale data: no fixation.
    try testing.expect(d.fixation(now + 200 * ms, 300 * ms, 13, 150 * ms) == null);
    // A saccade inside the window breaks it...
    d.add(now + 30 * ms, 300, 50);
    try testing.expect(d.fixation(now + 30 * ms, 300 * ms, 13, 150 * ms) == null);
    // ...until the window has moved past it.
    t = now + 60 * ms;
    while (t <= now + 400 * ms) : (t += 30 * ms) d.add(t, 300, 50);
    try testing.expect(d.fixation(now + 400 * ms, 300 * ms, 13, 150 * ms) != null);
    // After a reset (blink) the run must cover the window again.
    d.reset();
    d.add(now + 430 * ms, 300, 50);
    d.add(now + 460 * ms, 300, 50);
    d.add(now + 490 * ms, 300, 50);
    try testing.expect(d.fixation(now + 490 * ms, 300 * ms, 13, 150 * ms) == null);
}

test "buffer wraps" {
    var d = Detector{};
    var t: i64 = 0;
    while (t < 1000) : (t += 1) d.add(t * 1000, 0, 0);
    try testing.expect(d.len <= CAP);
    try testing.expect(d.fixation(999 * 1000, 300 * 1000, 1, 150 * 1000) != null);
}

test "angles" {
    try testing.expectApproxEqAbs(@as(f64, 13.09), degToMm(1, 750), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 1), mmToDeg(degToMm(1, 750), 750), 1e-9);
}
