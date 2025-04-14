const std = @import("std");

pub const Command = union(enum) {
    set_brightness: f64,
    get_brightness,
    toggle_auto,
    show_stats,
    help,
};

pub const Response = struct {
    success: bool,
    message: []const u8,
    data: ?union(enum) {
        brightness: i64,
        auto_mode: bool,
        stats: struct {
            ambient: f32,
            brightness: i64,
            auto_mode: bool,
        },
    } = null,
};

pub const ucred = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,
};
