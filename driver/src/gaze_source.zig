// gaze_source.zig — unified gaze source abstraction.
//
// Apps code against GazeSource and don't know whether they talk to
// USB directly or to tobiifreed over a unix socket.
//
//   var src = UsbSource.init(.{}) catch ...;  // or SocketSource.init()
//   var gs = src.gazeSource();
//   gs.onGaze(myCallback);
//   // event loop:
//   gs.poll();

const std = @import("std");
const core = @import("tobiifree_core");
const UsbSource = @import("usb_source").UsbSource;
const SocketSource = @import("socket_source").SocketSource;

pub const GazeSample = core.GazeSample;
pub const GazeFn = *const fn (*const GazeSample) void;

pub const GazeSource = union(enum) {
    usb: *UsbSource,
    socket: *SocketSource,

    pub fn onGaze(self: GazeSource, cb: GazeFn) void {
        switch (self) {
            .usb => |s| s.onGaze(cb),
            .socket => |s| s.onGaze(cb),
        }
    }

    pub fn poll(self: GazeSource) void {
        switch (self) {
            .usb => |s| s.poll(),
            .socket => |s| s.poll(),
        }
    }

    pub fn deinit(self: GazeSource) void {
        switch (self) {
            .usb => |s| s.deinit(),
            .socket => |s| s.deinit(),
        }
    }
};
