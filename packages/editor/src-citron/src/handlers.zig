const std = @import("std");
const citron = @import("citron");

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

// ── Command definitions ─────────────────────────────────────────────────────

pub const commands = [_]citron.CommandDef{
    // Launcher
    citron.cmd("launcher.getAppMode", getAppMode),
    citron.cmd("launcher.getRecentProjects", getRecentProjects),
    citron.cmd("launcher.removeRecentProject", removeRecentProject),
    citron.cmd("launcher.getTemplates", getTemplates),
    citron.cmd("launcher.openProject", openProject),
    citron.cmd("launcher.createProject", createProject),

    // Build
    citron.cmd("build.package", buildPackage),
    citron.cmd("build.cancel", buildCancel),
    citron.cmd("build.run", buildRun),

    // FS
    citron.cmd("fs.mkdir", fsMkdir),
    citron.cmd("fs.rename", fsRename),
    citron.cmd("fs.delete", fsDelete),
    citron.cmd("fs.createFile", fsCreateFile),
    citron.cmd("fs.importPaths", handleFsImportPaths), // complex — raw handler

    // Viewport
    citron.cmd("viewport.attachSurface", handleViewportAttachSurface), // raw handler
    citron.cmd("viewport.updateSurface", handleViewportUpdateSurface), // raw handler
    citron.cmd("viewport.detach", viewportDetach),
    citron.cmd("viewport.updateBounds", viewportUpdateBounds),
    citron.cmd("viewport.updateExclusions", handleViewportUpdateExclusions), // raw handler
    citron.cmd("viewport.getState", viewportGetState),

    // Popout
    citron.cmd("popout.panel", handlePopoutPanel), // raw handler
    citron.cmd("popout.close", popoutClose),
    citron.cmd("popout.getPanels", handlePopoutGetPanels), // raw handler
    citron.cmd("popout.isPopout", handlePopoutIsPopout), // raw handler
};

// ── Launcher ────────────────────────────────────────────────────────────────

fn getAppMode() citron.Json {
    return citron.json(appState().appMode());
}

fn getRecentProjects(ctx: *RequestContext) !citron.Json {
    var loaded = try appState().loadRecentProjects(ctx.allocator);
    defer loaded.deinit();
    return citron.json(loaded.value);
}

fn removeRecentProject(_: *RequestContext, params: struct { projectPath: []const u8 }) !void {
    try appState().removeRecentProject(params.projectPath);
}

fn getTemplates() citron.Json {
    return citron.json(templates.project_templates);
}

fn openProject(ctx: *RequestContext, params: struct { projectPath: []const u8 }) !void {
    try appState().openProject(ctx.allocator, params.projectPath);
}

fn createProject(ctx: *RequestContext, params: struct {
    projectPath: []const u8,
    projectName: []const u8,
    templateId: []const u8 = "empty",
}) !void {
    try appState().createProject(ctx.allocator, params.projectPath, params.projectName, params.templateId);
}

// ── Build ───────────────────────────────────────────────────────────────────

fn buildPackage(ctx: *RequestContext, params: struct {
    outputDir: []const u8,
    optimize: []const u8 = "ReleaseSafe",
}) !citron.Json {
    const project_path = appState().current_project_path orelse return error.NoProjectOpen;
    const result_path = try build_pipeline.buildPackage(ctx.allocator, project_path, params.outputDir, params.optimize);
    defer ctx.allocator.free(result_path);
    return citron.json(.{ .ok = true, .path = result_path });
}

fn buildCancel() !void {
    if (!build_pipeline.requestCancel()) return error.NoBuildActive;
}

fn buildRun(ctx: *RequestContext, params: struct { appPath: []const u8 }) !void {
    const result = try std.process.run(ctx.allocator, citron.globals.global_io, .{
        .argv = &.{ "/usr/bin/open", params.appPath },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(32 * 1024),
    });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.LaunchFailed,
        else => return error.LaunchFailed,
    }
}

// ── FS ──────────────────────────────────────────────────────────────────────

fn fsMkdir(ctx: *RequestContext, params: struct { path: []const u8 }) !void {
    const abs_path = try appState().resolveProjectPath(ctx.allocator, params.path);
    defer ctx.allocator.free(abs_path);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), citron.globals.global_io, abs_path);
}

fn fsRename(ctx: *RequestContext, params: struct { oldPath: []const u8, newPath: []const u8 }) !void {
    const old_abs = try appState().resolveProjectPath(ctx.allocator, params.oldPath);
    defer ctx.allocator.free(old_abs);
    const new_abs = try appState().resolveProjectPath(ctx.allocator, params.newPath);
    defer ctx.allocator.free(new_abs);
    try std.Io.Dir.renameAbsolute(old_abs, new_abs, citron.globals.global_io);
}

