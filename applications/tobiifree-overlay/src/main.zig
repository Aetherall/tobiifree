// tobiifree-overlay — transparent native overlay that renders the ET5 gaze dot.
//
// Uses GTK4 + gtk4-layer-shell for Wayland overlay. Delegates all
// protocol handling to the Tracker module from driver/.
// Renders the gaze dot with cairo in a single GtkDrawingArea.

const std = @import("std");
const core = @import("tobiifree_core");
const GazeSource = @import("gaze_source").GazeSource;
const UsbSource = @import("usb_source").UsbSource;
const SocketSource = @import("socket_source").SocketSource;
const DisplayArea = UsbSource.DisplayArea;

const log = std.log.scoped(.overlay);

/// Show all log levels (debug included) for all scopes.
pub const std_options: std.Options = .{
    .log_level = .debug,
};
const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("gtk4-layer-shell.h");
});

const DOT_RADIUS = 12.0;
const CONFIG_PATH = ".config/tobii.json";

// ─── Gaze state (written by callback, read by GTK draw) ────────────

var gaze_x: f64 = 0.5;
var gaze_y: f64 = 0.5;
var gaze_valid: bool = false;

// ─── GTK state ──────────────────────────────────────────────────────

var canvas: ?*c.GtkWidget = null;
var screen_w: f64 = 1920;
var screen_h: f64 = 1080;
var usb_source: UsbSource = undefined;
var socket_source: SocketSource = undefined;
var source: GazeSource = undefined;
var gtk_app: ?*c.GApplication = null;
var quit: bool = false;

// ─── Tracker callback ───────────────────────────────────────────────

var gaze_count: u64 = 0;
var gaze_valid_count: u64 = 0;

fn onGaze(sample: *const core.GazeSample) void {
    gaze_count += 1;
    if (sample.validity_L == 0 or sample.validity_R == 0) {
        gaze_x = sample.gaze_point_2d_norm[0];
        gaze_y = sample.gaze_point_2d_norm[1];
        gaze_valid = true;
        gaze_valid_count += 1;
        if (gaze_valid_count <= 3 or gaze_valid_count % 100 == 0) {
            log.info("gaze: x={d:.3} y={d:.3} (sample #{d})", .{ gaze_x, gaze_y, gaze_count });
        }
    } else {
        gaze_valid = false;
    }
    if (gaze_count <= 3 or gaze_count % 100 == 0) {
        log.debug("gaze sample #{d}: vL={d} vR={d} valid_total={d}", .{
            gaze_count, sample.validity_L, sample.validity_R, gaze_valid_count,
        });
    }
}

// ─── Poll callback (GLib timeout @ ~60Hz) ────────────────────────────

fn pollTracker(_: ?*anyopaque) callconv(.c) c_int {
    if (quit) {
        if (gtk_app) |app| c.g_application_quit(app);
        return 0;
    }

    source.poll();
    if (canvas) |w| c.gtk_widget_queue_draw(w);

    return 1; // keep source
}

// ─── Cairo draw function ────────────────────────────────────────────

fn drawOverlay(_: [*c]c.GtkDrawingArea, cr: ?*c.cairo_t, width: c_int, height: c_int, _: ?*anyopaque) callconv(.c) void {
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);

    // Clear to fully transparent.
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);

    // Draw gaze dot.
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
    const alpha: f64 = if (gaze_valid) 0.85 else 0.15;
    c.cairo_set_source_rgba(cr, 0.49, 0.98, 0.66, alpha); // #7df9a8
    const px = gaze_x * w;
    const py = gaze_y * h;
    c.cairo_arc(cr, px, py, DOT_RADIUS, 0, 2.0 * std.math.pi);
    c.cairo_fill(cr);
}

// ─── GTK setup ───────────────────────────────────────────────────────

fn onRealize(widget: *c.GtkWidget, _: ?*anyopaque) callconv(.c) void {
    const surface = c.gtk_native_get_surface(@ptrCast(widget));
    if (surface) |s| {
        c.gdk_surface_set_opaque_region(s, null);
        const empty = c.cairo_region_create();
        c.gdk_surface_set_input_region(s, empty);
        c.cairo_region_destroy(empty);
    }
}

