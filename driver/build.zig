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
