const std = @import("std");
const posix = std.posix;
const os = std.os;
const fs = std.fs;
const time = std.time;
const mem = std.mem;
const fmt = std.fmt;

/// 日志级别
pub const LogLevel = enum {
    Debug,
    Info,
    Warning,
    Error,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .Debug => "DEBUG",
            .Info => "INFO",
            .Warning => "WARN",
            .Error => "ERROR",
        };
    }

    pub fn fromString(str: []const u8) ?LogLevel {
        if (mem.eql(u8, str, "DEBUG")) return .Debug;
        if (mem.eql(u8, str, "INFO")) return .Info;
        if (mem.eql(u8, str, "WARN")) return .Warning;
        if (mem.eql(u8, str, "ERROR")) return .Error;
        return null;
    }
};

/// 日志配置
pub const LogOption = struct {
    /// 日志文件路径，如果为 null，则使用默认路径
    log_file_path: ?[]const u8 = null,
    /// 最小日志级别
    min_level: LogLevel = .Info,
    /// 是否输出到控制台
    enable_console: bool = true,
    /// 是否输出到文件
    enable_file: bool = true,
    /// 单个日志文件的最大大小（字节），默认 10MB
    max_file_size: usize = 10 * 1024 * 1024,
    /// 保留的日志文件数量，默认 5 个
    max_files: usize = 5,

    /// 获取默认的日志文件路径
    pub fn getDefaultLogPath(allocator: mem.Allocator) ![]const u8 {
        // 优先使用 XDG_STATE_HOME
        if (posix.getenv("XDG_STATE_HOME")) |xdg_state| {
            return try fs.path.join(allocator, &[_][]const u8{ xdg_state, "beelight", "beelight.log" });
        }
        // 其次使用 HOME/.local/state
        if (posix.getenv("HOME")) |home| {
            return try fs.path.join(allocator, &[_][]const u8{ home, ".local", "state", "beelight", "beelight.log" });
        }
        return error.NoHomeDirectory;
    }
};

