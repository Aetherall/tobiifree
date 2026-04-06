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

    // Tracker module (transport-agnostic).
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

    // Daemon protocol.
    const daemon_protocol = b.createModule(.{
        .root_source_file = b.path("../../driver/src/daemon_protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tobiifree_core", .module = tobiifree_core },
        },
    });

    // Server module.
    const server = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "daemon_protocol", .module = daemon_protocol },
            .{ .name = "tobiifree_core", .module = tobiifree_core },
        },
    });

    // WebSocket server module.
    const ws_server = b.createModule(.{
        .root_source_file = b.path("src/ws_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tobiifree_core", .module = tobiifree_core },
            .{ .name = "daemon_protocol", .module = daemon_protocol },
        },
    });

    const exe = b.addExecutable(.{
        .name = "tobiifreed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tobiifree_core", .module = tobiifree_core },
                .{ .name = "tracker", .module = tracker },
                .{ .name = "libusb_transport", .module = libusb_transport },
                .{ .name = "daemon_protocol", .module = daemon_protocol },
                .{ .name = "server", .module = server },
                .{ .name = "ws_server", .module = ws_server },
            },
        }),
    });

    exe.linkSystemLibrary("libusb-1.0");
    exe.linkLibC();

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run tobiifreed");
    run_step.dependOn(&run.step);
}
