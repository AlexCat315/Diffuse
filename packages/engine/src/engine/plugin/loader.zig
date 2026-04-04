const std = @import("std");
const types = @import("types.zig");

const log = std.log.scoped(.plugin_loader);

/// Type-erased interface for plugin type-specific loaders.
///
/// Each plugin type (render_style, script_vm, etc.) implements this
/// interface so the Renderer can dispatch to them uniformly via
/// `TypedLoaderRegistry` without hardcoding per-type branches.
///
/// Loaders own the subsystem-specific interpretation of a PluginRecord:
///   - `onDiscover`:  Validate and prepare (parse typed payload, check assets)
///   - `onEnable`:    Activate subsystem-side resources (register style, load plugin)
///   - `onDisable`:   Deactivate without destroying (rollback active state)
///   - `onUnload`:    Full teardown of subsystem-side resources
pub const PluginLoader = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called after PluginRegistry.discover() for each new record of this type.
        /// Should validate the plugin and set lifecycle to .loaded or .load_error.
        on_discover: *const fn (ctx: *anyopaque, record: *types.PluginRecord) void,
        /// Called when a loaded plugin transitions to enabled.
        /// Performs subsystem-specific activation (e.g. register style, load plugin module).
        on_enable: *const fn (ctx: *anyopaque, record: *types.PluginRecord) void,
        /// Called when an enabled plugin transitions to loaded (disabled).
        /// Performs subsystem-specific deactivation without full teardown.
        on_disable: *const fn (ctx: *anyopaque, record: *types.PluginRecord) void,
        /// Called when a plugin is fully unloaded.
        /// Performs full subsystem-side resource teardown.
        on_unload: *const fn (ctx: *anyopaque, record: *types.PluginRecord) void,
    };

    pub fn onDiscover(self: PluginLoader, record: *types.PluginRecord) void {
        self.vtable.on_discover(self.context, record);
    }

    pub fn onEnable(self: PluginLoader, record: *types.PluginRecord) void {
        self.vtable.on_enable(self.context, record);
    }

    pub fn onDisable(self: PluginLoader, record: *types.PluginRecord) void {
        self.vtable.on_disable(self.context, record);
    }

    pub fn onUnload(self: PluginLoader, record: *types.PluginRecord) void {
        self.vtable.on_unload(self.context, record);
    }
};

/// Registry mapping PluginType → PluginLoader.
/// Renderer populates this at init time, then uses it for all lifecycle dispatch.
pub const TypedLoaderRegistry = struct {
    loaders: std.AutoArrayHashMap(types.PluginType, PluginLoader),

    pub fn init(allocator: std.mem.Allocator) TypedLoaderRegistry {
        return .{
            .loaders = std.AutoArrayHashMap(types.PluginType, PluginLoader).init(allocator),
        };
    }

    pub fn deinit(self: *TypedLoaderRegistry) void {
        self.loaders.deinit();
    }

    pub fn register(self: *TypedLoaderRegistry, plugin_type: types.PluginType, loader: PluginLoader) !void {
        try self.loaders.put(plugin_type, loader);
    }

    pub fn get(self: *const TypedLoaderRegistry, plugin_type: types.PluginType) ?PluginLoader {
        return self.loaders.get(plugin_type);
    }

    /// Dispatch `onDiscover` to the appropriate loader for each record of the given type.
    /// Skips records already in .enabled or .load_error state.
    pub fn dispatchDiscover(self: *const TypedLoaderRegistry, records: []const *types.PluginRecord) void {
        for (records) |record| {
            if (record.lifecycle == .enabled) continue;
            if (record.lifecycle == .load_error) continue;
            const loader = self.loaders.get(record.manifest.plugin_type) orelse continue;
            loader.onDiscover(record);
        }
    }

    /// Dispatch `onDiscover` for all registered types from a PluginRegistry.
    pub fn dispatchAllDiscover(self: *const TypedLoaderRegistry, plugin_registry: anytype) void {
        var it = self.loaders.iterator();
        while (it.next()) |entry| {
            const plugin_type = entry.key_ptr.*;
            const loader = entry.value_ptr.*;
            const records = plugin_registry.getByType(plugin_type);
            for (records) |record| {
                if (record.lifecycle == .enabled) continue;
                if (record.lifecycle == .load_error) continue;
                loader.onDiscover(record);
            }
        }
    }
};

test "TypedLoaderRegistry init and deinit" {
    const allocator = std.testing.allocator;
    var registry = TypedLoaderRegistry.init(allocator);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 0), registry.loaders.count());
}
