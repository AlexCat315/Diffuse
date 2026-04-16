const std = @import("std");
const citron = @import("citron");

/// Popout window management for the Citron CEF runtime.
///
/// CEF supports creating additional browser windows. Each popout window
/// loads the same frontend URL with a `?popout=panelId1,panelId2` query
/// parameter. The frontend detects this and renders only the specified panels.
///
/// Since Citron's current framework only manages a single browser window,
/// popout state is tracked here and the frontend receives events to
/// coordinate multi-panel layouts. Real multi-window support requires
/// framework changes to CEF's life span handler.
///
/// For now, this module provides a "virtual popout" approach:
/// - Panels are tracked in-memory with their state
/// - The frontend receives events to manage floating panels within the
///   single window (similar to VS Code's editor groups / floating panels)
/// - When framework multi-window support is added, this module can be
///   upgraded to spawn actual CEF browser windows.
pub const PopoutManager = struct {
    allocator: std.mem.Allocator,
    next_id: i32 = 1,
    entries: std.ArrayList(PopoutEntry) = std.ArrayList(PopoutEntry).empty,

    pub const PopoutEntry = struct {
        id: i32,
        panels: [][]u8,
        origin_info: ?[]u8 = null,
        bounds: Bounds = .{},
    };

    pub const Bounds = struct {
        x: i32 = 0,
        y: i32 = 0,
        width: i32 = 600,
        height: i32 = 500,
    };

    pub fn init(allocator: std.mem.Allocator) PopoutManager {
        return .{ .allocator = allocator };
    }

    pub fn popoutPanel(self: *PopoutManager, panels_json: []const u8, origin_info_json: ?[]const u8, bounds_json: ?[]const u8) !i32 {
        const id = self.next_id;
        self.next_id += 1;

        // Parse panels array
        var parsed = try std.json.parseFromSlice([]const []const u8, self.allocator, panels_json, .{});
        defer parsed.deinit();

        var owned_panels = std.ArrayList([]u8).empty;
        for (parsed.value) |panel| {
            try owned_panels.append(self.allocator, try self.allocator.dupe(u8, panel));
        }

        var entry = PopoutEntry{
            .id = id,
            .panels = try owned_panels.toOwnedSlice(self.allocator),
        };

        if (origin_info_json) |info| {
            entry.origin_info = try self.allocator.dupe(u8, info);
        }

        if (bounds_json) |b| {
            var bp = std.json.parseFromSlice(Bounds, self.allocator, b, .{ .ignore_unknown_fields = true }) catch null;
            if (bp) |*p| {
                entry.bounds = p.value;
                p.deinit();
            }
        }

        try self.entries.append(self.allocator, entry);

        // Notify frontend
        const payload = std.json.Stringify.valueAlloc(self.allocator, .{
            .id = id,
            .panels = parsed.value,
            .bounds = entry.bounds,
        }, .{}) catch return id;
        defer self.allocator.free(payload);
        citron.ipc.enqueueEventJson("popout.opened", payload);

        return id;
    }

    pub fn closePopout(self: *PopoutManager, id: i32) void {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.id == id) {
                // Emit closed event
                var panel_names = std.ArrayList([]const u8).empty;
                for (entry.panels) |panel| {
                    panel_names.append(self.allocator, panel) catch break;
                }
                defer panel_names.deinit(self.allocator);

                const payload = std.json.Stringify.valueAlloc(self.allocator, .{
                    .id = id,
                    .panels = panel_names.items,
                    .bounds = entry.bounds,
                }, .{}) catch return;
                defer self.allocator.free(payload);
                citron.ipc.enqueueEventJson("popout.closed", payload);

                // Free resources
                for (entry.panels) |panel| self.allocator.free(panel);
                self.allocator.free(entry.panels);
                if (entry.origin_info) |info| self.allocator.free(info);
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }

    pub fn getPanels(self: *const PopoutManager) []const PopoutEntry {
        return self.entries.items;
    }

    pub fn isPopoutId(self: *const PopoutManager, id: i32) bool {
        for (self.entries.items) |entry| {
            if (entry.id == id) return true;
        }
        return false;
    }
};
