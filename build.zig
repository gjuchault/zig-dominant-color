const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const zstbi_dep = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("dominant_color", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zstbi", .module = zstbi_dep.module("root") },
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "dominant_color",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "dominant_color", .module = mod },
                .{ .name = "zstbi", .module = zstbi_dep.module("root") },
                .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
            },
        }),
    });

    const lib = b.addLibrary(.{ .name = "dominant_color", .root_module = mod });

    b.installArtifact(exe);
    b.installArtifact(lib);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
