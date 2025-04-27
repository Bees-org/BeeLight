const std = @import("std");
const time = std.time;
const Logger = @import("log.zig").Logger;
const math = std.math;

const ScreenError = error{
    FileOpenError,
    FileReadError,
    FileWriteError,
    ParseError,
    InvalidValue,
    NoSuidPermission,
};

const TransitionOptions = struct {
    duration_ms: u64 = 500,
    steps: u64 = 20,
};

/// 屏幕亮度控制器
/// 支持亮度读取、设置、过渡动画、权限检测等。
pub const Screen = struct {
    allocator: std.mem.Allocator,
    buffer: []u8 = undefined,
    fd: std.fs.File,
    max: i64,
    min: i64 = 0,
    backlight_path: []const u8,
    transition_config: TransitionOptions,
    last_brightness: i64,
    log: *Logger,
    offset: u64 = 0,

    /// 初始化屏幕控制器
    pub fn init(logger: *Logger) !Screen {
        logger.info("初始化屏幕控制器...", .{}) catch {};
        const allocator = std.heap.page_allocator;
        const buffer = allocator.alloc(u8, 16) catch |err| {
            logger.err("分配缓冲区失败: {}", .{err}) catch {};
            return err;
        };
        errdefer allocator.free(buffer);

        const backlight_path = "/sys/class/backlight/intel_backlight/brightness";

        const file = std.fs.openFileAbsolute(backlight_path, .{ .mode = .read_write }) catch |err| {
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
            .transition_config = TransitionOptions{},
            .last_brightness = 0,
            .log = logger,
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
        self.log.debug("清理屏幕控制器资源", .{}) catch {};
        self.allocator.free(self.buffer);
        self.fd.close();
    }

    /// 获取当前亮度原始值
    pub fn getRaw(self: *Screen) !i64 {
        self.log.debug("读取当前亮度值", .{}) catch {};

        const bytes_read = self.fd.pread(self.buffer, 0) catch |err| {
            self.log.err("读取亮度值失败: {}", .{err}) catch {};
            return err;
        };
        const value = std.fmt.parseInt(i64, self.buffer[0 .. bytes_read - 1], 10) catch |err| {
            self.log.err("解析亮度值失败: {}", .{err}) catch {};
            return err;
        };
        return value;
    }

    /// 设置亮度原始值（带过渡动画）
    pub fn setRaw(self: *Screen, value: i64) !void {
        self.log.debug("设置亮度值: {}", .{value}) catch {};

        if (value < self.min) {
            self.log.err("亮度值过低: {} (最小值: {})", .{ value, self.min }) catch {};
            return ScreenError.InvalidValue;
        }

        if (value > self.max) {
            self.log.err("亮度值过高: {} (最大值: {})", .{ value, self.max }) catch {};
            return ScreenError.InvalidValue;
        }

        // 获取当前亮度
        const current = try self.getRaw();
        if (current == value) {
            self.log.debug("亮度值未变化，无需调整", .{}) catch {};
            return;
        }

        // 计算过渡步骤和时间间隔
        const step_count = self.transition_config.steps;
        if (step_count == 0) {
            self.log.warn("过渡步数为0，将直接设置亮度", .{}) catch {};
            // 直接设置亮度，没有过渡
            const value_str = std.fmt.allocPrint(self.allocator, "{}\n", .{value}) catch |err| {
                self.log.err("格式化亮度值失败: {}", .{err}) catch {};
                return err;
            };
            _ = self.fd.pwrite(value_str, self.offset) catch |err| {
                self.log.err("写入亮度值失败: {}", .{err}) catch {};
                return err;
            };
            self.log.info("亮度调整完成: {} -> {}", .{ current, value }) catch {};
            return;
        }

        const sleep_duration = @divTrunc(self.transition_config.duration_ms * time.ns_per_ms, step_count);

        // 使用对数插值: 将亮度值映射到对数空间进行线性插值，再映射回线性空间
        // 避免 log(0)，将亮度范围映射到一个小正数范围，例如 [min, max] -> [min+1, max+1]
        const mapped_current = @as(f64, @floatFromInt(current + 1));
        const mapped_value = @as(f64, @floatFromInt(value + 1));

        const log_current = math.log2(mapped_current);
        const log_value = math.log2(mapped_value);
        const log_diff = log_value - log_current;
        const log_step_size = log_diff / @as(f64, @floatFromInt(step_count));

        // 逐步调整亮度
        var i: u64 = 0;
        while (i < step_count) : (i += 1) {
            var target_mapped_log_brightness: f64 = undefined;
            if (i == step_count - 1) {
                // 确保最后一步达到目标亮度
                target_mapped_log_brightness = log_value;
            } else {
                target_mapped_log_brightness = log_current + @as(f64, @floatFromInt(i + 1)) * log_step_size;
            }

            // 将对数空间的值映射回线性亮度空间
            const current_linear_brightness_float = math.exp2(target_mapped_log_brightness) - 1;
            // 将浮点数转换为整数，四舍五入以减少误差
            const current_value = @as(i64, @intFromFloat(math.round(current_linear_brightness_float)));

            // 确保亮度值在合法范围内 (理论上对数插值不会超出，但保险起见)
            const clamped_value = std.math.clamp(current_value, self.min, self.max);

            const value_str = std.fmt.allocPrint(self.allocator, "{}\n", .{clamped_value}) catch |err| {
                self.log.err("格式化亮度值失败: {}", .{err}) catch {};
                return err;
            };
            defer self.allocator.free(value_str); // 释放分配的字符串内存

            _ = self.fd.pwrite(value_str, self.offset) catch |err| {
                self.log.err("写入亮度值失败: {}", .{err}) catch {};
                return err;
            };

            if (sleep_duration > 0) {
                time.sleep(sleep_duration);
            }
        }

        self.log.info("亮度调整完成: {} -> {}", .{ current, value }) catch {};
    }

    /// 设置过渡动画参数
    pub fn setTransitionConfig(self: *Screen, duration_ms: u64, steps: u64) void {
        self.transition_config = TransitionOptions{
            .duration_ms = duration_ms,
            .steps = steps,
        };
    }
};
