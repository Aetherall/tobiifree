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

    // Correction map (TPS model, grid, file format; std only).
    const correction = b.createModule(.{
        .root_source_file = b.path("../../driver/src/correction.zig"),
        .target = target,
        .optimize = optimize,
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
                .{ .name = "correction", .module = correction },
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

    // tobiifree-ctl: CLI over the Zig SocketSource.
    const gaze_source = b.createModule(.{
        .root_source_file = b.path("../../driver/src/gaze_source.zig"),
        .target = target,
        .optimize = optimize,
    });
    const socket_source = b.createModule(.{
        .root_source_file = b.path("../../driver/src/socket_source.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "daemon_protocol", .module = daemon_protocol },
            .{ .name = "gaze_source", .module = gaze_source },
        },
    });
    const usb_source = b.createModule(.{
        .root_source_file = b.path("../../driver/src/usb_source.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tracker", .module = tracker },
            .{ .name = "libusb_transport", .module = libusb_transport },
            .{ .name = "gaze_source", .module = gaze_source },
        },
    });
    gaze_source.addImport("tobiifree_core", tobiifree_core);
    gaze_source.addImport("usb_source", usb_source);
    gaze_source.addImport("socket_source", socket_source);

    const ctl = b.addExecutable(.{
        .name = "tobiifree-ctl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ctl.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "daemon_protocol", .module = daemon_protocol },
                .{ .name = "socket_source", .module = socket_source },
            },
        }),
    });
    ctl.linkLibC();
    ctl.linkSystemLibrary("libusb-1.0");
    b.installArtifact(ctl);

    // Unit tests (config parsing/rendering).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run tobiifreed unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // Nested leave-one-out fits are very slow in Debug: test optimised.
    const corr_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("../../driver/src/correction.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    }) });
    test_step.dependOn(&b.addRunArtifact(corr_tests).step);
}
