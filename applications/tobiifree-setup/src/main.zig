// tobiifree-setup — fullscreen configurator for the Tobii ET5 (display area,
// position guide, calibration, validation), talking to tobiifreed.
//
// GTK4 + gtk4-layer-shell: one OVERLAY layer surface anchored to all edges of
// the output the tracker sits under, exclusive keyboard. Everything is drawn
// with cairo in physical pixels of that output (the cairo context is scaled by
// 1/surface-scale, pointer coordinates are multiplied by it).
//
// The daemon connection is a SocketSource driven from the GLib main loop
// (g_unix_fd_add on its fd); every device command is async and its reply
// moves the state machine on.
//
// Flow (ESC cancels at any time; nothing on the device changes before a step
// is confirmed):
//   1 display    two vertical lines over the marks of the ET5 -> ENTER sends
//                set_display_area_corners (the daemon persists it)
//   2 position   eyes in the track box, distance, hints -> SPACE
//   3 calibrate  start, 3 dots ▽ then 3 dots △ (add_point each), finish (the
//                daemon stores + reapplies the blob). On cancel/failure:
//                cancel_calibration + cal_apply of the stored blob.
//   4 validate   9 dots, per-dot and mean/max error -> redo / done

const std = @import("std");
const core = @import("tobiifree_core");
const proto = @import("daemon_protocol");
const SocketSource = @import("socket_source").SocketSource;
const Reply = @import("socket_source").Reply;
const geo = @import("geometry.zig");
const config = @import("config.zig");
const fixation = @import("fixation.zig");

const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("glib-unix.h");
    @cInclude("pango/pangocairo.h");
    @cInclude("gtk4-layer-shell.h");
});

const log = std.log.scoped(.setup);
const gpa = std.heap.c_allocator;

const usage =
    \\Usage: tobiifree-setup [options]
    \\
    \\Fullscreen configurator for the Tobii ET5 (needs tobiifreed running).
    \\
    \\Options:
    \\  --output NAME   output (connector) the tracker is mounted on, e.g. DP-1.
    \\                  Default: "output" in ~/.config/tobii.json, else the
    \\                  focused output (Hyprland), else the first one.
    \\  --gap MM        screen's bottom edge (first lit row) -> tracker camera
    \\                  centre, mm. Default: "gap_mm" in ~/.config/tobii.json,
    \\                  else 10. Saved there when step 1 is confirmed.
    \\  --step STEP     run one step only: display | calibrate | validate
    \\                  (calibrate includes the position guide)
    \\  -h, --help      this help
    \\
;

// ─── Options ────────────────────────────────────────────────────────

const Only = enum { all, display, calibrate, validate };

var opt_output: ?[]const u8 = null;
var opt_gap: ?f64 = null; // --gap
/// Gap in use: --gap, else "gap_mm" of tobii.json, else the default.
var gap_mm: f64 = geo.DEFAULT_GAP_MM;
var opt_only: Only = .all;

// ─── Gaze-contingent dots (tune here) ───────────────────────────────
//
// A fixation is FIX_WINDOW_S of valid gaze whose dispersion (x range +
// y range on the screen) stays under FIX_DISPERSION_DEG, newest sample not
// older than FIX_MAX_AGE_S. Angles are converted to mm with the current eye
// distance (eye_origin z).

const FIX_WINDOW_S = 0.3;
const FIX_DISPERSION_DEG = 1.0;
const FIX_MAX_AGE_S = 0.15;
/// No valid gaze for this long: "eyes not found" hint.
const GAZE_LOST_S = 1.0;

/// Calibration: the dot waits (pulsing) for a fixation this close to it.
/// Generous: the uncalibrated gaze can be 5–10° off (3.6–10.2° measured).
const CAL_RADIUS_DEG = 12.0;
/// No fixation near the dot after this long: any stable fixation counts
/// (the error is then larger than CAL_RADIUS_DEG, which the calibration is
/// there to fix) and a "look at the centre of the dot" hint is shown.
const CAL_FALLBACK_S = 5.0;
/// The dot shrinks over this time while the fixation holds, then add_point.
const CAL_SHRINK_S = 0.7;
/// When the fixation breaks the dot grows back this many times faster.
const CAL_GROW_FACTOR = 2.0;

/// Validation: fixation this close to the dot (larger than any realistic
/// error after a calibration: the error is what we measure).
const VAL_RADIUS_DEG = 5.0;
/// No fixation near the dot after this long: measure on any stable fixation
/// (the dot is then flagged, its error is > VAL_RADIUS_DEG or doubtful).
const VAL_FALLBACK_S = 5.0;
/// Seconds of fixation samples collected per dot.
const VAL_COLLECT_S = 1.0;
/// Give up a dot after this long; it keeps what was collected if at least
/// VAL_MIN_COLLECT_S, else "no fixation".
const VAL_TIMEOUT_S = 12.0;
const VAL_MIN_COLLECT_S = 0.3;

/// Waiting dots pulse between these radii (px × ui), shrink to DOT_SMALL.
const DOT_BIG = 28.0;
const DOT_PULSE = 4.0;
const DOT_SMALL = 9.0;
const PULSE_PERIOD_S = 1.2;
/// Orange <-> blue fade of the active dot (gaze on it or not), both ways;
/// a reversal mid-fade continues from the current colour.
const DOT_FADE_S = 0.1;

// ─── Colours ────────────────────────────────────────────────────────

const Rgb = [3]f64;
const BG: Rgb = .{ 0.07, 0.07, 0.086 };
const FG: Rgb = .{ 0.9, 0.9, 0.9 };
const DIM: Rgb = .{ 0.55, 0.55, 0.6 };
const ACC: Rgb = .{ 1.0, 0.667, 0.157 };
const ACC_DIM: Rgb = .{ 0.43, 0.31, 0.12 };
/// Gaze-contingent dot while the gaze is on it (fixation accepted).
const ON_GAZE: Rgb = .{ 0.25, 0.6, 1.0 };
const GOOD: Rgb = .{ 0.35, 0.85, 0.45 };
const WARN: Rgb = .{ 1.0, 0.45, 0.3 };

// ─── Global state ───────────────────────────────────────────────────

var src: SocketSource = undefined;
var gtk_app: ?*c.GApplication = null;
var window: ?*c.GtkWidget = null;
var canvas: ?*c.GtkWidget = null;
var exit_code: u8 = 0;

// Output
var monitor: ?*c.GdkMonitor = null;
var mon_name_buf: [64]u8 = undefined;
var mon_name: []const u8 = "?";
var width_px: u32 = 1920;
var height_px: u32 = 1080;
var mon_scale: f64 = 1;
var mon_mm: [2]i32 = .{ 0, 0 }; // EDID physical size
var draw_scale: f64 = 1; // surface scale (logical -> physical)
var ui: f64 = 1; // size factor for text and dots

// Device
var device_area: ?geo.Corners = null;
var daemon_lost: bool = false;

// Gaze (latest sample)
var gaze: core.GazeSample = std.mem.zeroes(core.GazeSample);
var gaze_time_us: i64 = 0;
var gaze_count: u64 = 0;
var gaze_last_valid_us: i64 = 0;
var fix_det: fixation.Detector = .{};
var eye_z_mm: f64 = 650; // latest eye distance (eye_origin z)

const Step = enum { display, position, calibrate, validate };
var step: Step = .display;

var msg_buf: [256]u8 = undefined;
var msg: []const u8 = "";
var msg_is_error = false;

fn setMsg(is_err: bool, comptime fmt: []const u8, args: anytype) void {
    msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "…";
    msg_is_error = is_err;
    if (is_err) log.err("{s}", .{msg}) else log.info("{s}", .{msg});
}

fn clearMsg() void {
    msg = "";
    msg_is_error = false;
}

fn now() i64 {
    return c.g_get_monotonic_time();
}

fn secsSince(t0: i64) f64 {
    return @as(f64, @floatFromInt(now() - t0)) / 1e6;
}

fn quit(code: u8) void {
    exit_code = code;
    if (gtk_app) |a| c.g_application_quit(a);
}

fn redraw() void {
    if (canvas) |w| c.gtk_widget_queue_draw(w);
}

fn setCursorHidden(hidden: bool) void {
    if (canvas) |w| c.gtk_widget_set_cursor_from_name(w, if (hidden) "none" else null);
}

// ─── Step 1: display setup ──────────────────────────────────────────

var marks: [2]i32 = .{ 0, 0 };
var marks_init = false;
var marks_touched = false;
var sel: usize = 0;
var drag_line: ?usize = null;
var drag_start_col: i32 = 0;
var set_pending = false;