fn activate(_: *c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    const app_ptr = @as(*c.GtkApplication, @ptrCast(@alignCast(c.g_application_get_default())));
    const window = c.gtk_application_window_new(app_ptr);

    // Layer shell (Wayland overlay).
    c.gtk_layer_init_for_window(@ptrCast(window));
    c.gtk_layer_set_layer(@ptrCast(window), c.GTK_LAYER_SHELL_LAYER_OVERLAY);
    c.gtk_layer_set_anchor(@ptrCast(window), c.GTK_LAYER_SHELL_EDGE_TOP, 1);
    c.gtk_layer_set_anchor(@ptrCast(window), c.GTK_LAYER_SHELL_EDGE_BOTTOM, 1);
    c.gtk_layer_set_anchor(@ptrCast(window), c.GTK_LAYER_SHELL_EDGE_LEFT, 1);
    c.gtk_layer_set_anchor(@ptrCast(window), c.GTK_LAYER_SHELL_EDGE_RIGHT, 1);
    c.gtk_layer_set_keyboard_mode(@ptrCast(window), c.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
    c.gtk_layer_set_namespace(@ptrCast(window), "tobiifree-overlay");

    _ = c.g_signal_connect_data(@ptrCast(window), "realize", @ptrCast(&onRealize), null, null, 0);

    c.gtk_window_set_decorated(@ptrCast(window), 0);

    // CSS — unset window background for transparency.
    const css = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(css, "window, headerbar { background: unset; }");
    c.gtk_style_context_add_provider_for_display(
        c.gdk_display_get_default(),
        @ptrCast(css),
        c.GTK_STYLE_PROVIDER_PRIORITY_USER,
    );

    // Pin overlay to the largest monitor.
    const display = c.gdk_display_get_default();
    if (display) |d| {
        const monitors = c.gdk_display_get_monitors(d);
        if (monitors) |mons| {
            const n_mons = c.g_list_model_get_n_items(mons);
            var best_mon: ?*c.GdkMonitor = null;
            var best_area: f64 = 0;
            var i: u32 = 0;
            while (i < n_mons) : (i += 1) {
                const mon = c.g_list_model_get_item(mons, i);
                if (mon) |m| {
                    var geo: c.GdkRectangle = undefined;
                    const monitor: *c.GdkMonitor = @ptrCast(@alignCast(m));
                    c.gdk_monitor_get_geometry(monitor, &geo);
                    log.info("monitor {d}: {d}x{d}", .{ i, geo.width, geo.height });
                    const area: f64 = @as(f64, @floatFromInt(geo.width)) * @as(f64, @floatFromInt(geo.height));
                    if (area > best_area) {
                        if (best_mon) |prev| c.g_object_unref(prev);
                        best_mon = monitor;
                        best_area = area;
                        screen_w = @floatFromInt(geo.width);
                        screen_h = @floatFromInt(geo.height);
                    } else {
                        c.g_object_unref(m);
                    }
                }
            }
            if (best_mon) |m| {
                c.gtk_layer_set_monitor(@ptrCast(window), m);
                log.info("overlay: {d:.0}x{d:.0}", .{ screen_w, screen_h });
                c.g_object_unref(m);
            }
        }
    }

    // Single drawing area — all rendering via cairo.
    const da = c.gtk_drawing_area_new();
    c.gtk_drawing_area_set_draw_func(@ptrCast(da), drawOverlay, null, null);
    c.gtk_window_set_child(@ptrCast(window), da);
    canvas = da;

    c.gtk_window_present(@ptrCast(window));

    _ = c.g_idle_add(@as(c.GSourceFunc, @ptrCast(&pollTracker)), null);
}

// ─── Signal handling ─────────────────────────────────────────────────

fn handleSignal(_: c_int) callconv(.c) void {
    quit = true;
    if (gtk_app) |app| c.g_application_quit(app);
}

fn installSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

// ─── Config ─────────────────────────────────────────────────────────

const Config = struct {
    display_area: ?std.json.Value = null,
};

fn loadConfig() ?std.json.Parsed(Config) {
    const home = std.posix.getenv("HOME") orelse return null;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, CONFIG_PATH }) catch return null;

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    return std.json.parseFromSlice(Config, std.heap.page_allocator, buf[0..n], .{
        .ignore_unknown_fields = true,
    }) catch null;
}

/// Parse a position expression: a number, or a string like "t + 10", "b - 10", "l + 50".
/// Anchors resolve relative to the half-dimension:
///   t = +half, b = -half, l = -half, r = +half, c = 0
fn parsePositionExpr(val: std.json.Value, half: f64, is_vertical: bool) ?f64 {
    switch (val) {
        .float => |f| return f,
        .integer => |i| return @floatFromInt(i),
        .string => |s| return evalAnchorExpr(s, half, is_vertical),
        else => return null,
    }
}

fn evalAnchorExpr(expr: []const u8, half: f64, is_vertical: bool) ?f64 {
    var pos: usize = 0;
    // skip leading whitespace
    while (pos < expr.len and expr[pos] == ' ') pos += 1;
    if (pos >= expr.len) return null;

    // parse anchor letter
    const anchor: f64 = switch (expr[pos]) {
        't' => if (is_vertical) half else return null,
        'b' => if (is_vertical) -half else return null,
        'l' => if (!is_vertical) -half else return null,
        'r' => if (!is_vertical) half else return null,
        'c' => 0,
        else => return null,
    };
    pos += 1;

    // skip whitespace
    while (pos < expr.len and expr[pos] == ' ') pos += 1;
    if (pos >= expr.len) return anchor;

    // parse operator
    const sign: f64 = switch (expr[pos]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    pos += 1;

    // skip whitespace
    while (pos < expr.len and expr[pos] == ' ') pos += 1;
    if (pos >= expr.len) return null;

    // parse number
    const num = std.fmt.parseFloat(f64, expr[pos..]) catch return null;
    return anchor + sign * num;
}

fn getFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => null,
    };
}

