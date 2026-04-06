// usb_source.zig — GazeSource backend that claims USB directly.
//
// Creates a LibusbTransport and a Tracker, wiring them together.

const std = @import("std");
const Tracker = @import("tracker").Tracker;
const LibusbTransport = @import("libusb_transport").LibusbTransport;
const gs = @import("gaze_source");

const log = std.log.scoped(.usb_source);

pub const UsbSource = struct {
    transport: LibusbTransport,
    tracker: Tracker,

    pub const DisplayArea = Tracker.DisplayArea;

    pub fn init() !UsbSource {
        log.info("init: opening USB transport", .{});
        var self: UsbSource = undefined;
        self.transport = try LibusbTransport.init();
        errdefer self.transport.deinit();

        log.info("init: starting tracker handshake", .{});
        self.tracker = Tracker.init(.{
            .send_fn = makeSendFn(&self.transport),
            .recv_fn = makeRecvFn(&self.transport),
            .try_recv_fn = makeTryRecvFn(&self.transport),
        }) catch |err| {
            log.err("init: tracker handshake failed: {}", .{err});
            self.transport.deinit();
            return err;
        };
        return self;
    }

    /// Re-bind the module-level transport pointer after the struct has been
    /// moved to its final location (e.g. a global variable). Must be called
    /// before poll() if the struct was returned by value from init().
    pub fn bind(self: *UsbSource) void {
        transport_ptr = &self.transport;
        Tracker.active = &self.tracker;
    }

    pub fn gazeSource(self: *UsbSource) gs.GazeSource {
        return .{ .usb = self };
    }

    pub fn setDisplayArea(self: *UsbSource, d: DisplayArea) bool {
        return self.tracker.setDisplayArea(d);
    }

    pub fn onGaze(self: *UsbSource, cb: gs.GazeFn) void {
        self.tracker.onGaze(cb);
    }

    pub fn poll(self: *UsbSource) void {
        self.tracker.poll();
    }

    pub fn deinit(self: *UsbSource) void {
        self.tracker.deinit();
        self.transport.deinit();
    }
};

// Bridge LibusbTransport methods to function pointers.
// We use module-level state since Tracker takes bare fn pointers.
var transport_ptr: ?*LibusbTransport = null;

fn makeSendFn(t: *LibusbTransport) Tracker.SendFn {
    transport_ptr = t;
    return &transportSend;
}

fn makeRecvFn(t: *LibusbTransport) Tracker.RecvFn {
    transport_ptr = t;
    return &transportRecv;
}

fn makeTryRecvFn(t: *LibusbTransport) Tracker.RecvFn {
    transport_ptr = t;
    return &transportTryRecv;
}

fn transportSend(data: []const u8) bool {
    if (transport_ptr) |t| return t.send(data);
    return false;
}

fn transportRecv(buf: []u8) ?usize {
    if (transport_ptr) |t| return t.recv(buf);
    return null;
}

fn transportTryRecv(buf: []u8) ?usize {
    if (transport_ptr) |t| return t.tryRecv(buf);
    return null;
}
