const std = @import("std");
const io_globals = @import("io_globals");
const types = @import("types.zig");
const manifest_mod = @import("manifest.zig");

/// Backward-compatible alias — prefer using types.PluginRecord directly.
pub const Plugin = types.PluginRecord;

pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    plugins: std.StringHashMap(*types.PluginRecord),
    by_type: std.AutoArrayHashMapUnmanaged(types.PluginType, std.ArrayList(*types.PluginRecord)),
    capabilities: std.AutoArrayHashMapUnmanaged(types.PluginCapability, std.ArrayList(*types.PluginRecord)),

    pub fn init(allocator: std.mem.Allocator) !PluginRegistry {
        return .{
            .allocator = allocator,
            .plugins = std.StringHashMap(*types.PluginRecord).init(allocator),
            .by_type = .empty,
            .capabilities = .empty,
        };
    }

    pub fn deinit(self: *PluginRegistry) void {
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.plugins.deinit();

        var type_it = self.by_type.iterator();
        while (type_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.by_type.deinit(self.allocator);

        var cap_it = self.capabilities.iterator();
        while (cap_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.capabilities.deinit(self.allocator);
    }

    pub fn register(self: *PluginRegistry, record: *types.PluginRecord) !void {
        const name = record.manifest.name;

        if (self.plugins.contains(name)) {
            return error.PluginAlreadyLoaded;
        }

        try self.plugins.put(name, record);

        const plugin_type_list = self.by_type.getOrPut(self.allocator, record.manifest.plugin_type) catch return error.OutOfMemory;
        if (!plugin_type_list.found_existing) {
            plugin_type_list.value_ptr.* = .empty;
        }
        try plugin_type_list.value_ptr.append(self.allocator, record);

        for (record.manifest.capabilities) |cap| {
            const cap_list = self.capabilities.getOrPut(self.allocator, cap) catch return error.OutOfMemory;
            if (!cap_list.found_existing) {
                cap_list.value_ptr.* = .empty;
            }
            try cap_list.value_ptr.append(self.allocator, record);
        }
    }

    pub fn getByName(self: *const PluginRegistry, name: []const u8) ?*const types.PluginRecord {
        return self.plugins.get(name);
    }

    pub fn getByType(self: *const PluginRegistry, plugin_type: types.PluginType) []const *types.PluginRecord {
        const list = self.by_type.get(plugin_type) orelse return &.{};
        return list.items;
    }

    pub fn getWithCapability(self: *const PluginRegistry, capability: types.PluginCapability) []const *types.PluginRecord {
        const list = self.capabilities.get(capability) orelse return &.{};
        return list.items;
    }

    pub fn isLoaded(self: *const PluginRegistry, name: []const u8) bool {
        return self.plugins.contains(name);
    }

    /// Discover plugins from a directory tree (engine/user/project).
    /// Iterates subdirectories of `root_path`, reads `manifest.json` from
    /// each, and registers a `PluginRecord` for every valid manifest.
    pub fn discover(self: *PluginRegistry, root_path: []const u8) !void {
        var dir = std.Io.Dir.cwd().openDir(io_globals.global_io, root_path, .{ .iterate = true }) catch |err| {
            std.log.warn("PluginRegistry: cannot open directory '{s}': {s}", .{ root_path, @errorName(err) });
            return;
        };
        defer dir.close(io_globals.global_io);

        var it = dir.iterate();
        while (try it.next(io_globals.global_io)) |entry| {
            if (entry.kind != .directory) continue;

            const manifest_path = std.fs.path.join(self.allocator, &.{ root_path, entry.name, "manifest.json" }) catch continue;
            defer self.allocator.free(manifest_path);

            const content = std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, manifest_path, self.allocator, .limited(64 * 1024)) catch continue;
            defer self.allocator.free(content);

            var plugin_manifest = manifest_mod.parseManifest(self.allocator, content) catch continue;
            errdefer plugin_manifest.deinit(self.allocator);

            // Set the path field (parseManifest does not know about file paths).
            plugin_manifest.path = self.allocator.dupe(u8, manifest_path) catch continue;

            const record = self.allocator.create(types.PluginRecord) catch continue;
            record.* = .{
                .manifest = plugin_manifest,
                .lifecycle = .loaded,
            };

            self.register(record) catch {
                record.deinit(self.allocator);
                self.allocator.destroy(record);
                continue;
            };
        }
    }

    /// Transition a plugin to the enabled state.
    pub fn enable(self: *PluginRegistry, name: []const u8) !void {
        const record = self.plugins.get(name) orelse return error.PluginNotFound;
        if (record.lifecycle == .load_error) return error.PluginInErrorState;
        record.lifecycle = .enabled;
    }

    /// Transition a plugin to the loaded (disabled) state.
    pub fn disable(self: *PluginRegistry, name: []const u8) !void {
        const record = self.plugins.get(name) orelse return error.PluginNotFound;
        if (record.lifecycle == .enabled) {
            record.lifecycle = .loaded;
        }
    }

    /// Fully unload and remove a plugin from all indices.
    pub fn unload(self: *PluginRegistry, name: []const u8) !void {
        const record_ptr = self.plugins.get(name) orelse return error.PluginNotFound;

        // Remove from by_type index
        if (self.by_type.getPtr(record_ptr.manifest.plugin_type)) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == record_ptr) {
                    _ = list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        // Remove from capability indices
        for (record_ptr.manifest.capabilities) |cap| {
            if (self.capabilities.getPtr(cap)) |list| {
                var i: usize = 0;
                while (i < list.items.len) {
                    if (list.items[i] == record_ptr) {
                        _ = list.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }
        }

        // Remove from main map, free record
        _ = self.plugins.remove(name);
        record_ptr.deinit(self.allocator);
        self.allocator.destroy(record_ptr);
    }

    /// Startup recovery: scan all plugins and apply error policies.
    /// - `skip_on_error`: leave in load_error, user can retry manually.
    /// - `retry_once`: if error_retry_count < 1, reset to .loaded for
    ///   re-discovery; otherwise leave in load_error.
    /// - `disable_permanently`: mark as .unloaded (effectively disabled).
    /// Returns the number of plugins that were reset for retry.
    pub fn applyStartupRecovery(self: *PluginRegistry) usize {
        var retry_count: usize = 0;
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            const record = entry.value_ptr.*;
            if (record.lifecycle != .load_error) continue;

            switch (record.error_policy) {
                .skip_on_error => {
                    // Leave in load_error — user can retry via Plugin Manager.
                },
                .retry_once => {
                    if (record.error_retry_count < 1) {
                        record.error_retry_count += 1;
                        record.lifecycle = .loaded;
                        record.clearLastError(self.allocator);
                        retry_count += 1;
                    }
                    // else: already retried once — leave in load_error.
                },
                .disable_permanently => {
                    record.lifecycle = .unloaded;
                },
            }
        }
        return retry_count;
    }
};

test "plugin registry init and deinit" {
    const allocator = std.testing.allocator;
    var registry = try PluginRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expect(registry.plugins.count() == 0);
}

test "plugin registry register and query" {
    const allocator = std.testing.allocator;
    var registry = try PluginRegistry.init(allocator);
    defer registry.deinit();

    const manifest = types.PluginManifest{
        .name = @constCast("test_plugin"),
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .plugin_type = .render_style,
        .source = .project,
    };

    const record = try allocator.create(types.PluginRecord);
    record.* = .{ .manifest = manifest, .lifecycle = .loaded };

    try registry.register(record);

    try std.testing.expectEqual(@as(usize, 1), registry.plugins.count());
    try std.testing.expect(registry.isLoaded("test_plugin"));

    const by_name = registry.getByName("test_plugin");
    try std.testing.expect(by_name != null);
    try std.testing.expectEqualSlices(u8, "test_plugin", by_name.?.getName());

    const render_styles = registry.getByType(.render_style);
    try std.testing.expectEqual(@as(usize, 1), render_styles.len);
    try std.testing.expectEqualSlices(u8, "test_plugin", render_styles[0].getName());

    // Duplicate registration should fail
    const record2 = try allocator.create(types.PluginRecord);
    record2.* = .{ .manifest = manifest, .lifecycle = .loaded };
    try std.testing.expectError(error.PluginAlreadyLoaded, registry.register(record2));
    allocator.destroy(record2);
}

test "plugin registry enable disable lifecycle" {
    const allocator = std.testing.allocator;
    var registry = try PluginRegistry.init(allocator);
    defer registry.deinit();

    const manifest = types.PluginManifest{
        .name = @constCast("lifecycle_test"),
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .plugin_type = .script_vm,
        .source = .user,
    };

    const record = try allocator.create(types.PluginRecord);
    record.* = .{ .manifest = manifest, .lifecycle = .loaded };
    try registry.register(record);

    // Start as loaded
    try std.testing.expectEqual(types.PluginLifecycle.loaded, record.lifecycle);

    // Enable
    try registry.enable("lifecycle_test");
    try std.testing.expectEqual(types.PluginLifecycle.enabled, record.lifecycle);

    // Disable
    try registry.disable("lifecycle_test");
    try std.testing.expectEqual(types.PluginLifecycle.loaded, record.lifecycle);

    // Cannot enable a plugin in error state
    record.lifecycle = .load_error;
    try std.testing.expectError(error.PluginInErrorState, registry.enable("lifecycle_test"));

    // Enable/disable non-existent plugin
    try std.testing.expectError(error.PluginNotFound, registry.enable("nope"));
    try std.testing.expectError(error.PluginNotFound, registry.disable("nope"));
}

test "plugin registry unload removes from all indices" {
    const allocator = std.testing.allocator;
    var registry = try PluginRegistry.init(allocator);
    defer registry.deinit();

    const caps = try allocator.dupe(types.PluginCapability, &.{ .shader, .render_pass });

    const manifest = types.PluginManifest{
        .name = try allocator.dupe(u8, "to_unload"),
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .plugin_type = .render_style,
        .capabilities = caps,
        .source = .project,
    };

    const record = try allocator.create(types.PluginRecord);
    record.* = .{ .manifest = manifest, .lifecycle = .loaded };
    try registry.register(record);

    // Verify it's in all indices
    try std.testing.expectEqual(@as(usize, 1), registry.plugins.count());
    try std.testing.expectEqual(@as(usize, 1), registry.getByType(.render_style).len);
    try std.testing.expectEqual(@as(usize, 1), registry.getWithCapability(.shader).len);
    try std.testing.expectEqual(@as(usize, 1), registry.getWithCapability(.render_pass).len);

    // Unload
    try registry.unload("to_unload");

    // Verify removed from all indices
    try std.testing.expectEqual(@as(usize, 0), registry.plugins.count());
    try std.testing.expect(!registry.isLoaded("to_unload"));
    try std.testing.expectEqual(@as(usize, 0), registry.getByType(.render_style).len);
    try std.testing.expectEqual(@as(usize, 0), registry.getWithCapability(.shader).len);
    try std.testing.expectEqual(@as(usize, 0), registry.getWithCapability(.render_pass).len);

    // Unload non-existent
    try std.testing.expectError(error.PluginNotFound, registry.unload("to_unload"));
}

test "plugin record error state" {
    const allocator = std.testing.allocator;
    const manifest = types.PluginManifest{
        .name = @constCast("err_test"),
        .version = .{ .major = 1, .minor = 0, .patch = 0 },
        .plugin_type = .render_style,
        .source = .user,
    };
    var record = types.PluginRecord{ .manifest = manifest, .lifecycle = .loaded };

    // Set error
    record.setLastError(allocator, "something went wrong");
    try std.testing.expect(record.last_error != null);
    try std.testing.expectEqualSlices(u8, "something went wrong", record.last_error.?);

    // Overwrite error
    record.setLastError(allocator, "new error");
    try std.testing.expectEqualSlices(u8, "new error", record.last_error.?);

    // Clear error
    record.clearLastError(allocator);
    try std.testing.expect(record.last_error == null);
}
