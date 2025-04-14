const std = @import("std");
const Logger = @import("core/log.zig").Logger;
const BrightnessController = @import("core/controller.zig").BrightnessController;
const IpcServer = @import("ipc/server.zig").IpcServer;
const LogConfig = @import("core/log.zig").LogConfig;
const Config = @import("core/config.zig").BrightnessConfig;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 初始化日志系统
    const log_config = LogConfig{
        .log_file_path = null, // 使用默认路径
        .min_level = .Debug,
        .enable_console = true,
        .enable_file = true,
    };
    var logger = try Logger.init(allocator, log_config);

    // 加载配置
    const config = Config.load() catch |err| {
        &logger.err("加载配置失败: {}", .{err}) catch {};
        return err;
    };

    // 初始化亮度控制器
    var controller = try BrightnessController.init(allocator, &logger, config);
    defer controller.deinit();

    // 初始化IPC服务器
    var server = try IpcServer.init(allocator, &controller);
    defer server.deinit();

    // 启动自动亮度调节线程
    const auto_thread = try std.Thread.spawn(.{}, autoAdjustmentThread, .{&controller});
    defer auto_thread.join();

    // 运行IPC服务器
    try server.run();
}

fn autoAdjustmentThread(controller: *BrightnessController) void {
    while (true) {
        if (controller.auto_mode) {
            controller.updateBrightness() catch |err| {
                controller.logger.err("自动亮度调节错误: {}", .{err}) catch {};
            };
        }
        std.time.sleep(std.time.ns_per_s * 2); // 每2秒更新一次
    }
}
