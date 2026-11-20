// tobiifree-ctl — command-line client for tobiifreed (uses the Zig SocketSource).
//
//   tobiifree-ctl get-area
//   tobiifree-ctl set-area TLx TLy TLz TRx TRy TRz BLx BLy BLz
//   tobiifree-ctl stimulus
//   tobiifree-ctl start-calibration
//   tobiifree-ctl cancel-calibration          # end the session, keep the device calibration
//   tobiifree-ctl add-point X Y
//   tobiifree-ctl finish-calibration OUT.bin   # replaces the device calibration!
//   tobiifree-ctl retrieve OUT.bin             # the calibration the device runs now
//   tobiifree-ctl apply FILE.bin               # replaces the device calibration!
//   tobiifree-ctl correction                   # state + correction.json of the map
//   tobiifree-ctl correction-set FILE.json     # install a correction map
//   tobiifree-ctl correction-clear             # delete it
//   tobiifree-ctl correction-enable on|off     # all clients, until the daemon restarts

const std = @import("std");
const proto = @import("daemon_protocol");
const SocketSource = @import("socket_source").SocketSource;

pub const std_options: std.Options = .{ .log_level = .warn };

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(s) catch {};
}

fn printArea(c: [9]f64) void {
    out("TL ({d:.3}, {d:.3}, {d:.3})\nTR ({d:.3}, {d:.3}, {d:.3})\nBL ({d:.3}, {d:.3}, {d:.3})\n", .{
        c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8],
    });
}

fn usage() u8 {
    out(
        \\usage: tobiifree-ctl get-area
        \\       tobiifree-ctl set-area TLx TLy TLz TRx TRy TRz BLx BLy BLz
        \\       tobiifree-ctl stimulus
        \\       tobiifree-ctl start-calibration
        \\       tobiifree-ctl cancel-calibration
        \\       tobiifree-ctl add-point X Y
        \\       tobiifree-ctl finish-calibration OUT.bin
        \\       tobiifree-ctl retrieve OUT.bin
        \\       tobiifree-ctl apply FILE.bin
        \\       tobiifree-ctl correction
        \\       tobiifree-ctl correction-set FILE.json
        \\       tobiifree-ctl correction-clear
        \\       tobiifree-ctl correction-enable on|off
        \\
    , .{});
    return 2;
}

fn parseF64s(args: []const []const u8, dst: []f64) !void {
    if (args.len != dst.len) return error.BadArgs;
    for (args, dst) |a, *d| d.* = try std.fmt.parseFloat(f64, a);
}

