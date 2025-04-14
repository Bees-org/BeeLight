const std = @import("std");
const Logger = @import("log.zig").Logger;

pub const Event = struct {
    brightness: i64,
};

pub const EventQueue = struct {
    mutex: std.Thread.Mutex,
    events: std.ArrayList(Event),
    allocator: std.mem.Allocator,
    logger: *Logger,

    pub fn init(allocator: std.mem.Allocator, logger: *Logger) EventQueue {
        logger.debug("初始化事件队列", .{}) catch {};
        return EventQueue{
            .mutex = std.Thread.Mutex{},
            .events = std.ArrayList(Event).init(allocator),
            .allocator = allocator,
            .logger = logger,
        };
    }

    pub fn deinit(self: *EventQueue) void {
        self.logger.debug("清理事件队列，剩余事件数: {}", .{self.events.items.len}) catch {};
        self.events.deinit();
    }

    pub fn push(self: *EventQueue, event: Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.events.append(event);
        self.logger.debug("添加新事件到队列 [亮度: {}], 当前队列长度: {}", .{ event.brightness, self.events.items.len }) catch {};
    }

    pub fn pop(self: *EventQueue) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.events.items.len == 0) {
            self.logger.debug("事件队列为空", .{}) catch {};
            return null;
        }
        const event = self.events.orderedRemove(0);
        self.logger.debug("从队列中移除事件 [亮度: {}], 剩余事件数: {}", .{ event.brightness, self.events.items.len }) catch {};
        return event;
    }

    pub fn getLength(self: *EventQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.events.items.len;
    }
};