fn initMarks() void {
    if (marks_touched) return;
    if (device_area) |a| if (geo.markersFromArea(a, width_px, height_px)) |m| {
        marks = m;
        marks_init = true;
        return;
    };
    if (marks_init) return;
    // EDID pitch guess, centred.
    const w: f64 = @floatFromInt(width_px);
    const p = if (mon_mm[0] > 0) @as(f64, @floatFromInt(mon_mm[0])) / w else 0.27;
    const half = geo.MARK_SPACING_MM / p / 2;
    marks = .{ @intFromFloat(@round(w / 2 - half)), @intFromFloat(@round(w / 2 + half)) };
    marks_init = true;
}

fn moveMark(i: usize, col: i32) void {
    marks[i] = std.math.clamp(col, 0, @as(i32, @intCast(width_px)) - 1);
    marks_touched = true;
    redraw();
}

fn currentArea() ?geo.Area {
    return geo.areaFromMarkers(marks[0], marks[1], width_px, height_px, gap_mm);
}

fn confirmDisplay() void {
    if (set_pending or daemon_lost) return;
    const a = currentArea() orelse {
        setMsg(true, "The two lines are on top of each other", .{});
        return;
    };
    // Write the output first: the daemon rewrites tobii.json on the set and
    // keeps our key.
    config.saveSetup(gpa, mon_name, gap_mm) catch |err| log.warn("could not save output/gap to tobii.json: {}", .{err});
    src.setDisplayAreaCorners(a.corners, onAreaSet, null) catch |err| {
        setMsg(true, "Sending the display area failed: {}", .{err});
        return;
    };
    set_pending = true;
    log.info("set display area: d={d:.0}px xc={d:.1}px p={d:.5}mm/px TL=({d:.3},{d:.3}) TR=({d:.3},{d:.3}) BL=({d:.3},{d:.3})", .{
        a.d_px, a.xc_px, a.mm_per_px, a.corners[0], a.corners[1], a.corners[3], a.corners[4], a.corners[6], a.corners[7],
    });
    setMsg(false, "Saving the display area…", .{});
}

fn onAreaSet(_: ?*anyopaque, _: proto.Cmd, reply: Reply) void {
    set_pending = false;
    switch (reply) {
        .ok => |p| {
            if (SocketSource.decodeDisplayArea(p)) |a| device_area = a;
            log.info("display area saved by the daemon", .{});
            clearMsg();
            if (opt_only == .display) quit(0) else enterStep(.position);
        },
        .err => |e| setMsg(true, "The daemon refused the display area ({s})", .{errName(e)}),
    }
    redraw();
}

fn onAreaGot(_: ?*anyopaque, _: proto.Cmd, reply: Reply) void {
    switch (reply) {
        .ok => |p| if (SocketSource.decodeDisplayArea(p)) |a| {
            device_area = a;
            log.info("device area TL=({d:.3},{d:.3},{d:.3}) TR=({d:.3},{d:.3},{d:.3}) BL=({d:.3},{d:.3},{d:.3})", .{
                a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8],
            });
            initMarks();
        },
        .err => |e| log.warn("get_display_area failed: {s}", .{errName(e)}),
    }
    redraw();
}

fn errName(code: u32) []const u8 {
    return switch (code) {
        proto.Err.failed => "failed",
        proto.Err.too_large => "too large",
        proto.Err.busy => "device busy",
        proto.Err.timeout => "device timeout",
        proto.Err.bad_payload => "bad payload",
        proto.Err.unknown_cmd => "unknown command (daemon too old?)",
        proto.Err.usb => "USB error",
        proto.Err.disconnected => "daemon disconnected",
        proto.Err.no_device => "no tracker connected",
        else => "device status error",
    };
}

fn keyDisplay(keyval: c_uint, shift: bool) void {
    const stepv: i32 = if (shift) 10 else 1;
    switch (keyval) {
        c.GDK_KEY_Tab, c.GDK_KEY_ISO_Left_Tab => sel ^= 1,
        c.GDK_KEY_Left, c.GDK_KEY_KP_Left => moveMark(sel, marks[sel] - stepv),
        c.GDK_KEY_Right, c.GDK_KEY_KP_Right => moveMark(sel, marks[sel] + stepv),
        c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => confirmDisplay(),
        else => {},
    }
}

fn drawDisplay(cr: *c.cairo_t, w: f64, h: f64) void {
    var y = h * 0.16;
    y += text(cr, w / 2, y, 34, .center, FG, "Step 1 · Display setup", .{});
    y += 12 * ui;
    y += text(cr, w / 2, y, 20, .center, DIM, "Put each line exactly above one of the two marks on the top edge of the eye tracker.", .{});
    y += text(cr, w / 2, y, 20, .center, DIM, "Drag a line with the mouse, or TAB to switch line, ← → to move 1 px, SHIFT + ← → for 10 px.", .{});
    y += text(cr, w / 2, y, 20, .center, DIM, "ENTER saves the display area · ESC cancels without changing anything.", .{});

    y = h * 0.42;
    if (currentArea()) |a| {
        y += text(cr, w / 2, y, 24, .center, FG, "{d:.0} px between the lines  →  {d:.4} mm/px  →  screen {d:.1} × {d:.1} mm", .{ a.d_px, a.mm_per_px, a.w_mm, a.h_mm });
        const off = a.xc_px - @as(f64, @floatFromInt(width_px)) / 2;
        y += text(cr, w / 2, y, 20, .center, DIM, "tracker centre at x = {d:.1} px ({d:.1} mm {s} the screen centre) · gap {d:.1} mm", .{
            a.xc_px, @abs(off * a.mm_per_px), if (off < 0) "left of" else "right of", gap_mm,
        });
        y += text(cr, w / 2, y, 16, .center, DIM, "gap: measure from the screen's bottom edge (first lit row) to the camera centre, set with --gap", .{});
        if (mon_mm[0] > 0 and mon_mm[1] > 0) {
            const ew: f64 = @floatFromInt(mon_mm[0]);
            const eh: f64 = @floatFromInt(mon_mm[1]);
            const dev = @max(@abs(a.w_mm - ew) / ew, @abs(a.h_mm - eh) / eh) * 100;
            y += text(cr, w / 2, y, 20, .center, DIM, "the monitor reports {d:.0} × {d:.0} mm (EDID)", .{ ew, eh });
            if (dev > 3) {
                y += text(cr, w / 2, y, 22, .center, WARN, "⚠ {d:.1} % off the reported size: check that the lines sit exactly over the marks", .{dev});
            } else {
                y += text(cr, w / 2, y, 20, .center, GOOD, "within {d:.1} % of the reported size", .{dev});
            }
        }
    }
    if (device_area) |a| {
        const s = geo.areaSize(a);
        y += 8 * ui;
        y += text(cr, w / 2, y, 18, .center, DIM, "current device area: {d:.1} × {d:.1} mm, TL ({d:.1}, {d:.1}) BL ({d:.1}, {d:.1})", .{ s[0], s[1], a[0], a[1], a[6], a[7] });
    }
    y += text(cr, w / 2, y, 18, .center, DIM, "output {s} · {d}×{d} px · scale {d:.2}", .{ mon_name, width_px, height_px, mon_scale });
    drawMsg(cr, w, y + 16 * ui);

    // The two lines: 1 physical px wide, bottom 30 % of the screen.
    const top = h * 0.70;
    for (marks, 0..) |m, i| {
        const x: f64 = @floatFromInt(m);
        const col = if (i == sel) ACC else ACC_DIM;
        c.cairo_set_source_rgb(cr, col[0], col[1], col[2]);
        c.cairo_rectangle(cr, x, top, 1, h - top);
        c.cairo_fill(cr);
        _ = text(cr, x + 0.5, top - 30 * ui, 16, .center, col, "{d}", .{m});
    }
}

// ─── Step 2: position guide ─────────────────────────────────────────

const Placement = struct {
    any_eye: bool,
    good: bool,
    z_mm: f64,
    hx: f64, // head centre in the box, 0..1 (mirror view)
    hy: f64,
    hint_buf: [96]u8 = undefined,
    hint_len: usize = 0,
};

const Z_NEAR = 500.0; // closer than this: move back
const Z_FAR = 850.0; // further than this: move closer

fn eyeValid(v: u32) bool {
    return v == 0;
}

fn gazeFresh() bool {
    return gaze_count > 0 and now() - gaze_time_us < 500_000;
}

/// Eye position in the box in mirror view (the person's left eye on the left).
fn eyeBox(tb: [3]f64) [2]f64 {
    return .{ 1 - tb[0], tb[1] };
}

