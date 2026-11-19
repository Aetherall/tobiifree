const std = @import("std");

pub fn build(b: *std.Build) void {
    // ============================================================
    // WASM artifact (wasm32-freestanding)
    // ============================================================
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_optimize = b.standardOptimizeOption(.{});

    const wasm = b.addExecutable(.{
        .name = "tobiifree_core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tobiifree_core.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    b.installArtifact(wasm);

    // ============================================================
    // Native tests (host target)
    // ============================================================
    const host_target = b.standardTargetOptions(.{});
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tobiifree_core.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // SocketSource (daemon client) tests: needs the module graph the apps use.
    const t_core = b.createModule(.{ .root_source_file = b.path("src/tobiifree_core.zig"), .target = host_target });
    const t_proto = b.createModule(.{
        .root_source_file = b.path("src/daemon_protocol.zig"),
        .target = host_target,
        .imports = &.{.{ .name = "tobiifree_core", .module = t_core }},
    });
    const t_tracker = b.createModule(.{
        .root_source_file = b.path("src/tracker.zig"),
        .target = host_target,
        .imports = &.{.{ .name = "tobiifree_core", .module = t_core }},
    });
    const t_libusb = b.createModule(.{ .root_source_file = b.path("src/libusb_transport.zig"), .target = host_target, .link_libc = true });
    t_libusb.linkSystemLibrary("libusb-1.0", .{});
    const t_usb_source = b.createModule(.{
        .root_source_file = b.path("src/usb_source.zig"),
        .target = host_target,
        .imports = &.{
            .{ .name = "tracker", .module = t_tracker },
            .{ .name = "libusb_transport", .module = t_libusb },
        },
    });
    const t_socket_source = b.createModule(.{
        .root_source_file = b.path("src/socket_source.zig"),
        .target = host_target,
        .optimize = .Debug,
        .imports = &.{.{ .name = "daemon_protocol", .module = t_proto }},
    });
    const t_gaze_source = b.createModule(.{
        .root_source_file = b.path("src/gaze_source.zig"),
        .target = host_target,
        .imports = &.{
            .{ .name = "tobiifree_core", .module = t_core },
            .{ .name = "usb_source", .module = t_usb_source },
            .{ .name = "socket_source", .module = t_socket_source },
        },
    });
    t_usb_source.addImport("gaze_source", t_gaze_source);
    t_socket_source.addImport("gaze_source", t_gaze_source);
    const socket_tests = b.addTest(.{ .root_module = t_socket_source });
    test_step.dependOn(&b.addRunArtifact(socket_tests).step);

    // ============================================================
    // Native CLI: tobiifree-decode  (tlv decoder playground)
    // ============================================================
    const tobiifree_decode = b.addExecutable(.{
        .name = "tobiifree-decode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tobiifree_decode.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    b.installArtifact(tobiifree_decode);

    const run_decode = b.addRunArtifact(tobiifree_decode);
    run_decode.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_decode.addArgs(args);
    const decode_step = b.step("tobiifree-decode", "Run the TLV decoder on a captured frame");
    decode_step.dependOn(&run_decode.step);
}
