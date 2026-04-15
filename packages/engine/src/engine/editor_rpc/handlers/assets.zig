///! handlers/assets.zig — asset browser & file management.
const std = @import("std");
const io_globals = @import("io_globals");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const components = @import("../../scene/components.zig");

/// List contents of a directory under the project root.
/// Defaults to the project's "Content" directory, falling back to "assets"
/// for backward compatibility with engine development.
pub fn list(ctx: *Ctx) !void {
    const rel_path = (try ctx.paramOpt([]const u8, "path")) orelse blk: {
        // Prefer project "Content" directory; fall back to "assets"
        if (ctx.project_root) |root| {
            var d = std.Io.Dir.openDirAbsolute(io_globals.global_io, root, .{}) catch break :blk "Content";
            defer d.close(io_globals.global_io);
            var content = d.openDir(io_globals.global_io, "Content", .{}) catch break :blk "assets";
            content.close(io_globals.global_io);
            break :blk "Content";
        }
        var d = std.Io.Dir.cwd().openDir(io_globals.global_io, "Content", .{}) catch {
            break :blk "assets";
        };
        d.close(io_globals.global_io);
        break :blk "Content";
    };

    // Sanitize: reject absolute paths and path traversal
    if (rel_path.len > 0 and rel_path[0] == '/') return error.InvalidArguments;
    if (std.mem.indexOf(u8, rel_path, "..") != null) return error.InvalidArguments;

    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(ctx.allocator);

    // Open the target directory relative to project root (or CWD as fallback).
    // We need to track whether we opened a base Dir so we can close it.
    var owned_base: ?std.Io.Dir = if (ctx.project_root) |root|
        (std.Io.Dir.openDirAbsolute(io_globals.global_io, root, .{}) catch null)
    else
        null;
    defer if (owned_base) |*d| d.close(io_globals.global_io);

    const base_dir: std.Io.Dir = owned_base orelse std.Io.Dir.cwd();

    var dir = base_dir.openDir(io_globals.global_io, rel_path, .{ .iterate = true }) catch {
        try ctx.reply(.{
            .path = rel_path,
            .entries = @as([]const Entry, &.{}),
        });
        return;
    };
    defer dir.close(io_globals.global_io);

    var iter = dir.iterate();
    while (try iter.next(io_globals.global_io)) |entry| {
        // Skip hidden files and .meta files
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (std.mem.endsWith(u8, entry.name, ".meta")) continue;

        const name = try ctx.allocator.dupe(u8, entry.name);
        const full_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ rel_path, entry.name });
        const is_dir = entry.kind == .directory;
        try entries.append(ctx.allocator, .{
            .name = name,
            .path = full_path,
            .isDirectory = is_dir,
            .assetType = if (is_dir) "folder" else classifyAsset(entry.name),
        });
    }

    // Sort: directories first, then alphabetically
    std.mem.sort(Entry, entries.items, {}, entryLessThan);

    try ctx.reply(.{
        .path = rel_path,
        .entries = entries.items,
    });

    for (entries.items) |e| {
        ctx.allocator.free(@constCast(e.name));
        ctx.allocator.free(@constCast(e.path));
    }
}

const Entry = struct {
    name: []const u8,
    path: []const u8,
    isDirectory: bool,
    assetType: []const u8,
};

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    if (a.isDirectory != b.isDirectory) return a.isDirectory;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn classifyAsset(name: []const u8) []const u8 {
    if (hasExt(name, ".glsl") or hasExt(name, ".vert") or hasExt(name, ".frag") or
        hasExt(name, ".comp") or hasExt(name, ".wgsl") or hasExt(name, ".msl"))
        return "shader";
    if (hasExt(name, ".gltf") or hasExt(name, ".glb") or hasExt(name, ".obj") or hasExt(name, ".fbx"))
        return "model";
    if (hasExt(name, ".png") or hasExt(name, ".jpg") or hasExt(name, ".jpeg") or
        hasExt(name, ".hdr") or hasExt(name, ".bmp") or hasExt(name, ".tga") or hasExt(name, ".exr"))
        return "texture";
    if (hasExt(name, ".guava_scene") or hasExt(name, ".json"))
        return "scene";
    if (hasExt(name, ".zig") or hasExt(name, ".cs") or hasExt(name, ".lua"))
        return "script";
    if (hasExt(name, ".wav") or hasExt(name, ".ogg") or hasExt(name, ".mp3") or hasExt(name, ".flac"))
        return "audio";
    if (hasExt(name, ".material") or hasExt(name, ".mat"))
        return "material";
    return "unknown";
}

fn hasExt(name: []const u8, ext: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ext);
}

/// List the project root directory — shows top-level folders like Content,
/// assets, Derived, etc.  Used by the Asset Browser to navigate from root.
pub fn listProjectRoot(ctx: *Ctx) !void {
    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(ctx.allocator);

    // Use project root if available, otherwise CWD
    var base_dir = if (ctx.project_root) |root|
        std.Io.Dir.openDirAbsolute(io_globals.global_io, root, .{ .iterate = true }) catch {
            try ctx.reply(.{ .path = ".", .entries = @as([]const Entry, &.{}) });
            return;
        }
    else
        std.Io.Dir.cwd().openDir(io_globals.global_io, ".", .{ .iterate = true }) catch {
            try ctx.reply(.{ .path = ".", .entries = @as([]const Entry, &.{}) });
            return;
        };
    defer base_dir.close(io_globals.global_io);

    var iter = base_dir.iterate();
    while (try iter.next(io_globals.global_io)) |entry| {
        // Skip hidden files, build artifacts, caches
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "zig-out")) continue;
        if (std.mem.eql(u8, entry.name, "zig-cache")) continue;
        if (std.mem.eql(u8, entry.name, ".zig-cache")) continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        if (std.mem.eql(u8, entry.name, "Build")) continue;
        if (std.mem.eql(u8, entry.name, "Derived")) continue;

        const name = try ctx.allocator.dupe(u8, entry.name);
        const is_dir = entry.kind == .directory;
        try entries.append(ctx.allocator, .{
            .name = name,
            .path = name,
            .isDirectory = is_dir,
            .assetType = if (is_dir) "folder" else classifyAsset(entry.name),
        });
    }
    std.mem.sort(Entry, entries.items, {}, entryLessThan);

    try ctx.reply(.{ .path = ".", .entries = entries.items });

    for (entries.items) |e| {
        ctx.allocator.free(@constCast(e.name));
    }
}

/// Import a GLTF/GLB model into the scene at the given position.
/// Params: { path: string, position?: [x,y,z] }
/// Returns: { rootEntity: ?u64, entityCount: usize }
pub fn importModel(ctx: *Ctx) !void {
    const rel_path = try ctx.param([]const u8, "path");

    // Sanitize: reject path traversal
    if (std.mem.indexOf(u8, rel_path, "..") != null) return error.InvalidArguments;

    // Parse optional position
    var transform = components.Transform.identity();
    if (ctx.paramArray("position")) |pos_arr| {
        if (pos_arr.items.len >= 3) {
            transform.translation = .{
                coerceF32(pos_arr.items[0]),
                coerceF32(pos_arr.items[1]),
                coerceF32(pos_arr.items[2]),
            };
        }
    } else |_| {}

    const world = ctx.layer.world;
    const report = try world.importGltfStaticModel(rel_path, transform);

    try ctx.reply(.{
        .rootEntity = report.root_entity,
        .entityCount = report.entity_count,
        .meshCount = report.mesh_count,
    });
}

fn coerceF32(val: std.json.Value) f32 {
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    };
}