fn placement() Placement {
    var p = Placement{ .any_eye = false, .good = false, .z_mm = 0, .hx = 0.5, .hy = 0.5 };
    if (!gazeFresh()) return p;
    var n: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var sz: f64 = 0;
    if (eyeValid(gaze.validity_L)) {
        const b = eyeBox(gaze.trackbox_eye_pos_L);
        sx += b[0];
        sy += b[1];
        sz += gaze.eye_origin_L_mm[2];
        n += 1;
    }
    if (eyeValid(gaze.validity_R)) {
        const b = eyeBox(gaze.trackbox_eye_pos_R);
        sx += b[0];
        sy += b[1];
        sz += gaze.eye_origin_R_mm[2];
        n += 1;
    }
    if (n == 0) return p;
    p.any_eye = true;
    p.hx = sx / n;
    p.hy = sy / n;
    p.z_mm = sz / n;
    var hints: [4][]const u8 = undefined;
    var k: usize = 0;
    if (p.z_mm > Z_FAR) {
        hints[k] = "move closer";
        k += 1;
    } else if (p.z_mm < Z_NEAR) {
        hints[k] = "move back";
        k += 1;
    }
    if (p.hx < 0.3) {
        hints[k] = "move right";
        k += 1;
    } else if (p.hx > 0.7) {
        hints[k] = "move left";
        k += 1;
    }
    if (p.hy < 0.25) {
        hints[k] = "move down";
        k += 1;
    } else if (p.hy > 0.75) {
        hints[k] = "move up";
        k += 1;
    }
    p.good = k == 0 and eyeValid(gaze.validity_L) and eyeValid(gaze.validity_R);
    var w: std.Io.Writer = .fixed(&p.hint_buf);
    for (hints[0..k], 0..) |hint, i| {
        if (i > 0) w.writeAll(", ") catch {};
        w.writeAll(hint) catch {};
    }
    if (k == 0 and !p.good) w.writeAll("keep both eyes visible") catch {};
    p.hint_len = w.end;
    return p;
}

fn drawPosition(cr: *c.cairo_t, w: f64, h: f64) void {
    var y = h * 0.08;
    y += text(cr, w / 2, y, 34, .center, FG, "Step 2 · Position", .{});
    y += 12 * ui;
    y += text(cr, w / 2, y, 20, .center, DIM, "Sit as you usually do and keep your head in the middle of the box, about 50–85 cm from the screen.", .{});
    y += text(cr, w / 2, y, 20, .center, DIM, "SPACE starts the calibration · ESC cancels.", .{});

    const p = placement();
    const col: Rgb = if (p.good) GOOD else if (p.any_eye) ACC else DIM;

    // Track box.
    const bw = w * 0.42;
    const bh = h * 0.42;
    const bx = (w - bw) / 2;
    const by = h * 0.28;
    c.cairo_set_line_width(cr, 2 * ui);
    c.cairo_set_source_rgb(cr, col[0] * 0.6, col[1] * 0.6, col[2] * 0.6);
    c.cairo_rectangle(cr, bx, by, bw, bh);
    c.cairo_stroke(cr);
    // Good zone.
    const dash = [_]f64{ 6 * ui, 6 * ui };
    c.cairo_set_dash(cr, &dash, 2, 0);
    c.cairo_set_source_rgb(cr, 0.3, 0.3, 0.34);
    c.cairo_rectangle(cr, bx + 0.3 * bw, by + 0.25 * bh, 0.4 * bw, 0.5 * bh);
    c.cairo_stroke(cr);
    c.cairo_set_dash(cr, null, 0, 0);

    // Eyes (bigger when closer).
    const r_base = 26 * ui;
    for ([_]struct { v: u32, tb: [3]f64, z: f64 }{
        .{ .v = gaze.validity_L, .tb = gaze.trackbox_eye_pos_L, .z = gaze.eye_origin_L_mm[2] },
        .{ .v = gaze.validity_R, .tb = gaze.trackbox_eye_pos_R, .z = gaze.eye_origin_R_mm[2] },
    }) |e| {
        if (!gazeFresh() or !eyeValid(e.v)) continue;
        const b = eyeBox(e.tb);
        const r = std.math.clamp(r_base * 650 / @max(e.z, 1), 8 * ui, 60 * ui);
        const ex = bx + std.math.clamp(b[0], 0, 1) * bw;
        const ey = by + std.math.clamp(b[1], 0, 1) * bh;
        c.cairo_set_source_rgb(cr, col[0], col[1], col[2]);
        c.cairo_arc(cr, ex, ey, r, 0, 2 * std.math.pi);
        c.cairo_fill(cr);
        c.cairo_set_source_rgb(cr, BG[0], BG[1], BG[2]);
        c.cairo_arc(cr, ex, ey, r * 0.4, 0, 2 * std.math.pi);
        c.cairo_fill(cr);
    }

    // Distance bar 40–100 cm.
    const zx0 = bx;
    const zy = by + bh + 40 * ui;
    const zmin = 400.0;
    const zmax = 1000.0;
    c.cairo_set_source_rgb(cr, 0.2, 0.2, 0.24);
    c.cairo_rectangle(cr, zx0, zy, bw, 10 * ui);
    c.cairo_fill(cr);
    c.cairo_set_source_rgb(cr, 0.2, 0.42, 0.25);
    c.cairo_rectangle(cr, zx0 + (Z_NEAR - zmin) / (zmax - zmin) * bw, zy, (Z_FAR - Z_NEAR) / (zmax - zmin) * bw, 10 * ui);
    c.cairo_fill(cr);
    _ = text(cr, zx0, zy + 16 * ui, 16, .left, DIM, "{d:.0} cm", .{zmin / 10});
    _ = text(cr, zx0 + bw, zy + 16 * ui, 16, .right, DIM, "{d:.0} cm", .{zmax / 10});
    if (p.any_eye) {
        const zx = zx0 + std.math.clamp((p.z_mm - zmin) / (zmax - zmin), 0, 1) * bw;
        c.cairo_set_source_rgb(cr, col[0], col[1], col[2]);
        c.cairo_rectangle(cr, zx - 2 * ui, zy - 8 * ui, 4 * ui, 26 * ui);
        c.cairo_fill(cr);
        _ = text(cr, w / 2, zy + 16 * ui, 18, .center, col, "{d:.0} cm", .{p.z_mm / 10});
    }

    const ty = zy + 60 * ui;
    if (daemon_lost) {
        _ = text(cr, w / 2, ty, 28, .center, WARN, "Lost the connection to tobiifreed", .{});
    } else if (!gazeFresh()) {
        _ = text(cr, w / 2, ty, 28, .center, DIM, "Waiting for the eye tracker…", .{});
    } else if (!p.any_eye) {
        _ = text(cr, w / 2, ty, 28, .center, ACC, "Eyes not found: look at the screen", .{});
    } else if (p.good) {
        _ = text(cr, w / 2, ty, 28, .center, GOOD, "Good position: press SPACE", .{});
    } else {
        var hb: [128]u8 = undefined;
        const hint = p.hint_buf[0..p.hint_len];
        const s = std.fmt.bufPrint(&hb, "{s}", .{hint}) catch hint;
        if (s.len > 0) hb[0] = std.ascii.toUpper(hb[0]);
        _ = text(cr, w / 2, ty, 28, .center, ACC, "{s}", .{s});
    }

    drawGazeDot(cr, w, h);
}

fn drawGazeDot(cr: *c.cairo_t, w: f64, h: f64) void {
    if (!gazeFresh() or !(eyeValid(gaze.validity_L) or eyeValid(gaze.validity_R))) return;
    c.cairo_set_source_rgba(cr, 0.49, 0.98, 0.66, 0.55);
    c.cairo_arc(cr, gaze.gaze_point_2d_norm[0] * w, gaze.gaze_point_2d_norm[1] * h, 10 * ui, 0, 2 * std.math.pi);
    c.cairo_fill(cr);
}

// ─── Step 3: calibration ────────────────────────────────────────────

/// Screen A ▽ then screen B △ (normalised, origin top-left).
const CAL_POINTS = [6][2]f64{
    .{ 0.1, 0.1 }, .{ 0.9, 0.1 }, .{ 0.5, 0.9 },
    .{ 0.1, 0.9 }, .{ 0.9, 0.9 }, .{ 0.5, 0.1 },
};
const INTRO_S = 2.0;
const BETWEEN_S = 0.8;

