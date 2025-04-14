const std = @import("std");

pub const EventType = enum {
    BrightnessChanged,
    SensorUpdated,
    ConfigChanged,
    Shutdown,
};

pub const Event = struct {
    type: EventType,
    data: Data,

    pub const Data = union {
        brightness_changed: struct {
            old_value: f64,
            new_value: f64,
        },
        sensor_updated: struct {
            value: i64,
        },
        config_changed: struct {
            key: []const u8,
            value: []const u8,
        },
        shutdown: void,
    };
};
