const std = @import("std");
const Event = @import("event.zig").Event;
const EventType = @import("event.zig").EventType;

pub const EventCallback = *const fn (event: Event) void;

pub const EventManager = struct {
    allocator: std.mem.Allocator,
    listeners: std.AutoHashMap(EventType, std.ArrayList(EventCallback)),

    pub fn init(allocator: std.mem.Allocator) !EventManager {
        return EventManager{
            .allocator = allocator,
            .listeners = std.AutoHashMap(EventType, std.ArrayList(EventCallback)).init(allocator),
        };
    }

    pub fn deinit(self: *EventManager) void {
        var it = self.listeners.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.listeners.deinit();
    }

    pub fn addEventListener(self: *EventManager, event_type: EventType, callback: EventCallback) !void {
        var listeners = self.listeners.get(event_type) orelse blk: {
            const list = std.ArrayList(EventCallback).init(self.allocator);
            try self.listeners.put(event_type, list);
            break :blk list;
        };
        try listeners.append(callback);
    }

    pub fn removeEventListener(self: *EventManager, event_type: EventType, callback: EventCallback) void {
        if (self.listeners.getPtr(event_type)) |listeners| {
            var i: usize = 0;
            while (i < listeners.items.len) {
                if (listeners.items[i] == callback) {
                    _ = listeners.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    pub fn emit(self: *EventManager, event: Event) void {
        if (self.listeners.get(event.type)) |listeners| {
            for (listeners.items) |callback| {
                callback(event);
            }
        }
    }
};
