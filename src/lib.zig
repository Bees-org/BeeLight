const std = @import("std");

pub const core = struct {
    pub const BrightnessController = @import("core/controller.zig").BrightnessController;
    pub const Config = @import("core/config.zig").BrightnessConfig;
    pub const Screen = @import("core/screen.zig").Screen;
    pub const Sensor = @import("core/sensor.zig").Sensor;
    pub const BrightnessModel = @import("ml/brightness_model.zig").BrightnessModel;
    pub const LogConfig = @import("core/log.zig").LogConfig;
    pub const Logger = @import("core/log.zig").Logger;
    pub const IpcServer = @import("ipc/server.zig").IpcServer;
};

pub const data = struct {
    pub const DataLogger = @import("storage/recorder.zig").DataLogger;
    pub const DataPoint = @import("storage/recorder.zig").DataPoint;
};

pub const event = struct {
    pub const EventManager = @import("core/event_manager.zig").EventManager;
    pub const Event = @import(" core/event.zig").Event;
};

pub const ml = struct {
    pub const EnhancedBrightnessModel = @import("ml/enhanced_brightness_model.zig").EnhancedBrightnessModel;
};

var controller: ?*core.BrightnessController = null;
var auto_adjust_enabled: bool = false;

pub const InitOptions = struct {
    enable_logging: bool = false,
};

pub fn init() !void {
    try initWithOptions(.{});
}

pub fn initWithOptions(options: InitOptions) !void {
    if (controller != null) return;

    const allocator = std.heap.page_allocator;
    controller = try allocator.create(core.BrightnessController);

    // 创建日志配置
    const log_config = core.LogConfig{
        .log_file_path = "/var/log/beelight.log",
        .min_level = .Info,
        .enable_console = options.enable_logging,
        .enable_file = options.enable_logging,
    };

    // 加载配置
    const config = core.Config.load() catch |err| {
        std.log.err("加载配置失败: {}", .{err});
        return err;
    };

    controller.?.* = try core.BrightnessController.init(allocator, log_config, config);
}

pub fn deinit() void {
    if (controller) |c| {
        c.deinit();
        std.heap.page_allocator.destroy(c);
        controller = null;
    }
}

pub fn setBrightness(value: u8) !void {
    if (controller == null) return error.NotInitialized;
    // 将百分比值（0-100）转换为实际亮度值（min_brightness-max_brightness）
    const min_brightness = controller.?.config.min_brightness;
    const max_brightness = controller.?.config.max_brightness;
    const brightness_range = max_brightness - min_brightness;
    const raw_value = min_brightness + @as(i64, @intFromFloat(@as(f64, @floatFromInt(value)) / 100.0 * @as(f64, @floatFromInt(brightness_range))));
    try controller.?.handleUserAdjustment(raw_value);
}

pub fn getBrightness() !u8 {
    if (controller == null) return error.NotInitialized;
    const brightness = try controller.?.screen.getBrightness();
    return @as(u8, @intCast(@max(0, @min(brightness, 100))));
}

pub fn enableAutoAdjust() !void {
    if (controller == null) return error.NotInitialized;
    auto_adjust_enabled = true;
    controller.?.auto_mode = true;
    try controller.?.updateBrightness();
}

pub fn disableAutoAdjust() !void {
    if (controller == null) return error.NotInitialized;
    auto_adjust_enabled = false;
    controller.?.auto_mode = false;
}

pub fn isAutoAdjustEnabled() bool {
    return auto_adjust_enabled;
}

test {
    std.testing.refAllDecls(@This());
}
