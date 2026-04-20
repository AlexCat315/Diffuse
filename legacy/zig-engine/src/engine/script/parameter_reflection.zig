const std = @import("std");

pub const ParameterKind = enum(u8) {
    float = 1,
    boolean = 2,
    integer = 3,
};

pub const ParameterValue = union(ParameterKind) {
    float: f32,
    boolean: bool,
    integer: i32,
};

pub const ParameterDefinition = struct {
    name: []u8,
    kind: ParameterKind,
    default_value: ParameterValue,
    min: f32,
    max: f32,
    step: f32,
};

const MetadataDocument = struct {
    version: u32 = 1,
    parameters: []const MetadataParameter,
};

const MetadataParameter = struct {
    name: []const u8,
    kind: ParameterKind,
    default_float: ?f32 = null,
    default_boolean: ?bool = null,
    default_integer: ?i32 = null,
    min: ?f32 = null,
    max: ?f32 = null,
    step: ?f32 = null,
};

pub fn defaultBounds(kind: ParameterKind) struct { min: f32, max: f32, step: f32 } {
    return switch (kind) {
        .float => .{ .min = -100.0, .max = 100.0, .step = 0.05 },
        .boolean => .{ .min = 0.0, .max = 1.0, .step = 1.0 },
        .integer => .{ .min = -1024.0, .max = 1024.0, .step = 1.0 },
    };
}

pub fn defaultValueForKind(kind: ParameterKind) ParameterValue {
    return switch (kind) {
        .float => .{ .float = 0.0 },
        .boolean => .{ .boolean = false },
        .integer => .{ .integer = 0 },
    };
}

pub fn deinitDefinitions(allocator: std.mem.Allocator, definitions: []ParameterDefinition) void {
    for (definitions) |definition| {
        allocator.free(definition.name);
    }
    allocator.free(definitions);
}

pub fn parseMetadataAlloc(allocator: std.mem.Allocator, source: []const u8) ![]ParameterDefinition {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) {
        return allocator.alloc(ParameterDefinition, 0);
    }

    var parsed = try std.json.parseFromSlice(MetadataDocument, allocator, trimmed, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const definitions = try allocator.alloc(ParameterDefinition, parsed.value.parameters.len);
    errdefer {
        for (definitions[0..parsed.value.parameters.len]) |definition| {
            allocator.free(definition.name);
        }
        allocator.free(definitions);
    }

    for (parsed.value.parameters, 0..) |parameter, index| {
        const bounds = defaultBounds(parameter.kind);
        definitions[index] = .{
            .name = try allocator.dupe(u8, parameter.name),
            .kind = parameter.kind,
            .default_value = switch (parameter.kind) {
                .float => .{ .float = parameter.default_float orelse 0.0 },
                .boolean => .{ .boolean = parameter.default_boolean orelse false },
                .integer => .{ .integer = parameter.default_integer orelse 0 },
            },
            .min = parameter.min orelse bounds.min,
            .max = parameter.max orelse bounds.max,
            .step = parameter.step orelse bounds.step,
        };
    }

    return definitions;
}

