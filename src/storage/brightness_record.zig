const std = @import("std");

/// 表示一个亮度调节记录
pub const BrightnessRecord = struct {
    /// Unix 时间戳（秒）
    timestamp: i64,
    /// 环境光照度值
    ambient_light: i64,
    /// 屏幕亮度值（0-100）
    screen_brightness: i64,
    /// 是否为手动调节
    is_manual_adjustment: bool,

    pub fn init(
        timestamp: i64,
        ambient_light: i64,
        screen_brightness: i64,
        is_manual_adjustment: bool,
    ) BrightnessRecord {
        return .{
            .timestamp = timestamp,
            .ambient_light = ambient_light,
            .screen_brightness = screen_brightness,
            .is_manual_adjustment = is_manual_adjustment,
        };
    }
};
