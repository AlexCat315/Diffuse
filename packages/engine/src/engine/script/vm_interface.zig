const std = @import("std");
const script_resource_mod = @import("../assets/script_resource.zig");
const context = @import("./context.zig");
const types = @import("./types.zig");

/// 脚本虚拟机接口 - 支持多种脚本语言后端
pub const ScriptVM = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (vm_context: *anyopaque, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void,
        unload: *const fn (vm_context: *anyopaque) void,
        createInstance: *const fn (vm_context: *anyopaque, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance,
        destroyInstance: *const fn (vm_context: *anyopaque, instance: *types.ScriptInstance) void,
        callInit: *const fn (vm_context: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void,
        callUpdate: *const fn (vm_context: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void,
        callDestroy: *const fn (vm_context: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void,
        callTriggerEnter: ?*const fn (vm_context: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void = null,
        callTriggerExit: ?*const fn (vm_context: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void = null,
        callCollisionEnter: ?*const fn (vm_context: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void = null,
        callCollisionExit: ?*const fn (vm_context: *anyopaque, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void = null,
        getError: *const fn (vm_context: *anyopaque) []const u8,
        destroy: *const fn (vm_context: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn load(self: *ScriptVM, resource: *const script_resource_mod.ScriptResource) types.ScriptError!void {
        return self.vtable.load(self.context, resource);
    }

    pub fn unload(self: *ScriptVM) void {
        self.vtable.unload(self.context);
    }

    pub fn createInstance(self: *ScriptVM, ctx: *context.ScriptContext) types.ScriptError!*types.ScriptInstance {
        return self.vtable.createInstance(self.context, ctx);
    }

    pub fn destroyInstance(self: *ScriptVM, instance: *types.ScriptInstance) void {
        self.vtable.destroyInstance(self.context, instance);
    }

    pub fn callInit(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        return self.vtable.callInit(self.context, instance, ctx);
    }

    pub fn callUpdate(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext, dt: f32) types.ScriptError!void {
        return self.vtable.callUpdate(self.context, instance, ctx, dt);
    }

    pub fn callDestroy(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext) types.ScriptError!void {
        return self.vtable.callDestroy(self.context, instance, ctx);
    }

    pub fn callTriggerEnter(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
        if (self.vtable.callTriggerEnter) |fn_ptr| {
            fn_ptr(self.context, instance, ctx, other);
        }
    }

    pub fn callTriggerExit(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
        if (self.vtable.callTriggerExit) |fn_ptr| {
            fn_ptr(self.context, instance, ctx, other);
        }
    }

    pub fn callCollisionEnter(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
        if (self.vtable.callCollisionEnter) |fn_ptr| {
            fn_ptr(self.context, instance, ctx, other);
        }
    }

    pub fn callCollisionExit(self: *ScriptVM, instance: *types.ScriptInstance, ctx: *context.ScriptContext, other: types.EntityId) void {
        if (self.vtable.callCollisionExit) |fn_ptr| {
            fn_ptr(self.context, instance, ctx, other);
        }
    }

    pub fn getError(self: *ScriptVM) []const u8 {
        return self.vtable.getError(self.context);
    }

    pub fn deinit(self: *ScriptVM, allocator: std.mem.Allocator) void {
        self.unload();
        self.vtable.destroy(self.context, allocator);
    }
};
