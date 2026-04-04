const std = @import("std");
const rhi_types = @import("types.zig");

pub const ResourceKind = rhi_types.ResourceKind;
pub const BarrierSyncAction = rhi_types.BarrierSyncAction;
pub const BarrierPassScope = rhi_types.BarrierPassScope;

pub const Error = error{
    OutOfMemory,
    InvalidOpcode,
    TruncatedStream,
};

pub const OpCode = enum(u8) {
    begin_render_pass,
    end_render_pass,
    begin_compute_pass,
    end_compute_pass,
    begin_copy_pass,
    end_copy_pass,
    set_binding_set,
    set_vertex_buffer,
    set_index_buffer,
    set_pipeline,
    draw_indexed,
    draw_indirect,
    dispatch,
    dispatch_indirect,
    pipeline_barrier,
    draw,
    push_uniform,
    set_viewport,
    set_scissor,
};

pub const BeginRenderPassCmd = extern struct {
    color_target_id: u32,
    depth_target_id: u32,
    clear_mask: u32,
    clear_r: f32 = 0.0,
    clear_g: f32 = 0.0,
    clear_b: f32 = 0.0,
    clear_a: f32 = 1.0,
    clear_depth: f32 = 1.0,
};

pub const BeginComputePassCmd = extern struct {
    reserved: u32 = 0,
};

pub const BeginCopyPassCmd = extern struct {
    reserved: u32 = 0,
};

pub const SetBindingSetCmd = extern struct {
    slot: u32,
    set_id: u32,
};

pub const SetVertexBufferCmd = extern struct {
    slot: u32,
    buffer_id: u32,
    offset: u32,
};

pub const SetIndexBufferCmd = extern struct {
    buffer_id: u32,
    offset: u32,
    format: u32, // 0 = u16, 1 = u32
};

pub const SetPipelineCmd = extern struct {
    pipeline_id: u32,
};

pub const DrawIndexedCmd = extern struct {
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    vertex_offset: i32,
    first_instance: u32,
};

pub const DrawIndirectCmd = extern struct {
    buffer_id: u32,
    offset: u32,
    draw_count: u32,
};

pub const DispatchCmd = extern struct {
    x: u32,
    y: u32,
    z: u32,
};

pub const DispatchIndirectCmd = extern struct {
    buffer_id: u32,
    offset: u32,
};

pub const PipelineBarrierCmd = extern struct {
    resource_id: u32,
    src_state_bits: u32,
    dst_state_bits: u32,
    subresource_base: u16 = 0,
    subresource_count: u16 = 1,
    resource_kind: u8,
    sync_action: u8 = @intCast(@intFromEnum(BarrierSyncAction.full)),
    pass_scope: u8 = @intCast(@intFromEnum(BarrierPassScope.outside_pass)),
    src_queue: u8 = 0,
    dst_queue: u8 = 0,
    _padding: [3]u8 = .{ 0, 0, 0 },
};

pub const DrawCmd = extern struct {
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
};

pub const PushUniformCmd = extern struct {
    stage: u8, // 0=vertex, 1=fragment, 2=compute
    slot: u8,
    _pad: u16 = 0,
    data_len: u32,
    // followed by data_len bytes of inline payload
};

pub const PushUniformData = struct {
    header: PushUniformCmd,
    data: []const u8,
};

pub const SetViewportCmd = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    min_depth: f32 = 0.0,
    max_depth: f32 = 1.0,
};

pub const SetScissorCmd = extern struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const DecodedCommand = union(OpCode) {
    begin_render_pass: BeginRenderPassCmd,
    end_render_pass: void,
    begin_compute_pass: BeginComputePassCmd,
    end_compute_pass: void,
    begin_copy_pass: BeginCopyPassCmd,
    end_copy_pass: void,
    set_binding_set: SetBindingSetCmd,
    set_vertex_buffer: SetVertexBufferCmd,
    set_index_buffer: SetIndexBufferCmd,
    set_pipeline: SetPipelineCmd,
    draw_indexed: DrawIndexedCmd,
    draw_indirect: DrawIndirectCmd,
    dispatch: DispatchCmd,
    dispatch_indirect: DispatchIndirectCmd,
    pipeline_barrier: PipelineBarrierCmd,
    draw: DrawCmd,
    push_uniform: PushUniformData,
    set_viewport: SetViewportCmd,
    set_scissor: SetScissorCmd,
};

