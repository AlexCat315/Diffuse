const std = @import("std");
const citron = @import("citron");

const protocol = citron.ipc.protocol;
const RequestContext = citron.ipc.Context;
const Response = citron.ipc.HandlerResult;
const state_mod = @import("state.zig");
const templates = @import("project_templates.zig");
const build_pipeline = @import("build_pipeline.zig");
const ViewportState = @import("viewport.zig").ViewportState;
const PopoutManager = @import("popout.zig").PopoutManager;

var g_state: ?*state_mod.AppState = null;
var g_viewport: ?*ViewportState = null;
var g_popout: ?*PopoutManager = null;

pub fn init(state: *state_mod.AppState, vp: *ViewportState, po: *PopoutManager) void {
    g_state = state;
    g_viewport = vp;
    g_popout = po;
}

fn appState() *state_mod.AppState {
    return g_state orelse unreachable;
}

fn viewport() *ViewportState {
    return g_viewport orelse unreachable;
}

fn popout() *PopoutManager {
    return g_popout orelse unreachable;
}

fn jsonResponse(value: anytype) Response {
    const encoded = std.json.Stringify.valueAlloc(std.heap.page_allocator, value, .{}) catch {
        return Response.fail(.internal_error, "Failed to serialize response");
    };
    return Response.okJsonOwned(encoded);
}

const ParsedParams = struct {
    parsed: std.json.Parsed(std.json.Value),

    fn init(allocator: std.mem.Allocator, payload: []const u8) !ParsedParams {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        if (parsed.value != .object) return error.InvalidParams;
        return .{ .parsed = parsed };
    }

    fn deinit(self: *ParsedParams) void {
        self.parsed.deinit();
    }

    fn getString(self: *ParsedParams, key: []const u8) ?[]const u8 {
        const value = self.parsed.value.object.get(key) orelse return null;
        if (value != .string) return null;
        return value.string;
    }

    fn getStringArray(self: *ParsedParams, key: []const u8) ?std.json.Array {
        const value = self.parsed.value.object.get(key) orelse return null;
        if (value != .array) return null;
        return value.array;
    }
};

pub fn register(router: *citron.ipc.Router) !void {
    try router.registerMethod("launcher.getAppMode", handleLauncherGetAppMode, protocol.MethodDef.init("launcher.getAppMode", .{}));
    try router.registerMethod("launcher.getRecentProjects", handleLauncherGetRecentProjects, protocol.MethodDef.init("launcher.getRecentProjects", .{}));
    try router.registerMethod("launcher.removeRecentProject", handleLauncherRemoveRecentProject, protocol.MethodDef.init("launcher.removeRecentProject", .{}));
    try router.registerMethod("launcher.getTemplates", handleLauncherGetTemplates, protocol.MethodDef.init("launcher.getTemplates", .{}));
    try router.registerMethod("launcher.openProject", handleLauncherOpenProject, protocol.MethodDef.init("launcher.openProject", .{}));
    try router.registerMethod("launcher.createProject", handleLauncherCreateProject, protocol.MethodDef.init("launcher.createProject", .{}));

    try router.registerMethod("build.package", handleBuildPackage, protocol.MethodDef.init("build.package", .{}));
    try router.registerMethod("build.cancel", handleBuildCancel, protocol.MethodDef.init("build.cancel", .{}));
    try router.registerMethod("build.run", handleBuildRun, protocol.MethodDef.init("build.run", .{}));

    try router.registerMethod("fs.mkdir", handleFsMkdir, protocol.MethodDef.init("fs.mkdir", .{ .fs_write = true }));
    try router.registerMethod("fs.rename", handleFsRename, protocol.MethodDef.init("fs.rename", .{ .fs_write = true }));
    try router.registerMethod("fs.delete", handleFsDelete, protocol.MethodDef.init("fs.delete", .{ .fs_write = true }));
    try router.registerMethod("fs.createFile", handleFsCreateFile, protocol.MethodDef.init("fs.createFile", .{ .fs_write = true }));
    try router.registerMethod("fs.importPaths", handleFsImportPaths, protocol.MethodDef.init("fs.importPaths", .{ .fs_write = true }));

    try router.registerMethod("viewport.attachSurface", handleViewportAttachSurface, protocol.MethodDef.init("viewport.attachSurface", .{}));
    try router.registerMethod("viewport.updateSurface", handleViewportUpdateSurface, protocol.MethodDef.init("viewport.updateSurface", .{}));
    try router.registerMethod("viewport.detach", handleViewportDetach, protocol.MethodDef.init("viewport.detach", .{}));
    try router.registerMethod("viewport.updateBounds", handleViewportUpdateBounds, protocol.MethodDef.init("viewport.updateBounds", .{}));
    try router.registerMethod("viewport.updateExclusions", handleViewportUpdateExclusions, protocol.MethodDef.init("viewport.updateExclusions", .{}));
    try router.registerMethod("viewport.getState", handleViewportGetState, protocol.MethodDef.init("viewport.getState", .{}));

    try router.registerMethod("popout.panel", handlePopoutPanel, protocol.MethodDef.init("popout.panel", .{}));
    try router.registerMethod("popout.close", handlePopoutClose, protocol.MethodDef.init("popout.close", .{}));
    try router.registerMethod("popout.getPanels", handlePopoutGetPanels, protocol.MethodDef.init("popout.getPanels", .{}));
    try router.registerMethod("popout.isPopout", handlePopoutIsPopout, protocol.MethodDef.init("popout.isPopout", .{}));
}

