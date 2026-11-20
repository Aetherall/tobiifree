// output_id.zig — find "the screen the tracker is on" among the current
// outputs, robustly. Connector names (DP-1, DP-2, …) are not stable: they
// can swap across reboots or re-plugs. tobii.json therefore stores both:
//   "output"       connector at setup time, e.g. "DP-2"
//   "output_desc"  the monitor's identity, make + model + serial as the
//                  compositor describes it, e.g. "BNQ BenQ XL2430T R9F02179SL0"
//                  (Hyprland's `description`, the `desc:` of its monitor rules)
// Resolution: the description first (exact, after normalisation), then the
// connector. `--output` takes a connector or `desc:<description>`.
//
// Descriptions differ slightly between sources: wl_output / GdkMonitor say
// "BNQ BenQ XL2430T R9F02179SL0 (DP-2)" and, without a serial,
// "LG Display 0x07C5  (eDP-1)"; Hyprland's JSON says "BNQ BenQ XL2430T
// R9F02179SL0". normalize() drops a trailing " (<connector>)" and collapses
// whitespace so all of them compare equal.

const std = @import("std");

pub const MAX_DESC = 256;

/// What to look for. Slices are borrowed.
pub const Want = struct {
    connector: ?[]const u8 = null,
    desc: ?[]const u8 = null,

    pub fn isEmpty(self: Want) bool {
        return self.connector == null and self.desc == null;
    }
};

/// `--output` value: "desc:<description>" or a connector name.
pub fn parseSpec(spec: []const u8) Want {
    if (std.mem.startsWith(u8, spec, "desc:")) return .{ .desc = std.mem.trim(u8, spec[5..], " ") };
    return .{ .connector = spec };
}

/// `desc` without a trailing " (<connector>)" (when given), whitespace runs
/// collapsed to one space, trimmed. Truncated to `buf`.
pub fn normalize(buf: *[MAX_DESC]u8, desc: []const u8, connector: ?[]const u8) []const u8 {
    var d = std.mem.trim(u8, desc, " \t\r\n");
    if (connector) |conn| if (conn.len > 0 and d.len >= conn.len + 2 and d[d.len - 1] == ')' and
        std.mem.eql(u8, d[d.len - 1 - conn.len .. d.len - 1], conn) and d[d.len - 2 - conn.len] == '(')
    {
        d = std.mem.trimRight(u8, d[0 .. d.len - 2 - conn.len], " \t");
    };
    var n: usize = 0;
    var space = false;
    for (d) |ch| {
        const ws = ch == ' ' or ch == '\t';
        if (ws) {
            space = true;
            continue;
        }
        if (space and n > 0 and n < buf.len) {
            buf[n] = ' ';
            n += 1;
        }
        space = false;
        if (n < buf.len) {
            buf[n] = ch;
            n += 1;
        }
    }
    return buf[0..n];
}

pub fn descEql(a: []const u8, a_conn: ?[]const u8, b: []const u8, b_conn: ?[]const u8) bool {
    var ba: [MAX_DESC]u8 = undefined;
    var bb: [MAX_DESC]u8 = undefined;
    const na = normalize(&ba, a, a_conn);
    return na.len > 0 and std.mem.eql(u8, na, normalize(&bb, b, b_conn));
}

/// One current output.
pub const Candidate = struct {
    connector: []const u8,
    /// As the source reports it (normalised when compared).
    desc: []const u8,
};

pub const How = enum { description, connector };

pub const Match = struct {
    index: usize,
    how: How,
    /// The wanted connector names another output now (matched by
    /// description elsewhere), or the connector's monitor is not the wanted
    /// one (matched by connector, description absent): the saved connector
    /// is stale.
    stale: bool,
};

