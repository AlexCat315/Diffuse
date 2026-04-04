const std = @import("std");
const engine = @import("guava");
const gui = @import("gui.zig");
const layout = @import("layout.zig");

pub const FieldChangedFn = *const fn (field_name: []const u8, value_str: []const u8) void;

pub const ReflectionContext = struct {
    changed: bool = false,
    on_field_changed: ?FieldChangedFn = null,
};

pub fn drawComponentUI(comptime T: type, ctx: *ReflectionContext, component: *T) void {
    const type_info = @typeInfo(T);
    if (type_info != .Struct) {
        @compileError("drawComponentUI only works with struct types");
    }

    const struct_info = type_info.Struct;
    const type_name = @typeName(T);

    if (gui.collapsingHeader(type_name, true)) {
        layout.beginSectionBody();
        inline for (struct_info.fields) |field| {
            drawFieldUI(field, ctx, @ptrCast(component));
        }
        layout.endSectionBody();
    }
}

fn drawFieldUI(comptime field: std.builtin.Type.StructField, ctx: *ReflectionContext, parent_ptr: anytype) void {
    const field_ptr = &@field(parent_ptr, field.name);
    const field_type = field.type;

    if (field_type == f32) {
        drawFloatField(field.name, ctx, field_ptr);
    } else if (field_type == bool) {
        drawBoolField(field.name, ctx, field_ptr);
    } else if (field_type == u8) {
        drawIntField(u8, field.name, ctx, field_ptr);
    } else if (field_type == u16) {
        drawIntField(u16, field.name, ctx, field_ptr);
    } else if (field_type == u32) {
        drawIntField(u32, field.name, ctx, field_ptr);
    } else if (field_type == i32) {
        drawIntField(i32, field.name, ctx, field_ptr);
    } else if (field_type == [3]f32) {
        drawVec3Field(field.name, ctx, field_ptr);
    } else if (field_type == [4]f32) {
        drawVec4Field(field.name, ctx, field_ptr);
    }
}

fn drawFloatField(name: []const u8, ctx: *ReflectionContext, value: *f32) void {
    layout.drawInspectorPropertyRow(name, null);
    if (gui.dragFloat("##value", value, 0.1, -10000.0, 10000.0)) {
        ctx.changed = true;
        if (ctx.on_field_changed) |callback| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{value.*}) catch return;
            callback(name, str);
        }
    }
}

fn drawBoolField(name: []const u8, ctx: *ReflectionContext, value: *bool) void {
    layout.drawInspectorPropertyRow(name, null);
    if (gui.checkbox("##value", value)) {
        ctx.changed = true;
        if (ctx.on_field_changed) |callback| {
            callback(name, if (value.*) "true" else "false");
        }
    }
}

fn drawIntField(comptime T: type, name: []const u8, ctx: *ReflectionContext, value: *T) void {
    layout.drawInspectorPropertyRow(name, null);
    var val: i32 = @intCast(value.*);
    if (gui.dragInt("##value", &val, 1.0, -100000, 100000)) {
        value.* = @intCast(val);
        ctx.changed = true;
        if (ctx.on_field_changed) |callback| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{}", .{value.*}) catch return;
            callback(name, str);
        }
    }
}

fn drawVec3Field(name: []const u8, ctx: *ReflectionContext, value: *[3]f32) void {
    layout.drawInspectorPropertyRow(name, null);
    if (gui.dragFloat3("##value", value, 0.1, -10000.0, 10000.0)) {
        ctx.changed = true;
        if (ctx.on_field_changed) |callback| {
            var buf: [96]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d},{d},{d}", .{ value[0], value[1], value[2] }) catch return;
            callback(name, str);
        }
    }
}

fn drawVec4Field(name: []const u8, ctx: *ReflectionContext, value: *[4]f32) void {
    layout.drawInspectorPropertyRow(name, null);
    if (gui.dragFloat4("##value", value, 0.1, -10000.0, 10000.0)) {
        ctx.changed = true;
        if (ctx.on_field_changed) |callback| {
            var buf: [128]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d},{d},{d},{d}", .{ value[0], value[1], value[2], value[3] }) catch return;
            callback(name, str);
        }
    }
}

pub fn getFieldTypeLabel(comptime T: type) []const u8 {
    if (T == f32) return "float";
    if (T == bool) return "bool";
    if (T == u8 or T == u16 or T == u32) return "uint";
    if (T == i32) return "int";
    if (T == [3]f32) return "vec3";
    if (T == [4]f32) return "vec4";

    const type_info = @typeInfo(T);
    if (type_info == .Enum) return "enum";
    if (type_info == .Optional) return "optional";
    if (type_info == .Struct) return "struct";

    return "unknown";
}
