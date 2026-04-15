const std = @import("std");
const io_globals = @import("io_globals");
const plugin_types = @import("../plugin/types.zig");
const loader_mod = @import("../plugin/loader.zig");

/// Configurable parameter exposed by a render style plugin.
pub const StyleParam = struct {
    name: []const u8,
    display_name: []const u8 = "",
    param_type: ParamType = .float,
    default_value: f32 = 0.0,
    min_value: f32 = 0.0,
    max_value: f32 = 1.0,

    pub const ParamType = enum {
        float,
        int,
        boolean,
        color3,
    };
};

/// Execution stage for a post-process pass injected by a style plugin.
pub const StylePassStage = enum {
    post_lighting,
    post_tonemap,
    pre_ui,
};

/// Descriptor for a single post-process pass contributed by a style plugin.
/// Declares execution stage, resource dependencies, and ordering constraints
/// so `RenderGraph` can safely schedule barriers and resource aliasing.
pub const StylePostPassDescriptor = struct {
    name: []const u8,
    shader_program: []const u8,
    stage: StylePassStage = .post_lighting,
    reads: []const []const u8 = &.{},
    writes: []const []const u8 = &.{},
    order_after: ?[]const u8 = null,
    order_before: ?[]const u8 = null,
};

/// Manifest describing a render style plugin's capabilities and shaders.
/// This is the typed payload for `render_style` plugins; `PluginManifest`
/// (in plugin/types.zig) holds the common shell (name, version, source, deps).
pub const StylePluginManifest = struct {
    name: []const u8,
    display_name: []const u8 = "",
    version: []const u8 = "1.0.0",
    source: plugin_types.PluginSource = .builtin,
    path: ?[]const u8 = null,

    /// Shader program name for mesh rendering.
    mesh_program: []const u8 = "mesh",
    /// Optional override shader program for shadows.
    shadow_program: ?[]const u8 = null,
    /// Built-in passes to disable when this style is active (e.g. "bloom", "taa").
    disabled_passes: []const []const u8 = &.{},
    /// User-tunable parameters for this style.
    config_schema: []const StyleParam = &.{},
    /// Post-process pass chain contributed by this style.
    /// Phase C feature — loaded but not yet injected into RenderGraph.
    post_chain: []const StylePostPassDescriptor = &.{},
};

/// Default PBR render style — maps to the built-in "mesh" shader program.
pub const default_pbr_style = StylePluginManifest{
    .name = "default_pbr",
    .display_name = "PBR (Default)",
    .version = "1.0.0",
    .source = .builtin,
    .mesh_program = "mesh",
    .shadow_program = "shadow_pass",
};

/// Unlit flat-color style — no lighting, just albedo output.
pub const unlit_flat_style = StylePluginManifest{
    .name = "unlit_flat",
    .display_name = "Unlit Flat",
    .version = "1.0.0",
    .source = .builtin,
    .mesh_program = "mesh",
    .shadow_program = null,
    .disabled_passes = &.{ "bloom", "ssr" },
    .config_schema = &.{
        .{ .name = "opacity", .display_name = "Opacity", .param_type = .float, .default_value = 1.0, .min_value = 0.0, .max_value = 1.0 },
    },
};

/// Runtime storage for parameter values set by the user for a given style.
pub const StyleParamValues = struct {
    allocator: std.mem.Allocator,
    values: std.StringHashMap(f32),

    pub fn init(allocator: std.mem.Allocator) StyleParamValues {
        return .{ .allocator = allocator, .values = std.StringHashMap(f32).init(allocator) };
    }

    pub fn deinit(self: *StyleParamValues) void {
        self.values.deinit();
    }

    pub fn set(self: *StyleParamValues, name: []const u8, value: f32) !void {
        try self.values.put(name, value);
    }

    pub fn get(self: *const StyleParamValues, name: []const u8, default: f32) f32 {
        return self.values.get(name) orelse default;
    }
};

