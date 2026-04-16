const std = @import("std");
const citron = @import("citron");

const protocol = citron.ipc.protocol;
const RequestContext = citron.ipc.Context;
const Response = citron.ipc.HandlerResult;
const state_mod = @import("state.zig");
const templates = @import("project_templates.zig");

var g_state: ?*state_mod.AppState = null;

pub fn init(state: *state_mod.AppState) void {
    g_state = state;
}

fn appState() *state_mod.AppState {
    return g_state orelse unreachable;
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
    try router.registerMethod("viewport.updateSurface", handleViewportNoop, protocol.MethodDef.init("viewport.updateSurface", .{}));
    try router.registerMethod("viewport.detach", handleViewportNoop, protocol.MethodDef.init("viewport.detach", .{}));
    try router.registerMethod("viewport.updateBounds", handleViewportNoop, protocol.MethodDef.init("viewport.updateBounds", .{}));
    try router.registerMethod("viewport.updateExclusions", handleViewportNoop, protocol.MethodDef.init("viewport.updateExclusions", .{}));
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
    _ = ctx;
    return errorObject("Citron build packaging is not implemented yet");
}

pub fn handleBuildCancel(ctx: *RequestContext) anyerror!Response {
    _ = ctx;
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
    _ = ctx;
    return simpleBoolResponse(false);
}

pub fn handleViewportNoop(ctx: *RequestContext) anyerror!Response {
    _ = ctx;
    return okObject(null);
}
