const std = @import("std");

/// Global Io handle, initialized from process Init in main.
/// All filesystem operations in the engine should use this.
pub var global_io: std.Io = undefined;
pub var global_args: std.process.Args = undefined;
pub var initialized: bool = false;

pub fn init(io_handle: std.Io, args: std.process.Args) void {
    global_io = io_handle;
    global_args = args;
    initialized = true;
}

/// Convenience: get cwd Dir (same as std.Io.Dir.cwd()).
pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}
