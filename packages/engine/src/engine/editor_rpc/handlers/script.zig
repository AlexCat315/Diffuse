///! handlers/script.zig — script file browsing and editing.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

/// List all script files under the configured scripts directory.
pub fn listScripts(ctx: *Ctx) !void {
    const scripts_dir = ctx.scripts_dir;

    var entries = std.ArrayList(ScriptEntry).empty;
    defer {
        for (entries.items) |e| {
            ctx.allocator.free(e.path);
            ctx.allocator.free(e.name);
        }
        entries.deinit(ctx.allocator);
    }

    // Open scripts directory relative to project root (or CWD as fallback).
    var owned_base: ?std.fs.Dir = if (ctx.project_root) |root|
        (std.fs.openDirAbsolute(root, .{}) catch null)
    else
        null;
    defer if (owned_base) |*d| d.close();
    const base_dir: std.fs.Dir = owned_base orelse std.fs.cwd();

    var dir = base_dir.openDir(scripts_dir, .{ .iterate = true }) catch {
        try ctx.reply(.{
            .scripts = @as([]const ScriptEntry, &.{}),
        });
        return;
    };
    defer dir.close();

    try collectScripts(ctx.allocator, dir, scripts_dir, &entries);

    try ctx.reply(.{
        .scripts = entries.items,
    });
}

fn collectScripts(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    out: *std.ArrayList(ScriptEntry),
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (entry.name.len > 0 and entry.name[0] == '_') continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        errdefer allocator.free(full_path);

        if (entry.kind == .directory) {
            const sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch {
                allocator.free(full_path);
                continue;
            };
            try collectScripts(allocator, sub_dir, full_path, out);
            // full_path ownership transferred to recursive entries; free here
            // since prefix is only used as a format arg (already copied into child paths).
            allocator.free(full_path);
            continue;
        }

        const lang = classifyLanguage(entry.name) orelse {
            allocator.free(full_path);
            continue;
        };

        const stat = dir.statFile(entry.name) catch {
            allocator.free(full_path);
            continue;
        };

        try out.append(allocator, .{
            .path = full_path,
            .name = try allocator.dupe(u8, entry.name),
            .language = lang,
            .sizeBytes = stat.size,
        });
    }
}

fn classifyLanguage(name: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, name, ".zig")) return "zig";
    if (std.mem.endsWith(u8, name, ".cs")) return "csharp";
    if (std.mem.endsWith(u8, name, ".lua")) return "lua";
    return null;
}

const ScriptEntry = struct {
    path: []const u8,
    name: []const u8,
    language: []const u8,
    sizeBytes: u64,
};

/// Read a script file's content.
pub fn getContent(ctx: *Ctx) !void {
    const rel_path = try ctx.param([]const u8, "path");

    // Sanitize
    if (rel_path.len > 0 and rel_path[0] == '/') return error.InvalidArguments;
    if (std.mem.indexOf(u8, rel_path, "..") != null) return error.InvalidArguments;

    var owned_base: ?std.fs.Dir = if (ctx.project_root) |root|
        (std.fs.openDirAbsolute(root, .{}) catch null)
    else
        null;
    defer if (owned_base) |*d| d.close();
    const base_dir: std.fs.Dir = owned_base orelse std.fs.cwd();

    const file = base_dir.openFile(rel_path, .{}) catch {
        return error.InvalidArguments;
    };
    defer file.close();

    const content = file.readToEndAlloc(ctx.allocator, 10 * 1024 * 1024) catch {
        return error.InvalidArguments;
    };

    const lang = classifyLanguage(rel_path) orelse "text";

    try ctx.reply(.{
        .content = content,
        .language = lang,
        .readOnly = false,
    });
}