/// Per-style heap allocations tracked for individual unload.
const StyleAlloc = struct {
    /// Raw JSON content buffer — parsed string slices point into this.
    content_buf: []u8,
    /// Allocator-owned directory path copy.
    path_buf: []u8,
};

/// Registry managing all available render styles and tracking the active one.
/// This is the typed runtime owner for `render_style` plugins.
/// `PluginRegistry` handles discovery/lifecycle; `StyleRegistry` handles
/// shader selection, parameters, and activation.
///
/// Ownership: Builtin styles use comptime string literals and are never freed.
/// User/project styles hold allocator-owned strings (`name`, `display_name`,
/// `path`, etc.) tracked in `style_allocs`.  `deinit()` and `unregister()`
/// release them.
pub const StyleRegistry = struct {
    allocator: std.mem.Allocator,
    styles: std.StringHashMap(StylePluginManifest),
    active_style_name: []const u8,
    previous_style_name: []const u8,
    param_values: std.StringHashMap(StyleParamValues),
    /// Per-style allocation records for user/project plugins.
    /// Keyed by style name (same slice as in `styles`).
    style_allocs: std.StringHashMap(StyleAlloc),

    pub fn init(allocator: std.mem.Allocator) StyleRegistry {
        var registry = StyleRegistry{
            .allocator = allocator,
            .styles = std.StringHashMap(StylePluginManifest).init(allocator),
            .active_style_name = "default_pbr",
            .previous_style_name = "default_pbr",
            .param_values = std.StringHashMap(StyleParamValues).init(allocator),
            .style_allocs = std.StringHashMap(StyleAlloc).init(allocator),
        };
        // Always register the builtin styles
        registry.styles.put(default_pbr_style.name, default_pbr_style) catch {};
        registry.styles.put(unlit_flat_style.name, unlit_flat_style) catch {};
        return registry;
    }

    pub fn deinit(self: *StyleRegistry) void {
        var it = self.param_values.iterator();
        while (it.next()) |entry| {
            var pv = entry.value_ptr.*;
            pv.deinit();
        }
        self.param_values.deinit();
        self.styles.deinit();
        var alloc_it = self.style_allocs.iterator();
        while (alloc_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.path_buf);
            self.allocator.free(entry.value_ptr.content_buf);
        }
        self.style_allocs.deinit();
    }

    pub fn register(self: *StyleRegistry, manifest: StylePluginManifest) !void {
        if (self.styles.contains(manifest.name)) {
            return error.StyleAlreadyRegistered;
        }
        try self.styles.put(manifest.name, manifest);
    }

    /// Remove a user/project style and free its per-style allocations.
    /// Builtins (no entry in `style_allocs`) are silently ignored.
    /// If the removed style was active, falls back to `default_pbr`.
    pub fn unregister(self: *StyleRegistry, name: []const u8) void {
        // Active/previous style rollback
        if (std.mem.eql(u8, self.active_style_name, name)) {
            self.active_style_name = "default_pbr";
        }
        if (std.mem.eql(u8, self.previous_style_name, name)) {
            self.previous_style_name = "default_pbr";
        }

        // Remove param values
        if (self.param_values.fetchRemove(name)) |kv| {
            var pv = kv.value;
            pv.deinit();
        }

        // Remove from styles map
        _ = self.styles.remove(name);

        // Free per-style owned allocations
        if (self.style_allocs.fetchRemove(name)) |kv| {
            self.allocator.free(kv.value.path_buf);
            self.allocator.free(kv.value.content_buf);
        }
    }

    /// Switch active style. Returns false if the style doesn't exist.
    /// Saves previous style for rollback.
    pub fn setActiveStyle(self: *StyleRegistry, name: []const u8) bool {
        if (self.styles.contains(name)) {
            self.previous_style_name = self.active_style_name;
            self.active_style_name = name;
            return true;
        }
        return false;
    }

    /// Rollback to the previously active style (e.g. on switch failure).
    pub fn rollbackStyle(self: *StyleRegistry) void {
        self.active_style_name = self.previous_style_name;
    }

    pub fn getActiveStyle(self: *const StyleRegistry) StylePluginManifest {
        return self.styles.get(self.active_style_name) orelse default_pbr_style;
    }

    pub fn getStyle(self: *const StyleRegistry, name: []const u8) ?StylePluginManifest {
        return self.styles.get(name);
    }

    pub fn styleCount(self: *const StyleRegistry) usize {
        return self.styles.count();
    }

    pub fn styleIterator(self: *const StyleRegistry) std.StringHashMap(StylePluginManifest).Iterator {
        return self.styles.iterator();
    }

    /// Check whether a given built-in pass should be disabled by the active style.
    pub fn isPassDisabledByActiveStyle(self: *const StyleRegistry, pass_name: []const u8) bool {
        const style = self.getActiveStyle();
        for (style.disabled_passes) |disabled| {
            if (std.mem.eql(u8, disabled, pass_name)) return true;
        }
        return false;
    }

    /// Get or create the runtime parameter values for a style.
    pub fn getParamValues(self: *StyleRegistry, style_name: []const u8) !*StyleParamValues {
        const result = try self.param_values.getOrPut(style_name);
        if (!result.found_existing) {
            result.value_ptr.* = StyleParamValues.init(self.allocator);
        }
        return result.value_ptr;
    }

    /// Load a user plugin manifest from a directory path.
    /// Expects `dir_path/manifest.json` with the structure documented in R-9.
    ///
    /// Ownership: the raw JSON buffer is appended to `owned_buffers` so that
    /// string slices parsed from it (name, display_name, …) stay valid for
    /// the lifetime of the registry.  The dir_path copy goes to `owned_paths`.
    pub fn loadUserPlugin(self: *StyleRegistry, dir_path: []const u8) !void {
        const manifest_path = try std.fs.path.join(self.allocator, &.{ dir_path, "manifest.json" });
        defer self.allocator.free(manifest_path);

        const content = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, manifest_path, self.allocator, .limited(64 * 1024));
        errdefer self.allocator.free(content);

        const RenderStyleJson = struct {
            display_name: []const u8 = "",
            mesh_program: []const u8 = "mesh",
            shadow_program: ?[]const u8 = null,
            disabled_passes: []const []const u8 = &.{},
        };
        const ManifestJson = struct {
            name: []const u8,
            version: []const u8 = "1.0.0",
            plugin_type: []const u8 = "render_style",
            source: []const u8 = "project",
            render_style: ?RenderStyleJson = null,
        };

        // parseFromSlice returns slices that point into `content`.
        // We keep `content` alive in `owned_buffers` so those slices remain valid.
        const parsed = std.json.parseFromSlice(ManifestJson, self.allocator, content, .{ .ignore_unknown_fields = true }) catch return error.InvalidManifest;
        // Note: we intentionally do NOT defer parsed.deinit() — the arena
        // backing nested slices (disabled_passes array) must stay alive.
        // Both `content` and `parsed` are freed on registry deinit via owned_buffers.

        const m = parsed.value;
        if (!std.mem.eql(u8, m.plugin_type, "render_style")) return error.NotRenderStylePlugin;

        const rs = m.render_style orelse return error.MissingRenderStylePayload;

        const source: plugin_types.PluginSource = if (std.mem.eql(u8, m.source, "project"))
            .project
        else if (std.mem.eql(u8, m.source, "user"))
            .user
        else
            .builtin;

        const path_copy = try self.allocator.dupe(u8, dir_path);
        errdefer self.allocator.free(path_copy);

        const style_manifest = StylePluginManifest{
            .name = m.name,
            .display_name = rs.display_name,
            .version = m.version,
            .source = source,
            .path = path_copy,
            .mesh_program = rs.mesh_program,
            .shadow_program = rs.shadow_program,
            .disabled_passes = rs.disabled_passes,
        };

        try self.register(style_manifest);

        // Track per-style allocations — only after register succeeds.
        try self.style_allocs.put(m.name, .{
            .content_buf = content,
            .path_buf = path_copy,
        });
    }

    /// Register a render_style directly from PluginRegistry discovery data.
    /// `dir_path` is the plugin directory; manifest.json is re-read for the
    /// typed render_style payload.
    pub fn loadFromDiscoveredPlugin(self: *StyleRegistry, dir_path: []const u8) !void {
        return self.loadUserPlugin(dir_path);
    }

    /// Scan a directory for plugin subdirectories and load each one.
    pub fn scanPluginDirectory(self: *StyleRegistry, root_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch |err| {
            std.log.warn("StyleRegistry: cannot open plugin directory '{s}': {s}", .{ root_path, @errorName(err) });
            return;
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            const subdir_path = std.fs.path.join(self.allocator, &.{ root_path, entry.name }) catch continue;
            defer self.allocator.free(subdir_path);
            self.loadUserPlugin(subdir_path) catch |err| {
                std.log.warn("StyleRegistry: failed to load plugin '{s}': {s}", .{ entry.name, @errorName(err) });
            };
        }
    }

    // ── PluginLoader vtable implementation ──────────────────────────────

    /// Return a type-erased PluginLoader backed by this StyleRegistry.
    pub fn pluginLoader(self: *StyleRegistry) loader_mod.PluginLoader {
        return .{
            .context = @ptrCast(self),
            .vtable = &style_loader_vtable,
        };
    }

    const style_loader_vtable = loader_mod.PluginLoader.VTable{
        .on_discover = &styleOnDiscover,
        .on_enable = &styleOnEnable,
        .on_disable = &styleOnDisable,
        .on_unload = &styleOnUnload,
    };

    fn styleOnDiscover(ctx: *anyopaque, record: *plugin_types.PluginRecord) void {
        const self: *StyleRegistry = @ptrCast(@alignCast(ctx));
        if (record.manifest.path.len == 0) return;
        const dir_path = std.fs.path.dirname(record.manifest.path) orelse return;
        // Already loaded in StyleRegistry — just sync lifecycle
        if (self.getStyle(record.manifest.name) != null) {
            if (record.lifecycle == .loaded) {
                record.lifecycle = .enabled;
                record.clearLastError(self.allocator);
            }
            return;
        }
        self.loadFromDiscoveredPlugin(dir_path) catch |err| {
            record.lifecycle = .load_error;
            record.setLastError(self.allocator, @errorName(err));
            std.log.warn("StyleRegistry: failed to load render style '{s}': {s}", .{ record.getName(), @errorName(err) });
            return;
        };
        record.lifecycle = .enabled;
        record.clearLastError(self.allocator);
    }

    fn styleOnEnable(ctx: *anyopaque, record: *plugin_types.PluginRecord) void {
        const self: *StyleRegistry = @ptrCast(@alignCast(ctx));
        // If not yet in StyleRegistry, try loading
        if (self.getStyle(record.manifest.name) == null) {
            const dir_path = std.fs.path.dirname(record.manifest.path) orelse {
                record.lifecycle = .load_error;
                record.setLastError(self.allocator, "cannot derive plugin directory");
                return;
            };
            self.loadFromDiscoveredPlugin(dir_path) catch |err| {
                record.lifecycle = .load_error;
                record.setLastError(self.allocator, @errorName(err));
                return;
            };
        }
        record.lifecycle = .enabled;
        record.clearLastError(self.allocator);
    }

    fn styleOnDisable(ctx: *anyopaque, record: *plugin_types.PluginRecord) void {
        const self: *StyleRegistry = @ptrCast(@alignCast(ctx));
        // If this style is currently active, roll back to default
        if (std.mem.eql(u8, self.active_style_name, record.manifest.name)) {
            _ = self.setActiveStyle("default_pbr");
        }
        record.lifecycle = .loaded;
    }

    fn styleOnUnload(ctx: *anyopaque, record: *plugin_types.PluginRecord) void {
        const self: *StyleRegistry = @ptrCast(@alignCast(ctx));
        self.unregister(record.manifest.name);
    }
};