const CalPhase = enum { starting, intro, gazing, adding, between, finishing, cancelling, restoring, failed, done };
var cal_phase: CalPhase = .done;
var cal_idx: usize = 0;
var cal_t0: i64 = 0;
var cal_cancel_req = false; // ESC while a command is in flight
var cal_quit_after = false; // quit once the previous calibration is restored
var cal_fail_buf: [160]u8 = undefined;
var cal_fail: []const u8 = "";
var cal_blob: ?[]u8 = null;
var cal_retries: u32 = 0; // of the current dot
// Gaze gating of the current dot.
var cal_progress: f64 = 0; // 0 = big (waiting), 1 = shrunk -> add_point
var cal_dot_t0: i64 = 0; // dot shown
var cal_fix_t: i64 = 0; // first qualifying fixation (0: none yet)
var cal_fix_offset: f64 = 0; // its distance to the dot (deg)
var cal_holding = false;
var cal_breaks: u32 = 0; // fixation lost while shrinking
var cal_fallback = false;
var cal_last_tick: i64 = 0;

fn startDot() void {
    cal_phase = .gazing;
    cal_progress = 0;
    cal_dot_t0 = now();
    cal_last_tick = cal_dot_t0;
    cal_fix_t = 0;
    cal_holding = false;
    cal_breaks = 0;
    cal_fallback = false;
    resetDotColour();
}
/// The device refuses a point when it has no usable gaze for it (eyes lost,
/// blink, looking away: status 0x20000502). Re-show the dot this many times.
const MAX_POINT_RETRIES = 2;

fn enterCalibrate() void {
    cal_idx = 0;
    cal_retries = 0;
    cal_cancel_req = false;
    cal_quit_after = false;
    cal_fail = "";
    cal_phase = .starting;
    cal_t0 = now();
    setCursorHidden(true);
    src.startCalibration(onCalStarted, null) catch |err| {
        calFailed(false, "Could not send start_calibration: {}", .{err});
        return;
    };
    log.info("calibration: start", .{});
}

fn onCalStarted(_: ?*anyopaque, _: proto.Cmd, reply: Reply) void {
    switch (reply) {
        .ok => {
            log.info("calibration: started", .{});
            if (cal_cancel_req) return restorePrevious(true);
            cal_phase = .intro;
            cal_t0 = now();
        },
        // start clears the device's point list even when it fails late: restore.
        .err => |e| calFailed(true, "start_calibration failed ({s})", .{errName(e)}),
    }
    redraw();
}

fn sendPoint() void {
    const pt = CAL_POINTS[cal_idx];
    const fix_after = @as(f64, @floatFromInt(cal_fix_t - cal_dot_t0)) / 1e6;
    const shrink = @as(f64, @floatFromInt(now() - cal_fix_t)) / 1e6;
    const fb: []const u8 = if (cal_fallback) " (fallback: any stable fixation)" else "";
    log.info("calibration: dot {d} ({d:.1},{d:.1}): fixation after {d:.2}s at {d:.1} deg{s}, shrink {d:.2}s, {d} break(s)", .{ cal_idx, pt[0], pt[1], fix_after, cal_fix_offset, fb, shrink, cal_breaks });
    cal_phase = .adding;
    cal_t0 = now();
    src.addCalibrationPoint(pt[0], pt[1], onPointAdded, null) catch |err| {
        calFailed(true, "Could not send add_calibration_point: {}", .{err});
        return;
    };
}

fn onPointAdded(_: ?*anyopaque, _: proto.Cmd, reply: Reply) void {
    switch (reply) {
        .ok => {
            log.info("calibration: point {d} ({d:.1},{d:.1}) added in {d:.2}s", .{ cal_idx, CAL_POINTS[cal_idx][0], CAL_POINTS[cal_idx][1], secsSince(cal_t0) });
            if (cal_cancel_req) return restorePrevious(true);
            cal_idx += 1;
            cal_retries = 0;
            cal_t0 = now();
            if (cal_idx == CAL_POINTS.len) {
                cal_phase = .finishing;
                src.finishCalibration(onCalFinished, null) catch |err| {
                    calFailed(true, "Could not send finish_calibration: {}", .{err});
                    return;
                };
                log.info("calibration: finish", .{});
            } else if (cal_idx == 3) {
                cal_phase = .between;
            } else startDot();
        },
        .err => |e| {
            if (cal_cancel_req) return restorePrevious(true);
            if (e >= 0x100 and cal_retries < MAX_POINT_RETRIES) {
                cal_retries += 1;
                log.warn("calibration: dot {d} refused by the device (0x{x}), showing it again ({d}/{d})", .{ cal_idx, e, cal_retries, MAX_POINT_RETRIES });
                startDot();
            } else calFailed(true, "The tracker could not use dot {d} ({s}): were your eyes visible?", .{ cal_idx + 1, errName(e) });
        },
    }
    redraw();
}

fn onCalFinished(_: ?*anyopaque, _: proto.Cmd, reply: Reply) void {
    switch (reply) {
        .ok => |blob| {
            log.info("calibration: finished, blob {d} bytes, {d:.2}s (stored and applied by the daemon)", .{ blob.len, secsSince(cal_t0) });
            cal_phase = .done;
            setCursorHidden(false);
            if (cal_cancel_req) return quit(0); // done anyway: the new calibration is in place
            if (opt_only == .calibrate) {
                setMsg(false, "Calibration saved.", .{});
                quit(0);
            } else enterStep(.validate);
        },
        .err => |e| calFailed(true, "finish_calibration failed ({s})", .{errName(e)}),
    }
    redraw();
}

fn calFailed(restore: bool, comptime fmt: []const u8, args: anytype) void {
    cal_fail = std.fmt.bufPrint(&cal_fail_buf, fmt, args) catch "calibration failed";
    log.err("{s}", .{cal_fail});
    if (restore) restorePrevious(false) else {
        cal_phase = .failed;
        setCursorHidden(false);
    }
}

/// Cancel the session on the device and re-apply the stored blob (start
/// cleared the device's calibration points).
fn restorePrevious(and_quit: bool) void {
    cal_quit_after = cal_quit_after or and_quit;
    cal_phase = .cancelling;
    setCursorHidden(false);
    log.info("calibration: cancel + restore the previous calibration", .{});
    src.cancelCalibration(onCalCancelled, null) catch |err| {
        log.err("cancel_calibration: {}", .{err});
        onCalCancelled(null, .cancel_calibration, .{ .err = proto.Err.disconnected });
    };
    redraw();
}

fn onCalCancelled(_: ?*anyopaque, _: proto.Cmd, reply: Reply) void {
    if (reply == .err) log.warn("cancel_calibration: {s}", .{errName(reply.err)});
    var pbuf: [512]u8 = undefined;
    const path = calibrationPath(&pbuf) orelse "";
    if (cal_blob) |b| gpa.free(b);
    cal_blob = std.fs.cwd().readFileAlloc(gpa, path, 4 << 20) catch null;
    if (cal_blob) |blob| {
        cal_phase = .restoring;
        src.calApply(blob, onCalRestored, null) catch |err| {
            log.err("cal_apply: {}", .{err});
            onCalRestored(null, .cal_apply, .{ .err = proto.Err.disconnected });
        };
    } else {
        log.warn("no stored calibration at {s}: nothing to restore", .{path});
        restoreDone("no stored calibration to restore");
    }
    redraw();
}

fn onCalRestored(_: ?*anyopaque, _: proto.Cmd, reply: Reply) void {
    switch (reply) {
        .ok => {
            log.info("calibration: previous calibration re-applied", .{});
            restoreDone(null);
        },
        .err => |e| {
            var b: [96]u8 = undefined;
            restoreDone(std.fmt.bufPrint(&b, "re-applying the stored calibration failed ({s})", .{errName(e)}) catch "restore failed");
        },
    }
    redraw();
}

fn restoreDone(problem: ?[]const u8) void {
    if (problem) |p| log.err("{s}", .{p});
    if (cal_quit_after) return quit(1);
    cal_phase = .failed;
    if (problem) |p| setMsg(true, "{s}", .{p}) else setMsg(false, "The previous calibration was restored.", .{});
}

fn calibrationPath(buf: []u8) ?[]const u8 {
    if (std.posix.getenv("XDG_STATE_HOME")) |s| if (s.len > 0) {
        return std.fmt.bufPrint(buf, "{s}/tobiifree/calibration.bin", .{s}) catch null;
    };
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/tobiifree/calibration.bin", .{home}) catch null;
}

fn escCalibrate() void {
    switch (cal_phase) {
        .intro, .gazing, .between => restorePrevious(true),
        .starting, .adding, .finishing => {
            cal_cancel_req = true;
            cal_quit_after = true;
        },
        .cancelling, .restoring => cal_quit_after = true,
        .failed, .done => quit(1),
    }
}

