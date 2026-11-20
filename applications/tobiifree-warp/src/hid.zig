// hid.zig — tell a QMK keyboard (Raw HID) that the host moved the cursor.
//
// The Chocozor sends F19 while a finger rests on its trackpad; when the
// host then moves the cursor to the gaze, the board must not turn the touch
// into a click. On the first real move of a follow session we write one Raw
// HID report: payload byte 0 = 'M', the rest zero, 32 bytes; on Linux hidraw
// a report-ID byte 0x00 comes first (33 bytes written), as chocozor-status
// does for its 'P' reports to the same node (separate writes are separate
// reports).
//
// Discovery: /sys/class/hidraw/hidraw*/device/uevent with
// HID_ID=<bus>:<vid>:<pid> (default 0003:0000FEED:00000130), on USB
// interface `iface` (default 1: device/../bInterfaceNumber); without that
// file (or iface = null) the Raw HID usage page at the start of the report
// descriptor (06 60 ff) identifies the interface.

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.hid);

pub const REPORT_LEN = 32;
pub const CMD_MOVED: u8 = 'M';
const RAW_USAGE_PAGE = [_]u8{ 0x06, 0x60, 0xff };

pub const Config = struct {
    hid_id: []const u8 = "0003:0000FEED:00000130",
    /// USB interface number of the Raw HID interface; null: by descriptor.
    iface: ?u8 = 1,
    sysfs_dir: []const u8 = "/sys/class/hidraw",
    dev_dir: []const u8 = "/dev",
};

/// The report as written to hidraw: report ID 0, then the 32-byte payload.
pub fn report(cmd: u8) [1 + REPORT_LEN]u8 {
    var r = [_]u8{0} ** (1 + REPORT_LEN);
    r[1] = cmd;
    return r;
}

fn readSmall(dir: std.fs.Dir, path: []const u8, buf: []u8) ?[]const u8 {
    const f = dir.openFile(path, .{}) catch return null;
    defer f.close();
    const n = f.readAll(buf) catch return null;
    return buf[0..n];
}

fn hasHidId(uevent: []const u8, id: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, uevent, "\n");
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "HID_ID=") and std.ascii.eqlIgnoreCase(line[7..], id)) return true;
    }
    return false;
}

/// Device node of the matching hidraw ("<dev_dir>/hidrawN" into `out`), or
/// null. The lowest-numbered match wins.
pub fn find(cfg: Config, out: []u8) ?[]const u8 {
    var dir = std.fs.cwd().openDir(cfg.sysfs_dir, .{ .iterate = true }) catch return null;
    defer dir.close();
    var best: ?u32 = null;
    var it = dir.iterate();
    while (it.next() catch null) |e| {
        if (!std.mem.startsWith(u8, e.name, "hidraw")) continue;
        const num = std.fmt.parseInt(u32, e.name[6..], 10) catch continue;
        var pbuf: [128]u8 = undefined;
        var buf: [512]u8 = undefined;
        const ue_path = std.fmt.bufPrint(&pbuf, "{s}/device/uevent", .{e.name}) catch continue;
        const ue = readSmall(dir, ue_path, &buf) orelse continue;
        if (!hasHidId(ue, cfg.hid_id)) continue;
        const ok = blk: {
            if (cfg.iface) |want| {
                const ip = std.fmt.bufPrint(&pbuf, "{s}/device/../bInterfaceNumber", .{e.name}) catch break :blk false;
                if (readSmall(dir, ip, &buf)) |t| {
                    const v = std.fmt.parseInt(u8, std.mem.trim(u8, t, " \n"), 16) catch break :blk false;
                    break :blk v == want;
                }
            }
            const dp = std.fmt.bufPrint(&pbuf, "{s}/device/report_descriptor", .{e.name}) catch break :blk false;
            const d = readSmall(dir, dp, buf[0..3]) orelse break :blk false;
            break :blk std.mem.eql(u8, d, &RAW_USAGE_PAGE);
        };
        if (!ok) continue;
        if (best == null or num < best.?) best = num;
    }
    const n = best orelse return null;
    return std.fmt.bufPrint(out, "{s}/hidraw{d}", .{ cfg.dev_dir, n }) catch null;
}