test "style registry init has builtins" {
    const allocator = std.testing.allocator;
    var registry = StyleRegistry.init(allocator);
    defer registry.deinit();

    // Should have default_pbr and unlit_flat
    try std.testing.expectEqual(@as(usize, 2), registry.styleCount());
    try std.testing.expect(registry.getStyle("default_pbr") != null);
    try std.testing.expect(registry.getStyle("unlit_flat") != null);
    try std.testing.expectEqualSlices(u8, "default_pbr", registry.active_style_name);
}

test "style registry set active and rollback" {
    const allocator = std.testing.allocator;
    var registry = StyleRegistry.init(allocator);
    defer registry.deinit();

    // Switch to unlit_flat
    try std.testing.expect(registry.setActiveStyle("unlit_flat"));
    try std.testing.expectEqualSlices(u8, "unlit_flat", registry.active_style_name);
    try std.testing.expectEqualSlices(u8, "default_pbr", registry.previous_style_name);

    // Rollback
    registry.rollbackStyle();
    try std.testing.expectEqualSlices(u8, "default_pbr", registry.active_style_name);

    // Cannot switch to nonexistent
    try std.testing.expect(!registry.setActiveStyle("nonexistent_style"));
    try std.testing.expectEqualSlices(u8, "default_pbr", registry.active_style_name);
}