fn tickCalibrate() void {
    switch (cal_phase) {
        .intro => if (secsSince(cal_t0) >= INTRO_S) startDot(),
        .between => if (secsSince(cal_t0) >= BETWEEN_S) startDot(),
        .gazing => tickDot(),
        else => {},
    }
}

/// Gate the current dot on the gaze: shrink while the person fixates near
/// it, grow back when the fixation breaks, add_point once shrunk.
fn tickDot() void {
    const t = now();
    const dt = @as(f64, @floatFromInt(t - cal_last_tick)) / 1e6;
    cal_last_tick = t;
    if (!cal_fallback and cal_fix_t == 0 and secsSince(cal_dot_t0) >= CAL_FALLBACK_S) {
        cal_fallback = true;
        log.warn("calibration: dot {d}: no fixation within {d:.0} deg after {d:.0}s, accepting any stable fixation", .{ cal_idx, CAL_RADIUS_DEG, CAL_FALLBACK_S });
    }
    const pt = CAL_POINTS[cal_idx];
    var ok = false;
    if (currentFixation()) |f| {
        const off = fixOffsetDeg(f, pt[0], pt[1]);
        ok = cal_fallback or off <= CAL_RADIUS_DEG;
        if (ok and cal_fix_t == 0) {
            cal_fix_t = t;
            cal_fix_offset = off;
        }
    }
    if (ok) {
        cal_progress += dt / CAL_SHRINK_S;
    } else {
        if (cal_holding) cal_breaks += 1;
        cal_progress = @max(0, cal_progress - dt * CAL_GROW_FACTOR / CAL_SHRINK_S);
    }
    cal_holding = ok;
    if (cal_progress >= 1) sendPoint();
}

fn drawTarget(cr: *c.cairo_t, x: f64, y: f64, r: f64, col: Rgb) void {
    c.cairo_set_source_rgb(cr, col[0], col[1], col[2]);
    c.cairo_arc(cr, x, y, r, 0, 2 * std.math.pi);
    c.cairo_fill(cr);
    c.cairo_set_source_rgb(cr, BG[0], BG[1], BG[2]);
    c.cairo_arc(cr, x, y, @min(3 * ui, r * 0.5), 0, 2 * std.math.pi);
    c.cairo_fill(cr);
}

fn drawCalibrate(cr: *c.cairo_t, w: f64, h: f64) void {
    switch (cal_phase) {
        .intro, .gazing, .adding, .between, .starting => {
            const screen_b = cal_idx >= 3;
            const first: usize = if (screen_b) 3 else 0;
            if (cal_phase == .intro or cal_phase == .starting) {
                _ = text(cr, w / 2, h * 0.45, 28, .center, FG, "Look at each dot until it disappears", .{});
                _ = text(cr, w / 2, h * 0.45 + 44 * ui, 18, .center, DIM, "Keep your head still · ESC cancels and keeps the previous calibration", .{});
            } else if (cal_phase == .gazing) {
                drawDotHint(cr, w, h, cal_fallback or cal_retries > 0);
            }
            for (first..first + 3) |i| {
                const pt = CAL_POINTS[i];
                const x = pt[0] * w;
                const y = pt[1] * h;
                if (i < cal_idx) continue; // done
                if (i == cal_idx and (cal_phase == .gazing or cal_phase == .adding)) {
                    const r = if (cal_phase == .adding)
                        DOT_SMALL
                    else if (cal_progress <= 0)
                        pulseRadius()
                    else
                        DOT_BIG + (DOT_SMALL - DOT_BIG) * std.math.clamp(cal_progress, 0, 1);
                    drawTarget(cr, x, y, r * ui, dotColour());
                } else {
                    drawTarget(cr, x, y, 8 * ui, ACC_DIM);
                }
            }
        },
        .finishing => _ = text(cr, w / 2, h * 0.45, 28, .center, FG, "Computing the calibration…", .{}),
        .cancelling, .restoring => _ = text(cr, w / 2, h * 0.45, 28, .center, FG, "Restoring the previous calibration…", .{}),
        .failed => {
            var y = h * 0.4;
            y += text(cr, w / 2, y, 30, .center, WARN, "Calibration not completed", .{});
            if (cal_fail.len > 0) y += text(cr, w / 2, y, 20, .center, FG, "{s}", .{cal_fail});
            y += 10 * ui;
            drawMsg(cr, w, y);
            _ = text(cr, w / 2, h * 0.62, 20, .center, DIM, "R retry · ESC quit", .{});
        },
        .done => {},
    }
}

// ─── Step 4: validation ─────────────────────────────────────────────

const VAL_POINTS = blk: {
    var pts: [9][2]f64 = undefined;
    for ([_]f64{ 0.1, 0.5, 0.9 }, 0..) |yv, j| {
        for ([_]f64{ 0.1, 0.5, 0.9 }, 0..) |xv, i| pts[j * 3 + i] = .{ xv, yv };
    }
    break :blk pts;
};
const ValPhase = enum { intro, dot, results };
var val_phase: ValPhase = .intro;
var val_idx: usize = 0;
var val_t0: i64 = 0;
var val_results: [9]?geo.PointError = .{null} ** 9;
var val_sum: struct { gx: f64 = 0, gy: f64 = 0, n: u32 = 0, z: f64 = 0, zn: u32 = 0 } = .{};
var val_fallback: [9]bool = .{false} ** 9; // measured on a fixation away from the dot
var val_collected_s: f64 = 0;
var val_last_acc: i64 = 0; // last accepted sample
var val_fix_t: i64 = 0; // first accepted sample of the dot

fn startValDot() void {
    val_phase = .dot;
    val_t0 = now();
    val_sum = .{};
    val_collected_s = 0;
    val_last_acc = 0;
    val_fix_t = 0;
    resetDotColour();
}
var val_live = false;

fn enterValidate() void {
    val_idx = 0;
    val_results = .{null} ** 9;
    val_fallback = .{false} ** 9;
    val_t0 = now();
    val_phase = .intro;
    setCursorHidden(true);
    // Fresh area (the errors are converted to mm with it).
    src.getDisplayArea(onAreaGot, null) catch {};
}

/// Collect the sample if it belongs to a fixation on the dot (or anywhere
/// once in fallback). Called after the sample went into the detector.
fn valAccumulate(s: *const core.GazeSample) void {
    if (step != .validate or val_phase != .dot) return;
    if (val_collected_s >= VAL_COLLECT_S) return;
    const l = eyeValid(s.validity_L);
    const r = eyeValid(s.validity_R);
    if (!l and !r) return;
    const f = currentFixation() orelse return;
    const t = VAL_POINTS[val_idx];
    if (!val_fallback[val_idx] and fixOffsetDeg(f, t[0], t[1]) > VAL_RADIUS_DEG) return;
    const tn = now();
    if (val_fix_t == 0) val_fix_t = tn;
    if (val_last_acc != 0 and tn - val_last_acc < 100_000) val_collected_s += @as(f64, @floatFromInt(tn - val_last_acc)) / 1e6;
    val_last_acc = tn;
    val_sum.gx += s.gaze_point_2d_norm[0];
    val_sum.gy += s.gaze_point_2d_norm[1];
    val_sum.n += 1;
    if (l) {
        val_sum.z += s.eye_origin_L_mm[2];
        val_sum.zn += 1;
    }
    if (r) {
        val_sum.z += s.eye_origin_R_mm[2];
        val_sum.zn += 1;
    }
}