/// Keeps the device open between follows; re-discovers after an error.
pub const Notifier = struct {
    cfg: Config,
    fd: ?posix.fd_t = null,
    path_buf: [256]u8 = undefined,
    path_len: usize = 0,
    /// "not found" was logged (once until it is found again).
    told_missing: bool = false,
    sent: usize = 0,

    /// Open the device if needed (cheap when already open). Call at follow
    /// start so that send() at the move decision is a single write.
    pub fn prepare(self: *Notifier) bool {
        if (self.fd != null) return true;
        var buf: [256]u8 = undefined;
        const p = find(self.cfg, &buf) orelse {
            if (!self.told_missing) log.info("no HID device {s} (interface {?d}): cursor-move notifications skipped", .{ self.cfg.hid_id, self.cfg.iface });
            self.told_missing = true;
            return false;
        };
        self.fd = posix.open(p, .{ .ACCMODE = .WRONLY, .CLOEXEC = true, .NONBLOCK = true }, 0) catch |err| {
            if (!self.told_missing) log.warn("{s}: {}; cursor-move notifications skipped", .{ p, err });
            self.told_missing = true;
            return false;
        };
        @memcpy(self.path_buf[0..p.len], p);
        self.path_len = p.len;
        self.told_missing = false;
        log.info("cursor-move notifications to {s}", .{p});
        return true;
    }

    pub fn path(self: *const Notifier) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Write one report; a failed write closes the device and retries once
    /// with a fresh discovery (unplugged / re-enumerated board).
    pub fn send(self: *Notifier, cmd: u8) bool {
        const r = report(cmd);
        var attempt: u8 = 0;
        while (attempt < 2) : (attempt += 1) {
            if (!self.prepare()) return false;
            const n = posix.write(self.fd.?, &r) catch |err| {
                log.warn("{s}: write failed ({})", .{ self.path(), err });
                self.close();
                continue;
            };
            if (n == r.len) {
                self.sent += 1;
                return true;
            }
            self.close();
        }
        return false;
    }

    pub fn close(self: *Notifier) void {
        if (self.fd) |fd| posix.close(fd);
        self.fd = null;
    }
};

// ── Tests (fake sysfs) ──────────────────────────────────────────────

const testing = std.testing;

/// hidrawN with a device dir under devices/<iface_dir>/<hid_dir>, like sysfs.
fn fakeNode(root: std.fs.Dir, n: u32, hid_id: []const u8, iface: ?[]const u8, desc: []const u8) !void {
    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    const ifdir = try std.fmt.bufPrint(&b1, "devices/usb:1.{d}", .{n});
    const hiddir = try std.fmt.bufPrint(&b2, "{s}/0003:FEED:0130.{d:0>4}", .{ ifdir, n });
    try root.makePath(hiddir);
    if (iface) |i| try root.writeFile(.{ .sub_path = try std.fmt.bufPrint(&b1, "devices/usb:1.{d}/bInterfaceNumber", .{n}), .data = i });
    var b3: [160]u8 = undefined;
    var b4: [64]u8 = undefined;
    try root.writeFile(.{ .sub_path = try std.fmt.bufPrint(&b3, "{s}/uevent", .{hiddir}), .data = try std.fmt.bufPrint(&b4, "DRIVER=hid-generic\nHID_ID={s}\nHID_NAME=x\n", .{hid_id}) });
    try root.writeFile(.{ .sub_path = try std.fmt.bufPrint(&b3, "{s}/report_descriptor", .{hiddir}), .data = desc });
    try root.makePath("class/hidraw");
    var b5: [64]u8 = undefined;
    const link = try std.fmt.bufPrint(&b5, "class/hidraw/hidraw{d}", .{n});
    try root.makePath(link);
    var b6: [200]u8 = undefined;
    var b7: [80]u8 = undefined;
    try root.symLink(try std.fmt.bufPrint(&b6, "../../../{s}", .{hiddir}), try std.fmt.bufPrint(&b7, "{s}/device", .{link}), .{ .is_directory = true });
}

