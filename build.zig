const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 创建库模块
    const lib = b.addModule("lib", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 主程序（守护进程）
    const daemon = b.addExecutable(.{
        .name = "beelightd",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });

    daemon.linkLibC();
    daemon.root_module.addImport("lib", lib);

    // CLI 程序
    const cli = b.addExecutable(.{
        .name = "beelight",
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    cli.linkLibC();

    const check = b.step("check", "Check if foo compiles");
    check.dependOn(&daemon.step);
    check.dependOn(&cli.step);

    // 安装两个可执行文件
    b.installArtifact(daemon);
    b.installArtifact(cli);
}