fn tickValidate() void {
    switch (val_phase) {
        .intro => if (secsSince(val_t0) >= INTRO_S) startValDot(),
        .dot => {
            const el = secsSince(val_t0);
            if (!val_fallback[val_idx] and val_fix_t == 0 and el >= VAL_FALLBACK_S) {
                val_fallback[val_idx] = true;
                log.warn("validation dot {d}: no fixation within {d:.0} deg after {d:.0}s, measuring on any stable fixation", .{ val_idx, VAL_RADIUS_DEG, VAL_FALLBACK_S });
            }
            if (val_collected_s < VAL_COLLECT_S and el < VAL_TIMEOUT_S) return;
            const t = VAL_POINTS[val_idx];
            const enough = val_collected_s >= VAL_MIN_COLLECT_S;
            if (val_fix_t != 0) {
                const fix_after = @as(f64, @floatFromInt(val_fix_t - val_t0)) / 1e6;
                const fb: []const u8 = if (val_fallback[val_idx]) ", fallback (not near the dot)" else "";
                log.info("validation dot {d}: fixation after {d:.2}s, {d:.2}s of fixation ({d} samples) in {d:.2}s{s}", .{ val_idx, fix_after, val_collected_s, val_sum.n, el, fb });
            }
            if (enough and val_sum.n > 0 and val_sum.zn > 0 and device_area != null) {
                const n: f64 = @floatFromInt(val_sum.n);
                const e = geo.pointError(t[0], t[1], val_sum.gx / n, val_sum.gy / n, val_sum.z / @as(f64, @floatFromInt(val_sum.zn)), device_area.?, val_sum.n);
                val_results[val_idx] = e;
                log.info("validation dot {d} ({d:.1},{d:.1}): {d:.2} deg, {d:.1} mm (dx {d:.1} dy {d:.1}), eye z {d:.0} mm, {d} samples", .{ val_idx, t[0], t[1], e.err_deg, e.err_mm, e.dx_mm, e.dy_mm, e.eye_z_mm, e.samples });
            } else {
                log.warn("validation dot {d}: no fixation ({d:.2}s collected in {d:.1}s)", .{ val_idx, val_collected_s, el });
            }
            val_idx += 1;
            val_t0 = now();
            if (val_idx == VAL_POINTS.len) {
                val_phase = .results;
                setCursorHidden(false);
                const s = geo.summarize(&val_results);
                log.info("validation: {d}/9 dots, mean {d:.2} deg ({d:.1} mm), max {d:.2} deg ({d:.1} mm), eye distance {d:.0} mm", .{ s.n, s.mean_deg, s.mean_mm, s.max_deg, s.max_mm, s.mean_eye_z_mm });
            } else startValDot();
        },
        else => {},
    }
}

fn keyValidate(keyval: c_uint) void {
    if (val_phase != .results) return;
    switch (keyval) {
        c.GDK_KEY_r, c.GDK_KEY_R => enterStep(.position),
        c.GDK_KEY_v, c.GDK_KEY_V => enterValidate(),
        c.GDK_KEY_g, c.GDK_KEY_G => val_live = !val_live,
        c.GDK_KEY_Return, c.GDK_KEY_KP_Enter, c.GDK_KEY_space => quit(0),
        else => {},
    }
}

fn drawValidate(cr: *c.cairo_t, w: f64, h: f64) void {
    switch (val_phase) {
        .intro => {
            _ = text(cr, w / 2, h * 0.45, 28, .center, FG, "Validation: look at each dot until it shrinks away", .{});
            _ = text(cr, w / 2, h * 0.45 + 44 * ui, 18, .center, DIM, "ESC quits (the calibration is already saved)", .{});
            const t = VAL_POINTS[0];
            drawTarget(cr, t[0] * w, t[1] * h, 8 * ui, ACC_DIM);
        },
        .dot => {
            const t = VAL_POINTS[val_idx];
            const r = if (val_collected_s <= 0)
                pulseRadius()
            else
                DOT_BIG + (DOT_SMALL - DOT_BIG) * std.math.clamp(val_collected_s / VAL_COLLECT_S, 0, 1);
            drawDotHint(cr, w, h, val_fallback[val_idx]);
            drawTarget(cr, t[0] * w, t[1] * h, r * ui, dotColour());
        },
        .results => drawResults(cr, w, h),
    }
}

fn qualityColour(deg: f64) Rgb {
    return if (deg < 1.0) GOOD else if (deg < 2.0) ACC else WARN;
}

fn drawResults(cr: *c.cairo_t, w: f64, h: f64) void {
    var any_fallback = false;
    for (VAL_POINTS, val_results, val_fallback) |t, r, fb| {
        const tx = t[0] * w;
        const ty = t[1] * h;
        c.cairo_set_line_width(cr, 2 * ui);
        c.cairo_set_source_rgb(cr, DIM[0], DIM[1], DIM[2]);
        c.cairo_new_path(cr);
        c.cairo_arc(cr, tx, ty, 10 * ui, 0, 2 * std.math.pi);
        c.cairo_stroke(cr);
        if (r) |e| {
            const col = qualityColour(e.err_deg);
            const gx = e.gx * w;
            const gy = e.gy * h;
            c.cairo_set_source_rgb(cr, col[0], col[1], col[2]);
            c.cairo_new_path(cr);
            c.cairo_move_to(cr, tx, ty);
            c.cairo_line_to(cr, gx, gy);
            c.cairo_stroke(cr);
            c.cairo_new_path(cr);
            c.cairo_arc(cr, gx, gy, 5 * ui, 0, 2 * std.math.pi);
            c.cairo_fill(cr);
            const below = t[1] < 0.5;
            _ = text(cr, tx, ty + @as(f64, if (below) 22 else -48) * ui, 18, .center, col, "{d:.2}° · {d:.1} mm{s}", .{ e.err_deg, e.err_mm, if (fb) " *" else "" });
            any_fallback = any_fallback or fb;
        } else {
            _ = text(cr, tx, ty + 22 * ui, 18, .center, WARN, "no fixation", .{});
        }
    }

    const s = geo.summarize(&val_results);
    var y = h * 0.3;
    y += text(cr, w / 2, y, 34, .center, FG, "Step 4 · Validation", .{});
    y += 10 * ui;
    if (s.n == 0) {
        y += text(cr, w / 2, y, 24, .center, WARN, "No gaze was recorded: were your eyes in front of the tracker?", .{});
    } else {
        y += text(cr, w / 2, y, 26, .center, qualityColour(s.mean_deg), "mean error {d:.2}° ({d:.1} mm) · max {d:.2}° ({d:.1} mm)", .{ s.mean_deg, s.mean_mm, s.max_deg, s.max_mm });
        y += text(cr, w / 2, y, 18, .center, DIM, "{d}/9 dots · eyes at {d:.0} cm · below 1° is good, above 2° redo the calibration", .{ s.n, s.mean_eye_z_mm / 10 });
        if (any_fallback) y += text(cr, w / 2, y, 18, .center, ACC, "* no fixation within {d:.0}° of the dot: measured on the fixation found, the error may be larger", .{VAL_RADIUS_DEG});
    }
    y += 16 * ui;
    _ = text(cr, w / 2, y, 20, .center, FG, "R redo calibration · V validate again · G live gaze {s} · ENTER done", .{if (val_live) "off" else "on"});
    if (val_live) drawGazeDot(cr, w, h);
}

// ─── Steps ──────────────────────────────────────────────────────────

fn enterStep(s: Step) void {
    step = s;
    clearMsg();
    log.info("step: {s}", .{@tagName(s)});
    switch (s) {
        .display => setCursorHidden(false),
        .position => setCursorHidden(false),
        .calibrate => enterCalibrate(),
        .validate => enterValidate(),
    }
    redraw();
}

fn onEscape() void {
    switch (step) {
        .calibrate => escCalibrate(),
        else => {
            log.info("cancelled", .{});
            quit(1);
        },
    }
}

// ─── Drawing ────────────────────────────────────────────────────────

const Align = enum { left, center, right };

/// Draw one line of text at (x, y) (top), size in px × ui. Returns its height.
fn text(cr: *c.cairo_t, x: f64, y: f64, size: f64, al: Align, col: Rgb, comptime fmt: []const u8, args: anytype) f64 {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    const layout = c.pango_cairo_create_layout(cr) orelse return 0;
    defer c.g_object_unref(layout);
    const fd = c.pango_font_description_from_string("Sans");
    defer c.pango_font_description_free(fd);
    c.pango_font_description_set_absolute_size(fd, size * ui * @as(f64, c.PANGO_SCALE));
    c.pango_layout_set_font_description(layout, fd);
    c.pango_layout_set_text(layout, s.ptr, @intCast(s.len));
    var tw: c_int = 0;
    var th: c_int = 0;
    c.pango_layout_get_pixel_size(layout, &tw, &th);
    const fw: f64 = @floatFromInt(tw);
    const x0 = switch (al) {
        .left => x,
        .center => x - fw / 2,
        .right => x - fw,
    };
    c.cairo_set_source_rgb(cr, col[0], col[1], col[2]);
    c.cairo_move_to(cr, x0, y);
    c.pango_cairo_show_layout(cr, layout);
    c.cairo_new_path(cr); // show_layout leaves a current point behind
    return @as(f64, @floatFromInt(th)) + 4 * ui;
}

fn drawMsg(cr: *c.cairo_t, w: f64, y: f64) void {
    if (msg.len > 0) _ = text(cr, w / 2, y, 22, .center, if (msg_is_error) WARN else GOOD, "{s}", .{msg});
}