fn fsDelete(ctx: *RequestContext, params: struct { path: []const u8 }) !void {
    const abs_path = try appState().resolveProjectPath(ctx.allocator, params.path);
    defer ctx.allocator.free(abs_path);
    std.Io.Dir.cwd().deleteTree(citron.globals.global_io, abs_path) catch {
        try std.Io.Dir.deleteFileAbsolute(citron.globals.global_io, abs_path);
    };
}

fn fsCreateFile(ctx: *RequestContext, params: struct { path: []const u8, content: []const u8 = "" }) !void {
    const abs_path = try appState().resolveProjectPath(ctx.allocator, params.path);
    defer ctx.allocator.free(abs_path);
    const parent = std.fs.path.dirname(abs_path) orelse return error.InvalidPath;
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), citron.globals.global_io, parent);
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), citron.globals.global_io, .{
        .sub_path = abs_path,
        .data = params.content,
    });
}

// ── FS (complex — raw handler) ──────────────────────────────────────────────

fn handleFsImportPaths(ctx: *RequestContext) anyerror!Response {
    const ParsedParams = struct {
        targetDir: []const u8,
        sourcePaths: []const []const u8,
    };
    const parsed = std.json.parseFromSlice(ParsedParams, ctx.allocator, ctx.payload, .{
        .ignore_unknown_fields = true,
    }) catch return Response.fail(.invalid_params, "Invalid params");
    defer parsed.deinit();
    const p = parsed.value;

    const target_abs = try appState().resolveProjectPath(ctx.allocator, p.targetDir);
    defer ctx.allocator.free(target_abs);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), citron.globals.global_io, target_abs);

    var imported = std.ArrayList([]const u8).empty;
    defer {
        for (imported.items) |item| ctx.allocator.free(item);
        imported.deinit(ctx.allocator);
    }

    for (p.sourcePaths, 0..) |src, index| {
        enqueueProgressEvent(ctx.allocator, "fs.importProgress", .{
            .current = index,
            .total = p.sourcePaths.len,
            .name = std.fs.path.basename(src),
        });

        const dest = try std.fs.path.join(ctx.allocator, &.{ target_abs, std.fs.path.basename(src) });
        defer ctx.allocator.free(dest);
        const rel_imported = try std.fs.path.join(ctx.allocator, &.{ p.targetDir, std.fs.path.basename(src) });
        try imported.append(ctx.allocator, rel_imported);

        const copy_result = try std.process.run(ctx.allocator, citron.globals.global_io, .{
            .argv = &.{ "/bin/cp", "-R", src, dest },
            .stdout_limit = .limited(1024),
            .stderr_limit = .limited(64 * 1024),
        });
        defer ctx.allocator.free(copy_result.stdout);
        defer ctx.allocator.free(copy_result.stderr);
        switch (copy_result.term) {
            .exited => |code| if (code != 0) return Response.fail(.internal_error, "Copy failed"),
            else => return Response.fail(.internal_error, "Copy failed"),
        }
    }

    enqueueProgressEvent(ctx.allocator, "fs.importProgress", .{
        .current = p.sourcePaths.len,
        .total = p.sourcePaths.len,
        .done = true,
    });

    const encoded = std.json.Stringify.valueAlloc(std.heap.page_allocator, .{ .ok = true, .files = imported.items }, .{}) catch
        return Response.fail(.internal_error, "Serialize failed");
    return Response.okJsonOwned(encoded);
}

// ── Viewport ────────────────────────────────────────────────────────────────

fn handleViewportAttachSurface(ctx: *RequestContext) anyerror!Response {
    const P = struct {
        surfaceId: i64 = 0,
        x: f64 = 0,
        y: f64 = 0,
        w: f64 = 0,
        h: f64 = 0,
        shmName: ?[]const u8 = null,
    };
    const parsed = std.json.parseFromSlice(P, ctx.allocator, if (ctx.payload.len == 0) "{}" else ctx.payload, .{
        .ignore_unknown_fields = true,
    }) catch return Response.fail(.invalid_params, "Invalid params");
    defer parsed.deinit();
    const p = parsed.value;
    const attached = viewport().attachSurface(p.surfaceId, p.x, p.y, p.w, p.h, p.shmName) catch false;
    return serializeBool(attached);
}