pub fn resolve(cands: []const Candidate, want: Want) ?Match {
    if (want.desc) |d| {
        for (cands, 0..) |c, i| if (descEql(c.desc, c.connector, d, null)) {
            const stale = if (want.connector) |wc| !std.mem.eql(u8, wc, c.connector) else false;
            return .{ .index = i, .how = .description, .stale = stale };
        };
    }
    if (want.connector) |wc| {
        for (cands, 0..) |c, i| if (std.mem.eql(u8, c.connector, wc)) {
            // Description wanted but not found: this connector carries
            // another monitor (or the monitor's description changed).
            return .{ .index = i, .how = .connector, .stale = want.desc != null };
        };
    }
    return null;
}

/// One log line about a resolution (into `buf`).
pub fn explain(buf: []u8, cands: []const Candidate, want: Want, m: ?Match) []const u8 {
    var nb: [MAX_DESC]u8 = undefined;
    const r = m orelse return std.fmt.bufPrint(buf, "no output matches {s}{s}{s}{s}", .{
        if (want.desc != null) "description \"" else "",
        want.desc orelse "",
        if (want.desc != null) (if (want.connector != null) "\" or connector " else "\"") else "connector ",
        want.connector orelse "",
    }) catch buf[0..0];
    const c = cands[r.index];
    const d = normalize(&nb, c.desc, c.connector);
    return switch (r.how) {
        .description => if (r.stale)
            std.fmt.bufPrint(buf, "output {s} ({s}) matched by description; the saved connector {s} is stale (now another screen or gone)", .{ c.connector, d, want.connector.? }) catch buf[0..0]
        else
            std.fmt.bufPrint(buf, "output {s} ({s}) matched by description", .{ c.connector, d }) catch buf[0..0],
        .connector => if (r.stale)
            std.fmt.bufPrint(buf, "output {s} matched by connector only: it is \"{s}\", not the saved \"{s}\" (stale tobii.json? re-run tobiifree-setup)", .{ c.connector, d, want.desc.? }) catch buf[0..0]
        else
            std.fmt.bufPrint(buf, "output {s} ({s}) matched by connector", .{ c.connector, d }) catch buf[0..0],
    };
}

/// "output" and "output_desc" of a tobii.json text (duplicated, caller
/// frees with `free`).
pub const Saved = struct {
    connector: ?[]u8 = null,
    desc: ?[]u8 = null,

    pub fn want(self: Saved) Want {
        return .{ .connector = self.connector, .desc = self.desc };
    }

    pub fn free(self: Saved, gpa: std.mem.Allocator) void {
        if (self.connector) |x| gpa.free(x);
        if (self.desc) |x| gpa.free(x);
    }
};

pub fn parseSaved(gpa: std.mem.Allocator, text: []const u8) Saved {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    var s = Saved{};
    if (parsed.value.object.get("output")) |v| if (v == .string and v.string.len > 0) {
        s.connector = gpa.dupe(u8, v.string) catch null;
    };
    if (parsed.value.object.get("output_desc")) |v| if (v == .string and v.string.len > 0) {
        s.desc = gpa.dupe(u8, v.string) catch null;
    };
    return s;
}

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "normalize: wl_output/GDK and Hyprland forms agree" {
    var b: [MAX_DESC]u8 = undefined;
    try testing.expectEqualStrings("BNQ BenQ XL2430T R9F02179SL0", normalize(&b, "BNQ BenQ XL2430T R9F02179SL0 (DP-2)", "DP-2"));
    try testing.expectEqualStrings("LG Display 0x07C5", normalize(&b, "LG Display 0x07C5  (eDP-1)", "eDP-1"));
    try testing.expectEqualStrings("LG Display 0x07C5", normalize(&b, " LG Display 0x07C5 ", null));
    // Suffix of another connector is part of the name: kept.
    try testing.expectEqualStrings("Foo (DP-1)", normalize(&b, "Foo (DP-1)", "DP-2"));
    try testing.expect(descEql("BNQ BenQ XL2430T R9F02179SL0 (DP-2)", "DP-2", "BNQ BenQ XL2430T R9F02179SL0", null));
    try testing.expect(!descEql("", null, "", null));
}