fn draw(_: [*c]c.GtkDrawingArea, cr_opt: ?*c.cairo_t, width: c_int, height: c_int, _: ?*anyopaque) callconv(.c) void {
    const cr = cr_opt orelse return;
    if (canvas) |cv| if (c.gtk_native_get_surface(c.gtk_widget_get_native(cv))) |s| {
        draw_scale = c.gdk_surface_get_scale(s);
    };
    const w = @as(f64, @floatFromInt(width)) * draw_scale;
    const h = @as(f64, @floatFromInt(height)) * draw_scale;
    c.cairo_scale(cr, 1 / draw_scale, 1 / draw_scale);
    c.cairo_set_source_rgb(cr, BG[0], BG[1], BG[2]);
    c.cairo_paint(cr);
    switch (step) {
        .display => drawDisplay(cr, w, h),
        .position => drawPosition(cr, w, h),
        .calibrate => drawCalibrate(cr, w, h),
        .validate => drawValidate(cr, w, h),
    }
    if (daemon_lost and step != .position) _ = text(cr, w / 2, h * 0.92, 22, .center, WARN, "Lost the connection to tobiifreed · ESC quits", .{});
}

// ─── Input ──────────────────────────────────────────────────────────

fn onKey(_: ?*c.GtkEventControllerKey, keyval: c_uint, _: c_uint, state: c.GdkModifierType, _: ?*anyopaque) callconv(.c) c.gboolean {
    if (keyval == c.GDK_KEY_Escape) {
        onEscape();
        return 1;
    }
    const shift = (state & c.GDK_SHIFT_MASK) != 0;
    switch (step) {
        .display => keyDisplay(keyval, shift),
        .position => if (keyval == c.GDK_KEY_space and !daemon_lost) enterStep(.calibrate),
        .calibrate => if (cal_phase == .failed and (keyval == c.GDK_KEY_r or keyval == c.GDK_KEY_R) and !daemon_lost) enterStep(.position),
        .validate => keyValidate(keyval),
    }
    redraw();
    return 1;
}

fn onDragBegin(_: ?*c.GtkGestureDrag, x: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    if (step != .display) return;
    const px = x * draw_scale;
    const d0 = @abs(px - @as(f64, @floatFromInt(marks[0])));
    const d1 = @abs(px - @as(f64, @floatFromInt(marks[1])));
    const i: usize = if (d0 <= d1) 0 else 1;
    sel = i;
    drag_line = i;
    drag_start_col = marks[i];
    redraw();
}

fn onDragUpdate(_: ?*c.GtkGestureDrag, ox: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    const i = drag_line orelse return;
    if (step != .display) return;
    moveMark(i, drag_start_col + @as(i32, @intFromFloat(@round(ox * draw_scale))));
}

fn onDragEnd(_: ?*c.GtkGestureDrag, _: f64, _: f64, _: ?*anyopaque) callconv(.c) void {
    drag_line = null;
}

// ─── Main loop hooks ────────────────────────────────────────────────

fn onGaze(s: *const core.GazeSample) void {
    const t = now();
    gaze = s.*;
    gaze_time_us = t;
    gaze_count += 1;
    const l = eyeValid(s.validity_L);
    const r = eyeValid(s.validity_R);
    if (l or r) {
        var z: f64 = 0;
        if (l) z += s.eye_origin_L_mm[2];
        if (r) z += s.eye_origin_R_mm[2];
        z /= @as(f64, if (l and r) 2 else 1);
        if (z > 100) eye_z_mm = z;
        const mm = screenSizeMm();
        fix_det.add(t, s.gaze_point_2d_norm[0] * mm[0], s.gaze_point_2d_norm[1] * mm[1]);
        gaze_last_valid_us = t;
    } else fix_det.reset();
    valAccumulate(s);
}

/// Screen size in mm: the device area, else the monitor's EDID size.
fn screenSizeMm() [2]f64 {
    if (device_area) |a| return geo.areaSize(a);
    if (mon_mm[0] > 0 and mon_mm[1] > 0) return .{ @floatFromInt(mon_mm[0]), @floatFromInt(mon_mm[1]) };
    return .{ @as(f64, @floatFromInt(width_px)) * 0.27, @as(f64, @floatFromInt(height_px)) * 0.27 };
}

fn usFromS(s: f64) i64 {
    return @intFromFloat(s * 1e6);
}

fn currentFixation() ?fixation.Fixation {
    return fix_det.fixation(now(), usFromS(FIX_WINDOW_S), fixation.degToMm(FIX_DISPERSION_DEG, eye_z_mm), usFromS(FIX_MAX_AGE_S));
}

/// Angle (deg) between a fixation and a target (normalised coords).
fn fixOffsetDeg(f: fixation.Fixation, tx: f64, ty: f64) f64 {
    const mm = screenSizeMm();
    return fixation.mmToDeg(std.math.hypot(f.x - tx * mm[0], f.y - ty * mm[1]), eye_z_mm);
}

fn gazeLost() bool {
    return gaze_last_valid_us == 0 or now() - gaze_last_valid_us > usFromS(GAZE_LOST_S);
}

fn pulseRadius() f64 {
    const ph = @as(f64, @floatFromInt(@mod(now(), usFromS(PULSE_PERIOD_S)))) / 1e6 / PULSE_PERIOD_S;
    return DOT_BIG + DOT_PULSE * @sin(2 * std.math.pi * ph);
}

/// Hint under a gaze-contingent dot (centre of the screen, where no dot is).
fn drawDotHint(cr: *c.cairo_t, w: f64, h: f64, fallback: bool) void {
    if (gazeLost()) {
        _ = text(cr, w / 2, h * 0.45, 24, .center, ACC, "Eyes not found: look at the screen", .{});
    } else if (fallback) {
        _ = text(cr, w / 2, h * 0.45, 22, .center, DIM, "Look at the centre of the orange dot", .{});
    }
}

fn onReadable(_: c_int, _: c.GIOCondition, _: ?*anyopaque) callconv(.c) c.gboolean {
    src.poll();
    if (!src.connected) {
        daemon_lost = true;
        log.err("lost the connection to tobiifreed", .{});
        if (step == .calibrate and (cal_phase == .cancelling or cal_phase == .restoring) and cal_quit_after) quit(1);
        redraw();
        return 0;
    }
    return 1;
}

// Active dot colour: 0 = orange (waiting), 1 = blue (gaze on it).
var dot_blend: f64 = 0;
var dot_blend_t: i64 = 0;

/// Is the gaze on the active dot right now (fixation accepted)?
fn gazeOnDot() bool {
    return switch (step) {
        .calibrate => cal_phase == .adding or (cal_phase == .gazing and cal_holding),
        // Collecting: an accepted sample in the last 150 ms.
        .validate => val_phase == .dot and val_last_acc != 0 and now() - val_last_acc < 150_000,
        else => false,
    };
}

/// A new dot starts orange.
fn resetDotColour() void {
    dot_blend = 0;
    dot_blend_t = now();
}

fn updateDotColour() void {
    const t = now();
    const dt = if (dot_blend_t == 0) 0 else @as(f64, @floatFromInt(t - dot_blend_t)) / 1e6;
    dot_blend_t = t;
    const target: f64 = if (gazeOnDot()) 1 else 0;
    const stepv = dt / DOT_FADE_S;
    dot_blend = if (target > dot_blend) @min(target, dot_blend + stepv) else @max(target, dot_blend - stepv);
}

fn dotColour() Rgb {
    var col: Rgb = undefined;
    for (&col, ACC, ON_GAZE) |*o, a, b| o.* = a + (b - a) * dot_blend;
    return col;
}

fn onTick(_: ?*c.GtkWidget, _: ?*c.GdkFrameClock, _: ?*anyopaque) callconv(.c) c.gboolean {
    switch (step) {
        .calibrate => tickCalibrate(),
        .validate => tickValidate(),
        else => {},
    }
    updateDotColour();
    redraw();
    return 1;
}

fn onSignal(_: ?*anyopaque) callconv(.c) c.gboolean {
    log.info("signal: cancelling", .{});
    onEscape();
    return 1;
}

// ─── Output selection ───────────────────────────────────────────────

/// Focused output name from `hyprctl monitors -j` (caller frees), or null.
fn hyprFocusedOutput() ?[]u8 {
    if (std.posix.getenv("HYPRLAND_INSTANCE_SIGNATURE") == null) return null;
    const r = std.process.Child.run(.{ .allocator = gpa, .argv = &.{ "hyprctl", "monitors", "-j" }, .max_output_bytes = 1 << 20 }) catch return null;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, r.stdout, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;
    for (parsed.value.array.items) |m| {
        if (m != .object) continue;
        const f = m.object.get("focused") orelse continue;
        if (f == .bool and f.bool) {
            const n = m.object.get("name") orelse continue;
            if (n == .string) return gpa.dupe(u8, n.string) catch null;
        }
    }
    return null;
}