pub const CommandBuffer = struct {
    allocator: std.mem.Allocator,
    opcodes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) CommandBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CommandBuffer) void {
        self.opcodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *CommandBuffer) void {
        self.opcodes.clearRetainingCapacity();
    }

    pub fn encodeBeginRenderPass(self: *CommandBuffer, cmd: BeginRenderPassCmd) Error!void {
        try self.writeOp(.begin_render_pass);
        try self.writeStruct(BeginRenderPassCmd, cmd);
    }

    pub fn encodeEndRenderPass(self: *CommandBuffer) Error!void {
        try self.writeOp(.end_render_pass);
    }

    pub fn encodeBeginComputePass(self: *CommandBuffer, cmd: BeginComputePassCmd) Error!void {
        try self.writeOp(.begin_compute_pass);
        try self.writeStruct(BeginComputePassCmd, cmd);
    }

    pub fn encodeEndComputePass(self: *CommandBuffer) Error!void {
        try self.writeOp(.end_compute_pass);
    }

    pub fn encodeBeginCopyPass(self: *CommandBuffer, cmd: BeginCopyPassCmd) Error!void {
        try self.writeOp(.begin_copy_pass);
        try self.writeStruct(BeginCopyPassCmd, cmd);
    }

    pub fn encodeEndCopyPass(self: *CommandBuffer) Error!void {
        try self.writeOp(.end_copy_pass);
    }

    pub fn encodeSetBindingSet(self: *CommandBuffer, cmd: SetBindingSetCmd) Error!void {
        try self.writeOp(.set_binding_set);
        try self.writeStruct(SetBindingSetCmd, cmd);
    }

    pub fn encodeSetVertexBuffer(self: *CommandBuffer, cmd: SetVertexBufferCmd) Error!void {
        try self.writeOp(.set_vertex_buffer);
        try self.writeStruct(SetVertexBufferCmd, cmd);
    }

    pub fn encodeSetIndexBuffer(self: *CommandBuffer, cmd: SetIndexBufferCmd) Error!void {
        try self.writeOp(.set_index_buffer);
        try self.writeStruct(SetIndexBufferCmd, cmd);
    }

    pub fn encodeSetPipeline(self: *CommandBuffer, cmd: SetPipelineCmd) Error!void {
        try self.writeOp(.set_pipeline);
        try self.writeStruct(SetPipelineCmd, cmd);
    }

    pub fn encodeDrawIndexed(self: *CommandBuffer, cmd: DrawIndexedCmd) Error!void {
        try self.writeOp(.draw_indexed);
        try self.writeStruct(DrawIndexedCmd, cmd);
    }

    pub fn encodeDrawIndirect(self: *CommandBuffer, cmd: DrawIndirectCmd) Error!void {
        try self.writeOp(.draw_indirect);
        try self.writeStruct(DrawIndirectCmd, cmd);
    }

    pub fn encodeDispatch(self: *CommandBuffer, cmd: DispatchCmd) Error!void {
        try self.writeOp(.dispatch);
        try self.writeStruct(DispatchCmd, cmd);
    }

    pub fn encodeDispatchIndirect(self: *CommandBuffer, cmd: DispatchIndirectCmd) Error!void {
        try self.writeOp(.dispatch_indirect);
        try self.writeStruct(DispatchIndirectCmd, cmd);
    }

    pub fn encodePipelineBarrier(self: *CommandBuffer, cmd: PipelineBarrierCmd) Error!void {
        try self.writeOp(.pipeline_barrier);
        try self.writeStruct(PipelineBarrierCmd, cmd);
    }

    pub fn encodePipelineBarriers(self: *CommandBuffer, cmds: []const PipelineBarrierCmd) Error!void {
        for (cmds) |cmd| {
            try self.encodePipelineBarrier(cmd);
        }
    }

    pub fn encodeDraw(self: *CommandBuffer, cmd: DrawCmd) Error!void {
        try self.writeOp(.draw);
        try self.writeStruct(DrawCmd, cmd);
    }

    pub fn encodePushUniform(self: *CommandBuffer, stage: u8, slot: u8, data: []const u8) Error!void {
        try self.writeOp(.push_uniform);
        try self.writeStruct(PushUniformCmd, .{
            .stage = stage,
            .slot = slot,
            .data_len = @intCast(data.len),
        });
        self.opcodes.appendSlice(self.allocator, data) catch return error.OutOfMemory;
    }

    pub fn encodeSetViewport(self: *CommandBuffer, cmd: SetViewportCmd) Error!void {
        try self.writeOp(.set_viewport);
        try self.writeStruct(SetViewportCmd, cmd);
    }

    pub fn encodeSetScissor(self: *CommandBuffer, cmd: SetScissorCmd) Error!void {
        try self.writeOp(.set_scissor);
        try self.writeStruct(SetScissorCmd, cmd);
    }

    pub fn encodeDecoded(self: *CommandBuffer, decoded: DecodedCommand) Error!void {
        switch (decoded) {
            .begin_render_pass => |cmd| try self.encodeBeginRenderPass(cmd),
            .end_render_pass => try self.encodeEndRenderPass(),
            .begin_compute_pass => |cmd| try self.encodeBeginComputePass(cmd),
            .end_compute_pass => try self.encodeEndComputePass(),
            .begin_copy_pass => |cmd| try self.encodeBeginCopyPass(cmd),
            .end_copy_pass => try self.encodeEndCopyPass(),
            .set_binding_set => |cmd| try self.encodeSetBindingSet(cmd),
            .set_vertex_buffer => |cmd| try self.encodeSetVertexBuffer(cmd),
            .set_index_buffer => |cmd| try self.encodeSetIndexBuffer(cmd),
            .set_pipeline => |cmd| try self.encodeSetPipeline(cmd),
            .draw_indexed => |cmd| try self.encodeDrawIndexed(cmd),
            .draw_indirect => |cmd| try self.encodeDrawIndirect(cmd),
            .dispatch => |cmd| try self.encodeDispatch(cmd),
            .dispatch_indirect => |cmd| try self.encodeDispatchIndirect(cmd),
            .pipeline_barrier => |cmd| try self.encodePipelineBarrier(cmd),
            .draw => |cmd| try self.encodeDraw(cmd),
            .push_uniform => |cmd| try self.encodePushUniform(cmd.header.stage, cmd.header.slot, cmd.data),
            .set_viewport => |cmd| try self.encodeSetViewport(cmd),
            .set_scissor => |cmd| try self.encodeSetScissor(cmd),
        }
    }

    pub fn decoder(self: *const CommandBuffer) Decoder {
        return Decoder.init(self.opcodes.items);
    }

    /// Raw byte slice for FFI — used by the Metal bridge to decode commands.
    pub fn rawBytes(self: *const CommandBuffer) []const u8 {
        return self.opcodes.items;
    }

    fn writeOp(self: *CommandBuffer, op: OpCode) Error!void {
        self.opcodes.append(self.allocator, @intFromEnum(op)) catch return error.OutOfMemory;
    }

    fn writeStruct(self: *CommandBuffer, comptime T: type, value: T) Error!void {
        const bytes = std.mem.asBytes(&value);
        self.opcodes.appendSlice(self.allocator, bytes) catch return error.OutOfMemory;
    }
};

