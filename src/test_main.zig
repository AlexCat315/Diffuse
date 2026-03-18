// Test entry point with console logging configuration
const std = @import("std");
const editor_console = @import("editor/ui/windows/console.zig");

// 配置测试日志输出到编辑器控制台
pub const std_options = std.Options{
    .logFn = editor_console.logFn,
    .log_level = .debug,
};

// 重新导出所有测试
test {
    std.testing.refAllDecls(@import("root.zig"));
}
