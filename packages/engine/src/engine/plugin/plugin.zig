const std = @import("std");
const types = @import("types.zig");
const registry = @import("registry.zig");
const manifest = @import("manifest.zig");
const loader_mod = @import("loader.zig");
const hot_reload_mod = @import("hot_reload.zig");

pub const PluginType = types.PluginType;
pub const PluginCapability = types.PluginCapability;
pub const PluginSource = types.PluginSource;
pub const PluginLifecycle = types.PluginLifecycle;
pub const PluginErrorPolicy = types.PluginErrorPolicy;
pub const PluginVersion = types.PluginVersion;
pub const PluginManifest = types.PluginManifest;
pub const PluginRecord = types.PluginRecord;
pub const Plugin = registry.Plugin;
pub const PluginRegistry = registry.PluginRegistry;
pub const PluginLoader = loader_mod.PluginLoader;
pub const TypedLoaderRegistry = loader_mod.TypedLoaderRegistry;
pub const PluginHotReloadManager = hot_reload_mod.PluginHotReloadManager;
pub const parseManifest = manifest.parseManifest;

pub fn createRegistry(allocator: std.mem.Allocator) !registry.PluginRegistry {
    return try registry.PluginRegistry.init(allocator);
}