fn findMonitor(name: []const u8) ?*c.GdkMonitor {
    const mons = c.gdk_display_get_monitors(c.gdk_display_get_default());
    const n = c.g_list_model_get_n_items(mons);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const m: *c.GdkMonitor = @ptrCast(@alignCast(c.g_list_model_get_item(mons, i) orelse continue));
        if (c.gdk_monitor_get_connector(m)) |conn| {
            if (std.mem.eql(u8, std.mem.span(conn), name)) return m;
        }
        c.g_object_unref(m);
    }
    return null;
}

fn listMonitors() void {
    const mons = c.gdk_display_get_monitors(c.gdk_display_get_default());
    const n = c.g_list_model_get_n_items(mons);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const m: *c.GdkMonitor = @ptrCast(@alignCast(c.g_list_model_get_item(mons, i) orelse continue));
        defer c.g_object_unref(m);
        const conn = c.gdk_monitor_get_connector(m);
        std.debug.print("  {s}\n", .{if (conn) |s| std.mem.span(s) else "?"});
    }
}

fn firstMonitor() ?*c.GdkMonitor {
    const mons = c.gdk_display_get_monitors(c.gdk_display_get_default());
    if (c.g_list_model_get_n_items(mons) == 0) return null;
    return @ptrCast(@alignCast(c.g_list_model_get_item(mons, 0)));
}

fn pickMonitor() ?*c.GdkMonitor {
    if (opt_output) |name| {
        if (findMonitor(name)) |m| return m;
        std.debug.print("tobiifree-setup: no output named {s}; outputs:\n", .{name});
        listMonitors();
        return null;
    }
    if (config.loadOutput(gpa)) |name| {
        defer gpa.free(name);
        if (findMonitor(name)) |m| {
            log.info("output {s} (from tobii.json)", .{name});
            return m;
        }
        log.warn("output {s} from tobii.json is not connected, using the focused one", .{name});
    }
    if (hyprFocusedOutput()) |name| {
        defer gpa.free(name);
        if (findMonitor(name)) |m| {
            log.info("output {s} (focused)", .{name});
            return m;
        }
    }
    return firstMonitor();
}

fn useMonitor(m: *c.GdkMonitor) void {
    monitor = m;
    const conn = c.gdk_monitor_get_connector(m);
    const name = if (conn) |s| std.mem.span(s) else "?";
    const len = @min(name.len, mon_name_buf.len);
    @memcpy(mon_name_buf[0..len], name[0..len]);
    mon_name = mon_name_buf[0..len];
    var g: c.GdkRectangle = undefined;
    c.gdk_monitor_get_geometry(m, &g);
    mon_scale = c.gdk_monitor_get_scale(m);
    width_px = @intFromFloat(@round(@as(f64, @floatFromInt(g.width)) * mon_scale));
    height_px = @intFromFloat(@round(@as(f64, @floatFromInt(g.height)) * mon_scale));
    mon_mm = .{ c.gdk_monitor_get_width_mm(m), c.gdk_monitor_get_height_mm(m) };
    draw_scale = mon_scale;
    ui = @max(1.0, mon_scale);
    log.info("output {s}: {d}x{d} logical, scale {d:.3} -> {d}x{d} px, {d}x{d} mm", .{ mon_name, g.width, g.height, mon_scale, width_px, height_px, mon_mm[0], mon_mm[1] });
}

// ─── GTK setup ──────────────────────────────────────────────────────

fn activate(app: *c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    const m = pickMonitor() orelse {
        exit_code = 2;
        return;
    };
    useMonitor(m);
    initMarks();

    const win = c.gtk_application_window_new(app);
    window = win;
    const gw: *c.GtkWindow = @ptrCast(win);
    c.gtk_layer_init_for_window(gw);
    c.gtk_layer_set_layer(gw, c.GTK_LAYER_SHELL_LAYER_OVERLAY);
    for ([_]c.GtkLayerShellEdge{ c.GTK_LAYER_SHELL_EDGE_TOP, c.GTK_LAYER_SHELL_EDGE_BOTTOM, c.GTK_LAYER_SHELL_EDGE_LEFT, c.GTK_LAYER_SHELL_EDGE_RIGHT }) |e| {
        c.gtk_layer_set_anchor(gw, e, 1);
    }
    c.gtk_layer_set_exclusive_zone(gw, -1); // cover bars too
    c.gtk_layer_set_keyboard_mode(gw, c.GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE);
    c.gtk_layer_set_namespace(gw, "tobiifree-setup");
    c.gtk_layer_set_monitor(gw, m);
    c.gtk_window_set_decorated(gw, 0);

    const da = c.gtk_drawing_area_new();
    canvas = da;
    c.gtk_drawing_area_set_draw_func(@ptrCast(da), draw, null, null);
    c.gtk_widget_set_hexpand(da, 1);
    c.gtk_widget_set_vexpand(da, 1);
    c.gtk_window_set_child(gw, da);

    const keys = c.gtk_event_controller_key_new();
    _ = c.g_signal_connect_data(@ptrCast(keys), "key-pressed", @ptrCast(&onKey), null, null, 0);
    c.gtk_widget_add_controller(win, keys);

    const drag = c.gtk_gesture_drag_new();
    _ = c.g_signal_connect_data(@ptrCast(drag), "drag-begin", @ptrCast(&onDragBegin), null, null, 0);
    _ = c.g_signal_connect_data(@ptrCast(drag), "drag-update", @ptrCast(&onDragUpdate), null, null, 0);
    _ = c.g_signal_connect_data(@ptrCast(drag), "drag-end", @ptrCast(&onDragEnd), null, null, 0);
    c.gtk_widget_add_controller(da, @ptrCast(drag));

    _ = c.gtk_widget_add_tick_callback(da, onTick, null, null);
    _ = c.g_unix_fd_add(src.fd, c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR, onReadable, null);
    _ = c.g_unix_signal_add(std.posix.SIG.INT, onSignal, null);
    _ = c.g_unix_signal_add(std.posix.SIG.TERM, onSignal, null);

    // (validate fetches it itself)
    if (opt_only != .validate) src.getDisplayArea(onAreaGot, null) catch |err| log.warn("get_display_area: {}", .{err});

    enterStep(switch (opt_only) {
        .all, .display => .display,
        .calibrate => .position,
        .validate => .validate,
    });
    c.gtk_window_present(gw);
}

// ─── Main ───────────────────────────────────────────────────────────

fn parseArgs() !void {
    var args = std.process.args();
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, a, "--output")) {
            opt_output = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--gap")) {
            const v = args.next() orelse return error.MissingValue;
            opt_gap = try std.fmt.parseFloat(f64, v);
            if (!(opt_gap.? >= 0 and opt_gap.? < 500)) return error.BadGap;
        } else if (std.mem.eql(u8, a, "--step")) {
            const v = args.next() orelse return error.MissingValue;
            opt_only = std.meta.stringToEnum(Only, v) orelse return error.BadStep;
            if (opt_only == .all) return error.BadStep;
        } else {
            std.debug.print("tobiifree-setup: unknown argument {s}\n\n{s}", .{ a, usage });
            std.process.exit(2);
        }
    }
}

pub fn main() u8 {
    parseArgs() catch |err| {
        std.debug.print("tobiifree-setup: bad arguments ({})\n\n{s}", .{ err, usage });
        return 2;
    };

    gap_mm = opt_gap orelse config.loadGap(gpa) orelse geo.DEFAULT_GAP_MM;
    log.info("gap {d:.1} mm ({s})", .{ gap_mm, if (opt_gap != null) "--gap" else if (config.loadGap(gpa) != null) "tobii.json" else "default" });

    src = SocketSource.initWithAllocator(gpa) catch |err| {
        std.debug.print("tobiifree-setup: cannot reach tobiifreed ({}). Is the daemon running?\n", .{err});
        return 1;
    };
    defer src.deinit();
    src.onGaze(onGaze);

    const app = c.gtk_application_new("dev.tobiifree.setup", c.G_APPLICATION_NON_UNIQUE);
    gtk_app = @ptrCast(app);
    _ = c.g_signal_connect_data(@ptrCast(app), "activate", @ptrCast(&activate), null, null, 0);
    _ = c.g_application_run(@ptrCast(app), 0, null);
    c.g_object_unref(@ptrCast(app));
    return exit_code;
}
