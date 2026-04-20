const std = @import("std");
const io_globals = @import("io_globals");
const types = @import("./types.zig");
const runtime_mod = @import("./runtime.zig");
const handles = @import("../assets/handles.zig");

const log = std.log.scoped(.hot_reload);

const WatchedScript = struct {
    handle: handles.ScriptHandle,
    last_mtime: i96,
};

/// 热重载管理器
pub const HotReloadManager = struct {
    /// 已注册脚本文件
    watched_scripts: std.StringHashMap(WatchedScript),
    /// 待重载的脚本列表
    pending_reload: std.ArrayList(handles.ScriptHandle),
    /// 运行时引用
    runtime: *runtime_mod.ScriptRuntime,
    /// 分配器
    allocator: std.mem.Allocator,
    /// 上次检查文件变更的时间戳（纳秒）
    last_check_timestamp: i96 = 0,

    pub fn init(allocator: std.mem.Allocator, rt: *runtime_mod.ScriptRuntime) HotReloadManager {
        return .{
            .watched_scripts = std.StringHashMap(WatchedScript).init(allocator),
            .pending_reload = .empty,
            .runtime = rt,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HotReloadManager) void {
        var keys = self.watched_scripts.keyIterator();
        while (keys.next()) |key| {
            self.allocator.free(key.*);
        }
        self.watched_scripts.deinit();
        self.pending_reload.deinit(self.allocator);
    }

    /// 注册脚本文件
    pub fn registerScript(self: *HotReloadManager, path: []const u8, handle: handles.ScriptHandle) !void {
        if (self.watched_scripts.getEntry(path)) |entry| {
            entry.value_ptr.* = .{
                .handle = handle,
                .last_mtime = getFileMtime(path) catch entry.value_ptr.last_mtime,
            };
            return;
        }

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        const mtime = getFileMtime(path) catch 0;
        try self.watched_scripts.put(path_copy, .{
            .handle = handle,
            .last_mtime = mtime,
        });
    }

    /// 检查是否有脚本需要重载（节流：最多每秒检查一次）
    pub fn checkForChanges(self: *HotReloadManager) void {
        const now = std.Io.Timestamp.now(io_globals.global_io, .boot).nanoseconds;
        const elapsed_ns = now - self.last_check_timestamp;
        if (elapsed_ns < 1_000_000_000) return; // throttle to once per second
        self.last_check_timestamp = now;

        self.pending_reload.clearRetainingCapacity();

        var it = self.watched_scripts.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const watched_script = entry.value_ptr;

            const current_mtime = getFileMtime(path) catch continue;
            if (current_mtime > watched_script.last_mtime) {
                // 文件已修改，标记待重载
                log.info("Script file modified: {s}", .{path});
                self.pending_reload.append(self.allocator, watched_script.handle) catch |err| {
                    log.err("Failed to queue hot reload for {s}: {}", .{ path, err });
                    continue;
                };
                watched_script.last_mtime = current_mtime;
            }
        }
    }

    /// 处理待重载的脚本
    pub fn processPendingReload(self: *HotReloadManager) void {
        for (self.pending_reload.items) |handle| {
            self.reloadScript(handle) catch |err| {
                log.err("Failed to hot reload script {}: {}", .{ handle, err });
            };
        }
    }

    /// 触发单个脚本重载
    pub fn reloadScript(self: *HotReloadManager, handle: handles.ScriptHandle) !void {
        try self.runtime.reloadScript(handle);
    }
};

/// 获取文件修改时间
fn getFileMtime(path: []const u8) !i96 {
    const file = try std.Io.Dir.cwd().openFile(io_globals.global_io, path, .{});
    defer file.close(io_globals.global_io);

    const stat = try file.stat(io_globals.global_io);
    return stat.mtime.nanoseconds;
}

/// 文件监听器（未来可扩展为操作系统原生监听）
pub const FileWatcher = struct {
    /// 监听的文件路径
    paths: std.ArrayList([]const u8),
    /// 分配器
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FileWatcher {
        return .{
            .paths = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        for (self.paths.items) |path| {
            self.allocator.free(path);
        }
        self.paths.deinit(self.allocator);
    }

    /// 添加监听路径
    pub fn addPath(self: *FileWatcher, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        try self.paths.append(self.allocator, path_copy);
    }

    /// 检查变更（轮询实现）
    pub fn pollChanges(self: *FileWatcher, last_mtimes: *std.AutoHashMap([]const u8, i96)) void {
        for (self.paths.items) |path| {
            const current_mtime = getFileMtime(path) catch continue;
            if (last_mtimes.get(path)) |last_mtime| {
                if (current_mtime > last_mtime) {
                    log.info("File changed: {s}", .{path});
                }
            }
            last_mtimes.put(path, current_mtime) catch {};
        }
    }
};
