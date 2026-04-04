const std = @import("std");
const editor_console = @import("editor/core/logging.zig");

pub const std_options = std.Options{
    .logFn = editor_console.logFn,
    .log_level = .debug,
};

pub fn main() !void {
    try editor_console.initLogFile();
    defer editor_console.deinitLogFile();

    std.log.info("Test: This should appear in ImGui console", .{});
    std.log.debug("Test: Debug message", .{});
    std.log.warn("Test: Warning message", .{});
    std.log.err("Test: Error message", .{});

    std.debug.print("Test completed. Check logs/ directory for output.\n", .{});
}
