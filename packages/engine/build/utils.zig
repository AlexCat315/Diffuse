const std = @import("std");
const Io = std.Io;

/// Run an external command and return its trimmed stdout, or null on failure.
pub fn captureCommandOutput(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = argv,
    }) catch return null;
    defer {
        b.allocator.free(result.stdout);
        b.allocator.free(result.stderr);
    }

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
    return b.allocator.dupe(u8, trimmed) catch @panic("OOM");
}

/// Recursively collect source files with the given extension under `root`.
pub fn collectSourceFiles(b: *std.Build, root: []const u8, extension: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(b.allocator);

    var dir = Io.Dir.cwd().openDir(b.graph.io, root, .{ .iterate = true }) catch |err| {
        std.debug.panic("failed to open source root {s}: {s}", .{ root, @errorName(err) });
    };
    defer dir.close(b.graph.io);

    var walker = dir.walk(b.allocator) catch |err| {
        std.debug.panic("failed to walk source root {s}: {s}", .{ root, @errorName(err) });
    };
    defer walker.deinit();

    while (walker.next(b.graph.io) catch |err| {
        std.debug.panic("failed to iterate source root {s}: {s}", .{ root, @errorName(err) });
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, extension)) {
            continue;
        }
        list.append(b.allocator, b.pathJoin(&.{ root, entry.path })) catch @panic("OOM");
    }

    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}
