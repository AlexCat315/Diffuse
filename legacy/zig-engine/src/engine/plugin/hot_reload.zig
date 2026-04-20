const std = @import("std");
const io_globals = @import("io_globals");
const types = @import("types.zig");

const log = std.log.scoped(.plugin_hot_reload);

/// Polls registered plugin directories for manifest.json changes.
///
/// Usage:
///   1. `registerDirectory(root_path)` for each plugin root.
///   2. Call `tick()` once per frame (internally throttled to 1 s).
///   3. Consume `pending_changes` to trigger unload/re-discover.
pub const PluginHotReloadManager = struct {
    allocator: std.mem.Allocator,

    /// Root directories being watched.
    watched_dirs: std.StringHashMap(WatchedDir),

    /// Plugin names whose manifest changed since last `tick()`.
    /// Caller should drain this after each tick.
    pending_changes: std.ArrayListUnmanaged([]const u8) = .empty,

    last_check_timestamp: i96 = 0,

    /// Minimum interval between checks (1 second in nanoseconds).
    const check_interval_ns: i96 = 1_000_000_000;

    const WatchedDir = struct {
        /// mtime of the latest-modified manifest.json in this tree.
        last_mtime: i128 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) PluginHotReloadManager {
        return .{
            .allocator = allocator,
            .watched_dirs = std.StringHashMap(WatchedDir).init(allocator),
        };
    }

    pub fn deinit(self: *PluginHotReloadManager) void {
        // Free duped keys
        var it = self.watched_dirs.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.watched_dirs.deinit();

        // Free duped pending names
        for (self.pending_changes.items) |name| {
            self.allocator.free(name);
        }
        self.pending_changes.deinit(self.allocator);
    }

    /// Register a plugin root directory for watching.
    pub fn registerDirectory(self: *PluginHotReloadManager, root_path: []const u8) void {
        if (self.watched_dirs.contains(root_path)) return;
        const key = self.allocator.dupe(u8, root_path) catch return;
        self.watched_dirs.put(key, .{}) catch {
            self.allocator.free(key);
        };
    }

    /// Called once per frame.  Checks all watched directories for
    /// manifest.json mtime changes (throttled to 1 s).
    pub fn tick(self: *PluginHotReloadManager) void {
        const now = std.Io.Timestamp.now(io_globals.global_io, .boot).nanoseconds;
        const elapsed = now - self.last_check_timestamp;
        if (elapsed < check_interval_ns) return;
        self.last_check_timestamp = now;

        // Clear previous pending list
        for (self.pending_changes.items) |name| {
            self.allocator.free(name);
        }
        self.pending_changes.clearRetainingCapacity();

        var dir_it = self.watched_dirs.iterator();
        while (dir_it.next()) |entry| {
            const root_path = entry.key_ptr.*;
            self.scanDirectory(root_path, entry.value_ptr);
        }
    }

    /// Returns the list of plugin names that changed since last tick.
    /// Names are owned by this manager; valid until next `tick()`.
    pub fn pendingChanges(self: *const PluginHotReloadManager) []const []const u8 {
        return self.pending_changes.items;
    }

    fn scanDirectory(self: *PluginHotReloadManager, root_path: []const u8, watched: *WatchedDir) void {
        var dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch return) |entry| {
            if (entry.kind != .directory) continue;

            const manifest_path = std.fs.path.join(self.allocator, &.{ root_path, entry.name, "manifest.json" }) catch continue;
            defer self.allocator.free(manifest_path);

            const mtime = getFileMtime(manifest_path) orelse continue;

            if (mtime > watched.last_mtime) {
                watched.last_mtime = mtime;
                const name = self.allocator.dupe(u8, entry.name) catch continue;
                self.pending_changes.append(self.allocator, name) catch {
                    self.allocator.free(name);
                };
                log.info("plugin manifest changed: {s}", .{entry.name});
            }
        }
    }

    fn getFileMtime(path: []const u8) ?i128 {
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        const stat = file.stat() catch return null;
        return stat.mtime;
    }
};

test "PluginHotReloadManager init and deinit" {
    const allocator = std.testing.allocator;
    var mgr = PluginHotReloadManager.init(allocator);
    defer mgr.deinit();
    try std.testing.expectEqual(@as(usize, 0), mgr.watched_dirs.count());
}
