const std = @import("std");
const gfx_mod = @import("render_context.zig");
const id_pass_mod = @import("passes/id_pass.zig");
const selection_history_mod = @import("selection_history.zig");

const selection_readback_bytes: u32 = 4;

pub const SelectionReadbackRequest = struct {
    pixel_x: u32,
    pixel_y: u32,
    mode: selection_history_mod.SelectionUpdateMode,
};

pub const InFlightSelectionReadback = struct {
    request: SelectionReadbackRequest,
    offset: u32,
};

pub const InFlightSelectionBatch = struct {
    fence: gfx_mod.Fence,
    transfer_buffer: gfx_mod.TransferBuffer,
    readbacks: []InFlightSelectionReadback,

    pub fn deinit(self: *InFlightSelectionBatch, allocator: std.mem.Allocator, device: *gfx_mod.RenderContext) void {
        device.releaseTransferBuffer(&self.transfer_buffer);
        allocator.free(self.readbacks);
        device.releaseFence(&self.fence);
        self.* = undefined;
    }
};

pub fn enqueueSelectionReadbacks(
    allocator: std.mem.Allocator,
    gfx: *gfx_mod.RenderContext,
    frame: gfx_mod.Frame,
    id_texture: *const gfx_mod.Texture,
    pending: []SelectionReadbackRequest,
    in_flight_batches: *std.ArrayList(InFlightSelectionBatch),
) !void {
    const total_buffer_size = std.math.cast(u32, pending.len * @as(usize, selection_readback_bytes)) orelse return error.OutOfMemory;
    const id_texture_desc = gfx.textureDesc(id_texture);

    if (id_texture_desc.width == 0 or id_texture_desc.height == 0) {
        try gfx.submitFrame(frame);
        for (pending) |request| {
            _ = request;
        }
        return;
    }

    var readbacks = try allocator.alloc(InFlightSelectionReadback, pending.len);
    errdefer allocator.free(readbacks);

    var transfer_buffer = try gfx.createTransferBuffer(.{
        .size = total_buffer_size,
        .upload = false,
    });
    errdefer gfx.releaseTransferBuffer(&transfer_buffer);

    for (pending, 0..) |request, index| {
        readbacks[index] = .{
            .request = request,
            .offset = std.math.cast(u32, index * @as(usize, selection_readback_bytes)) orelse return error.OutOfMemory,
        };
    }

    const copy_pass = try gfx.beginCopyPass(frame);

    for (readbacks) |readback| {
        const pixel_x = @min(readback.request.pixel_x, id_texture_desc.width - 1);
        const pixel_y = @min(readback.request.pixel_y, id_texture_desc.height - 1);
        gfx.downloadTexturePixelToOffset(copy_pass, id_texture, &transfer_buffer, readback.offset, pixel_x, pixel_y);
    }

    gfx.endCopyPass(copy_pass);

    var fence = try gfx.submitFrameAndAcquireFence(frame);
    errdefer gfx.releaseFence(&fence);

    try in_flight_batches.append(allocator, .{
        .fence = fence,
        .transfer_buffer = transfer_buffer,
        .readbacks = readbacks,
    });
}

pub fn resolveSelectionReadbacks(
    allocator: std.mem.Allocator,
    gfx: *gfx_mod.RenderContext,
    in_flight_batches: *std.ArrayList(InFlightSelectionBatch),
    selection_history: *selection_history_mod.SelectionHistory,
) !void {
    while (in_flight_batches.items.len > 0) {
        if (!gfx.isFenceSignaled(&in_flight_batches.items[0].fence)) {
            break;
        }

        var batch = in_flight_batches.orderedRemove(0);
        defer batch.deinit(allocator, gfx);

        for (batch.readbacks) |readback| {
            var pixel: [4]u8 = undefined;
            try gfx.readTransferBufferBytesAt(&batch.transfer_buffer, readback.offset, pixel[0..]);
            const entity = id_pass_mod.decodeEntityIdBgra(pixel);
            _ = try selection_history.applyPick(entity, readback.request.mode);
        }
    }
}

pub fn releaseInFlightSelectionBatches(
    allocator: std.mem.Allocator,
    gfx: *gfx_mod.RenderContext,
    in_flight_batches: *std.ArrayList(InFlightSelectionBatch),
) void {
    for (in_flight_batches.items) |*batch| {
        batch.deinit(allocator, gfx);
    }
    in_flight_batches.deinit(allocator);
}