fn okObject(message: ?[]const u8) Response {
    if (message) |msg| {
        return jsonResponse(.{ .ok = true, .message = msg });
    }
    return jsonResponse(.{ .ok = true });
}

fn errorObject(message: []const u8) Response {
    return jsonResponse(.{ .ok = false, .@"error" = message });
}

fn simpleBoolResponse(value: bool) Response {
    return jsonResponse(value);
}

fn enqueueProgressEvent(allocator: std.mem.Allocator, event_name: []const u8, payload: anytype) void {
    const encoded = std.json.Stringify.valueAlloc(allocator, payload, .{}) catch return;
    defer allocator.free(encoded);
    citron.ipc.enqueueEventJson(event_name, encoded);
}

fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

pub fn handleLauncherGetAppMode(ctx: *RequestContext) anyerror!Response {
    _ = ctx;
    return jsonResponse(appState().appMode());
}

pub fn handleLauncherGetRecentProjects(ctx: *RequestContext) anyerror!Response {
    var loaded = try appState().loadRecentProjects(ctx.allocator);
    defer loaded.deinit();
    return jsonResponse(loaded.value);
}

pub fn handleLauncherRemoveRecentProject(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const project_path = params.getString("projectPath") orelse return errorObject("Missing projectPath");
    appState().removeRecentProject(project_path) catch |err| return errorObject(@errorName(err));
    return okObject(null);
}

pub fn handleLauncherGetTemplates(ctx: *RequestContext) anyerror!Response {
    _ = ctx;
    return jsonResponse(templates.project_templates);
}

pub fn handleLauncherOpenProject(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const project_path = params.getString("projectPath") orelse return errorObject("Missing projectPath");
    appState().openProject(ctx.allocator, project_path) catch |err| return errorObject(@errorName(err));
    return okObject(null);
}

pub fn handleLauncherCreateProject(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const project_path = params.getString("projectPath") orelse return errorObject("Missing projectPath");
    const project_name = params.getString("projectName") orelse return errorObject("Missing projectName");
    const template_id = params.getString("templateId") orelse "empty";

    appState().createProject(ctx.allocator, project_path, project_name, template_id) catch |err| return errorObject(@errorName(err));
    return okObject(null);
}

pub fn handleBuildPackage(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const project_path = appState().current_project_path orelse return errorObject("No project open");
    const output_dir = params.getString("outputDir") orelse return errorObject("Missing outputDir");
    const optimize = params.getString("optimize") orelse "ReleaseSafe";

    const result_path = build_pipeline.buildPackage(ctx.allocator, project_path, output_dir, optimize) catch |err| {
        return errorObject(@errorName(err));
    };
    defer ctx.allocator.free(result_path);

    return jsonResponse(.{ .ok = true, .path = result_path });
}

pub fn handleBuildCancel(ctx: *RequestContext) anyerror!Response {
    _ = ctx;
    if (build_pipeline.requestCancel()) {
        return okObject("Build cancellation requested");
    }
    return errorObject("No active build");
}

pub fn handleBuildRun(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const app_path = params.getString("appPath") orelse return errorObject("Missing appPath");
    const result = std.process.run(ctx.allocator, citron.globals.global_io, .{
        .argv = &.{ "/usr/bin/open", app_path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(32 * 1024),
    }) catch |err| return errorObject(@errorName(err));
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    return switch (result.term) {
        .exited => |code| if (code == 0) okObject(null) else errorObject(result.stderr),
        else => errorObject("Failed to launch built app"),
    };
}

pub fn handleFsMkdir(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const rel_path = params.getString("path") orelse return errorObject("Missing path");
    const abs_path = appState().resolveProjectPath(ctx.allocator, rel_path) catch |err| return errorObject(@errorName(err));
    defer ctx.allocator.free(abs_path);

    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), citron.globals.global_io, abs_path) catch |err| return errorObject(@errorName(err));
    return okObject(null);
}

