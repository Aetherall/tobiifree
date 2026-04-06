const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared tobiifree_core module.
    const tobiifree_core = b.createModule(.{
        .root_source_file = b.path("../../driver/src/tobiifree_core.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tracker module (transport-agnostic, no libusb dependency).
    const tracker = b.createModule(.{
        .root_source_file = b.path("../../driver/src/tracker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tobiifree_core", .module = tobiifree_core },
        },
    });

    // Libusb transport.
    const libusb_transport = b.createModule(.{
        .root_source_file = b.path("../../driver/src/libusb_transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    libusb_transport.linkSystemLibrary("libusb-1.0", .{});
    libusb_transport.link_libc = true;

    // Daemon protocol (wire format for tobiifreed IPC).
    const daemon_protocol = b.createModule(.{
        .root_source_file = b.path("../../driver/src/daemon_protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tobiifree_core", .module = tobiifree_core },
        },
    });

    // USB source (LibusbTransport + Tracker).
    const usb_source = b.createModule(.{
        .root_source_file = b.path("../../driver/src/usb_source.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tracker", .module = tracker },
            .{ .name = "libusb_transport", .module = libusb_transport },
            .{ .name = "gaze_source", .module = undefined }, // forward ref
        },
    });

    // Socket source (unix socket client to tobiifreed).
    const socket_source = b.createModule(.{
        .root_source_file = b.path("../../driver/src/socket_source.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "daemon_protocol", .module = daemon_protocol },
            .{ .name = "gaze_source", .module = undefined }, // forward ref
        },
    });

    // GazeSource (tagged union over usb/socket).
    const gaze_source = b.createModule(.{
        .root_source_file = b.path("../../driver/src/gaze_source.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tobiifree_core", .module = tobiifree_core },
            .{ .name = "usb_source", .module = usb_source },
            .{ .name = "socket_source", .module = socket_source },
        },
    });

    // Resolve forward references.
    usb_source.addImport("gaze_source", gaze_source);
    socket_source.addImport("gaze_source", gaze_source);

    const exe = b.addExecutable(.{
        .name = "tobiifree-overlay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tobiifree_core", .module = tobiifree_core },
                .{ .name = "gaze_source", .module = gaze_source },
                .{ .name = "usb_source", .module = usb_source },
                .{ .name = "socket_source", .module = socket_source },
            },
        }),
    });

    // System C libraries (GTK for the overlay, libusb for USB source).
    exe.linkSystemLibrary("gtk4");
    exe.linkSystemLibrary("gtk4-layer-shell-0");
    exe.linkSystemLibrary("libusb-1.0");
    exe.linkLibC();

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the gaze overlay");
    run_step.dependOn(&run.step);
}
