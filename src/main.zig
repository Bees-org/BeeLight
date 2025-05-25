const std = @import("std");
const lib = @import("lib");
const Logger = lib.core.Logger;
const BrightnessController = lib.core.BrightnessController;
const IpcServer = lib.ipc.IpcServer;
const LogConfig = lib.core.LogConfig;
const Config = lib.core.Config;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
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
    var server = try IpcServer.init(allocator, &controller, &logger);
    defer server.deinit();

    // 启动自动亮度调节线程
    const auto_thread = try std.Thread.spawn(.{}, autoAdjustmentThread, .{&controller});
    defer auto_thread.join();

    // IPC服务器线程
    const ipc_thread = try std.Thread.spawn(.{}, ipcServerThread, .{&server});
    defer ipc_thread.join();
}

fn autoAdjustmentThread(controller: *BrightnessController) void {
    var sleep_time: u64 = std.time.ns_per_s * 2; // 每2秒更新一次
    while (true) {
        if (controller.auto_mode) {
            sleep_time = std.time.ns_per_s * 2;
            controller.updateBrightness() catch |err| {
                controller.logger.err("自动亮度调节错误: {}", .{err}) catch {};
            };
        } else {
            sleep_time = std.time.ns_per_s * 5;
        }
        std.time.sleep(sleep_time); // 每2秒更新一次
    }
}

fn ipcServerThread(server: *IpcServer) void {
    server.run() catch |err| {
        server.logger.err("IPC服务器错误: {}", .{err}) catch {};
    };
}