pub fn handleFsRename(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const old_rel = params.getString("oldPath") orelse return errorObject("Missing oldPath");
    const new_rel = params.getString("newPath") orelse return errorObject("Missing newPath");
    const old_abs = appState().resolveProjectPath(ctx.allocator, old_rel) catch |err| return errorObject(@errorName(err));
    defer ctx.allocator.free(old_abs);
    const new_abs = appState().resolveProjectPath(ctx.allocator, new_rel) catch |err| return errorObject(@errorName(err));
    defer ctx.allocator.free(new_abs);

    std.Io.Dir.renameAbsolute(old_abs, new_abs, citron.globals.global_io) catch |err| return errorObject(@errorName(err));
    return okObject(null);
}

pub fn handleFsDelete(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const rel_path = params.getString("path") orelse return errorObject("Missing path");
    const abs_path = appState().resolveProjectPath(ctx.allocator, rel_path) catch |err| return errorObject(@errorName(err));
    defer ctx.allocator.free(abs_path);

    std.Io.Dir.cwd().deleteTree(citron.globals.global_io, abs_path) catch {
        std.Io.Dir.deleteFileAbsolute(citron.globals.global_io, abs_path) catch |err| return errorObject(@errorName(err));
    };
    return okObject(null);
}

pub fn handleFsCreateFile(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const rel_path = params.getString("path") orelse return errorObject("Missing path");
    const content = params.getString("content") orelse "";
    const abs_path = appState().resolveProjectPath(ctx.allocator, rel_path) catch |err| return errorObject(@errorName(err));
    defer ctx.allocator.free(abs_path);

    const parent = std.fs.path.dirname(abs_path) orelse return errorObject("Invalid path");
    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), citron.globals.global_io, parent) catch |err| return errorObject(@errorName(err));
    std.Io.Dir.writeFile(std.Io.Dir.cwd(), citron.globals.global_io, .{
        .sub_path = abs_path,
        .data = content,
    }) catch |err| return errorObject(@errorName(err));
    return okObject(null);
}

