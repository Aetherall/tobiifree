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

    // Correction map (shared with tobiifreed).
    const correction = b.createModule(.{
        .root_source_file = b.path("../../driver/src/correction.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "tobiifree-setup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tobiifree_core", .module = tobiifree_core },
                .{ .name = "daemon_protocol", .module = daemon_protocol },
                .{ .name = "socket_source", .module = socket_source },
                .{ .name = "correction", .module = correction },
            },
        }),
    });

    // GTK4 + layer-shell for the fullscreen surface; libusb only because the
    // gaze_source module graph (pulled in by socket_source) references it.
    exe.linkSystemLibrary("gtk4");
    exe.linkSystemLibrary("gtk4-layer-shell-0");
    exe.linkSystemLibrary("libusb-1.0");
    exe.linkLibC();

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the setup tool");
    run_step.dependOn(&run.step);

    // Pure logic (geometry, validation stats, tobii.json handling).
    const test_step = b.step("test", "Run unit tests");
    for ([_][]const u8{ "src/geometry.zig", "src/config.zig", "src/fixation.zig" }) |path| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    // The nested leave-one-out fits are ~400× slower in Debug: test them
    // optimised.
    const correction_opt = b.createModule(.{
        .root_source_file = b.path("../../driver/src/correction.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const refine_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/refine.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "correction", .module = correction_opt }},
    }) });
    test_step.dependOn(&b.addRunArtifact(refine_tests).step);
}