pub fn buildMetadataJsonAlloc(allocator: std.mem.Allocator, definitions: []const ParameterDefinition) ![]u8 {
    var parameters = try allocator.alloc(MetadataParameter, definitions.len);
    defer allocator.free(parameters);

    for (definitions, 0..) |definition, index| {
        parameters[index] = .{
            .name = definition.name,
            .kind = definition.kind,
            .default_float = switch (definition.default_value) {
                .float => |value| value,
                else => null,
            },
            .default_boolean = switch (definition.default_value) {
                .boolean => |value| value,
                else => null,
            },
            .default_integer = switch (definition.default_value) {
                .integer => |value| value,
                else => null,
            },
            .min = if (definition.kind == .boolean) null else definition.min,
            .max = if (definition.kind == .boolean) null else definition.max,
            .step = if (definition.kind == .boolean) null else definition.step,
        };
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var writer = out.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(MetadataDocument{
        .parameters = parameters,
    }, .{ .whitespace = .indent_2 }, &adapter.new_interface);
    try adapter.new_interface.flush();
    try writer.writeByte('\n');
    return try out.toOwnedSlice(allocator);
}

pub fn parseValuesAlloc(
    allocator: std.mem.Allocator,
    definitions: []const ParameterDefinition,
    source: []const u8,
) ![]ParameterValue {
    const values = try allocator.alloc(ParameterValue, definitions.len);
    errdefer allocator.free(values);

    for (definitions, 0..) |definition, index| {
        values[index] = definition.default_value;
    }

    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) {
        return values;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    if (parsed.value != .object) {
        return values;
    }

    for (definitions, 0..) |definition, index| {
        const json_value = parsed.value.object.get(definition.name) orelse continue;
        values[index] = coerceJsonValue(definition, json_value);
    }

    return values;
}

pub fn buildValuesJsonAlloc(
    allocator: std.mem.Allocator,
    definitions: []const ParameterDefinition,
    values: []const ParameterValue,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var writer = out.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var adapter = writer.adaptToNewApi(&adapter_buffer);

    try adapter.new_interface.writeByte('{');
    if (definitions.len != 0) {
        try adapter.new_interface.writeByte('\n');
    }

    for (definitions, 0..) |definition, index| {
        if (index != 0) {
            try adapter.new_interface.writeAll(",\n");
        }
        try adapter.new_interface.writeAll("  ");
        try std.json.Stringify.value(definition.name, .{}, &adapter.new_interface);
        try adapter.new_interface.writeAll(": ");
        switch (values[index]) {
            .float => |value| try std.json.Stringify.value(value, .{}, &adapter.new_interface),
            .boolean => |value| try std.json.Stringify.value(value, .{}, &adapter.new_interface),
            .integer => |value| try std.json.Stringify.value(value, .{}, &adapter.new_interface),
        }
    }

    if (definitions.len != 0) {
        try adapter.new_interface.writeByte('\n');
    }
    try adapter.new_interface.writeByte('}');
    try adapter.new_interface.writeByte('\n');
    try adapter.new_interface.flush();
    return try out.toOwnedSlice(allocator);
}

fn coerceJsonValue(definition: ParameterDefinition, value: std.json.Value) ParameterValue {
    return switch (definition.kind) {
        .float => .{ .float = switch (value) {
            .float => |number| @as(f32, @floatCast(number)),
            .integer => |number| @floatFromInt(number),
            else => switch (definition.default_value) {
                .float => |fallback| fallback,
                else => 0.0,
            },
        } },
        .boolean => .{ .boolean = switch (value) {
            .bool => |boolean| boolean,
            .integer => |number| number != 0,
            else => switch (definition.default_value) {
                .boolean => |fallback| fallback,
                else => false,
            },
        } },
        .integer => .{ .integer = switch (value) {
            .integer => |number| std.math.cast(i32, number) orelse switch (definition.default_value) {
                .integer => |fallback| fallback,
                else => 0,
            },
            .float => |number| @as(i32, @intFromFloat(number)),
            else => switch (definition.default_value) {
                .integer => |fallback| fallback,
                else => 0,
            },
        } },
    };
}

test "parameter reflection metadata and values round-trip" {
    const definitions = try std.testing.allocator.alloc(ParameterDefinition, 3);
    defer deinitDefinitions(std.testing.allocator, definitions);

    definitions[0] = .{
        .name = try std.testing.allocator.dupe(u8, "speed"),
        .kind = .float,
        .default_value = .{ .float = 2.5 },
        .min = 0.0,
        .max = 10.0,
        .step = 0.25,
    };
    definitions[1] = .{
        .name = try std.testing.allocator.dupe(u8, "enabled"),
        .kind = .boolean,
        .default_value = .{ .boolean = true },
        .min = 0.0,
        .max = 1.0,
        .step = 1.0,
    };
    definitions[2] = .{
        .name = try std.testing.allocator.dupe(u8, "count"),
        .kind = .integer,
        .default_value = .{ .integer = 3 },
        .min = -10.0,
        .max = 10.0,
        .step = 1.0,
    };

    const metadata = try buildMetadataJsonAlloc(std.testing.allocator, definitions);
    defer std.testing.allocator.free(metadata);

    const parsed = try parseMetadataAlloc(std.testing.allocator, metadata);
    defer deinitDefinitions(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqualStrings("speed", parsed[0].name);
    try std.testing.expectEqual(ParameterKind.boolean, parsed[1].kind);

    const values = try parseValuesAlloc(std.testing.allocator, parsed, "{\"speed\":7.5,\"count\":9}\n");
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(f32, 7.5), values[0].float);
    try std.testing.expectEqual(true, values[1].boolean);
    try std.testing.expectEqual(@as(i32, 9), values[2].integer);

    const encoded_values = try buildValuesJsonAlloc(std.testing.allocator, parsed, values);
    defer std.testing.allocator.free(encoded_values);
    try std.testing.expect(std.mem.indexOf(u8, encoded_values, "\"speed\": 7.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_values, "\"enabled\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded_values, "\"count\": 9") != null);
}
