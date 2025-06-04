const std = @import("std");
const time = @import("std").time;
const DataPoint = @import("../model/recorder.zig").DataPoint;
const Config = @import("../core/config.zig").BrightnessConfig;

pub const TimeFeatures = struct {
    hour: u8,
    is_day: bool,

    pub fn fromTimestamp(timestamp: i64) TimeFeatures {
        const hour = @as(u8, @intCast(@mod(@divFloor(timestamp, 3600), 24)));
        // 简单判断白天：6点到18点
        const is_day = hour >= 6 and hour < 18;
        return .{
            .hour = hour,
            .is_day = is_day,
        };
    }
};

pub const WeightedDataPoint = struct {
    brightness: i64,
    weight: f64,
    timestamp: i64,
};

pub const AdaptiveBin = struct {
    min_value: i64,
    max_value: i64,
    points: std.ArrayList(WeightedDataPoint),
    total_weight: f64,

    pub fn init(allocator: std.mem.Allocator, min: i64, max: i64) AdaptiveBin {
        return .{
            .min_value = min,
            .max_value = max,
            .points = std.ArrayList(WeightedDataPoint).init(allocator),
            .total_weight = 0,
        };
    }

    pub fn deinit(self: *AdaptiveBin) void {
        self.points.deinit();
    }

    pub fn update(self: *AdaptiveBin, brightness: i64, weight: f64) !void {
        try self.points.append(.{
            .brightness = brightness,
            .weight = weight,
            .timestamp = std.time.timestamp(),
        });
        self.total_weight += weight;

        // 如果数据点过多，移除权重最小的点
        if (self.points.items.len > 50) {
            var min_weight_idx: usize = 0;
            var min_weight = self.points.items[0].weight;

            for (self.points.items, 0..) |point, i| {
                if (point.weight < min_weight) {
                    min_weight = point.weight;
                    min_weight_idx = i;
                }
            }

            self.total_weight -= self.points.items[min_weight_idx].weight;
            _ = self.points.orderedRemove(min_weight_idx);
        }
    }

    pub fn getWeightedAverage(self: *const AdaptiveBin) ?f64 {
        if (self.points.items.len == 0) return null;

        var sum: f64 = 0;
        for (self.points.items) |point| {
            sum += @as(f64, @floatFromInt(point.brightness)) * point.weight;
        }
        return sum / self.total_weight;
    }
};

