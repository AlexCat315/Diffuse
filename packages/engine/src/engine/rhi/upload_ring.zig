const std = @import("std");
const rhi = @import("rhi.zig");

pub const SubAlloc = struct {
    cpu_slice: []u8,
    gpu_offset: u64,
    buffer: rhi.Buffer,
};

pub const UploadRing = struct {
    const Chunk = struct {
        storage: []u8,
        buffer: rhi.Buffer,
        offset: usize,
        capacity: usize,
        version: u64,
    };

    allocator: std.mem.Allocator,
    chunks: std.ArrayList(Chunk),
    free_indices: std.ArrayList(usize),
    current_index: ?usize = null,
    frame_version: u64 = 0,
    chunk_size: usize = 64 * 1024,
    next_buffer_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, chunk_size: usize) UploadRing {
        return .{
            .allocator = allocator,
            .chunks = .empty,
            .free_indices = .empty,
            .chunk_size = if (chunk_size == 0) 64 * 1024 else chunk_size,
        };
    }

    pub fn deinit(self: *UploadRing) void {
        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk.storage);
        }
        self.chunks.deinit(self.allocator);
        self.free_indices.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn beginFrame(self: *UploadRing, frame_version: u64) void {
        self.frame_version = frame_version;
        self.current_index = null;
    }

    pub fn onFrameComplete(self: *UploadRing, completed_version: u64) !void {
        self.free_indices.clearRetainingCapacity();
        for (self.chunks.items, 0..) |*chunk, index| {
            if (chunk.version <= completed_version) {
                chunk.offset = 0;
                try self.free_indices.append(self.allocator, index);
            }
        }
    }

    pub fn suballocate(self: *UploadRing, size: usize, alignment: usize) !SubAlloc {
        if (size == 0) return error.InvalidSize;
        const aligned_requirement = if (alignment == 0) 1 else alignment;

        if (self.current_index) |index| {
            if (try self.trySuballocateInChunk(index, size, aligned_requirement)) |alloc| {
                return alloc;
            }
        }

        if (self.free_indices.items.len > 0) {
            const reused_index = self.free_indices.pop().?;
            self.current_index = reused_index;
            if (try self.trySuballocateInChunk(reused_index, size, aligned_requirement)) |alloc| {
                return alloc;
            }
        }

        const capacity = @max(self.chunk_size, std.mem.alignForward(usize, size, aligned_requirement));
        const storage = try self.allocator.alloc(u8, capacity);
        const chunk = Chunk{
            .storage = storage,
            .buffer = .{ .id = self.next_buffer_id },
            .offset = 0,
            .capacity = capacity,
            .version = self.frame_version,
        };
        self.next_buffer_id += 1;
        try self.chunks.append(self.allocator, chunk);
        const new_index = self.chunks.items.len - 1;
        self.current_index = new_index;

        return (try self.trySuballocateInChunk(new_index, size, aligned_requirement)).?;
    }

    fn trySuballocateInChunk(self: *UploadRing, chunk_index: usize, size: usize, alignment: usize) !?SubAlloc {
        var chunk = &self.chunks.items[chunk_index];
        const aligned_offset = std.mem.alignForward(usize, chunk.offset, alignment);
        const end = aligned_offset + size;
        if (end > chunk.capacity) return null;

        chunk.offset = end;
        chunk.version = self.frame_version;
        return .{
            .cpu_slice = chunk.storage[aligned_offset..end],
            .gpu_offset = @intCast(aligned_offset),
            .buffer = chunk.buffer,
        };
    }
};

test "upload ring reuses chunk after frame complete" {
    var ring = UploadRing.init(std.testing.allocator, 64);
    defer ring.deinit();

    ring.beginFrame(1);
    const a = try ring.suballocate(16, 8);
    try std.testing.expect(a.buffer.id != 0);

    try ring.onFrameComplete(1);
    ring.beginFrame(2);
    const b = try ring.suballocate(16, 8);
    try std.testing.expectEqual(a.buffer.id, b.buffer.id);
}

test "upload ring creates new chunk when full" {
    var ring = UploadRing.init(std.testing.allocator, 32);
    defer ring.deinit();

    ring.beginFrame(1);
    const first = try ring.suballocate(24, 8);
    const second = try ring.suballocate(24, 8);
    try std.testing.expect(first.buffer.id != second.buffer.id);
}