test "style registry register and unregister" {
    const allocator = std.testing.allocator;
    var registry = StyleRegistry.init(allocator);
    defer registry.deinit();

    const custom = StylePluginManifest{
        .name = "custom_style",
        .display_name = "Custom",
        .version = "1.0.0",
        .source = .project,
        .mesh_program = "custom_mesh",
    };

    try registry.register(custom);
    try std.testing.expectEqual(@as(usize, 3), registry.styleCount());
    try std.testing.expect(registry.getStyle("custom_style") != null);

    // Duplicate registration should fail
    try std.testing.expectError(error.StyleAlreadyRegistered, registry.register(custom));

    // Unregister
    registry.unregister("custom_style");
    try std.testing.expectEqual(@as(usize, 2), registry.styleCount());
    try std.testing.expect(registry.getStyle("custom_style") == null);
}

test "style registry unregister active style falls back" {
    const allocator = std.testing.allocator;
    var registry = StyleRegistry.init(allocator);
    defer registry.deinit();

    const style = StylePluginManifest{
        .name = "doomed_style",
        .display_name = "Doomed",
        .version = "1.0.0",
        .source = .user,
        .mesh_program = "mesh",
    };
    try registry.register(style);
    _ = registry.setActiveStyle("doomed_style");
    try std.testing.expectEqualSlices(u8, "doomed_style", registry.active_style_name);

    // Unregister the active style
    registry.unregister("doomed_style");

    // Should fall back to default_pbr
    try std.testing.expectEqualSlices(u8, "default_pbr", registry.active_style_name);
    try std.testing.expect(registry.getStyle("doomed_style") == null);
}

test "style registry isPassDisabledByActiveStyle" {
    const allocator = std.testing.allocator;
    var registry = StyleRegistry.init(allocator);
    defer registry.deinit();

    // default_pbr has no disabled passes
    try std.testing.expect(!registry.isPassDisabledByActiveStyle("bloom"));

    // Switch to unlit_flat which disables bloom and ssr
    _ = registry.setActiveStyle("unlit_flat");
    try std.testing.expect(registry.isPassDisabledByActiveStyle("bloom"));
    try std.testing.expect(registry.isPassDisabledByActiveStyle("ssr"));
    try std.testing.expect(!registry.isPassDisabledByActiveStyle("tonemap"));
}
