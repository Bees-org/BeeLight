const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("ckdl", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const upstream = b.dependency("ckdl", .{});
    const lib = b.addStaticLibrary(.{
        .name = "ckdl",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.linkLibCpp();
    lib.addIncludePath(upstream.path("include"));

    lib.addCSourceFiles(.{ .root = upstream.path(""), .files = &.{
        "src/bigint.c",
        "src/compat.c",
        "src/emitter.c",
        "src/parser.c",
        "src/str.c",
        "src/tokenizer.c",

        "src/utils/ckdl-parse-events.c",
        "src/utils/ckdl-tokenize.c",
    } });

    b.installArtifact(lib);
}
