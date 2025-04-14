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
    });

    daemon.linkLibC();
    daemon.root_module.addImport("lib", lib);

    // CLI 程序
    const cli = b.addExecutable(.{
        .name = "beelight",
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli.linkLibC();
    cli.root_module.addImport("lib", lib);
    cli.root_module.addImport("protocol", b.createModule(.{ .root_source_file = b.path("src/protocol/protocol.zig") }));

    const check = b.step("check", "Check if foo compiles");
    check.dependOn(&daemon.step);
    check.dependOn(&cli.step);

    // 安装两个可执行文件
    b.installArtifact(daemon);
    b.installArtifact(cli);

    // 运行命令
    const run_daemon_cmd = b.addRunArtifact(daemon);
    run_daemon_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_daemon_cmd.addArgs(args);
    }

    const run_cli_cmd = b.addRunArtifact(cli);
    run_cli_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cli_cmd.addArgs(args);
    }

    // 添加运行步骤
    const run_daemon_step = b.step("run-daemon", "运行守护进程");
    run_daemon_step.dependOn(&run_daemon_cmd.step);

    const run_cli_step = b.step("run-cli", "运行命令行工具");
    run_cli_step.dependOn(&run_cli_cmd.step);
}
