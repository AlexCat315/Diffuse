const std = @import("std");
const citron = @import("citron");
const state_mod = @import("state.zig");
const handlers = @import("handlers.zig");
const ViewportState = @import("viewport.zig").ViewportState;
const PopoutManager = @import("popout.zig").PopoutManager;

var app_state: state_mod.AppState = undefined;
var viewport_state: ViewportState = undefined;
var popout_manager: PopoutManager = undefined;

fn setup(router: *citron.ipc.Router) !void {
    handlers.init(&app_state, &viewport_state, &popout_manager);
    try handlers.register(router);
    try app_state.startInitialProject();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    app_state = state_mod.AppState.init(allocator);
    viewport_state = ViewportState.init(allocator);
    popout_manager = PopoutManager.init(allocator);
    app_state.bootstrapFromArgs(init.minimal.args.vector);

    try citron.run(init, .{
        .app_name = "Guava Editor",
        .bundle_id = "com.guava.editor",
        .exe_name = "guava-editor",
        .setup = setup,
    });
}
