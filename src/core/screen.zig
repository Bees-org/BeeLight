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
    duration_ms: u64 = 2000,
    steps: u64 = 30,
};

const SysfsBrightnessError = error{
    FileOpenError,
    FileReadError,
    FileWriteError,
    ParseError,
    SysfsPathNotFound, // 新增错误，用于路径不存在
};

const SysfsBrightness = struct {
    allocator: std.mem.Allocator,
    log: *Logger,
    brightness_fd: std.fs.File,
    max_brightness: i64,
    buffer: []u8, // 用于读写操作

    const default_buffer_size = 16;

    pub fn init(allocator: std.mem.Allocator, logger: *Logger, backlight_device: []const u8) !SysfsBrightness {
        logger.debug("初始化 SysfsBrightness 控制器: {s}", .{backlight_device}) catch {};

        const brightness_path_fmt = "/sys/class/backlight/{s}/brightness";
        const max_brightness_path_fmt = "/sys/class/backlight/{s}/max_brightness";

        const brightness_path = std.fmt.allocPrint(allocator, brightness_path_fmt, .{backlight_device}) catch |err| {
            logger.err("无法分配亮度路径字符串: {}", .{err}) catch {};
            return SysfsBrightnessError.FileOpenError; // Or a more specific allocation error?
        };
        defer allocator.free(brightness_path);

        const max_brightness_path = std.fmt.allocPrint(allocator, max_brightness_path_fmt, .{backlight_device}) catch |err| {
            logger.err("无法分配最大亮度路径字符串: {}", .{err}) catch {};
            return SysfsBrightnessError.FileOpenError; // Or a more specific allocation error?
        };
        defer allocator.free(max_brightness_path);

        // 检查亮度文件路径是否存在
        std.fs.accessAbsolute(brightness_path, .{}) catch |err| {
            // 如果 accessAbsolute 抛出错误，则路径有问题
            logger.err("亮度文件路径不存在或无法访问 '{s}': {}", .{ brightness_path, err }) catch {};
            return SysfsBrightnessError.SysfsPathNotFound;
        };
        // 如果没有错误，则路径存在且可访问，继续执行

        // 检查最大亮度文件路径是否存在
        std.fs.accessAbsolute(max_brightness_path, .{}) catch |err| {
            // 如果 accessAbsolute 抛出错误，则路径有问题
            logger.err("最大亮度文件路径不存在或无法访问 '{s}': {}", .{ max_brightness_path, err }) catch {};
            return SysfsBrightnessError.SysfsPathNotFound;
        };
        // 如果没有错误，则路径存在且可访问，继续执行

        const brightness_file = std.fs.openFileAbsolute(brightness_path, .{ .mode = .read_write }) catch |err| {
            logger.err("打开亮度文件失败: {s}, 错误: {}", .{ brightness_path, err }) catch {};
            return SysfsBrightnessError.FileOpenError;
        };
        errdefer brightness_file.close(); // Close if subsequent steps fail

        const max_brightness_file = std.fs.openFileAbsolute(max_brightness_path, .{ .mode = .read_only }) catch |err| {
            logger.err("打开最大亮度文件失败: {s}, 错误: {}", .{ max_brightness_path, err }) catch {};
            return SysfsBrightnessError.FileOpenError;
        };
        defer max_brightness_file.close(); // Ensure closed after reading

        var read_buffer: [default_buffer_size]u8 = undefined; // Temporary buffer for reading max brightness

        const bytes_read = max_brightness_file.readAll(&read_buffer) catch |err| {
            logger.err("读取最大亮度值失败: {}", .{err}) catch {};
            return SysfsBrightnessError.FileReadError;
        };

        // Trim newline before parsing
        const max_brightness_str = std.mem.trimRight(u8, read_buffer[0..bytes_read], "\n");

        const max_val = std.fmt.parseInt(i64, max_brightness_str, 10) catch |err| {
            logger.err("解析最大亮度值 '{s}' 失败: {}", .{ max_brightness_str, err }) catch {};
            return SysfsBrightnessError.ParseError;
        };

        const buffer = allocator.alloc(u8, default_buffer_size) catch |err| {
            logger.err("分配 SysfsBrightness 缓冲区失败: {}", .{err}) catch {};
            return SysfsBrightnessError.FileOpenError; // Reusing error, consider specific allocation error
        };

        logger.debug("SysfsBrightness 初始化成功，最大亮度: {}", .{max_val}) catch {};

        return SysfsBrightness{
            .allocator = allocator,
            .log = logger,
            .brightness_fd = brightness_file,
            .max_brightness = max_val,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *SysfsBrightness) void {
        self.log.debug("清理 SysfsBrightness 资源", .{}) catch {};
        self.allocator.free(self.buffer);
        self.brightness_fd.close();
    }

    pub fn getRaw(self: *SysfsBrightness) !i64 {
        // Reset buffer position/contents if necessary, or use a fresh slice
        // pwrite/pread might be safer if multiple operations can occur
        const bytes_read = self.brightness_fd.pread(self.buffer, 0) catch |err| {
            self.log.err("读取亮度值失败 (Sysfs): {}", .{err}) catch {};
            return SysfsBrightnessError.FileReadError;
        };
        // Ensure null termination or careful slicing if buffer is reused
        // Trim newline character before parsing
        const value_str = std.mem.trimRight(u8, self.buffer[0..bytes_read], "\n");
        const value = std.fmt.parseInt(i64, value_str, 10) catch |err| {
            self.log.err("解析亮度值失败 (Sysfs): '{s}', {}", .{ value_str, err }) catch {};
            return SysfsBrightnessError.ParseError;
        };
        return value;
    }

    pub fn setRaw(self: *SysfsBrightness, value: i64) !void {
        // Format value into buffer
        const value_str = std.fmt.bufPrint(self.buffer, "{d}", .{value}) catch |err| {
            self.log.err("格式化亮度值到缓冲区失败: {}", .{err}) catch {};
            return SysfsBrightnessError.FileWriteError; // Or a different error
        };

        // Use pwrite to write from the beginning of the file
        _ = self.brightness_fd.pwriteAll(value_str, 0) catch |err| {
            self.log.err("写入亮度值失败 (Sysfs): {}", .{err}) catch {};
            return SysfsBrightnessError.FileWriteError;
        };
    }

    pub fn getMaxRaw(self: *const SysfsBrightness) i64 {
        return self.max_brightness;
    }
};

/// 屏幕亮度控制器
/// 支持亮度读取、设置、过渡动画、权限检测等。
/// 使用可插拔的底层亮度控制机制。
pub const Screen = struct {
    allocator: std.mem.Allocator,
    controller: SysfsBrightness, // 持有具体的控制器实例
    min: i64, // 用户定义的最小亮度 (可以低于控制器的物理最小值)
    transition_config: TransitionOptions,
    last_brightness: i64, // 缓存最后一次成功获取或设置的亮度
    log: *Logger,

    /// 初始化屏幕控制器
    /// backlight_device: 例如 "intel_backlight" 或 "amdgpu_bl0"
    pub fn init(logger: *Logger, backlight_device: []const u8) !Screen {
        logger.info("初始化屏幕控制器 (设备: {s})...", .{backlight_device}) catch {};
        const allocator = std.heap.page_allocator; // 或者传入 allocator

        // 初始化底层的亮度控制器 (这里是 SysfsBrightness)
        const sysfs_controller = SysfsBrightness.init(allocator, logger, backlight_device) catch |err| {
            logger.err("初始化 Sysfs 控制器失败: {}", .{err}) catch {};
            // 根据 SysfsBrightnessError 映射到 ScreenError 或直接返回
            return switch (err) {
                error.FileOpenError => ScreenError.FileOpenError,
                error.FileReadError => ScreenError.FileReadError,
                error.ParseError => ScreenError.ParseError,
                error.SysfsPathNotFound => ScreenError.FileOpenError, // Map appropriately
                else => |e| e, // Propagate other potential errors like OOM
            };
        };
        // errdefer sysfs_controller.deinit(); // Deinit if subsequent Screen init fails

        // min 值现在由 Screen 管理，可以从配置加载或硬编码
        const user_min_brightness: i64 = 50; // 示例：用户设置的最小值

        var screen = Screen{
            .allocator = allocator,
            .controller = sysfs_controller,
            .min = user_min_brightness,
            .transition_config = TransitionOptions{},
            .last_brightness = 0, // 会在下面被更新
            .log = logger,
        };

        // 初始化时读取当前亮度
        screen.last_brightness = screen.getRaw() catch |err| {
            logger.err("初始化时读取亮度失败: {}", .{err}) catch {};
            screen.deinit(); // Clean up already initialized controller
            return err;
        };

        const max_raw = screen.controller.getMaxRaw();
        logger.info("屏幕控制器初始化完成，当前亮度: {}, 最小限制: {}, 最大物理亮度: {}", .{ screen.last_brightness, screen.min, max_raw }) catch {};

        return screen;
    }

    /// 释放屏幕控制器资源
    pub fn deinit(self: *Screen) void {
        self.log.debug("清理屏幕控制器资源", .{}) catch {};
        self.controller.deinit();
        // 注意：如果 allocator 是传入的，Screen 不应该释放它
        // 如果 allocator 是 Screen::init 分配的，则需要释放
        // 目前使用 page_allocator，不需要释放
    }

    /// 获取当前亮度原始值 (通过底层控制器)
    pub fn getRaw(self: *Screen) !i64 {
        self.log.debug("读取当前亮度值 (通过控制器)", .{}) catch {};
        const value = self.controller.getRaw() catch |err| {
            // 可以根据底层错误类型转换 ScreenError
            self.log.err("控制器读取亮度失败: {}", .{err}) catch {};
            return ScreenError.FileReadError; // 示例转换
        };
        self.last_brightness = value; // 更新缓存
        return value;
    }

    /// 设置亮度原始值（带过渡动画）
    pub fn setRaw(self: *Screen, value: i64) !void {
        const start_time = time.milliTimestamp();
        self.log.debug("请求设置亮度值: {}", .{value}) catch {};

        const current_max = self.controller.getMaxRaw(); // 从控制器获取最大值

        // 使用 Screen 自己的 min 和从控制器获取的 max 进行范围检查
        if (value < self.min) {
            self.log.warn("请求亮度 {} 低于设定最小值 {}，将使用最小值", .{ value, self.min }) catch {};
            return self.setRaw(self.min); // 递归调用设置最小值
        }

        if (value > current_max) {
            self.log.warn("请求亮度 {} 高于物理最大值 {}，将使用最大值", .{ value, current_max }) catch {};
            return self.setRaw(current_max); // 递归调用设置最大值
        }

        // 获取当前亮度 (尝试使用缓存，如果需要更精确可以强制重新读取)
        const current: i64 = try self.getRaw(); // 总是重新读取

        if (current == value) {
            self.log.debug("亮度值未变化，无需调整", .{}) catch {};
            return;
        }

        // --- 过渡动画逻辑不变，但是使用 self.controller.setRaw() ---
        // 计算过渡步骤和时间间隔
        // 注意：这里的 diff 计算应该使用物理范围 (0 到 max_raw) 还是用户范围 (min 到 max_raw)？
        // 使用物理范围可能更平滑：
        const physical_range: f64 = @as(f64, @floatFromInt(current_max)); // 假设物理最小为0
        // const current_f: f64 = @as(f64, @floatFromInt(current));
        // const target_f: f64 = @as(f64, @floatFromInt(value));
        // const diff_percent = if (physical_range > 0) math.fabs(target_f - current_f) / physical_range * 100.0 else 0.0;

        // 基于百分比差异调整步数似乎不合理了，直接用固定步数或基于绝对值差异调整
        // const diff_abs = @abs(value - current);
        const diff: f64 = @as(f64, @floatFromInt(@abs(value - current))) / physical_range * 100.0 / 2.0;
        const step_count = self.transition_config.steps + @as(u64, @intFromFloat(diff)); // 示例调整方式
        // const step_count = self.transition_config.steps; // 简化：使用固定步数

        self.log.info("过渡步数: {}", .{step_count}) catch {};
        if (step_count == 0) {
            self.log.warn("过渡步数为0，将直接设置亮度", .{}) catch {};
            try self.controller.setRaw(value);
            self.last_brightness = value; // 更新缓存
            self.log.info("亮度直接调整完成: {} -> {}", .{ current, value }) catch {};
            return;
        }

        const sleep_duration = @divTrunc(self.transition_config.duration_ms * time.ns_per_ms, step_count);

        // 对数插值逻辑不变，但范围是 [min, max_raw]
        // 映射到 [min+1, max_raw+1]
        const mapped_current = @as(f64, @floatFromInt(current + 1));
        const mapped_value = @as(f64, @floatFromInt(value + 1));

        const log_current = math.log2(mapped_current);
        const log_value = math.log2(mapped_value);
        const log_diff = log_value - log_current;
        const log_step_size = log_diff / @as(f64, @floatFromInt(step_count));

        var i: u64 = 0;
        while (i < step_count) : (i += 1) {
            var target_mapped_log_brightness: f64 = undefined;
            if (i == step_count - 1) {
                target_mapped_log_brightness = log_value;
            } else {
                target_mapped_log_brightness = log_current + @as(f64, @floatFromInt(i + 1)) * log_step_size;
            }

            const current_linear_brightness_float = math.exp2(target_mapped_log_brightness) - 1;
            const current_value_int = @as(i64, @intFromFloat(math.round(current_linear_brightness_float)));

            // 钳位到 [min, max_raw]
            const clamped_value = std.math.clamp(current_value_int, self.min, current_max);

            // 使用控制器设置亮度
            self.controller.setRaw(clamped_value) catch |err| {
                // 如何处理过渡中的错误？可以选择停止过渡或记录错误并继续
                self.log.err("写入亮度值失败 (过渡中): {}", .{err}) catch {};
                // 停止过渡可能比较安全
                return ScreenError.FileWriteError; // Or map appropriately
            };
            // self.last_brightness = clamped_value; // 可以在每一步更新缓存，或只在最后更新

            if (sleep_duration > 0) {
                time.sleep(sleep_duration);
            }
        }
        // 确保最后设置的是目标值（如果插值有误差）
        try self.controller.setRaw(value);
        self.last_brightness = value; // 更新缓存

        const end_time = time.milliTimestamp();
        self.log.debug("亮度调整完成: {} -> {}, 总耗时{}ms", .{ current, value, end_time - start_time }) catch {};
    }

    // setTransitionConfig 方法保持不变
    pub fn setTransitionConfig(self: *Screen, duration_ms: u64, steps: u64) void {
        self.transition_config = TransitionOptions{
            .duration_ms = duration_ms,
            .steps = steps,
        };
    }
};
