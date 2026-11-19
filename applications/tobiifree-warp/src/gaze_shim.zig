// gaze_shim.zig — stands in for driver/src/gaze_source.zig, which
// socket_source.zig imports only for the callback type. The real module
// pulls in the USB source (libusb); this tool only ever talks to tobiifreed.
const core = @import("tobiifree_core");
pub const GazeSample = core.GazeSample;
pub const GazeFn = *const fn (*const GazeSample) void;
pub const GazeSource = union(enum) { socket: *anyopaque };
