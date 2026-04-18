const std = @import("std");

pub const PipelineLayoutCache = struct {
    const Key = struct {
        hash: u64,
    };

    allocator: std.mem.Allocator,
    map: std.AutoHashMap(Key, u32),
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) PipelineLayoutCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(Key, u32).init(allocator),
        };
    }

    pub fn deinit(self: *PipelineLayoutCache) void {
        self.map.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const PipelineLayoutCache, layout_ids: []const u32) ?u32 {
        return self.map.get(.{ .hash = hashLayoutIds(layout_ids) });
    }

    pub fn put(self: *PipelineLayoutCache, layout_ids: []const u32, pipeline_layout_id: u32) !void {
        try self.map.put(.{ .hash = hashLayoutIds(layout_ids) }, pipeline_layout_id);
    }

    pub fn nextSyntheticId(self: *PipelineLayoutCache) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn hashLayoutIds(layout_ids: []const u32) u64 {
        var h = std.hash.Wyhash.init(0);
        for (layout_ids) |id| {
            const bytes = std.mem.asBytes(&id);
            h.update(bytes);
        }
        return h.final();
    }
};

pub const BindingSetCacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,

    pub fn hitRate(self: BindingSetCacheStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }

    pub fn totalLookups(self: BindingSetCacheStats) u64 {
        return self.hits + self.misses;
    }

    /// Returns the difference (this - prev), useful for per-frame delta computation.
    pub fn delta(self: BindingSetCacheStats, prev: BindingSetCacheStats) BindingSetCacheStats {
        return .{
            .hits = self.hits -| prev.hits,
            .misses = self.misses -| prev.misses,
            .evictions = self.evictions -| prev.evictions,
        };
    }
};

pub const BindingSetCache = struct {
    const Key = struct {
        hash: u64,
    };

    pub const max_entries: u32 = 1024;

    allocator: std.mem.Allocator,
    map: std.AutoHashMap(Key, u32),
    /// FIFO eviction ring: stores hashes in insertion order.
    insertion_order: std.ArrayList(u64),
    next_id: u32 = 1,
    stats: BindingSetCacheStats = .{},

    pub fn init(allocator: std.mem.Allocator) BindingSetCache {
        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(Key, u32).init(allocator),
            .insertion_order = std.ArrayList(u64).empty,
        };
    }

    pub fn deinit(self: *BindingSetCache) void {
        self.insertion_order.deinit(self.allocator);
        self.map.deinit();
        self.* = undefined;
    }

    pub fn getByHash(self: *BindingSetCache, hash: u64) ?u32 {
        if (self.map.get(.{ .hash = hash })) |id| {
            self.stats.hits += 1;
            return id;
        }
        self.stats.misses += 1;
        return null;
    }

    pub fn putByHash(self: *BindingSetCache, hash: u64, binding_set_id: u32) !void {
        try self.map.put(.{ .hash = hash }, binding_set_id);
        try self.insertion_order.append(self.allocator, hash);
    }

    pub fn evictOldest(self: *BindingSetCache) ?u32 {
        if (self.insertion_order.items.len == 0) return null;
        const oldest_hash = self.insertion_order.orderedRemove(0);
        const key = Key{ .hash = oldest_hash };
        const id = self.map.get(key) orelse return null;
        _ = self.map.remove(key);
        self.stats.evictions += 1;
        return id;
    }

    pub fn nextSyntheticId(self: *BindingSetCache) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn resetStats(self: *BindingSetCache) void {
        self.stats = .{};
    }

    pub fn entryCount(self: *const BindingSetCache) u32 {
        return @intCast(self.map.count());
    }
};
