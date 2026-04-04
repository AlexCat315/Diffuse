//! Game save/load system — persistent game state with named slots.
//!
//! Builds on top of the scene serialization (`scene_io`) to provide a
//! player-facing save/load mechanism with:
//!
//! - **Named save slots** — numbered or named save files
//! - **Metadata** — timestamp, play time, scene name, custom tags
//! - **Quick save/load** — convenience API for immediate save/restore
//! - **Runtime noise filtering** — editor-only entities excluded automatically
//!
//! ## Directory Layout
//!
//! ```
//! saves/
//!   quicksave/
//!     world.guava_save
//!     meta.json
//!   slot_1/
//!     world.guava_save
//!     meta.json
//!   slot_2/
//!     ...
//! ```
//!
//! ## Usage
//!
//! ```zig
//! var save_sys = SaveSystem.init(allocator, "saves");
//! defer save_sys.deinit();
//!
//! // Save to slot 1
//! try save_sys.save(world, runtime_state, .{ .slot = 1, .display_name = "Before boss" });
//!
//! // Quick save
//! try save_sys.quickSave(world, runtime_state);
//!
//! // List slots
//! const slots = try save_sys.listSlots();
//! defer allocator.free(slots);
//!
//! // Load
//! try save_sys.load(world, 1, &runtime_state);
//! ```

const std = @import("std");
const scene_io = @import("scene_io.zig");
const world_mod = @import("world.zig");

pub const SceneRuntimeState = scene_io.SceneRuntimeState;

// ---------------------------------------------------------------------------
// Save metadata
// ---------------------------------------------------------------------------