/// 增强亮度模型（Adaptive Binning）
pub const BrightnessModel = struct {
    allocator: std.mem.Allocator,
    ambient_bins: []AdaptiveBin,
    time_weight: f64,
    recency_weight: f64,
    config: Config,
    activity_weight: f64,
    last_predictions: [3]f64 = .{ 0, 0, 0 },

    const default_time_weight = 0.3;
    const default_recency_weight = 0.4;
    const default_activity_weight = 0.3;

    pub fn init(
        allocator: std.mem.Allocator,
        config: Config,
        min_ambient: i64,
        max_ambient: i64,
        bin_count: usize,
    ) !BrightnessModel {
        var bins = try allocator.alloc(AdaptiveBin, bin_count);
        const bin_size = @divFloor(max_ambient - min_ambient, @as(i64, @intCast(bin_count)));

        for (0..bin_count) |i| {
            const bin_min = min_ambient + @as(i64, @intCast(i)) * bin_size;
            const bin_max = if (i == bin_count - 1) max_ambient else bin_min + bin_size;
            bins[i] = AdaptiveBin.init(allocator, bin_min, bin_max);
        }

        return .{
            .allocator = allocator,
            .config = config,
            .ambient_bins = bins,
            .time_weight = default_time_weight,
            .recency_weight = default_recency_weight,
            .activity_weight = default_activity_weight,
        };
    }

    pub fn deinit(self: *BrightnessModel) void {
        for (self.ambient_bins) |*bin| {
            bin.deinit();
        }
        self.allocator.free(self.ambient_bins);
    }

    /// 判断是否为异常点（基于亮度和环境光变化）
    fn isOutlier(new: DataPoint, last: ?DataPoint) bool {
        if (last == null) return false;
        const brightness_diff = @abs(new.screen_brightness - last.?.screen_brightness);
        const ambient_diff = @abs(new.ambient_light - last.?.ambient_light);
        return brightness_diff > 80 or ambient_diff > 1200;
    }

    /// 自适应分箱（基于历史数据分位数）
    pub fn adaptBins(self: *BrightnessModel, historical: []DataPoint) !void {
        if (historical.len < 10) return; // 数据太少不自适应
        var ambient_list = try self.allocator.alloc(i64, historical.len);
        defer self.allocator.free(ambient_list);
        for (historical, 0..) |d, i| ambient_list[i] = d.ambient_light;
        std.sort.heap(i64, ambient_list, {}, std.sort.asc(i64));
        const bin_count = self.ambient_bins.len;
        for (self.ambient_bins, 0..) |*bin, i| {
            const start_idx = @divTrunc(i * ambient_list.len, bin_count);
            const end_idx = @divTrunc((i + 1) * ambient_list.len, bin_count) - 1;
            bin.min_value = ambient_list[start_idx];
            bin.max_value = ambient_list[@min(end_idx, ambient_list.len - 1)];
        }
    }

    /// 非线性环境光映射（sigmoid）
    fn nonlinearMap(ambient: i64) f64 {
        return 1.0 / (1.0 + std.math.exp(-@as(f64, @floatFromInt(ambient)) / 300.0));
    }

    fn calculateWeight(
        self: *const BrightnessModel,
        current_time: TimeFeatures,
        point_time: TimeFeatures,
        time_diff_seconds: i64,
        is_active: bool,
    ) f64 {
        // 时间相关性权重
        const time_similarity: f64 = if (current_time.is_day == point_time.is_day)
            1.0
        else
            0.2;
        const time_weight = self.time_weight * time_similarity;

        // 时间衰减权重
        const max_age_seconds = 7 * 24 * 3600; // 一周
        const age_factor = @max(0.0, 1.0 - @as(f64, @floatFromInt(time_diff_seconds)) / @as(f64, @floatFromInt(max_age_seconds)));
        const recency_weight = self.recency_weight * age_factor;

        // 活动状态权重
        const activity_similarity: f64 = if (is_active) 1.0 else 0.5;
        const activity_weight = self.activity_weight * activity_similarity;

        return time_weight + recency_weight + activity_weight;
    }

    pub fn train(
        self: *BrightnessModel,
        data_point: DataPoint,
        current_timestamp: i64,
        is_active: bool,
    ) !void {
        if (!data_point.is_manual_adjustment) return;
        // 异常点过滤：只在非异常时训练
        var last_point: ?DataPoint = null;
        for (self.ambient_bins) |bin| {
            if (bin.points.items.len > 0) {
                last_point = DataPoint{
                    .timestamp = bin.points.items[bin.points.items.len - 1].timestamp,
                    .ambient_light = bin.points.items[bin.points.items.len - 1].brightness, // 近似
                    .screen_brightness = bin.points.items[bin.points.items.len - 1].brightness,
                    .is_manual_adjustment = true,
                };
            }
        }
        if (isOutlier(data_point, last_point)) return;

        const current_time = TimeFeatures.fromTimestamp(current_timestamp);
        const point_time = TimeFeatures.fromTimestamp(data_point.timestamp);
        const time_diff = current_timestamp - data_point.timestamp;

        const weight = self.calculateWeight(current_time, point_time, time_diff, is_active);

        // 找到对应的光照区间
        for (self.ambient_bins) |*bin| {
            if (data_point.ambient_light >= bin.min_value and
                data_point.ambient_light < bin.max_value)
            {
                try bin.update(data_point.screen_brightness, weight);
                break;
            }
        }
    }

    pub fn predict(
        self: *const BrightnessModel,
        ambient_light: i64,
        is_active: bool,
    ) ?i64 {
        // 非线性预处理（如需使用 mapped_ambient，可直接替换 ambient_light）
        const mapped_ambient = nonlinearMap(ambient_light);
        // 找到主要区间
        var main_bin: ?*const AdaptiveBin = null;
        var main_bin_index: usize = 0;
        for (self.ambient_bins, 0..) |*bin, i| {
            if (mapped_ambient >= @as(f64, @floatFromInt(bin.min_value)) and mapped_ambient < @as(f64, @floatFromInt(bin.max_value))) {
                main_bin = bin;
                main_bin_index = i;
                break;
            }
        }

        if (main_bin == null) {
            return null;
        }

        // 获取主区间的预测值
        const main_prediction = main_bin.?.getWeightedAverage() orelse {
            std.debug.print("主区间无数据，使用对数映射\n", .{});
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
            std.debug.print("使用对数映射，映射值：{d}\n", .{mapped_brightness});
            return @as(i64, mapped_brightness);
        };

        // 应用时间和活动状态的调整因子
        const time_features = TimeFeatures.fromTimestamp(std.time.timestamp());
        const time_factor: f64 = if (time_features.is_day) 1.0 else 0.8;
        const activity_factor: f64 = if (is_active) 1.0 else 0.9;

        var adjusted_prediction = main_prediction * time_factor * activity_factor;

        // 区间边界插值
        const bin_size = self.ambient_bins[1].min_value - self.ambient_bins[0].min_value;
        const position_in_bin = @as(f64, @floatFromInt(ambient_light - main_bin.?.min_value)) / @as(f64, @floatFromInt(bin_size));

        if (position_in_bin < 0.2 or position_in_bin > 0.8) {
            if (main_bin_index > 0 and main_bin_index < self.ambient_bins.len - 1) {
                const prev_prediction = self.ambient_bins[main_bin_index - 1].getWeightedAverage();
                const next_prediction = self.ambient_bins[main_bin_index + 1].getWeightedAverage();

                if (prev_prediction != null and next_prediction != null) {
                    const weight = if (position_in_bin < 0.2) 0.2 - position_in_bin else position_in_bin - 0.8;

                    const neighbor_prediction = if (position_in_bin < 0.2)
                        prev_prediction.? * time_factor * activity_factor
                    else
                        next_prediction.? * time_factor * activity_factor;

                    adjusted_prediction = adjusted_prediction * (1 - weight) + neighbor_prediction * weight;
                }
            }
        }

        // 滑动平均平滑
        var self_mut = @constCast(self);
        self_mut.last_predictions[0] = self_mut.last_predictions[1];
        self_mut.last_predictions[1] = self_mut.last_predictions[2];
        self_mut.last_predictions[2] = adjusted_prediction;
        return @as(i64, @intFromFloat((self_mut.last_predictions[0] + self_mut.last_predictions[1] + self_mut.last_predictions[2]) / 3.0));
    }

    /// 清理过期数据
    pub fn cleanup(self: *BrightnessModel, current_timestamp: i64) void {
        const max_age = 7 * 24 * 3600; // 一周
        for (self.ambient_bins) |*bin| {
            var i: usize = 0;
            while (i < bin.points.items.len) {
                const point = bin.points.items[i];
                const age = current_timestamp - point.timestamp;
                if (age > max_age) {
                    bin.total_weight -= point.weight;
                    _ = bin.points.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }
};
