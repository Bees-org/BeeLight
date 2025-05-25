const std = @import("std");
const posix = std.posix;

pub const DataPoint = struct {
    timestamp: i64,
    ambient_light: i64,
    screen_brightness: i64,
    is_manual_adjustment: bool,
};

pub const DataLogger = struct {
    const Self = @This();

    file: std.fs.File,
    writer: std.fs.File.Writer,
    allocator: std.mem.Allocator,
    buffer: []u8,

    pub fn init(allocator: std.mem.Allocator) !Self {
        // 获取用户的配置目录
        const config_dir = blk: {
            if (posix.getenv("XDG_CONFIG_HOME")) |xdg_config| {
                break :blk try std.fs.path.join(allocator, &[_][]const u8{ xdg_config, "beelight" });
            } else if (posix.getenv("HOME")) |home| {
                const config_path = try std.fs.path.join(allocator, &[_][]const u8{ home, ".config" });
                defer allocator.free(config_path);
                break :blk try std.fs.path.join(allocator, &[_][]const u8{ config_path, "beelight" });
            } else {
                return error.NoHomeDirectory;
            }
        };
        defer allocator.free(config_dir);

        // 创建配置目录（如果不存在）
        std.fs.makeDirAbsolute(config_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                return err;
            }
        };

        // 构建日志文件路径
        const log_path = try std.fs.path.join(allocator, &[_][]const u8{ config_dir, "brightness_data.csv" });
        defer allocator.free(log_path);

        // 创建或打开日志文件
        const file = try std.fs.createFileAbsolute(log_path, .{
            .read = true,
            .truncate = false,
        });

        // 如果是新文件，写入CSV头
        const file_size = (try file.stat()).size;
        if (file_size == 0) {
            try file.writeAll("timestamp,ambient_light,screen_brightness,is_manual\n");
        } else {
            // 将文件指针移到末尾以追加数据
            try file.seekFromEnd(0);
        }

        return Self{
            .file = file,
            .writer = file.writer(),
            .allocator = allocator,
            .buffer = try allocator.alloc(u8, 1024),
        };
    }

    pub fn deinit(self: *Self) void {
        self.file.close();
        self.allocator.free(self.buffer);
    }

    pub fn logDataPoint(self: *Self, data: DataPoint) !void {
        // 格式化数据点为CSV行
        const line = try std.fmt.bufPrint(
            self.buffer,
            "{},{},{},{}\n",
            .{
                data.timestamp,
                data.ambient_light,
                data.screen_brightness,
                if (data.is_manual_adjustment) @as(u8, 1) else @as(u8, 0),
            },
        );

        // 写入文件
        try self.writer.writeAll(line);
        try self.file.sync(); // 确保数据被写入磁盘
    }

    pub fn readHistoricalData(self: *Self) ![]DataPoint {
        var data = std.ArrayList(DataPoint).init(self.allocator);
        errdefer data.deinit();

        try self.file.seekTo(0);
        var buf_reader = std.io.bufferedReader(self.file.reader());
        var reader = buf_reader.reader();

        // 跳过CSV头
        _ = try reader.readUntilDelimiterOrEof(self.buffer, '\n');

        // 读取所有数据行
        while (try reader.readUntilDelimiterOrEof(self.buffer, '\n')) |line| {
            var iter = std.mem.splitScalar(u8, line, ',');

            const timestamp = try std.fmt.parseInt(i64, iter.next() orelse continue, 10);
            const ambient = try std.fmt.parseInt(i64, iter.next() orelse continue, 10);
            const brightness = try std.fmt.parseInt(i64, iter.next() orelse continue, 10);
            const manual_value = try std.fmt.parseInt(u8, iter.next() orelse continue, 10);

            try data.append(DataPoint{
                .timestamp = timestamp,
                .ambient_light = ambient,
                .screen_brightness = brightness,
                .is_manual_adjustment = manual_value != 0,
            });
        }

        return data.toOwnedSlice();
    }
};