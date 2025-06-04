const std = @import("std");

const Config = @import("core/config.zig").BrightnessConfig;
const Model = @import("model/brightness_model.zig").BrightnessModel;

const Point = struct {
    x: i64, // ambient
    y: i64, // screen light
};

pub fn main() !void {
    const config = try Config.load();
    const model = Model.init(std.heap.page_allocator, config, config.min_ambient_light, config.max_ambient_light, config.bin_count) catch |err| {
        std.debug.print("初始化模型失败：{s}\n", .{@errorName(err)});
        return err;
    };

    var data = std.ArrayList(Point).init(std.heap.page_allocator);
    defer data.deinit();

    for (0..23333) |i| {
        if (model.predict(@as(i64, @intCast(i)), true)) |result| {
            try data.append(Point{ .x = @as(i64, @intCast(i)), .y = result });
        } else {}
    }

    std.log.debug("Data points:", .{});
    for (data.items) |point| {
        std.log.debug("  {{ x: {}, y: {} }}", .{ point.x, point.y });
    }
}
