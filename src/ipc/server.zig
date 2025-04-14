const std = @import("std");
const BrightnessController = @import("../core/controller.zig").BrightnessController;
const Command = @import("../protocol/protocol.zig").Command;
const Response = @import("../protocol/protocol.zig").Response;
const os = std.os;
const linux = os.linux;
const net = std.net;
const mem = std.mem;

const ucred = extern struct {
    pid: i32,
    uid: u32,
    gid: u32,
};

pub const IpcServer = struct {
    socket: i32,
    controller: *BrightnessController,
    allocator: std.mem.Allocator,
    running: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, controller: *BrightnessController) !Self {
        const raw_socket = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (raw_socket < 0) {
            controller.logger.err("创建 socket 失败: {}", .{raw_socket}) catch {};
            return error.SocketCreationFailed;
        }
        const socket = @as(i32, @intCast(raw_socket));
        errdefer _ = linux.close(socket);

        // 删除可能存在的旧socket文件
        _ = std.fs.deleteFileAbsolute("/tmp/beelight.sock") catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                controller.logger.err("删除旧 socket 文件失败: {}", .{err}) catch {};
                return err;
            },
        };

        var addr: linux.sockaddr.un = undefined;
        addr.family = linux.AF.UNIX;
        const path = "/tmp/beelight.sock";
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;

        const rc = linux.bind(socket, @as(*const linux.sockaddr, @ptrCast(&addr)), @sizeOf(linux.sockaddr.un));
        if (rc != 0) {
            controller.logger.err("绑定 socket 失败: {}", .{rc}) catch {};
            return error.BindFailed;
        }

        const rc2 = linux.listen(socket, 128);
        if (rc2 != 0) {
            controller.logger.err("监听 socket 失败: {}", .{rc2}) catch {};
            return error.ListenFailed;
        }

        // 设置socket文件权限
        const rc3 = linux.chmod("/tmp/beelight.sock", 0o666);
        if (rc3 < 0) {
            controller.logger.err("设置 socket 权限失败: {}", .{rc3}) catch {};
            return error.ChmodFailed;
        }

        controller.logger.info("IPC 服务器初始化成功", .{}) catch {};

        return Self{
            .socket = socket,
            .controller = controller,
            .allocator = allocator,
            .running = true,
        };
    }

    pub fn deinit(self: *Self) void {
        self.running = false;
        _ = linux.close(self.socket);
        _ = std.fs.deleteFileAbsolute("/tmp/beelight.sock") catch {};
        self.controller.logger.info("IPC 服务器已关闭", .{}) catch {};
    }

    pub fn run(self: *Self) !void {
        self.controller.logger.info("IPC 服务器开始运行", .{}) catch {};
        while (self.running) {
            const raw_client_socket = linux.accept(self.socket, null, null);
            if (raw_client_socket < 0) {
                self.controller.logger.err("接受连接失败: {}", .{raw_client_socket}) catch {};
                continue;
            }
            const client_socket = @as(i32, @intCast(raw_client_socket));
            errdefer _ = linux.close(client_socket);

            self.controller.logger.debug("接受新的客户端连接", .{}) catch {};
            try self.handleClient(client_socket);
        }
    }

    fn handleClient(self: *Self, client_socket: i32) !void {
        // 获取客户端进程信息
        var cred: ucred = undefined;
        var len: u32 = @sizeOf(ucred);
        const rc = linux.getsockopt(
            client_socket,
            linux.SOL.SOCKET,
            linux.SO.PEERCRED,
            @as([*]u8, @ptrCast(&cred))[0..@sizeOf(ucred)],
            &len,
        );
        if (rc == 0) {
            self.controller.logger.info("客户端连接 - PID: {}, UID: {}, GID: {}", .{ cred.pid, cred.uid, cred.gid }) catch {};
        }

        var buf: [4096]u8 = undefined;
        const recv_len = linux.recvfrom(client_socket, &buf, buf.len, 0, null, null);
        if (recv_len < 0) {
            self.controller.logger.err("接收数据失败: {}", .{recv_len}) catch {};
            return error.RecvFailed;
        }
        if (recv_len == 0) return;

        const parsed = std.json.parseFromSlice(Command, self.allocator, buf[0..@intCast(recv_len)], .{}) catch {
            self.controller.logger.err("解析命令失败，客户端 PID: {}", .{if (rc == 0) cred.pid else 0}) catch {};
            try self.sendError(client_socket, "无效的命令格式");
            return;
        };
        defer parsed.deinit();

        self.controller.logger.info("收到命令 - PID: {}, 命令: {}", .{ if (rc == 0) cred.pid else 0, parsed.value }) catch {};
        try self.handleCommand(client_socket, parsed.value);
    }

    fn handleCommand(self: *Self, client_socket: i32, parsed_command: Command) !void {
        switch (parsed_command) {
            .set_brightness => |value| {
                self.controller.logger.info("收到设置亮度命令: {d}%", .{value}) catch {};
                // 将百分比值（0-100）转换为实际亮度值
                const min_brightness = self.controller.config.min_brightness;
                const max_brightness = self.controller.config.max_brightness;
                const brightness_range = max_brightness - min_brightness;
                const raw_value = min_brightness + @as(i64, @intFromFloat(@min(100.0, @max(0.0, value)) / 100.0 * @as(f64, @floatFromInt(brightness_range))));

                try self.controller.handleUserAdjustment(raw_value);
                self.controller.logger.info("亮度已设置: {d}% -> {d} (原始值)", .{ value, raw_value }) catch {};
                try self.sendResponse(client_socket, .{
                    .success = true,
                    .message = "亮度设置成功",
                });
            },
            .get_brightness => {
                self.controller.logger.info("收到获取亮度命令", .{}) catch {};
                const raw_brightness = try self.controller.screen.getRaw();
                const min_brightness = self.controller.config.min_brightness;
                const max_brightness = self.controller.config.max_brightness;
                const brightness_range = @as(f64, @floatFromInt(max_brightness - min_brightness));
                const percentage = @as(i64, @intFromFloat((@as(f64, @floatFromInt(raw_brightness - min_brightness)) / brightness_range) * 100.0));

                self.controller.logger.info("当前亮度: {d} (原始值) -> {d}%", .{ raw_brightness, percentage }) catch {};
                try self.sendResponse(client_socket, .{
                    .success = true,
                    .message = "获取亮度成功",
                    .data = .{ .brightness = percentage },
                });
            },
            .toggle_auto => {
                const old_mode = self.controller.auto_mode;
                self.controller.logger.info("收到切换自动模式命令，当前状态: {}", .{old_mode}) catch {};
                try self.controller.setAutoMode(!old_mode);
                self.controller.logger.info("自动模式已切换: {} -> {}", .{ old_mode, self.controller.auto_mode }) catch {};
                try self.sendResponse(client_socket, .{
                    .success = true,
                    .message = if (self.controller.auto_mode) "自动模式已开启" else "自动模式已关闭",
                    .data = .{ .auto_mode = self.controller.auto_mode },
                });
            },
            .show_stats => {
                self.controller.logger.info("收到获取统计信息命令", .{}) catch {};
                const ambient = try self.controller.sensor.readAmbientLight();
                const raw_brightness = try self.controller.screen.getRaw();
                const min_brightness = self.controller.config.min_brightness;
                const max_brightness = self.controller.config.max_brightness;
                const brightness_range = @as(f64, @floatFromInt(max_brightness - min_brightness));
                const percentage = @as(i64, @intFromFloat((@as(f64, @floatFromInt(raw_brightness - min_brightness)) / brightness_range) * 100.0));

                self.controller.logger.info("系统状态 - 环境光: {d}, 亮度: {d} ({d}%), 自动模式: {}", .{ ambient, raw_brightness, percentage, self.controller.auto_mode }) catch {};
                try self.sendResponse(client_socket, .{
                    .success = true,
                    .message = "获取统计信息成功",
                    .data = .{ .stats = .{
                        .ambient = @as(f32, @floatFromInt(ambient)),
                        .brightness = percentage,
                        .auto_mode = self.controller.auto_mode,
                    } },
                });
            },
            .help => {
                self.controller.logger.info("收到帮助命令", .{}) catch {};
                try self.sendResponse(client_socket, .{
                    .success = true,
                    .message = "帮助命令已执行",
                    .data = null,
                });
            },
        }
    }

    fn sendResponse(self: *Self, client_socket: i32, response: Response) !void {
        var msg = std.ArrayList(u8).init(self.allocator);
        defer msg.deinit();

        try std.json.stringify(response, .{}, msg.writer());
        const rc = linux.sendto(client_socket, msg.items.ptr, msg.items.len, 0, null, 0);
        if (rc < 0) {
            self.controller.logger.err("发送响应失败: {}", .{rc}) catch {};
            return error.SendFailed;
        }
        self.controller.logger.debug("已发送响应: {s}", .{msg.items}) catch {};
    }

    fn sendError(self: *Self, client_socket: i32, message: []const u8) !void {
        self.controller.logger.err("发送错误响应: {s}", .{message}) catch {};
        try self.sendResponse(client_socket, .{
            .success = false,
            .message = message,
            .data = null,
        });
    }
};
