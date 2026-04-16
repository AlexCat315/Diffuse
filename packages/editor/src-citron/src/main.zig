const std = @import("std");
const citron = @import("citron");
const state_mod = @import("state.zig");
const handlers = @import("handlers.zig");

var app_state: state_mod.AppState = undefined;

fn setup(router: *citron.ipc.Router) !void {
    handlers.init(&app_state);
    try handlers.register(router);
    try app_state.startInitialProject();
}

pub fn main(init: std.process.Init) !void {
    app_state = state_mod.AppState.init(init.arena.allocator());
    app_state.bootstrapFromArgs(init.minimal.args.vector);

    try citron.run(init, .{
        .app_name = "Guava Editor",
        .bundle_id = "com.guava.editor",
        .exe_name = "guava-editor",
        .setup = setup,
    });
}
