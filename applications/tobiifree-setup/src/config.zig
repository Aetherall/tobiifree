// config.zig — the setup tool's bits of ~/.config/tobii.json.
//
// tobiifreed owns "display_area" (it rewrites the file on every successful
// set and keeps the other top-level keys). The tool adds a top-level
// "output": the connector name (e.g. "DP-1") of the screen the tracker is
// mounted on, used as the default output of the next run.

const std = @import("std");

pub const CONFIG_REL_PATH = ".config/tobii.json";

pub fn configPath(buf: []u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, CONFIG_REL_PATH }) catch null;
}

/// "output" of a tobii.json text, duplicated with `gpa`; null if absent.
pub fn parseOutput(gpa: std.mem.Allocator, text: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const v = parsed.value.object.get("output") orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return gpa.dupe(u8, v.string) catch null;
}

/// `text` (or an empty object) with "output" set to `name`. Other keys are
/// kept as they are. Caller frees.
pub fn renderWithOutput(gpa: std.mem.Allocator, text: ?[]const u8, name: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var root: std.json.Value = .{ .object = std.json.ObjectMap.init(a) };
    if (text) |t| {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, t, .{})) |v| {
            if (v == .object) root = v else return error.NotAnObject;
        } else |_| return error.InvalidJson;
    }
    try root.object.put("output", .{ .string = name });
    const out = try std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_2 });
    defer gpa.free(out);
    return std.mem.concat(gpa, u8, &.{ out, "\n" });
}

/// Saved output name (caller frees), or null.
pub fn loadOutput(gpa: std.mem.Allocator) ?[]u8 {
    var pbuf: [512]u8 = undefined;
    const path = configPath(&pbuf) orelse return null;
    const text = std.fs.cwd().readFileAlloc(gpa, path, 1 << 20) catch return null;
    defer gpa.free(text);
    return parseOutput(gpa, text);
}

/// Store `name` as "output" in tobii.json (atomic replace). A file that is
/// not valid JSON is left alone (error).
pub fn saveOutput(gpa: std.mem.Allocator, name: []const u8) !void {
    var pbuf: [512]u8 = undefined;
    const path = configPath(&pbuf) orelse return error.NoHome;
    const existing: ?[]u8 = std.fs.cwd().readFileAlloc(gpa, path, 1 << 20) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |e| gpa.free(e);
    if (existing) |e| if (parseOutput(gpa, e)) |cur| {
        defer gpa.free(cur);
        if (std.mem.eql(u8, cur, name)) return;
    };
    const text = try renderWithOutput(gpa, existing, name);
    defer gpa.free(text);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    var tmp_buf: [600]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.setup.tmp", .{path});
    {
        const f = try std.fs.cwd().createFile(tmp, .{ .truncate = true });
        defer f.close();
        try f.writeAll(text);
    }
    try std.fs.cwd().rename(tmp, path);
}

const testing = std.testing;

test "output is added and other keys kept" {
    const text =
        \\{ "display_area": { "tl": [-224.705, 291.044, 0], "w_mm": 499.633 }, "other": [1, "x"] }
    ;
    const out = try renderWithOutput(testing.allocator, text, "DP-1");
    defer testing.allocator.free(out);
    const name = parseOutput(testing.allocator, out).?;
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("DP-1", name);
    try testing.expect(std.mem.indexOf(u8, out, "\"w_mm\": 499.633") != null);
    try testing.expect(std.mem.indexOf(u8, out, "-224.705") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"other\"") != null);

    // Replacing keeps a single key.
    const out2 = try renderWithOutput(testing.allocator, out, "HDMI-A-1");
    defer testing.allocator.free(out2);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out2, "\"output\""));
}

test "missing file, invalid json" {
    const out = try renderWithOutput(testing.allocator, null, "DP-1");
    defer testing.allocator.free(out);
    const n = parseOutput(testing.allocator, out).?;
    defer testing.allocator.free(n);
    try testing.expectEqualStrings("DP-1", n);
    try testing.expectError(error.InvalidJson, renderWithOutput(testing.allocator, "{ nope", "DP-1"));
    try testing.expect(parseOutput(testing.allocator, "{}") == null);
}