/// 日志管理器
/// 用于输出和轮转日志，支持多级别、文件和控制台。
pub const Logger = struct {
    const Self = @This();

    allocator: mem.Allocator,
    config: LogOption,
    file: ?fs.File,
    mutex: std.Thread.Mutex,
    current_file_size: usize,

    /// 初始化 Logger
    pub fn init(allocator: mem.Allocator, config: LogOption) !Self {
        var file: ?fs.File = null;
        if (config.enable_file) {
            const log_path = if (config.log_file_path) |path|
                try allocator.dupe(u8, path)
            else
                try LogOption.getDefaultLogPath(allocator);
            defer allocator.free(log_path);

            // 确保日志目录存在
            const dir_path = fs.path.dirname(log_path) orelse return error.InvalidPath;
            fs.makeDirAbsolute(dir_path) catch |mkdir_err| switch (mkdir_err) {
                error.PathAlreadyExists => {},
                error.AccessDenied => {
                    // 尝试创建用户目录
                    if (posix.getenv("HOME")) |home| {
                        const local_state = try fs.path.join(allocator, &[_][]const u8{ home, ".local", "state" });
                        defer allocator.free(local_state);
                        try fs.makeDirAbsolute(local_state);
                        const beelight_dir = try fs.path.join(allocator, &[_][]const u8{ local_state, "beelight" });
                        defer allocator.free(beelight_dir);
                        try fs.makeDirAbsolute(beelight_dir);
                    } else {
                        return mkdir_err;
                    }
                },
                else => return mkdir_err,
            };

            file = try fs.createFileAbsolute(log_path, .{
                .read = true,
                .truncate = false,
            });
            try file.?.seekFromEnd(0);
        }

        return Self{
            .allocator = allocator,
            .config = config,
            .file = file,
            .mutex = std.Thread.Mutex{},
            .current_file_size = 0,
        };
    }

    /// 释放 Logger 资源
    pub fn deinit(self: *Self) void {
        if (self.file) |f| {
            f.close();
        }
    }

    /// 写日志（支持级别、格式化、线程安全、文件轮转）
    pub fn log(self: *Self, level: LogLevel, comptime format: []const u8, args: anytype) !void {
        if (@intFromEnum(level) < @intFromEnum(self.config.min_level)) {
            return;
        }

        const timestamp = time.timestamp();
        var time_buf: [32]u8 = undefined;
        const time_str = try formatTimestamp(timestamp, &time_buf);

        // 格式化日志消息
        const message = try fmt.allocPrint(
            self.allocator,
            "{s} [{s}] " ++ format ++ "\n",
            .{
                time_str,
                level.toString(),
            } ++ args,
        );
        defer self.allocator.free(message);

        self.mutex.lock();
        defer self.mutex.unlock();

        // 输出到控制台
        if (self.config.enable_console) {
            const writer = if (@intFromEnum(level) >= @intFromEnum(LogLevel.Warning))
                std.io.getStdErr().writer()
            else
                std.io.getStdOut().writer();
            try writer.writeAll(message);
        }

        // 写入文件
        if (self.config.enable_file and self.file != null) {
            // 检查是否需要轮转日志文件
            if (self.current_file_size + message.len > self.config.max_file_size) {
                try self.rotateLogFile();
            }

            try self.file.?.writeAll(message);
            try self.file.?.sync();
            self.current_file_size += message.len;
        }
    }

    /// 调试日志
    pub fn debug(self: *Self, comptime format: []const u8, args: anytype) !void {
        try self.log(.Debug, format, args);
    }

    /// 信息日志
    pub fn info(self: *Self, comptime format: []const u8, args: anytype) !void {
        try self.log(.Info, format, args);
    }

    /// 警告日志
    pub fn warn(self: *Self, comptime format: []const u8, args: anytype) !void {
        try self.log(.Warning, format, args);
    }

    /// 错误日志
    pub fn err(self: *Self, comptime format: []const u8, args: anytype) !void {
        try self.log(.Error, format, args);
    }

    fn formatTimestamp(timestamp: i64, buf: []u8) ![]u8 {
        const seconds = @mod(timestamp, 86400);
        const hours = @divFloor(seconds, 3600);
        const minutes = @divFloor(@mod(seconds, 3600), 60);
        const secs = @mod(seconds, 60);
        const millis = @divFloor(@mod(timestamp, 1000), 1);

        return try fmt.bufPrint(
            buf,
            "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
            .{ hours, minutes, secs, millis },
        );
    }

    fn rotateLogFile(self: *Self) !void {
        if (self.file == null) return;

        const log_path = if (self.config.log_file_path) |path|
            try self.allocator.dupe(u8, path)
        else
            try LogOption.getDefaultLogPath(self.allocator);
        defer self.allocator.free(log_path);

        // 关闭当前日志文件
        self.file.?.close();

        // 重命名现有的日志文件
        var i: usize = self.config.max_files - 1;
        while (i > 0) : (i -= 1) {
            const old_path = try fmt.allocPrint(self.allocator, "{s}.{d}", .{ log_path, i });
            defer self.allocator.free(old_path);
            const new_path = try fmt.allocPrint(self.allocator, "{s}.{d}", .{ log_path, i + 1 });
            defer self.allocator.free(new_path);

            fs.renameAbsolute(old_path, new_path) catch |rename_err| switch (rename_err) {
                error.FileNotFound => continue,
                else => return rename_err,
            };
        }

        // 重命名当前日志文件
        const backup_path = try fmt.allocPrint(self.allocator, "{s}.1", .{log_path});
        defer self.allocator.free(backup_path);
        try fs.renameAbsolute(log_path, backup_path);

        // 创建新的日志文件
        self.file = try fs.createFileAbsolute(log_path, .{
            .read = true,
            .truncate = false,
        });
        self.current_file_size = 0;
    }
};

pub fn getLogger() Logger {
    return Logger.init(std.heap.page_allocator, LogOption{});
}