pub const Decoder = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn init(bytes: []const u8) Decoder {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Decoder) Error!?DecodedCommand {
        if (self.cursor >= self.bytes.len) return null;

        const raw_op = self.bytes[self.cursor];
        self.cursor += 1;
        const op = std.meta.intToEnum(OpCode, raw_op) catch return error.InvalidOpcode;

        return switch (op) {
            .begin_render_pass => .{ .begin_render_pass = try self.readStruct(BeginRenderPassCmd) },
            .end_render_pass => .{ .end_render_pass = {} },
            .begin_compute_pass => .{ .begin_compute_pass = try self.readStruct(BeginComputePassCmd) },
            .end_compute_pass => .{ .end_compute_pass = {} },
            .begin_copy_pass => .{ .begin_copy_pass = try self.readStruct(BeginCopyPassCmd) },
            .end_copy_pass => .{ .end_copy_pass = {} },
            .set_binding_set => .{ .set_binding_set = try self.readStruct(SetBindingSetCmd) },
            .set_vertex_buffer => .{ .set_vertex_buffer = try self.readStruct(SetVertexBufferCmd) },
            .set_index_buffer => .{ .set_index_buffer = try self.readStruct(SetIndexBufferCmd) },
            .set_pipeline => .{ .set_pipeline = try self.readStruct(SetPipelineCmd) },
            .draw_indexed => .{ .draw_indexed = try self.readStruct(DrawIndexedCmd) },
            .draw_indirect => .{ .draw_indirect = try self.readStruct(DrawIndirectCmd) },
            .dispatch => .{ .dispatch = try self.readStruct(DispatchCmd) },
            .dispatch_indirect => .{ .dispatch_indirect = try self.readStruct(DispatchIndirectCmd) },
            .pipeline_barrier => .{ .pipeline_barrier = try self.readStruct(PipelineBarrierCmd) },
            .draw => .{ .draw = try self.readStruct(DrawCmd) },
            .push_uniform => blk: {
                const hdr = try self.readStruct(PushUniformCmd);
                const end = self.cursor + hdr.data_len;
                if (end > self.bytes.len) return error.TruncatedStream;
                const payload = self.bytes[self.cursor..end];
                self.cursor = end;
                break :blk .{ .push_uniform = .{
                    .header = hdr,
                    .data = payload,
                } };
            },
            .set_viewport => .{ .set_viewport = try self.readStruct(SetViewportCmd) },
            .set_scissor => .{ .set_scissor = try self.readStruct(SetScissorCmd) },
        };
    }

    fn readStruct(self: *Decoder, comptime T: type) Error!T {
        const size = @sizeOf(T);
        const end = self.cursor + size;
        if (end > self.bytes.len) return error.TruncatedStream;
        var value: T = undefined;
        @memcpy(std.mem.asBytes(&value), self.bytes[self.cursor..end]);
        self.cursor = end;
        return value;
    }
};