test "report: id 0 + 'M' + zeros, 33 bytes" {
    const r = report(CMD_MOVED);
    try testing.expectEqual(@as(usize, 33), r.len);
    try testing.expectEqual(@as(u8, 0), r[0]);
    try testing.expectEqual(@as(u8, 0x4D), r[1]);
    for (r[2..]) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "find: the Chocozor's Raw HID interface among others (like kuvanukor)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeNode(tmp.dir, 0, "0003:0000046D:0000C08D", "00", "\x05\x01\x09");
    try fakeNode(tmp.dir, 2, "0003:0000046D:0000C08D", "02", "\x06\x00\xff");
    try fakeNode(tmp.dir, 6, "0003:0000FEED:00000130", "00", "\x05\x01\x09"); // keyboard
    try fakeNode(tmp.dir, 7, "0003:0000FEED:00000130", "01", "\x06\x60\xff"); // raw HID
    try fakeNode(tmp.dir, 15, "0003:0000FEED:00000130", "02", "\x05\x01\x09"); // mouse
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    var sys_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sys = try std.fmt.bufPrint(&sys_buf, "{s}/class/hidraw", .{root});
    var out: [256]u8 = undefined;
    try testing.expectEqualStrings("/dev/hidraw7", find(.{ .sysfs_dir = sys }, &out).?);
    // By descriptor only.
    try testing.expectEqualStrings("/dev/hidraw7", find(.{ .sysfs_dir = sys, .iface = null }, &out).?);
    // Another interface number, other ids (case-insensitive), absent ones.
    try testing.expectEqualStrings("/dev/hidraw15", find(.{ .sysfs_dir = sys, .iface = 2 }, &out).?);
    try testing.expectEqualStrings("/dev/hidraw2", find(.{ .sysfs_dir = sys, .hid_id = "0003:0000046d:0000c08d", .iface = 2 }, &out).?);
    try testing.expect(find(.{ .sysfs_dir = sys, .hid_id = "0003:00001234:00005678" }, &out) == null);
    try testing.expect(find(.{ .sysfs_dir = "/nonexistent" }, &out) == null);
}

test "find: no bInterfaceNumber file falls back to the Raw HID usage page" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeNode(tmp.dir, 3, "0003:0000FEED:00000130", null, "\x05\x01\x09");
    try fakeNode(tmp.dir, 4, "0003:0000FEED:00000130", null, "\x06\x60\xff");
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    var sys_buf: [std.fs.max_path_bytes]u8 = undefined;
    const sys = try std.fmt.bufPrint(&sys_buf, "{s}/class/hidraw", .{root});
    var out: [256]u8 = undefined;
    try testing.expectEqualStrings("/x/hidraw4", find(.{ .sysfs_dir = sys, .dev_dir = "/x" }, &out).?);
}

test "notifier writes the report to the found node, re-discovers, skips when absent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fakeNode(tmp.dir, 7, "0003:0000FEED:00000130", "01", "\x06\x60\xff");
    try tmp.dir.makePath("dev");
    try tmp.dir.writeFile(.{ .sub_path = "dev/hidraw7", .data = "" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    var sys_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dev_buf: [std.fs.max_path_bytes]u8 = undefined;
    var n = Notifier{ .cfg = .{
        .sysfs_dir = try std.fmt.bufPrint(&sys_buf, "{s}/class/hidraw", .{root}),
        .dev_dir = try std.fmt.bufPrint(&dev_buf, "{s}/dev", .{root}),
    } };
    defer n.close();
    try testing.expect(n.send(CMD_MOVED));
    try testing.expect(n.send(CMD_MOVED));
    var got: [100]u8 = undefined;
    const data = try tmp.dir.readFile("dev/hidraw7", &got);
    try testing.expectEqual(@as(usize, 66), data.len);
    try testing.expectEqual(@as(u8, 'M'), data[1]);
    try testing.expectEqual(@as(u8, 'M'), data[34]);
    // Board gone: send fails quietly.
    var none = Notifier{ .cfg = .{ .sysfs_dir = "/nonexistent" } };
    try testing.expect(!none.send(CMD_MOVED));
    try testing.expect(none.told_missing);
}
