const std = @import("std");

pub const PluginType = enum {
    render_style,
    audio_effect,
    physics_ext,
    terrain_gen,
    ai_behavior,
    ui_extension,
    script_vm,
};

pub const PluginCapability = enum {
    shader,
    compute_pass,
    render_pass,
    audio_processor,
    script_handler,
};

pub const PluginSource = enum {
    builtin,
    user,
    project,
};

pub const PluginLifecycle = enum {
    unloaded,
    loaded,
    enabled,
    load_error,
};

/// Error governance policy — controls how the system handles plugin failures.
pub const PluginErrorPolicy = enum {
    /// Skip the plugin on error; it can be manually re-enabled later.
    skip_on_error,
    /// The system will retry enable once on the next discovery pass.
    retry_once,
    /// Permanently disable; requires explicit user intervention to re-enable.
    disable_permanently,
};

pub const PluginVersion = struct {
    major: u16,
    minor: u16,
    patch: u16,

    pub fn parse(str: []const u8) !PluginVersion {
        var parts = std.mem.splitSequence(u8, str, ".");
        const major = std.fmt.parseInt(u16, parts.next() orelse return error.InvalidVersion, 0) catch return error.InvalidVersion;
        const minor = std.fmt.parseInt(u16, parts.next() orelse return error.InvalidVersion, 0) catch return error.InvalidVersion;
        const patch = std.fmt.parseInt(u16, parts.next() orelse return error.InvalidVersion, 0) catch return error.InvalidVersion;
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn compatible(self: PluginVersion, other: PluginVersion) bool {
        return self.major == other.major;
    }
};

/// Common shell shared by all plugin types.
/// Type-specific payloads (StylePluginManifest, etc.) are owned by their
/// respective subsystem registries, not embedded here.
///
/// Ownership: All slice fields (.name, .path) are allocator-owned when the
/// manifest is created by `discover()`.  Callers must call `deinit()` to
/// release them.
pub const PluginManifest = struct {
    name: []u8,
    version: PluginVersion,
    plugin_type: PluginType,
    capabilities: []const PluginCapability = &.{},
    source: PluginSource = .user,
    path: []u8 = &.{},
    dependencies: []const []const u8 = &.{},

    on_load: ?[]const u8 = null,
    on_unload: ?[]const u8 = null,
    on_enable: ?[]const u8 = null,

    pub fn deinit(self: *PluginManifest, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.path.len > 0) allocator.free(self.path);
        if (self.capabilities.len > 0) {
            const ptr: [*]const PluginCapability = self.capabilities.ptr;
            allocator.free(ptr[0..self.capabilities.len]);
        }
        self.* = undefined;
    }
};

/// Record tracked by PluginRegistry: common manifest + lifecycle + error state.
pub const PluginRecord = struct {
    manifest: PluginManifest,
    lifecycle: PluginLifecycle = .unloaded,
    last_error: ?[]u8 = null,
    error_policy: PluginErrorPolicy = .skip_on_error,
    /// Number of consecutive enable attempts that resulted in load_error.
    error_retry_count: u8 = 0,

    pub fn deinit(self: *PluginRecord, allocator: std.mem.Allocator) void {
        self.clearLastError(allocator);
        self.manifest.deinit(allocator);
    }

    /// Set an owned error message (dupes `msg`). Frees any previous error.
    pub fn setLastError(self: *PluginRecord, allocator: std.mem.Allocator, msg: []const u8) void {
        self.clearLastError(allocator);
        self.last_error = allocator.dupe(u8, msg) catch null;
    }

    /// Clear the owned error message.
    pub fn clearLastError(self: *PluginRecord, allocator: std.mem.Allocator) void {
        if (self.last_error) |err| allocator.free(err);
        self.last_error = null;
    }

    pub fn getName(self: *const PluginRecord) []const u8 {
        return self.manifest.name;
    }

    pub fn getVersion(self: *const PluginRecord) PluginVersion {
        return self.manifest.version;
    }

    pub fn getType(self: *const PluginRecord) PluginType {
        return self.manifest.plugin_type;
    }

    pub fn getSource(self: *const PluginRecord) PluginSource {
        return self.manifest.source;
    }

    pub fn isEnabled(self: *const PluginRecord) bool {
        return self.lifecycle == .enabled;
    }

    pub fn hasError(self: *const PluginRecord) bool {
        return self.lifecycle == .load_error;
    }
};

test "plugin version parsing" {
    const v = try PluginVersion.parse("1.2.3");
    try std.testing.expectEqual(@as(u16, 1), v.major);
    try std.testing.expectEqual(@as(u16, 2), v.minor);
    try std.testing.expectEqual(@as(u16, 3), v.patch);
}
