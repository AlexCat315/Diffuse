///! handlers/script.zig — script file browsing and editing.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

/// List all script files under the assets/scripts directory.
pub fn listScripts(ctx: *Ctx) !void {
    const scripts_dir = "assets/scripts";

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
    // Only allow writing to assets/scripts/
    if (!std.mem.startsWith(u8, rel_path, "assets/scripts/")) return error.InvalidArguments;

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
