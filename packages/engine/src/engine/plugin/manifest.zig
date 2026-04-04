const std = @import("std");
const types = @import("types.zig");

pub const ManifestParseError = error{
    InvalidJson,
    MissingField,
    InvalidPluginType,
    InvalidCapability,
    InvalidVersion,
    OutOfMemory,
};

/// Parse a `manifest.json` blob into a `PluginManifest`.
/// All string fields in the returned manifest are allocator-owned and must
/// be released by calling `PluginManifest.deinit(allocator)`.
pub fn parseManifest(allocator: std.mem.Allocator, json_content: []const u8) ManifestParseError!types.PluginManifest {
    const ManifestJson = struct {
        name: []const u8 = "",
        version: []const u8 = "1.0.0",
        plugin_type: []const u8 = "render_style",
        source: []const u8 = "user",
        capabilities: []const []const u8 = &.{},
    };

    const parsed = std.json.parseFromSlice(ManifestJson, allocator, json_content, .{
        .ignore_unknown_fields = true,
    }) catch return ManifestParseError.InvalidJson;
    defer parsed.deinit();

    const m = parsed.value;
    if (m.name.len == 0) return ManifestParseError.MissingField;

    const plugin_type = std.meta.stringToEnum(types.PluginType, m.plugin_type) orelse
        return ManifestParseError.InvalidPluginType;
    const source = std.meta.stringToEnum(types.PluginSource, m.source) orelse .user;
    const version = types.PluginVersion.parse(m.version) catch
        return ManifestParseError.InvalidVersion;

    // Parse capabilities into an owned slice.
    var caps: std.ArrayListUnmanaged(types.PluginCapability) = .empty;
    defer caps.deinit(allocator);
    for (m.capabilities) |cap_str| {
        const cap = std.meta.stringToEnum(types.PluginCapability, cap_str) orelse
            return ManifestParseError.InvalidCapability;
        caps.append(allocator, cap) catch return ManifestParseError.OutOfMemory;
    }

    const name_dupe = allocator.dupe(u8, m.name) catch return ManifestParseError.OutOfMemory;
    errdefer allocator.free(name_dupe);

    const owned_caps = caps.toOwnedSlice(allocator) catch return ManifestParseError.OutOfMemory;

    return .{
        .name = name_dupe,
        .version = version,
        .plugin_type = plugin_type,
        .capabilities = owned_caps,
        .source = source,
    };
}

test "parse manifest basic" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "test_plugin",
        \\  "version": "1.2.3",
        \\  "plugin_type": "render_style",
        \\  "capabilities": ["shader", "render_pass"]
        \\}
    ;

    var manifest = try parseManifest(allocator, json);
    defer manifest.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "test_plugin", manifest.name);
    try std.testing.expectEqual(@as(u16, 1), manifest.version.major);
    try std.testing.expectEqual(@as(u16, 2), manifest.version.minor);
    try std.testing.expectEqual(@as(u16, 3), manifest.version.patch);
    try std.testing.expectEqual(types.PluginType.render_style, manifest.plugin_type);
    try std.testing.expectEqual(@as(usize, 2), manifest.capabilities.len);
    try std.testing.expectEqual(types.PluginCapability.shader, manifest.capabilities[0]);
    try std.testing.expectEqual(types.PluginCapability.render_pass, manifest.capabilities[1]);
}

test "parse manifest invalid json" {
    const allocator = std.testing.allocator;
    const result = parseManifest(allocator, "not json at all {{{");
    try std.testing.expectError(ManifestParseError.InvalidJson, result);
}

test "parse manifest missing name" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.0.0",
        \\  "plugin_type": "render_style"
        \\}
    ;
    const result = parseManifest(allocator, json);
    try std.testing.expectError(ManifestParseError.MissingField, result);
}

test "parse manifest unknown plugin_type" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "bad_type",
        \\  "version": "1.0.0",
        \\  "plugin_type": "nonexistent_type"
        \\}
    ;
    const result = parseManifest(allocator, json);
    try std.testing.expectError(ManifestParseError.InvalidPluginType, result);
}

test "parse manifest invalid version" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "bad_ver",
        \\  "version": "abc",
        \\  "plugin_type": "render_style"
        \\}
    ;
    const result = parseManifest(allocator, json);
    try std.testing.expectError(ManifestParseError.InvalidVersion, result);
}

test "parse manifest script_vm type" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "my_wasm_mod",
        \\  "version": "0.1.0",
        \\  "plugin_type": "script_vm",
        \\  "capabilities": ["script_handler"]
        \\}
    ;
    var manifest = try parseManifest(allocator, json);
    defer manifest.deinit(allocator);
    try std.testing.expectEqual(types.PluginType.script_vm, manifest.plugin_type);
    try std.testing.expectEqual(@as(usize, 1), manifest.capabilities.len);
    try std.testing.expectEqual(types.PluginCapability.script_handler, manifest.capabilities[0]);
}

test "parse manifest unknown capability" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "bad_cap",
        \\  "version": "1.0.0",
        \\  "plugin_type": "render_style",
        \\  "capabilities": ["bogus_capability"]
        \\}
    ;
    const result = parseManifest(allocator, json);
    try std.testing.expectError(ManifestParseError.InvalidCapability, result);
}

test "parse manifest extra fields ignored" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "extra_fields",
        \\  "version": "2.0.0",
        \\  "plugin_type": "render_style",
        \\  "render_style": { "display_name": "Foo" },
        \\  "unknown_key": 42
        \\}
    ;
    var manifest = try parseManifest(allocator, json);
    defer manifest.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "extra_fields", manifest.name);
}
