const std = @import("std");
const prefab_mod = @import("prefab.zig");

/// Prefab 库 - 管理所有 Prefab 资源
pub const PrefabLibrary = struct {
    allocator: std.mem.Allocator,

    /// Prefab 资源存储
    prefabs: std.ArrayList(prefab_mod.PrefabResource) = .empty,

    /// Asset ID 到索引的映射
    prefab_by_id: std.AutoHashMap([]const u8, usize) = .empty,

    /// 文件路径到 Asset ID 的映射
    prefab_by_path: std.StringHashMap([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) PrefabLibrary {
        return .{
            .allocator = allocator,
            .prefabs = std.ArrayList(prefab_mod.PrefabResource).init(allocator),
            .prefab_by_id = std.AutoHashMap([]const u8, usize).init(allocator),
            .prefab_by_path = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *PrefabLibrary) void {
        for (self.prefabs.items) |*prefab| {
            prefab.deinit();
        }
        self.prefabs.deinit(self.allocator);
        self.prefab_by_id.deinit();
        // prefab_by_path 的值由 prefab_by_id 管理
        self.prefab_by_path.deinit();
    }

    /// 从文件加载 Prefab
    pub fn loadFromPath(self: *PrefabLibrary, path: []const u8) !prefab_mod.PrefabId {
        const prefab = try prefab_mod.loadPrefabFromPath(self.allocator, path);
        const id = try self.allocator.dupe(u8, prefab.id);
        try self.add(prefab, id, path);
        return id;
    }

    /// 保存 Prefab 到文件
    pub fn saveToPath(self: *PrefabLibrary, id: []const u8, path: []const u8) !void {
        const prefab = self.get(id) orelse return error.PrefabNotFound;
        try prefab_mod.savePrefabToPath(self.allocator, prefab, path);
    }

    /// 添加 Prefab 到库
    pub fn add(self: *PrefabLibrary, prefab: prefab_mod.PrefabResource, id: []const u8, path: ?[]const u8) !void {
        const index = self.prefabs.items.len;
        try self.prefabs.append(self.allocator, prefab);
        try self.prefab_by_id.put(id, index);
        if (path) |p| {
            try self.prefab_by_path.put(try self.allocator.dupe(u8, p), id);
        }
    }

    /// 创建新的 Prefab
    pub fn create(self: *PrefabLibrary, id: []const u8, name: []const u8) !void {
        var prefab = prefab_mod.PrefabResource.init(self.allocator, id, name);
        try self.add(prefab, id, null);
    }

    /// 获取 Prefab
    pub fn get(self: *const PrefabLibrary, id: []const u8) ?*prefab_mod.PrefabResource {
        const index = self.prefab_by_id.get(id) orelse return null;
        return &self.prefabs.items[index];
    }

    /// 通过路径获取 Prefab ID
    pub fn getIdByPath(self: *const PrefabLibrary, path: []const u8) ?[]const u8 {
        return self.prefab_by_path.get(path);
    }

    /// 移除 Prefab
    pub fn remove(self: *PrefabLibrary, id: []const u8) !void {
        const index = self.prefab_by_id.get(id) orelse return error.PrefabNotFound;
        _ = self.prefab_by_id.remove(id);

        // 从 path 映射中移除
        var it = self.prefab_by_path.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, id)) {
                self.prefab_by_path.remove(entry.key_ptr.*);
                break;
            }
        }

        // 释放资源
        self.prefabs.items[index].deinit();

        // 移除并替换
        _ = self.prefabs.swapRemove(index);

        // 更新索引映射
        var it2 = self.prefab_by_id.iterator();
        while (it2.next()) |entry| {
            if (entry.value_ptr.* > index) {
                entry.value_ptr.* -= 1;
            }
        }
    }

    /// 获取所有 Prefab IDs
    pub fn allIds(self: *const PrefabLibrary) []const []const u8 {
        var ids = self.allocator.alloc([]const u8, self.prefabs.items.len) catch unreachable;
        var it = self.prefab_by_id.iterator();
        while (it.next()) |entry| {
            ids[entry.value_ptr.*] = entry.key_ptr.*;
        }
        return ids;
    }

    /// 获取 Prefab 数量
    pub fn count(self: *const PrefabLibrary) usize {
        return self.prefabs.items.len;
    }
};
