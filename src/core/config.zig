const std = @import("std");

pub const TransitionType = enum {
    Linear,
    Exponential,
    EaseInOut,
};

pub const TimeSchedule = struct {
    start_hour: u8,
    end_hour: u8,
    target_brightness: f64,
};

const default_schedule = [_]TimeSchedule{
    .{ .start_hour = 9, .end_hour = 17, .target_brightness = 1.0 },
    .{ .start_hour = 18, .end_hour = 22, .target_brightness = 0.8 },
    .{ .start_hour = 23, .end_hour = 8, .target_brightness = 0.5 },
};

pub const BrightnessConfig = struct {
    // 自动亮度调节设置
    auto_brightness_enabled: bool = true,
    min_brightness: i64 = 5200,
    max_brightness: i64 = 21333,
    ambient_sensitivity: f64 = 1.0,
    min_ambient_light: i64 = 0,
    max_ambient_light: i64 = 1000,
    bin_count: usize = 10,
    activity_timeout: i64 = 300, // 5分钟无操作视为不活跃
    update_interval_ms: i64 = 50,
    transition_duration_ms: u64 = 200,

    // 平滑过渡设置
    transition_enabled: bool = true,
    transition_type: TransitionType = .Linear,

    // 时间表设置
    time_schedule: []const TimeSchedule = &default_schedule,

    /// 从文件加载配置（当前为默认实现，后续可扩展为文件读取）
    pub fn load() !BrightnessConfig {
        // TODO: 从文件加载配置
        return BrightnessConfig{};
    }

    /// 保存配置到文件（当前为占位，后续可扩展为文件保存）
    pub fn save(_: *const BrightnessConfig) !void {
        // TODO: 保存配置到文件
    }
};
