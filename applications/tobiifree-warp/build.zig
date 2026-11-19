const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tobiifree_core = b.createModule(.{
        .root_source_file = b.path("../../driver/src/tobiifree_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const daemon_protocol = b.createModule(.{
        .root_source_file = b.path("../../driver/src/daemon_protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tobiifree_core", .module = tobiifree_core }},
    });
    // socket_source imports gaze_source only for the callback type; a shim
    // keeps libusb (the USB source) out of this tool.
    const gaze_shim = b.createModule(.{
        .root_source_file = b.path("src/gaze_shim.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tobiifree_core", .module = tobiifree_core }},
    });
    const socket_source = b.createModule(.{
        .root_source_file = b.path("../../driver/src/socket_source.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "daemon_protocol", .module = daemon_protocol },
            .{ .name = "gaze_source", .module = gaze_shim },
        },
    });

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tobiifree_core", .module = tobiifree_core },
            .{ .name = "socket_source", .module = socket_source },
        },
    });
    const exe = b.addExecutable(.{ .name = "tobiifree-warp", .root_module = root });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run tobiifree-warp").dependOn(&run.step);

    // Sample selection, layout mapping, gaze extraction (src/main.zig pulls
    // them in).
    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