test "decoder readStruct handles unaligned stream" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(std.testing.allocator);

    try bytes.append(std.testing.allocator, 0xFF); // intentional misalignment
    const cmd = DrawIndexedCmd{ .index_count = 3, .instance_count = 1, .first_index = 0, .vertex_offset = 0, .first_instance = 0 };
    try bytes.appendSlice(std.testing.allocator, std.mem.asBytes(&cmd));

    var d = Decoder.init(bytes.items[1..]);
    const decoded = try d.readStruct(DrawIndexedCmd);
    try std.testing.expectEqual(cmd.index_count, decoded.index_count);
}

test "encodePipelineBarriers preserves barrier order" {
    var cb = CommandBuffer.init(std.testing.allocator);
    defer cb.deinit();

    try cb.encodePipelineBarriers(&.{
        .{
            .resource_id = 3,
            .src_state_bits = 1,
            .dst_state_bits = 2,
            .resource_kind = @intCast(@intFromEnum(ResourceKind.texture)),
        },
        .{
            .resource_id = 7,
            .src_state_bits = 4,
            .dst_state_bits = 8,
            .resource_kind = @intCast(@intFromEnum(ResourceKind.buffer)),
            .subresource_base = 2,
            .subresource_count = 4,
            .sync_action = @intCast(@intFromEnum(BarrierSyncAction.acquire)),
            .pass_scope = @intCast(@intFromEnum(BarrierPassScope.before_pass)),
        },
    });

    var decoder = cb.decoder();
    const first = (try decoder.next()).?.pipeline_barrier;
    const second = (try decoder.next()).?.pipeline_barrier;

    try std.testing.expectEqual(@as(u32, 3), first.resource_id);
    try std.testing.expectEqual(@as(u32, 7), second.resource_id);
    try std.testing.expectEqual(@as(u16, 2), second.subresource_base);
    try std.testing.expectEqual(@as(u16, 4), second.subresource_count);
    try std.testing.expectEqual(
        @as(u8, @intCast(@intFromEnum(BarrierPassScope.before_pass))),
        second.pass_scope,
    );
}