pub fn handleFsImportPaths(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const target_dir = params.getString("targetDir") orelse return errorObject("Missing targetDir");
    const sources = params.getStringArray("sourcePaths") orelse return errorObject("Missing sourcePaths");
    const target_abs = appState().resolveProjectPath(ctx.allocator, target_dir) catch |err| return errorObject(@errorName(err));
    defer ctx.allocator.free(target_abs);

    std.Io.Dir.createDirPath(std.Io.Dir.cwd(), citron.globals.global_io, target_abs) catch |err| return errorObject(@errorName(err));

    var imported = std.ArrayList([]const u8).empty;
    defer {
        for (imported.items) |item| ctx.allocator.free(item);
        imported.deinit(ctx.allocator);
    }

    for (sources.items, 0..) |value, index| {
        if (value != .string) continue;
        enqueueProgressEvent(ctx.allocator, "fs.importProgress", .{
            .current = index,
            .total = sources.items.len,
            .name = basename(value.string),
        });

        const dest = try std.fs.path.join(ctx.allocator, &.{ target_abs, basename(value.string) });
        defer ctx.allocator.free(dest);
        const rel_imported = try std.fs.path.join(ctx.allocator, &.{ target_dir, basename(value.string) });
        try imported.append(ctx.allocator, rel_imported);

        const copy_result = std.process.run(ctx.allocator, citron.globals.global_io, .{
            .argv = &.{ "/bin/cp", "-R", value.string, dest },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch |err| return errorObject(@errorName(err));
        defer ctx.allocator.free(copy_result.stdout);
        defer ctx.allocator.free(copy_result.stderr);

        switch (copy_result.term) {
            .exited => |code| if (code != 0) return errorObject(copy_result.stderr),
            else => return errorObject("Copy failed"),
        }
    }

    enqueueProgressEvent(ctx.allocator, "fs.importProgress", .{
        .current = sources.items.len,
        .total = sources.items.len,
        .done = true,
    });

    return jsonResponse(.{ .ok = true, .files = imported.items });
}

pub fn handleViewportAttachSurface(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const surface_id = blk: {
        const v = params.parsed.value.object.get("surfaceId") orelse break :blk @as(i64, 0);
        if (v == .integer) break :blk v.integer;
        break :blk @as(i64, 0);
    };

    const x = getFloat(&params, "x") orelse 0;
    const y = getFloat(&params, "y") orelse 0;
    const w = getFloat(&params, "w") orelse 0;
    const h = getFloat(&params, "h") orelse 0;
    const shm_name = params.getString("shmName");

    const attached = viewport().attachSurface(surface_id, x, y, w, h, shm_name) catch false;
    return simpleBoolResponse(attached);
}

pub fn handleViewportUpdateSurface(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return okObject(null);
    defer params.deinit();

    const surface_id = blk: {
        const v = params.parsed.value.object.get("surfaceId") orelse break :blk @as(i64, 0);
        if (v == .integer) break :blk v.integer;
        break :blk @as(i64, 0);
    };

    const shm_name = params.getString("shmName");
    const width = getFloat(&params, "width");
    const height = getFloat(&params, "height");

    viewport().updateSurface(surface_id, shm_name, width, height);
    return okObject(null);
}

pub fn handleViewportDetach(ctx: *RequestContext) anyerror!Response {
    _ = ctx;
    viewport().detach();
    return okObject(null);
}

pub fn handleViewportUpdateBounds(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return okObject(null);
    defer params.deinit();

    const x = getFloat(&params, "x") orelse 0;
    const y = getFloat(&params, "y") orelse 0;
    const w = getFloat(&params, "w") orelse 0;
    const h = getFloat(&params, "h") orelse 0;

    viewport().updateBounds(x, y, w, h);
    return okObject(null);
}

pub fn handleViewportUpdateExclusions(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return okObject(null);
    defer params.deinit();

    const rects_val = params.parsed.value.object.get("rects") orelse return okObject(null);
    const rects_json = std.json.Stringify.valueAlloc(ctx.allocator, rects_val, .{}) catch return okObject(null);
    defer ctx.allocator.free(rects_json);

    viewport().updateExclusions(rects_json);
    return okObject(null);
}

pub fn handleViewportGetState(ctx: *RequestContext) anyerror!Response {
    _ = ctx;
    const state = viewport().getState();
    return jsonResponse(state);
}

// ── Popout handlers ───────────────────────────────────────────────

pub fn handlePopoutPanel(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const panels_val = params.parsed.value.object.get("panels") orelse return errorObject("Missing panels");
    const panels_json = std.json.Stringify.valueAlloc(ctx.allocator, panels_val, .{}) catch return errorObject("Invalid panels");
    defer ctx.allocator.free(panels_json);

    const origin_json = blk: {
        const v = params.parsed.value.object.get("originInfo") orelse break :blk null;
        const s = std.json.Stringify.valueAlloc(ctx.allocator, v, .{}) catch break :blk null;
        break :blk s;
    };
    defer if (origin_json) |j| ctx.allocator.free(j);

    const bounds_json = blk: {
        const v = params.parsed.value.object.get("bounds") orelse break :blk null;
        const s = std.json.Stringify.valueAlloc(ctx.allocator, v, .{}) catch break :blk null;
        break :blk s;
    };
    defer if (bounds_json) |j| ctx.allocator.free(j);

    const id = popout().popoutPanel(panels_json, origin_json, bounds_json) catch |err| {
        return errorObject(@errorName(err));
    };
    return jsonResponse(id);
}

pub fn handlePopoutClose(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return errorObject("Invalid params");
    defer params.deinit();

    const id = blk: {
        const v = params.parsed.value.object.get("id") orelse return errorObject("Missing id");
        if (v == .integer) break :blk @as(i32, @intCast(v.integer));
        return errorObject("Invalid id");
    };

    popout().closePopout(id);
    return okObject(null);
}

pub fn handlePopoutGetPanels(ctx: *RequestContext) anyerror!Response {
    const entries = popout().getPanels();
    var result = std.ArrayList(struct { id: i32, panels: []const []const u8 }).empty;
    defer result.deinit(ctx.allocator);

    for (entries) |entry| {
        const panel_slices = ctx.allocator.alloc([]const u8, entry.panels.len) catch continue;
        for (entry.panels, 0..) |p, i| {
            panel_slices[i] = p;
        }
        result.append(ctx.allocator, .{ .id = entry.id, .panels = panel_slices }) catch continue;
    }

    return jsonResponse(result.items);
}

pub fn handlePopoutIsPopout(ctx: *RequestContext) anyerror!Response {
    var params = ParsedParams.init(ctx.allocator, ctx.payload) catch return simpleBoolResponse(false);
    defer params.deinit();

    const id = blk: {
        const v = params.parsed.value.object.get("id") orelse return simpleBoolResponse(false);
        if (v == .integer) break :blk @as(i32, @intCast(v.integer));
        return simpleBoolResponse(false);
    };

    return simpleBoolResponse(popout().isPopoutId(id));
}

fn getFloat(params: *ParsedParams, key: []const u8) ?f64 {
    const value = params.parsed.value.object.get(key) orelse return null;
    return switch (value) {
        .float => value.float,
        .integer => @floatFromInt(value.integer),
        else => null,
    };
}
