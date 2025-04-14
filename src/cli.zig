const std = @import("std");
const linux = std.os.linux;
const protocol = @import("protocol");
const Command = protocol.Command;
const Response = protocol.Response;

const IpcClient = struct {
    sock: i32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !IpcClient {
        const raw_socket = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (raw_socket < 0) {
            return error.SocketCreationFailed;
        }
        const sock = @as(i32, @intCast(raw_socket));
        errdefer _ = linux.close(sock);

        var addr = linux.sockaddr.un{
            .family = linux.AF.UNIX,
            .path = undefined,
        };
        const path = "/tmp/beelight.sock";
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;

        const rc = linux.connect(sock, @as(*const linux.sockaddr, @ptrCast(&addr)), @sizeOf(linux.sockaddr.un));
        if (rc != 0) {
            return error.ConnectionFailed;
        }

        return IpcClient{
            .sock = sock,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IpcClient) void {
        _ = linux.close(self.sock);
    }

    pub fn sendCommand(self: *IpcClient, command: Command) !Response {
        var msg = std.ArrayList(u8).init(self.allocator);
        defer msg.deinit();

        try std.json.stringify(command, .{}, msg.writer());
        const rc = linux.sendto(self.sock, msg.items.ptr, msg.items.len, 0, null, 0);
        if (rc < 0) return error.SendFailed;

        var buf: [4096]u8 = undefined;
        const len = linux.recvfrom(self.sock, &buf, buf.len, 0, null, null);
        if (len < 0) return error.RecvFailed;
        if (len == 0) return error.ConnectionClosed;

        var parsed = try std.json.parseFromSlice(Response, self.allocator, buf[0..@intCast(len)], .{});
        defer parsed.deinit();
        return parsed.value;
    }
};

pub fn parseCommand(args: []const []const u8) !?Command {
    if (args.len < 2) return null;
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return Command.help;
    } else if (std.mem.eql(u8, cmd, "set")) {
        if (args.len < 3) return error.MissingValue;
        const value = try std.fmt.parseFloat(f64, args[2]);
        return Command{ .set_brightness = value };
    } else if (std.mem.eql(u8, cmd, "get")) {
        return Command.get_brightness;
    } else if (std.mem.eql(u8, cmd, "auto")) {
        return Command.toggle_auto;
    } else if (std.mem.eql(u8, cmd, "stats")) {
        return Command.show_stats;
    }
    return error.UnknownCommand;
}

pub fn printHelp() void {
    const help_text =
        \\用法: beelight <命令> [参数]\n
        \\命令:\n
        \\  set <亮度>   设置屏幕亮度 (0-100)\n
        \\  get          获取当前亮度\n
        \\  auto         切换自动调节模式\n
        \\  stats        显示系统状态\n
        \\  help         显示此帮助信息\n
    ;
    std.debug.print("{s}", .{help_text});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const command = parseCommand(args) catch |err| {
        switch (err) {
            error.MissingValue => {
                std.debug.print("错误: 缺少必要的参数\n", .{});
                printHelp();
                return;
            },
            error.UnknownCommand => {
                std.debug.print("错误: 未知命令\n", .{});
                printHelp();
                return;
            },
            else => {
                std.debug.print("错误: {}\n", .{err});
                return;
            },
        }
    };

    if (command == null) {
        printHelp();
        return;
    }

    var client = try IpcClient.init(allocator);
    defer client.deinit();

    const response = try client.sendCommand(command.?);
    if (!response.success) {
        std.debug.print("错误: {s}\n", .{response.message});
        return;
    }

    if (response.data) |data| {
        switch (data) {
            .brightness => |b| std.debug.print("当前亮度: {d}%\n", .{b}),
            .auto_mode => |enabled| std.debug.print("自动模式: {s}\n", .{if (enabled) "开启" else "关闭"}),
            .stats => |s| std.debug.print(
                \\统计信息:
                \\当前环境光: {d:.2}
                \\当前亮度: {d}%
                \\自动模式: {s}
                \\
            , .{
                s.ambient,
                s.brightness,
                if (s.auto_mode) "开启" else "关闭",
            }),
        }
    } else {
        std.debug.print("{s}\n", .{response.message});
    }
    return;
}
