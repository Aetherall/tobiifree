// backend.zig — where the cursor gets moved. Only Hyprland (IPC socket) is
// implemented; a wlr-virtual-pointer (generic wlroots) or uinput backend
// would be another variant here, giving the same three operations.

const std = @import("std");
const layout = @import("layout.zig");
pub const Hyprland = @import("hyprland.zig").Hyprland;

pub const Backend = union(enum) {
    hyprland: Hyprland,

    /// Current outputs in the global logical layout (caller deinit()s).
    pub fn monitors(self: *Backend) !layout.Parsed {
        return switch (self.*) {
            .hyprland => |*h| h.monitors(),
        };
    }

    pub fn cursorPos(self: *Backend) ![2]f64 {
        return switch (self.*) {
            .hyprland => |*h| h.cursorPos(),
        };
    }

    /// Move to a global logical position.
    pub fn moveCursor(self: *Backend, x: f64, y: f64) !void {
        return switch (self.*) {
            .hyprland => |*h| h.moveCursor(x, y),
        };
    }
};
