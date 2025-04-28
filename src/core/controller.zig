const std = @import("std");
const Screen = @import("screen.zig").Screen;
const Sensor = @import("sensor.zig").Sensor;
const DataLogger = @import("../model/recorder.zig").DataLogger;
const DataPoint = @import("../model/recorder.zig").DataPoint;
const EnhancedBrightnessModel = @import("../model/enhanced_brightness_model.zig").EnhancedBrightnessModel;
const Logger = @import("log.zig").Logger;
const LogConfig = @import("log.zig").LogConfig;
const Config = @import("config.zig").BrightnessConfig;

pub const BrightnessController = struct {
    screen: Screen,
    sensor: Sensor,
    data_logger: DataLogger,
    model: EnhancedBrightnessModel,
    last_activity_time: i64,
    allocator: std.mem.Allocator,
    config: Config,
    logger: *Logger,
    auto_mode: bool,

    /// 初始化亮度控制器。
    pub fn init(allocator: std.mem.Allocator, logger: *Logger, config: Config) !BrightnessController {
        var screen = Screen.init(logger, "intel_backlight") catch |err| {
            logger.err("初始化屏幕控制器失败: {}", .{err}) catch {};
            return err;
        };
        const sensor = Sensor.init() catch |err| {
            logger.err("初始化环境光传感器失败: {}", .{err}) catch {};
            return err;
        };
        var data_logger = DataLogger.init(allocator) catch |err| {
            logger.err("初始化数据记录器失败: {}", .{err}) catch {};
            return err;
        };
        screen.setTransitionConfig(config.transition_duration_ms, 30);
        logger.debug("已配置亮度过渡: 持续时间={}ms, 步数={}", .{ config.transition_duration_ms, 30 }) catch {};

        var controller = BrightnessController{
            .screen = screen,
            .sensor = sensor,
            .data_logger = data_logger,
            .model = undefined,
            .last_activity_time = std.time.timestamp(),
            .allocator = allocator,
            .config = config,
            .logger = logger,
            .auto_mode = config.auto_brightness_enabled,
        };

        logger.info("正在读取历史数据...", .{}) catch {};
        const historical_data = data_logger.readHistoricalData() catch |err| {
            logger.err("读取历史数据失败: {}", .{err}) catch {};
            return err;
        };
        defer allocator.free(historical_data);
        logger.info("已读取 {} 条历史数据", .{historical_data.len}) catch {};

        // 初始化增强亮度模型
        var model = EnhancedBrightnessModel.init(
            allocator,
            config.min_ambient_light,
            config.max_ambient_light,
            config.bin_count,
        ) catch |err| {
            logger.err("初始化亮度模型失败: {}", .{err}) catch {};
            return err;
        };
        logger.info("亮度模型已初始化: 环境光范围=[{}, {}], 分箱数={}", .{ config.min_ambient_light, config.max_ambient_light, config.bin_count }) catch {};

        // 自适应分箱
        model.adaptBins(historical_data) catch |err| {
            logger.err("自适应分箱失败: {}", .{err}) catch {};
        };

        // 训练模型
        const current_time = std.time.timestamp();
        var trained_count: usize = 0;
        for (historical_data) |data_point| {
            const is_active = (current_time - data_point.timestamp) < config.activity_timeout;
            model.train(data_point, current_time, is_active) catch |err| {
                logger.err("训练数据点失败: {}", .{err}) catch {};
            };
            trained_count += 1;
        }
        logger.info("模型训练完成，成功训练数据点: {}/{}", .{ trained_count, historical_data.len }) catch {};

        controller.model = model;
        return controller;
    }

    pub fn deinit(self: *BrightnessController) void {
        self.screen.deinit();
        self.sensor.deinit();
        self.data_logger.deinit();
        self.model.deinit();
        self.logger.deinit();
    }

    pub fn updateBrightness(self: *BrightnessController) !void {
        if (!self.auto_mode) {
            return;
        }
        const current_time = std.time.timestamp();
        const ambient_light = try self.sensor.readAmbientLight();
        const is_active = (current_time - self.last_activity_time) < self.config.activity_timeout;
        const current_brightness = try self.screen.getRaw();
        self.logger.debug("当前状态 - 环境光: {}, 亮度: {}, 是否活跃: {}, 距离上次活动: {}秒", .{
            ambient_light,
            current_brightness,
            is_active,
            current_time - self.last_activity_time,
        }) catch {};

        // 获取模型预测的亮度
        if (self.model.predict(ambient_light, current_time, is_active)) |predicted_brightness| {
            const raw_brightness = @as(i64, @intFromFloat(predicted_brightness * @as(f64, @floatFromInt(self.config.max_brightness - self.config.min_brightness)) / 100.0)) + self.config.min_brightness;
            const clamped_brightness = @min(@max(raw_brightness, self.config.min_brightness), self.config.max_brightness);

            // 只有当亮度差异超过阈值时才更新
            const brightness_diff = @abs(clamped_brightness - current_brightness);
            const threshold = @divTrunc(self.config.max_brightness - self.config.min_brightness, 20); // 5%阈值
            if (brightness_diff > threshold) {
                self.logger.debug("更新亮度: 当前 {} -> 目标 {}", .{ current_brightness, clamped_brightness }) catch {};
                try self.screen.setRaw(clamped_brightness); // 使用setRaw而不是setBrightness

                // 记录数据点
                try self.data_logger.logDataPoint(.{
                    .timestamp = current_time,
                    .ambient_light = ambient_light,
                    .screen_brightness = clamped_brightness,
                    .is_manual_adjustment = false,
                });
            } else {
                self.logger.debug("亮度变化不大，保持当前值: {}", .{current_brightness}) catch {};
            }
        } else {
            // 使用对数映射而不是线性映射
            const ambient_f = @as(f64, @floatFromInt(ambient_light));
            var mapped_brightness: i64 = undefined;
            if (ambient_light < 1) {
                mapped_brightness = self.config.min_brightness;
            } else {
                // 使用对数函数进行映射，提供更好的低光照响应
                const log_ambient = std.math.log(f64, std.math.e, ambient_f);
                const brightness_range = @as(f64, @floatFromInt(self.config.max_brightness - self.config.min_brightness));
                const min_brightness_f = @as(f64, @floatFromInt(self.config.min_brightness));

                mapped_brightness = @as(i64, @intFromFloat((log_ambient / std.math.log(f64, std.math.e, @as(f64, @floatFromInt(self.config.max_ambient_light)))) * brightness_range + min_brightness_f));
            }
            const clamped_brightness = @min(@max(mapped_brightness, self.config.min_brightness), self.config.max_brightness);

            // 只有当亮度差异超过阈值时才更新
            const brightness_diff = @abs(clamped_brightness - current_brightness);
            const threshold = @divTrunc(self.config.max_brightness - self.config.min_brightness, 20);
            if (brightness_diff > threshold) {
                self.logger.debug("使用对数映射更新亮度: 当前 {} -> 目标 {}", .{ current_brightness, clamped_brightness }) catch {};
                try self.screen.setRaw(clamped_brightness); // 使用setRaw而不是setBrightness

                // 记录数据点
                try self.data_logger.logDataPoint(.{
                    .timestamp = current_time,
                    .ambient_light = ambient_light,
                    .screen_brightness = clamped_brightness,
                    .is_manual_adjustment = false,
                });
            } else {
                self.logger.debug("亮度变化不大，保持当前值: {}", .{current_brightness}) catch {};
            }
        }
    }

    pub fn handleUserAdjustment(self: *BrightnessController, new_brightness: i64) !void {
        const current_time = std.time.timestamp();
        const ambient_light = try self.sensor.readAmbientLight();
        self.logger.info("用户手动调节亮度: {}, 当前环境光: {}", .{ new_brightness, ambient_light }) catch {};

        // 更新最后活动时间
        self.last_activity_time = current_time;

        // 记录手动调节数据
        const data_point = DataPoint{
            .timestamp = current_time,
            .ambient_light = ambient_light,
            .screen_brightness = new_brightness,
            .is_manual_adjustment = true,
        };
        try self.data_logger.logDataPoint(data_point);
        try self.model.train(data_point, current_time, true);

        // 设置新的亮度
        try self.screen.setRaw(new_brightness);
    }

    pub fn cleanup(self: *BrightnessController) void {
        const current_time = std.time.timestamp();
        self.model.cleanup(current_time);
        self.logger.info("执行清理操作", .{}) catch {};
    }

    pub fn setAutoMode(self: *BrightnessController, enabled: bool) !void {
        if (self.auto_mode == enabled) return;
        self.auto_mode = enabled;
        self.logger.info("自动亮度调节模式已{s}", .{if (enabled) "开启" else "关闭"}) catch {};

        // 如果开启了自动模式，立即执行一次亮度更新
        if (enabled) {
            try self.updateBrightness();
        }
    }

    pub fn handleExternalBrightnessChange(self: *BrightnessController, new_brightness: i64) !void {
        const current_time = std.time.timestamp();
        const ambient_light = try self.sensor.readAmbientLight();
        self.logger.info("检测到外部程序调节亮度: {} -> {}, 当前环境光: {}", .{ try self.screen.getRaw(), new_brightness, ambient_light }) catch {};
        const data_point = DataPoint{
            .timestamp = current_time,
            .ambient_light = ambient_light,
            .screen_brightness = new_brightness,
            .is_manual_adjustment = true,
        };
        self.data_logger.logDataPoint(data_point) catch |err| {
            self.logger.err("记录外部亮度调节数据失败: {}", .{err}) catch {};
            return err;
        };
        if (self.auto_mode) {
            self.logger.info("自动模式下检测到外部亮度变化 - 当前策略：在下次更新时调整", .{}) catch {};
        } else {
            self.logger.debug("手动模式下检测到外部亮度变化 - 保持外部设置的亮度值", .{}) catch {};
        }
    }
};
