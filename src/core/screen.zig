const std = @import("std");
const time = std.time;
const Thread = std.Thread;
const Logger = @import("log.zig").Logger;

const BacklightError = error{
    FileOpenError,
    FileReadError,
    FileWriteError,
    ParseError,
    InvalidValue,
    NoSuidPermission,
};

pub const BrightnessChangeCallback = *const fn (i64) void;

fn detectSuid() bool {
    const euid = std.os.linux.geteuid();
    return euid == 0;
}

const TransitionConfig = struct {
    duration_ms: u64 = 200,
    steps: u64 = 20,
};

/// 屏幕亮度控制器
/// 支持亮度读取、设置、过渡动画、权限检测等。
pub const Screen = struct {
    buffer: []u8,
    allocator: std.mem.Allocator,
    fd: std.fs.File,
    max: i64,
    min: i64,
    backlight_path: []const u8,
    transition_config: TransitionConfig,
    last_brightness: i64,
    on_brightness_change: ?BrightnessChangeCallback,
    logger: *Logger,

    /// 初始化屏幕控制器
    pub fn init(logger: *Logger) !Screen {
        logger.info("初始化屏幕控制器...", .{}) catch {};
        const allocator = std.heap.page_allocator;
        const buffer = allocator.alloc(u8, 10) catch |err| {
            logger.err("分配缓冲区失败: {}", .{err}) catch {};
            return err;
        };
        errdefer allocator.free(buffer);

        const backlight_path = "/sys/class/backlight/intel_backlight/brightness";

        const file = std.fs.openFileAbsolute(backlight_path, .{ .mode = .read_only }) catch |err| {
            logger.err("打开亮度文件失败: {s}, 错误: {}", .{ backlight_path, err }) catch {};
            return err;
        };

        var screen = Screen{
            .buffer = buffer,
            .allocator = allocator,
            .fd = file,
            .max = 21333,
            .min = 5200,
            .backlight_path = backlight_path,
            .transition_config = TransitionConfig{},
            .last_brightness = 0,
            .on_brightness_change = null,
            .logger = logger,
        };

        // 初始化时读取当前亮度
        screen.last_brightness = screen.getRaw() catch |err| {
            logger.err("初始化时读取亮度失败: {}", .{err}) catch {};
            return err;
        };
        logger.info("屏幕控制器初始化完成，当前亮度: {}", .{screen.last_brightness}) catch {};
        return screen;
    }

    /// 释放屏幕控制器资源
    pub fn deinit(self: *Screen) void {
        self.logger.debug("清理屏幕控制器资源", .{}) catch {};
        self.allocator.free(self.buffer);
        self.fd.close();
    }

    /// 获取当前亮度原始值
    pub fn getRaw(self: *Screen) !i64 {
        self.logger.debug("读取当前亮度值", .{}) catch {};

        const bytes_read = self.fd.pread(self.buffer, 0) catch |err| {
            self.logger.err("读取亮度值失败: {}", .{err}) catch {};
            return err;
        };
        const value = std.fmt.parseInt(i64, self.buffer[0 .. bytes_read - 1], 10) catch |err| {
            self.logger.err("解析亮度值失败: {}", .{err}) catch {};
            return err;
        };

        // 检查亮度是否发生变化（由外部程序修改）
        if (value != self.last_brightness) {
            self.logger.info("检测到亮度变化: {} -> {}", .{ self.last_brightness, value }) catch {};
            self.last_brightness = value;
            if (self.on_brightness_change) |callback| {
                self.logger.debug("触发亮度变化回调", .{}) catch {};
                callback(value);
            }
        }

        return value;
    }

    /// 设置亮度原始值（带过渡动画）
    pub fn setRaw(self: *Screen, value: i64) !void {
        self.logger.debug("设置亮度值: {}", .{value}) catch {};

        if (value < self.min) {
            self.logger.err("亮度值过低: {} (最小值: {})", .{ value, self.min }) catch {};
            return BacklightError.InvalidValue;
        }

        if (value > self.max) {
            self.logger.err("亮度值过高: {} (最大值: {})", .{ value, self.max }) catch {};
            return BacklightError.InvalidValue;
        }

        if (!detectSuid()) {
            self.logger.err("没有root权限，当前EUID: {}", .{std.os.linux.geteuid()}) catch {};
            return BacklightError.NoSuidPermission;
        }

        // 获取当前亮度
        const current = try self.getRaw();
        if (current == value) {
            self.logger.debug("亮度值未变化，无需调整", .{}) catch {};
            return;
        }

        // 计算过渡步骤
        const step_count = self.transition_config.steps;
        const sleep_duration = @divTrunc(self.transition_config.duration_ms * time.ns_per_ms, step_count);
        const brightness_diff = value - current;
        const step_size = @divTrunc(brightness_diff, @as(i64, @intCast(step_count)));

        // 逐步调整亮度
        var i: u64 = 0;
        var current_value = current;
        while (i < step_count) : (i += 1) {
            current_value += step_size;
            if (i == step_count - 1) {
                current_value = value; // 确保最后一步达到目标亮度
            }

            const file = std.fs.openFileAbsolute(self.backlight_path, .{ .mode = .write_only }) catch |err| {
                self.logger.err("打开亮度文件失败: {}", .{err}) catch {};
                return err;
            };
            defer file.close();

            const value_str = std.fmt.allocPrint(self.allocator, "{}\n", .{current_value}) catch |err| {
                self.logger.err("格式化亮度值失败: {}", .{err}) catch {};
                return err;
            };
            defer self.allocator.free(value_str);

            file.writeAll(value_str) catch |err| {
                self.logger.err("写入亮度值失败: {}", .{err}) catch {};
                return err;
            };

            time.sleep(sleep_duration);
        }

        self.logger.info("亮度调整完成: {} -> {}", .{ current, value }) catch {};
    }

    /// 设置亮度（自动裁剪到有效范围）
    pub fn setBrightness(self: *Screen, value: i64) !void {
        const clamped_value = @min(@max(value, self.min), self.max);
        try self.setRaw(clamped_value);
    }

    /// 获取亮度百分比（0-100）
    pub fn getBrightness(self: *Screen) !i64 {
        const raw_value = try self.getRaw();
        const brightness_range = @as(f64, @floatFromInt(self.max - self.min));
        const normalized_value = @as(f64, @floatFromInt(raw_value - self.min)) / brightness_range;
        return @as(i64, @intFromFloat(normalized_value * 100));
    }

    /// 设置过渡动画参数
    pub fn setTransitionConfig(self: *Screen, duration_ms: u64, steps: u64) void {
        self.transition_config = TransitionConfig{
            .duration_ms = duration_ms,
            .steps = steps,
        };
    }

    /// 设置亮度变化回调
    pub fn setOnBrightnessChange(self: *Screen, callback: ?BrightnessChangeCallback) void {
        self.on_brightness_change = callback;
    }
};
