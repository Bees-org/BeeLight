const std = @import("std");
const DataLogger = @import("../storage/recorder.zig").DataLogger;
const DataPoint = @import("../storage/recorder.zig").DataPoint;

// 简单的移动平均模型
pub const MovingAverageModel = struct {
    allocator: std.mem.Allocator,
    ambient_bins: []AmbientBin,
    window_size: usize,

    pub const AmbientBin = struct {
        min_ambient: i64,
        max_ambient: i64,
        brightness_sum: f64,
        count: usize,
        last_n_brightness: std.ArrayList(i64),

        pub fn init(allocator: std.mem.Allocator, min: i64, max: i64, window_size: usize) !AmbientBin {
            return AmbientBin{
                .min_ambient = min,
                .max_ambient = max,
                .brightness_sum = 0,
                .count = 0,
                .last_n_brightness = try std.ArrayList(i64).initCapacity(allocator, window_size),
            };
        }

        pub fn deinit(self: *AmbientBin) void {
            self.last_n_brightness.deinit();
        }

        pub fn update(self: *AmbientBin, brightness: i64) !void {
            if (self.last_n_brightness.items.len >= self.last_n_brightness.capacity) {
                self.brightness_sum -= @as(f64, @floatFromInt(self.last_n_brightness.items[0]));
                _ = self.last_n_brightness.orderedRemove(0);
                self.count -= 1;
            }

            try self.last_n_brightness.append(brightness);
            self.brightness_sum += @as(f64, @floatFromInt(brightness));
            self.count += 1;
        }

        pub fn getAverageBrightness(self: *const AmbientBin) ?f64 {
            if (self.count == 0) return null;
            return self.brightness_sum / @as(f64, @floatFromInt(self.count));
        }
    };

    pub fn init(allocator: std.mem.Allocator, min_ambient: i64, max_ambient: i64, bin_count: usize, window_size: usize) !MovingAverageModel {
        var bins = try allocator.alloc(AmbientBin, bin_count);
        const bin_size = @divFloor(max_ambient - min_ambient, @as(i64, @intCast(bin_count)));

        for (0..bin_count) |i| {
            const bin_min = min_ambient + @as(i64, @intCast(i)) * bin_size;
            const bin_max = if (i == bin_count - 1) max_ambient else bin_min + bin_size;
            bins[i] = try AmbientBin.init(allocator, bin_min, bin_max, window_size);
        }

        return MovingAverageModel{
            .allocator = allocator,
            .ambient_bins = bins,
            .window_size = window_size,
        };
    }

    pub fn deinit(self: *MovingAverageModel) void {
        for (self.ambient_bins) |*bin| {
            bin.deinit();
        }
        self.allocator.free(self.ambient_bins);
    }

    pub fn train(self: *MovingAverageModel, data: []const DataPoint) !void {
        for (data) |point| {
            if (!point.is_manual_adjustment) continue; // 只使用手动调节的数据进行训练

            // 找到对应的光照区间
            for (self.ambient_bins) |*bin| {
                if (point.ambient_light >= bin.min_ambient and point.ambient_light < bin.max_ambient) {
                    try bin.update(point.screen_brightness);
                    break;
                }
            }
        }
    }

    pub fn predict(self: *const MovingAverageModel, ambient_light: i64) ?f64 {
        // 找到对应的光照区间
        for (self.ambient_bins) |bin| {
            if (ambient_light >= bin.min_ambient and ambient_light < bin.max_ambient) {
                return bin.getAverageBrightness();
            }
        }
        return null;
    }
};