pub const SaveMeta = struct {
    /// Save system format version.
    version: u32 = 1,
    /// Slot number (0 = quicksave).
    slot: u32 = 0,
    /// Player-visible display name.
    display_name: []const u8 = "",
    /// RFC-3339-ish timestamp string (e.g. "2025-07-17T12:34:56").
    timestamp: []const u8 = "",
    /// Total play time in seconds at time of save.
    play_time_seconds: f32 = 0,
    /// Name of the active scene.
    scene_name: []const u8 = "",
    /// Number of entities in the saved world.
    entity_count: u32 = 0,
    /// Arbitrary user tags (e.g. "chapter_3", "before_boss").
    tags: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// Save options
// ---------------------------------------------------------------------------

pub const SaveOptions = struct {
    /// Slot number. 0 = quicksave.
    slot: u32 = 0,
    /// Optional display name; if empty, auto-generated.
    display_name: []const u8 = "",
    /// Total play time so far (seconds).
    play_time_seconds: f32 = 0,
    /// Name of the current scene (for display).
    scene_name: []const u8 = "",
    /// Arbitrary tags.
    tags: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// SaveSystem
// ---------------------------------------------------------------------------

pub const SaveSystem = struct {
    allocator: std.mem.Allocator,
    /// Root directory for saves (relative to cwd).
    root_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, root_dir: []const u8) SaveSystem {
        return .{ .allocator = allocator, .root_dir = root_dir };
    }

    pub fn deinit(self: *SaveSystem) void {
        _ = self;
        // No owned resources to free.
    }

    // -- Save ---------------------------------------------------------------

    /// Save the current world + runtime state to the given slot.
    pub fn save(
        self: *SaveSystem,
        world: *const world_mod.World,
        runtime_state: SceneRuntimeState,
        options: SaveOptions,
    ) !void {
        const slot_dir = try self.slotPath(options.slot);
        defer self.allocator.free(slot_dir);

        // Ensure directory exists.
        try std.fs.cwd().makePath(slot_dir);

        // 1. Serialize world with runtime state.
        const world_data = try scene_io.serializeWorldWithRuntimeStateAlloc(
            self.allocator,
            world,
            runtime_state,
        );
        defer self.allocator.free(world_data);

        // Write world file.
        const world_path = try std.fmt.allocPrint(self.allocator, "{s}/world.guava_save", .{slot_dir});
        defer self.allocator.free(world_path);
        try std.fs.cwd().writeFile(.{ .sub_path = world_path, .data = world_data });

        // 2. Build metadata.
        var ts_buf: [32]u8 = undefined;
        const ts = timestampNow(&ts_buf);

        const display = if (options.display_name.len > 0)
            options.display_name
        else
            ts;

        const meta = SaveMeta{
            .slot = options.slot,
            .display_name = display,
            .timestamp = ts,
            .play_time_seconds = options.play_time_seconds,
            .scene_name = options.scene_name,
            .entity_count = @intCast(world.entities.items.len),
            .tags = options.tags,
        };

        const meta_data = try serializeMetaAlloc(self.allocator, meta);
        defer self.allocator.free(meta_data);

        const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/meta.json", .{slot_dir});
        defer self.allocator.free(meta_path);
        try std.fs.cwd().writeFile(.{ .sub_path = meta_path, .data = meta_data });
    }

    /// Quick save (slot 0).
    pub fn quickSave(
        self: *SaveSystem,
        world: *const world_mod.World,
        runtime_state: SceneRuntimeState,
    ) !void {
        try self.save(world, runtime_state, .{ .slot = 0, .display_name = "Quick Save" });
    }

    // -- Load ---------------------------------------------------------------

    /// Load world + runtime state from the given slot.
    pub fn load(
        self: *SaveSystem,
        world: *world_mod.World,
        slot: u32,
        runtime_state: ?*SceneRuntimeState,
    ) !void {
        const world_path = try self.worldFilePath(slot);
        defer self.allocator.free(world_path);
        try scene_io.loadWorldWithRuntimeStateFromPath(self.allocator, world, world_path, runtime_state);
    }

    /// Quick load (slot 0).
    pub fn quickLoad(
        self: *SaveSystem,
        world: *world_mod.World,
        runtime_state: ?*SceneRuntimeState,
    ) !void {
        try self.load(world, 0, runtime_state);
    }

    // -- Metadata queries ---------------------------------------------------

    /// Read metadata for a specific slot.
    /// The returned SaveMeta owns all string memory and must be released
    /// with `freeMeta`.
    pub fn readMeta(self: *SaveSystem, slot: u32) !SaveMeta {
        const meta_path = try self.metaFilePath(slot);
        defer self.allocator.free(meta_path);

        const data = std.fs.cwd().readFileAlloc(self.allocator, meta_path, 64 * 1024) catch
            return error.SlotNotFound;
        defer self.allocator.free(data);

        const parsed = std.json.parseFromSlice(SaveMeta, self.allocator, data, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return error.InvalidMetadata;
        defer parsed.deinit();

        return try cloneSaveMetaAlloc(self.allocator, parsed.value);
    }

    /// Free a metadata snapshot returned by `readMeta` / `listSlots`.
    pub fn freeMeta(self: *SaveSystem, meta: *SaveMeta) void {
        freeSaveMetaOwned(self.allocator, meta);
    }

    /// List all populated save slots (returns owned slice of SaveMeta).
    /// Caller must call `freeMeta` for each entry, then free the returned slice.
    pub fn listSlots(self: *SaveSystem) ![]SaveMeta {
        var result: std.ArrayListUnmanaged(SaveMeta) = .empty;
        errdefer {
            for (result.items) |*meta| self.freeMeta(meta);
            result.deinit(self.allocator);
        }

        // Scan for slot directories: quicksave + slot_1..slot_N
        const max_slot: u32 = 100; // scan up to 100 slots
        var slot: u32 = 0;
        while (slot <= max_slot) : (slot += 1) {
            const meta = self.readMeta(slot) catch continue;
            try result.append(self.allocator, meta);
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Check if a slot has a save.
    pub fn slotExists(self: *SaveSystem, slot: u32) bool {
        const meta_path = self.metaFilePath(slot) catch return false;
        defer self.allocator.free(meta_path);

        std.fs.cwd().access(meta_path, .{}) catch return false;
        return true;
    }

    // -- Delete -------------------------------------------------------------

    /// Delete a save slot.
    pub fn deleteSlot(self: *SaveSystem, slot: u32) !void {
        const slot_dir = try self.slotPath(slot);
        defer self.allocator.free(slot_dir);

        // Delete files in the slot directory.
        const world_path = try self.worldFilePath(slot);
        defer self.allocator.free(world_path);
        std.fs.cwd().deleteFile(world_path) catch |err| {
            std.log.err("failed to delete save world file: {s}", .{@errorName(err)});
        };

        const meta_path = try self.metaFilePath(slot);
        defer self.allocator.free(meta_path);
        std.fs.cwd().deleteFile(meta_path) catch |err| {
            std.log.err("failed to delete save meta file: {s}", .{@errorName(err)});
        };

        // Try to remove the directory (only succeeds if empty).
        std.fs.cwd().deleteDir(slot_dir) catch |err| {
            std.log.err("failed to delete save slot directory: {s}", .{@errorName(err)});
        };
    }

    // -- Path helpers -------------------------------------------------------

    fn slotDirName(slot: u32) [32]u8 {
        var buf: [32]u8 = undefined;
        if (slot == 0) {
            const name = "quicksave";
            @memcpy(buf[0..name.len], name);
            buf[name.len] = 0;
        } else {
            _ = std.fmt.bufPrint(&buf, "slot_{d}", .{slot}) catch unreachable;
        }
        return buf;
    }

    fn slotPath(self: *SaveSystem, slot: u32) ![]u8 {
        const dir_name = slotDirName(slot);
        const name = std.mem.sliceTo(&dir_name, 0);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root_dir, name });
    }

    fn worldFilePath(self: *SaveSystem, slot: u32) ![]u8 {
        const dir_name = slotDirName(slot);
        const name = std.mem.sliceTo(&dir_name, 0);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/world.guava_save", .{ self.root_dir, name });
    }

    fn metaFilePath(self: *SaveSystem, slot: u32) ![]u8 {
        const dir_name = slotDirName(slot);
        const name = std.mem.sliceTo(&dir_name, 0);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/meta.json", .{ self.root_dir, name });
    }
};

// ---------------------------------------------------------------------------
// JSON serialization helper
// ---------------------------------------------------------------------------

fn serializeMetaAlloc(allocator: std.mem.Allocator, meta: SaveMeta) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    var legacy_writer = output.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var writer_adapter = legacy_writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(meta, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();
    if (writer_adapter.err) |err| {
        return err;
    }
    return output.toOwnedSlice(allocator);
}

fn cloneSaveMetaAlloc(allocator: std.mem.Allocator, src: SaveMeta) !SaveMeta {
    var tags: []const []const u8 = &.{};
    if (src.tags.len > 0) {
        tags = try allocator.alloc([]const u8, src.tags.len);
        var i: usize = 0;
        errdefer {
            while (i > 0) : (i -= 1) {
                if (tags[i - 1].len > 0) allocator.free(tags[i - 1]);
            }
            allocator.free(tags);
        }
        for (src.tags, 0..) |tag, idx| {
            tags[idx] = if (tag.len > 0) try allocator.dupe(u8, tag) else &.{};
            i += 1;
        }
    }

    return .{
        .version = src.version,
        .slot = src.slot,
        .display_name = if (src.display_name.len > 0) try allocator.dupe(u8, src.display_name) else &.{},
        .timestamp = if (src.timestamp.len > 0) try allocator.dupe(u8, src.timestamp) else &.{},
        .play_time_seconds = src.play_time_seconds,
        .scene_name = if (src.scene_name.len > 0) try allocator.dupe(u8, src.scene_name) else &.{},
        .entity_count = src.entity_count,
        .tags = tags,
    };
}

fn freeSaveMetaOwned(allocator: std.mem.Allocator, meta: *SaveMeta) void {
    if (meta.display_name.len > 0) allocator.free(meta.display_name);
    if (meta.timestamp.len > 0) allocator.free(meta.timestamp);
    if (meta.scene_name.len > 0) allocator.free(meta.scene_name);
    if (meta.tags.len > 0) {
        for (meta.tags) |tag| {
            if (tag.len > 0) allocator.free(tag);
        }
        allocator.free(meta.tags);
    }
    meta.* = .{};
}

// ---------------------------------------------------------------------------
// Timestamp helper
// ---------------------------------------------------------------------------

fn timestampNow(buf: *[32]u8) []const u8 {
    // Use epoch seconds to generate a simple timestamp.
    // In a real implementation this would use std.time.timestamp() or platform API.
    const epoch = std.time.timestamp();
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch) };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();

    const len = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        @as(u32, @intFromEnum(md.month)) + 1,
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch return "unknown";
    return buf[0..len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "slotDirName quicksave" {
    const buf = SaveSystem.slotDirName(0);
    const name = std.mem.sliceTo(&buf, 0);
    try std.testing.expectEqualStrings("quicksave", name);
}

test "slotDirName slot_3" {
    const buf = SaveSystem.slotDirName(3);
    const name = std.mem.sliceTo(&buf, 0);
    try std.testing.expectEqualStrings("slot_3", name);
}

test "timestampNow format" {
    var buf: [32]u8 = undefined;
    const ts = timestampNow(&buf);
    // Should look like "YYYY-MM-DDTHH:MM:SS"
    try std.testing.expect(ts.len >= 19);
    try std.testing.expectEqual(@as(u8, '-'), ts[4]);
    try std.testing.expectEqual(@as(u8, 'T'), ts[10]);
}

test "clone/free SaveMeta owned snapshot" {
    const allocator = std.testing.allocator;
    const src = SaveMeta{
        .version = 1,
        .slot = 2,
        .display_name = "Before boss",
        .timestamp = "2026-01-01T00:00:00",
        .play_time_seconds = 42.5,
        .scene_name = "chapter_3",
        .entity_count = 123,
        .tags = &.{ "chapter_3", "boss_gate" },
    };

    var cloned = try cloneSaveMetaAlloc(allocator, src);
    defer freeSaveMetaOwned(allocator, &cloned);

    try std.testing.expectEqual(@as(u32, 2), cloned.slot);
    try std.testing.expectEqualStrings("Before boss", cloned.display_name);
    try std.testing.expectEqualStrings("chapter_3", cloned.scene_name);
    try std.testing.expectEqual(@as(usize, 2), cloned.tags.len);
    try std.testing.expectEqualStrings("boss_gate", cloned.tags[1]);
}
