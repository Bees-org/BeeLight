const std = @import("std");
const Thread = std.Thread;

const SensorError = error{
    FileOpenError,
    FileReadError,
    ParseError,
    AllocationError,
};

const circleData = struct {
    data: [60]i64,
    index: i32,
};

/// 环境光传感器管理器
/// 用于读取环境光强度并处理相关错误。
pub const Sensor = struct {
    allocator: std.mem.Allocator,
    buffer: []u8 = undefined,
    history: circleData, // 历史数据
    fd: std.fs.File,

    /// 初始化传感器
    pub fn init() !Sensor {
        const allocator = std.heap.page_allocator;
        const buffer = allocator.alloc(u8, 16) catch |err| {
            std.log.err("分配缓冲区失败: {}", .{err});
            return SensorError.AllocationError;
        };

        const sensor_path = "/sys/bus/iio/devices/iio:device0/in_illuminance_raw";
        const file = std.fs.openFileAbsolute(sensor_path, .{ .mode = std.fs.File.OpenMode.read_only }) catch |err| {
            allocator.free(buffer);
            std.log.err("打开传感器文件失败: {}", .{err});
            return SensorError.FileOpenError;
        };

        return Sensor{
            .buffer = buffer,
            .allocator = allocator,
            .history = circleData{
                .data = [_]i64{0} ** 60,
                .index = 0,
            },
            .fd = file,
        };
    }

    /// 释放传感器资源
    pub fn deinit(self: *Sensor) void {
        self.allocator.free(self.buffer);
        self.fd.close();
    }

    /// 读取环境光强度（lux）
    pub fn readAmbientLight(self: *Sensor) !i64 {
        return self.read();
    }

    /// 读取原始传感器值
    pub fn read(self: *Sensor) !i64 {
        const offset: u64 = 0;
        const size = self.fd.pread(self.buffer[0..], offset) catch |err| {
            std.log.err("读取传感器值失败: {}", .{err});
            return SensorError.FileReadError;
        };

        return std.fmt.parseInt(i64, self.buffer[0 .. size - 1], 10) catch |err| {
            std.log.err("解析传感器值失败: {}", .{err});
            return SensorError.ParseError;
        };
    }
};