/// Save modified content back to a script file.
pub fn saveContent(ctx: *Ctx) !void {
    const rel_path = try ctx.param([]const u8, "path");
    const content = try ctx.param([]const u8, "content");

    // Sanitize
    if (rel_path.len > 0 and rel_path[0] == '/') return error.InvalidArguments;
    if (std.mem.indexOf(u8, rel_path, "..") != null) return error.InvalidArguments;
    // Only allow writing to the configured scripts directory
    if (!std.mem.startsWith(u8, rel_path, ctx.scripts_dir)) return error.InvalidArguments;

    var owned_base: ?std.fs.Dir = if (ctx.project_root) |root|
        (std.fs.openDirAbsolute(root, .{}) catch null)
    else
        null;
    defer if (owned_base) |*d| d.close();
    const base_dir: std.fs.Dir = owned_base orelse std.fs.cwd();

    const file = base_dir.createFile(rel_path, .{}) catch {
        try ctx.reply(.{ .success = false });
        return;
    };
    defer file.close();

    file.writeAll(content) catch {
        try ctx.reply(.{ .success = false });
        return;
    };

    try ctx.reply(.{ .success = true });
}

/// Get the current parameter values of an entity's script component.
/// script.getEntityParameters(entityId, scriptIndex?)
pub fn getEntityParameters(ctx: *Ctx) !void {
    const eid: u64 = @intCast(try ctx.param(i64, "entityId"));
    const entity = ctx.layer.world.getEntityConst(eid) orelse {
        try ctx.reply(.{ .parameters = @as(?[]const u8, null) });
        return;
    };

    const script_index = try ctx.paramOpt(i64, "scriptIndex");
    if (script_index) |raw_idx| {
        if (raw_idx == -1) {
            // Legacy single script
            if (entity.script) |script| {
                if (script.parameters.len > 0) {
                    try ctx.reply(.{ .parameters = script.parameters });
                    return;
                }
            }
        } else {
            const idx: usize = @intCast(raw_idx);
            if (idx < entity.scripts.len) {
                const script = entity.scripts[idx];
                if (script.parameters.len > 0) {
                    try ctx.reply(.{ .parameters = script.parameters });
                    return;
                }
            }
        }
    } else {
        // Fallback: try scripts[0], then legacy
        if (entity.scripts.len > 0) {
            const script = entity.scripts[0];
            if (script.parameters.len > 0) {
                try ctx.reply(.{ .parameters = script.parameters });
                return;
            }
        } else if (entity.script) |script| {
            if (script.parameters.len > 0) {
                try ctx.reply(.{ .parameters = script.parameters });
                return;
            }
        }
    }
    try ctx.reply(.{ .parameters = @as(?[]const u8, null) });
}

/// Set parameter values on an entity's script component.
/// script.setEntityParameters(entityId, parameters, scriptIndex?)
/// `parameters` is a JSON string like '{"speed": 5.0, "jump_height": 2.0}'
pub fn setEntityParameters(ctx: *Ctx) !void {
    const eid: u64 = @intCast(try ctx.param(i64, "entityId"));
    const parameters = try ctx.param([]const u8, "parameters");
    const entity = ctx.layer.world.getEntity(eid) orelse {
        try ctx.reply(.{ .success = false });
        return;
    };

    const alloc = ctx.layer.world.allocator;
    const script_index = try ctx.paramOpt(i64, "scriptIndex");

    if (script_index) |raw_idx| {
        if (raw_idx == -1) {
            // Legacy single script
            if (entity.script) |*script| {
                script.parameters = alloc.dupe(u8, parameters) catch {
                    try ctx.reply(.{ .success = false });
                    return;
                };
                ctx.layer.world.markDirty(eid);
                try ctx.reply(.{ .success = true });
                return;
            }
        } else {
            const idx: usize = @intCast(raw_idx);
            if (idx < entity.scripts.len) {
                entity.scripts[idx].parameters = alloc.dupe(u8, parameters) catch {
                    try ctx.reply(.{ .success = false });
                    return;
                };
                ctx.layer.world.markDirty(eid);
                try ctx.reply(.{ .success = true });
                return;
            }
        }
    } else {
        // Fallback: try scripts[0], then legacy
        if (entity.scripts.len > 0) {
            entity.scripts[0].parameters = alloc.dupe(u8, parameters) catch {
                try ctx.reply(.{ .success = false });
                return;
            };
            ctx.layer.world.markDirty(eid);
            try ctx.reply(.{ .success = true });
            return;
        } else if (entity.script) |*script| {
            script.parameters = alloc.dupe(u8, parameters) catch {
                try ctx.reply(.{ .success = false });
                return;
            };
            ctx.layer.world.markDirty(eid);
            try ctx.reply(.{ .success = true });
            return;
        }
    }

    try ctx.reply(.{ .success = false });
}
