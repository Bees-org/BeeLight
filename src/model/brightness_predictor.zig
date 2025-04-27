const std = @import("std");

pub const BrightnessModel = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    weights: std.ArrayList(f64),
    bias: f64,
    learning_rate: f64,

    pub fn init(allocator: std.mem.Allocator) !Self {
        var weights = std.ArrayList(f64).init(allocator);
        try weights.append(1.0); // 初始权重
        return Self{
            .allocator = allocator,
            .weights = weights,
            .bias = 0.0,
            .learning_rate = 0.01,
        };
    }

    pub fn deinit(self: *Self) void {
        self.weights.deinit();
    }

    pub fn predict(self: *const Self, ambient_light: f64) f64 {
        var result = self.bias;
        for (self.weights.items) |weight| {
            result += weight * ambient_light;
        }
        return @max(0.0, @min(100.0, result));
    }

    // Optimize the training function to handle larger datasets efficiently
    pub fn train(self: *Self, ambient_light: f64, target_brightness: f64) void {
        const prediction = self.predict(ambient_light);
        const err = target_brightness - prediction;

        // Update bias with a learning rate
        self.bias += self.learning_rate * err;

        // Update weights with gradient descent
        for (self.weights.items) |*weight| {
            weight.* += self.learning_rate * err * ambient_light;
        }

        // Add a mechanism to limit the size of weights to prevent overfitting
        if (self.weights.items.len > 100) {
            self.weights.removeAt(0);
        }
    }

    pub fn save(self: *const Self, file_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        var writer = file.writer();
        try writer.print("{d}\n", .{self.bias});
        for (self.weights.items) |weight| {
            try writer.print("{d}\n", .{weight});
        }
    }

    pub fn load(self: *Self, file_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        var reader = buf_reader.reader();
        var buf: [100]u8 = undefined;

        // 读取偏置
        if (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            self.bias = try std.fmt.parseFloat(f64, line);
        }

        // 读取权重
        self.weights.clearRetainingCapacity();
        while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            const weight = try std.fmt.parseFloat(f64, line);
            try self.weights.append(weight);
        }
    }
};