fn displayAreaFromConfig(cfg: ?std.json.Parsed(Config)) DisplayArea {
    var area = DisplayArea{};
    const parsed = cfg orelse return area;
    const da_val = parsed.value.display_area orelse return area;
    const obj = switch (da_val) {
        .object => |o| o,
        else => return area,
    };

    if (getFloat(obj, "w_mm")) |v| area.w_mm = v;
    if (getFloat(obj, "h_mm")) |v| area.h_mm = v;
    if (getFloat(obj, "z_mm")) |v| area.z_mm = v;
    if (getFloat(obj, "tilt")) |v| area.tilt_deg = v;

    // cx/cy: position expressions relative to screen center.
    // cx=0 means tracker centered horizontally, cy=0 means centered vertically.
    // "b - 10" means tracker is 10mm below bottom edge.
    // These describe where the tracker is relative to screen center,
    // so ox = -cx - w/2, oy = -cy - h/2.
    const half_w = area.w_mm / 2.0;
    const half_h = area.h_mm / 2.0;

    if (obj.get("cx")) |cx_val| {
        if (parsePositionExpr(cx_val, half_w, false)) |cx| {
            area.ox_mm = -cx - half_w;
        }
    }
    if (obj.get("cy")) |cy_val| {
        if (parsePositionExpr(cy_val, half_h, true)) |cy| {
            area.oy_mm = -cy - half_h;
        }
    }

    return area;
}

// ─── Init config ────────────────────────────────────────────────────

const DEFAULT_CONFIG =
    \\{
    \\  "display_area": {
    \\    "w_mm": 800,
    \\    "h_mm": 340,
    \\    "z_mm": 0,
    \\    "tilt": 0,
    \\    "cx": 0,
    \\    "cy": "b - 10"
    \\  }
    \\}
    \\
;

fn initConfig() bool {
    const home = std.posix.getenv("HOME") orelse {
        log.err("$HOME not set", .{});
        return false;
    };
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, CONFIG_PATH }) catch return false;

    // Check if it already exists.
    if (std.fs.cwd().access(path, .{})) |_| {
        log.info("{s} already exists, not overwriting", .{path});
        return true;
    } else |_| {}

    // Ensure parent directory exists.
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config", .{home}) catch return false;
    std.fs.cwd().makePath(dir_path) catch {};

    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        log.err("could not create {s}: {}", .{ path, err });
        return false;
    };
    defer file.close();
    file.writeAll(DEFAULT_CONFIG) catch |err| {
        log.err("could not write {s}: {}", .{ path, err });
        return false;
    };
    log.info("created {s}", .{path});
    return true;
}

// ─── Main ────────────────────────────────────────────────────────────

const Mode = enum { auto, direct, socket };

pub fn main() void {
    // Parse args.
    var args = std.process.args();
    _ = args.next(); // skip argv[0]
    var mode: Mode = .auto;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--init-config")) {
            _ = initConfig();
            return;
        } else if (std.mem.eql(u8, arg, "--direct")) {
            mode = .direct;
        } else if (std.mem.eql(u8, arg, "--socket")) {
            mode = .socket;
        }
    }

    const cfg = loadConfig();
    const display = displayAreaFromConfig(cfg);
    if (cfg != null) {
        log.info("config: loaded from ~/{s}", .{CONFIG_PATH});
    } else {
        log.warn("config: no ~/{s}, using defaults", .{CONFIG_PATH});
    }
    log.info("display_area: {d:.0}x{d:.0}mm  origin=({d:.0},{d:.0})  z={d:.0}", .{
        display.w_mm, display.h_mm, display.ox_mm, display.oy_mm, display.z_mm,
    });

    // Connect: auto tries socket first, falls back to USB.
    const use_socket = switch (mode) {
        .socket => true,
        .direct => false,
        .auto => blk: {
            socket_source = SocketSource.init() catch break :blk false;
            break :blk true;
        },
    };

    if (use_socket and mode == .socket) {
        socket_source = SocketSource.init() catch |err| {
            log.err("Failed to connect to tobiifreed: {}", .{err});
            return;
        };
    }

    if (use_socket) {
        source = socket_source.gazeSource();
        log.info("source: tobiifreed (socket)", .{});
    } else {
        usb_source = UsbSource.init() catch |err| {
            log.err("Failed to connect: {}", .{err});
            return;
        };
        usb_source.bind();
        if (usb_source.tracker.display.isReset()) {
            log.info("device display area looks reset, applying config", .{});
            _ = usb_source.setDisplayArea(display);
        }
        source = usb_source.gazeSource();
        log.info("source: direct USB", .{});
    }
    defer source.deinit();
    source.onGaze(onGaze);
    installSignalHandlers();

    const app = c.gtk_application_new("dev.tobiifree.overlay", c.G_APPLICATION_NON_UNIQUE);
    gtk_app = @ptrCast(app);
    _ = c.g_signal_connect_data(@ptrCast(app), "activate", @ptrCast(&activate), null, null, 0);
    _ = c.g_application_run(@ptrCast(app), 0, null);
    c.g_object_unref(@ptrCast(app));
}
