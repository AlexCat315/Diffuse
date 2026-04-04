///! handlers/assets.zig — asset browser & file management.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

/// List contents of a directory under the project root.
/// Defaults to "assets" if no path is provided.
pub fn list(ctx: *Ctx) !void {
    const rel_path = (try ctx.paramOpt([]const u8, "path")) orelse "assets";

    // Sanitize: reject absolute paths and path traversal
    if (rel_path.len > 0 and rel_path[0] == '/') return error.InvalidArguments;
    if (std.mem.indexOf(u8, rel_path, "..") != null) return error.InvalidArguments;

    var entries = std.ArrayList(Entry).empty;
    defer entries.deinit(ctx.allocator);

    const dir = std.fs.cwd().openDir(rel_path, .{ .iterate = true }) catch {
        try ctx.reply(.{
            .path = rel_path,
            .entries = @as([]const Entry, &.{}),
        });
        return;
    };

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
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
