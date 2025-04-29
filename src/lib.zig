const std = @import("std");

pub const core = struct {
    pub const BrightnessController = @import("core/controller.zig").BrightnessController;
    pub const Config = @import("core/config.zig").BrightnessConfig;
    pub const Screen = @import("core/screen.zig").Screen;
    pub const Sensor = @import("core/sensor.zig").Sensor;
    pub const LogConfig = @import("core/log.zig").LogConfig;
    pub const Logger = @import("core/log.zig").Logger;
};

pub const ipc = struct {
    pub const IpcServer = @import("ipc/server.zig").IpcServer;
};