fn handleViewportUpdateSurface(ctx: *RequestContext) anyerror!Response {
    const P = struct {
        surfaceId: i64 = 0,
        shmName: ?[]const u8 = null,
        width: ?f64 = null,
        height: ?f64 = null,
    };
    const parsed = std.json.parseFromSlice(P, ctx.allocator, if (ctx.payload.len == 0) "{}" else ctx.payload, .{
        .ignore_unknown_fields = true,
    }) catch return ok();
    defer parsed.deinit();
    const p = parsed.value;
    viewport().updateSurface(p.surfaceId, p.shmName, p.width, p.height);
    return ok();
}

fn viewportDetach() void {
    viewport().detach();
}

fn viewportUpdateBounds(_: *RequestContext, params: struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
}) void {
    viewport().updateBounds(params.x, params.y, params.w, params.h);
}

fn handleViewportUpdateExclusions(ctx: *RequestContext) anyerror!Response {
    const rects_parsed = std.json.parseFromSlice(struct { rects: std.json.Value }, ctx.allocator, if (ctx.payload.len == 0) "{}" else ctx.payload, .{
        .ignore_unknown_fields = true,
    }) catch return ok();
    defer rects_parsed.deinit();
    const rects_json = std.json.Stringify.valueAlloc(ctx.allocator, rects_parsed.value.rects, .{}) catch return ok();
    defer ctx.allocator.free(rects_json);
    viewport().updateExclusions(rects_json);
    return ok();
}

fn viewportGetState() citron.Json {
    return citron.json(viewport().getState());
}

// ── Popout ──────────────────────────────────────────────────────────────────

fn handlePopoutPanel(ctx: *RequestContext) anyerror!Response {
    const P = struct {
        panels: std.json.Value = .null,
        originInfo: std.json.Value = .null,
        bounds: std.json.Value = .null,
    };
    const parsed = std.json.parseFromSlice(P, ctx.allocator, if (ctx.payload.len == 0) "{}" else ctx.payload, .{
        .ignore_unknown_fields = true,
    }) catch return Response.fail(.invalid_params, "Invalid params");
    defer parsed.deinit();
    const p = parsed.value;

    const panels_json = std.json.Stringify.valueAlloc(ctx.allocator, p.panels, .{}) catch
        return Response.fail(.internal_error, "Serialize failed");
    defer ctx.allocator.free(panels_json);

    const origin_json: ?[]const u8 = if (p.originInfo != .null)
        (std.json.Stringify.valueAlloc(ctx.allocator, p.originInfo, .{}) catch null)
    else
        null;
    defer if (origin_json) |j| ctx.allocator.free(j);

    const bounds_json: ?[]const u8 = if (p.bounds != .null)
        (std.json.Stringify.valueAlloc(ctx.allocator, p.bounds, .{}) catch null)
    else
        null;
    defer if (bounds_json) |j| ctx.allocator.free(j);

    const id = popout().popoutPanel(panels_json, origin_json, bounds_json) catch |err| {
        return Response.fail(.internal_error, @errorName(err));
    };
    const encoded = std.json.Stringify.valueAlloc(std.heap.page_allocator, id, .{}) catch
        return Response.fail(.internal_error, "Serialize failed");
    return Response.okJsonOwned(encoded);
}

fn popoutClose(_: *RequestContext, params: struct { id: i32 }) void {
    popout().closePopout(params.id);
}

fn handlePopoutGetPanels(ctx: *RequestContext) anyerror!Response {
    _ = ctx;
    const entries = popout().getPanels();
    const encoded = std.json.Stringify.valueAlloc(std.heap.page_allocator, entries, .{}) catch
        return Response.fail(.internal_error, "Serialize failed");
    return Response.okJsonOwned(encoded);
}

fn handlePopoutIsPopout(ctx: *RequestContext) anyerror!Response {
    const parsed = std.json.parseFromSlice(struct { id: i32 = 0 }, ctx.allocator, if (ctx.payload.len == 0) "{}" else ctx.payload, .{
        .ignore_unknown_fields = true,
    }) catch return serializeBool(false);
    defer parsed.deinit();
    return serializeBool(popout().isPopoutId(parsed.value.id));
}

// ── Helpers ─────────────────────────────────────────────────────────────────

fn ok() Response {
    return Response.okJsonOwned(std.heap.page_allocator.dupe(u8, "{\"ok\":true}") catch "{\"ok\":true}");
}

fn serializeBool(value: bool) Response {
    const s = if (value) "true" else "false";
    return Response.okJsonOwned(std.heap.page_allocator.dupe(u8, s) catch s);
}

fn enqueueProgressEvent(allocator: std.mem.Allocator, event_name: []const u8, payload: anytype) void {
    const encoded = std.json.Stringify.valueAlloc(allocator, payload, .{}) catch return;
    defer allocator.free(encoded);
    citron.ipc.enqueueEventJson(event_name, encoded);
}