pub fn main() u8 {
    const gpa = std.heap.page_allocator;
    const argv = std.process.argsAlloc(gpa) catch return 1;
    defer std.process.argsFree(gpa, argv);
    if (argv.len < 2) return usage();
    const verb = argv[1];
    const rest = argv[2..];

    var src = SocketSource.init() catch |err| {
        out("cannot connect to tobiifreed: {}\n", .{err});
        return 1;
    };
    defer src.deinit();

    var payload_buf: [72]u8 = undefined;
    var file_blob: ?[]u8 = null;
    defer if (file_blob) |b| gpa.free(b);

    const cmd: proto.Cmd, const payload: []const u8, const timeout_ms: i64 = blk: {
        if (std.mem.eql(u8, verb, "get-area")) break :blk .{ .get_display_area, &.{}, 5000 };
        if (std.mem.eql(u8, verb, "set-area")) {
            var c: [9]f64 = undefined;
            parseF64s(rest, &c) catch return usage();
            proto.encodeDisplayArea(&payload_buf, c);
            break :blk .{ .set_display_area_corners, &payload_buf, 10000 };
        }
        if (std.mem.eql(u8, verb, "stimulus")) break :blk .{ .get_calibration_stimulus, &.{}, 5000 };
        if (std.mem.eql(u8, verb, "start-calibration")) break :blk .{ .start_calibration, &.{}, 30000 };
        if (std.mem.eql(u8, verb, "cancel-calibration")) break :blk .{ .cancel_calibration, &.{}, 30000 };
        if (std.mem.eql(u8, verb, "add-point")) {
            var p: [2]f64 = undefined;
            parseF64s(rest, &p) catch return usage();
            std.mem.writeInt(u64, payload_buf[0..8], @bitCast(p[0]), .little);
            std.mem.writeInt(u64, payload_buf[8..16], @bitCast(p[1]), .little);
            break :blk .{ .add_calibration_point, payload_buf[0..16], 10000 };
        }
        if (std.mem.eql(u8, verb, "finish-calibration")) {
            if (rest.len != 1) return usage();
            break :blk .{ .finish_calibration, &.{}, 180000 };
        }
        if (std.mem.eql(u8, verb, "retrieve")) {
            if (rest.len != 1) return usage();
            break :blk .{ .retrieve_calibration, &.{}, 60000 };
        }
        if (std.mem.eql(u8, verb, "apply")) {
            if (rest.len != 1) return usage();
            file_blob = std.fs.cwd().readFileAlloc(gpa, rest[0], 4 << 20) catch |err| {
                out("cannot read {s}: {}\n", .{ rest[0], err });
                return 1;
            };
            break :blk .{ .cal_apply, file_blob.?, 180000 };
        }
        if (std.mem.eql(u8, verb, "correction")) break :blk .{ .get_correction, &.{}, 5000 };
        if (std.mem.eql(u8, verb, "correction-clear")) break :blk .{ .clear_correction, &.{}, 5000 };
        if (std.mem.eql(u8, verb, "correction-set")) {
            if (rest.len != 1) return usage();
            file_blob = std.fs.cwd().readFileAlloc(gpa, rest[0], 1 << 20) catch |err| {
                out("cannot read {s}: {}\n", .{ rest[0], err });
                return 1;
            };
            break :blk .{ .set_correction, file_blob.?, 10000 };
        }
        if (std.mem.eql(u8, verb, "correction-enable")) {
            if (rest.len != 1) return usage();
            payload_buf[0] = if (std.mem.eql(u8, rest[0], "on")) 1 else if (std.mem.eql(u8, rest[0], "off")) 0 else return usage();
            break :blk .{ .set_correction_enabled, payload_buf[0..1], 5000 };
        }
        return usage();
    };

    const t0 = std.time.milliTimestamp();
    const reply = src.call(cmd, payload, timeout_ms) catch |err| {
        out("{s}: {}\n", .{ verb, err });
        return 1;
    };
    defer reply.deinit();
    const dt = std.time.milliTimestamp() - t0;
    if (reply.cmd_err) |code| {
        out("{s}: error 0x{x} ({d} ms)\n", .{ verb, code, dt });
        return 1;
    }

    switch (cmd) {
        .get_display_area, .set_display_area_corners => printArea(SocketSource.decodeDisplayArea(reply.data) orelse {
            out("short reply ({} bytes)\n", .{reply.data.len});
            return 1;
        }),
        .get_calibration_stimulus => {
            const s = SocketSource.decodeStimulus(reply.data) orelse {
                out("bad stimulus reply ({} bytes)\n", .{reply.data.len});
                return 1;
            };
            out("{d} points\n", .{s.n});
            for (s.points[0..s.n], 0..) |p, i| out("  [{d}] ({d:.3}, {d:.3})  L status {d:.0} ({d:.4}, {d:.4})  R status {d:.0} ({d:.4}, {d:.4})\n", .{
                i, p.x, p.y, p.left.status, p.left.a, p.left.b, p.right.status, p.right.a, p.right.b,
            });
            out("raw ({d} bytes): {x}\n", .{ s.raw.len, s.raw });
        },
        .finish_calibration, .retrieve_calibration => {
            std.fs.cwd().writeFile(.{ .sub_path = rest[0], .data = reply.data }) catch |err| {
                out("cannot write {s}: {}\n", .{ rest[0], err });
                return 1;
            };
            out("calibration blob: {d} bytes -> {s}\n", .{ reply.data.len, rest[0] });
        },
        .get_correction => {
            if (reply.data.len == 0 or reply.data[0] == 0) {
                out("no correction map\n", .{});
            } else {
                out("correction map: {s}\n", .{if (reply.data[0] == 1) "active" else "stored but inactive (other calibration/area, or disabled)"});
                std.fs.File.stdout().writeAll(reply.data[1..]) catch {};
                out("\n", .{});
            }
        },
        else => out("ok ({d} bytes)\n", .{reply.data.len}),
    }
    out("({d} ms)\n", .{dt});
    return 0;
}