test "parseSpec" {
    try testing.expectEqualStrings("DP-1", parseSpec("DP-1").connector.?);
    const w = parseSpec("desc:BNQ BenQ XL2430T R9F02179SL0");
    try testing.expectEqualStrings("BNQ BenQ XL2430T R9F02179SL0", w.desc.?);
    try testing.expect(w.connector == null);
}

// After the reboot: the BenQ moved from DP-1 to DP-2, the iiyama took DP-1.
const after_swap = [_]Candidate{
    .{ .connector = "eDP-1", .desc = "LG Display 0x07C5  (eDP-1)" },
    .{ .connector = "DP-1", .desc = "iiyama Corporation PL2470H 0x30373034 (DP-1)" },
    .{ .connector = "DP-2", .desc = "BNQ BenQ XL2430T R9F02179SL0 (DP-2)" },
};
const benq = "BNQ BenQ XL2430T R9F02179SL0";

test "connectors swapped: description wins, saved connector flagged stale" {
    const m = resolve(&after_swap, .{ .connector = "DP-1", .desc = benq }).?;
    try testing.expectEqual(@as(usize, 2), m.index);
    try testing.expectEqual(How.description, m.how);
    try testing.expect(m.stale);
    var buf: [400]u8 = undefined;
    const line = explain(&buf, &after_swap, .{ .connector = "DP-1", .desc = benq }, m);
    try testing.expect(std.mem.indexOf(u8, line, "DP-1 is stale") != null);
}

test "unchanged layout: description match, not stale" {
    const m = resolve(&after_swap, .{ .connector = "DP-2", .desc = benq }).?;
    try testing.expectEqual(@as(usize, 2), m.index);
    try testing.expect(!m.stale);
}

test "old tobii.json without output_desc: connector as before" {
    const m = resolve(&after_swap, .{ .connector = "DP-2" }).?;
    try testing.expectEqual(@as(usize, 2), m.index);
    try testing.expectEqual(How.connector, m.how);
    try testing.expect(!m.stale);
}

test "monitor gone: falls back to the connector, flagged stale" {
    const m = resolve(&after_swap, .{ .connector = "DP-1", .desc = "Dell U2412M ABC" }).?;
    try testing.expectEqual(@as(usize, 1), m.index);
    try testing.expectEqual(How.connector, m.how);
    try testing.expect(m.stale);
    var buf: [400]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, explain(&buf, &after_swap, .{ .connector = "DP-1", .desc = "Dell U2412M ABC" }, m), "not the saved") != null);
}

test "desc: spec only, and no match at all" {
    const m = resolve(&after_swap, parseSpec("desc:" ++ benq)).?;
    try testing.expectEqual(@as(usize, 2), m.index);
    try testing.expect(!m.stale);
    try testing.expectEqual(@as(?Match, null), resolve(&after_swap, parseSpec("desc:Nope")));
    try testing.expectEqual(@as(?Match, null), resolve(&after_swap, .{ .connector = "HDMI-A-1" }));
    try testing.expectEqual(@as(?Match, null), resolve(&after_swap, .{}));
    var buf: [200]u8 = undefined;
    try testing.expectEqualStrings("no output matches description \"Nope\"", explain(&buf, &after_swap, parseSpec("desc:Nope"), null));
}

test "parseSaved" {
    const s = parseSaved(testing.allocator, "{\"output\": \"DP-2\", \"output_desc\": \"" ++ benq ++ "\", \"gap_mm\": 10}");
    defer s.free(testing.allocator);
    try testing.expectEqualStrings("DP-2", s.connector.?);
    try testing.expectEqualStrings(benq, s.desc.?);
    const e = parseSaved(testing.allocator, "{nope");
    try testing.expect(e.connector == null and e.desc == null);
}
