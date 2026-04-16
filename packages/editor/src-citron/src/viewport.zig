const std = @import("std");
const citron = @import("citron");

const globals = citron.globals;

/// Viewport state for managing the engine rendering surface connection.
///
/// In the Citron CEF runtime, native IOSurface overlay is not available.
/// Instead, the viewport uses an IPC pixel streaming path:
/// 1. Frontend requests attach with surface_id from the engine
/// 2. Backend tracks the surface state and periodically polls pixel data
/// 3. Pixel data is pushed to frontend via `viewport.pixels` events
///
/// For the initial implementation, we manage the attachment state and let
/// the frontend handle rendering via its existing WebSocket connection to
/// the engine for viewport frame data.
pub const ViewportState = struct {
    attached: bool = false,
    surface_id: i64 = 0,
    shm_name: ?[]u8 = null,
    bounds: Bounds = .{},
    exclusions: std.ArrayList(Rect) = std.ArrayList(Rect).empty,
    allocator: std.mem.Allocator,

    pub const Bounds = struct {
        x: f64 = 0,
        y: f64 = 0,
        w: f64 = 0,
        h: f64 = 0,
    };

    pub const Rect = struct {
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    };

    pub fn init(allocator: std.mem.Allocator) ViewportState {
        return .{ .allocator = allocator };
    }

    pub fn attachSurface(self: *ViewportState, surface_id: i64, x: f64, y: f64, w: f64, h: f64, shm_name: ?[]const u8) !bool {
        self.detach();
        self.surface_id = surface_id;
        self.bounds = .{ .x = x, .y = y, .w = w, .h = h };
        if (shm_name) |name| {
            self.shm_name = try self.allocator.dupe(u8, name);
        }
        self.attached = true;

        // Notify frontend that viewport is now active
        const payload = std.json.Stringify.valueAlloc(self.allocator, .{
            .attached = true,
            .surfaceId = surface_id,
            .bounds = .{ .x = x, .y = y, .w = w, .h = h },
        }, .{}) catch return true;
        defer self.allocator.free(payload);
        citron.ipc.enqueueEventJson("viewport.stateChanged", payload);

        return true;
    }

    pub fn updateSurface(self: *ViewportState, surface_id: i64, shm_name: ?[]const u8, width: ?f64, height: ?f64) void {
        if (!self.attached) return;
        self.surface_id = surface_id;
        if (shm_name) |name| {
            if (self.shm_name) |old| self.allocator.free(old);
            self.shm_name = self.allocator.dupe(u8, name) catch null;
        }
        if (width) |w| self.bounds.w = w;
        if (height) |h| self.bounds.h = h;
    }

    pub fn detach(self: *ViewportState) void {
        if (!self.attached) return;
        self.attached = false;
        self.surface_id = 0;
        if (self.shm_name) |name| {
            self.allocator.free(name);
            self.shm_name = null;
        }
        self.exclusions.clearAndFree(self.allocator);

        const payload = std.json.Stringify.valueAlloc(self.allocator, .{
            .attached = false,
        }, .{}) catch return;
        defer self.allocator.free(payload);
        citron.ipc.enqueueEventJson("viewport.stateChanged", payload);
    }

    pub fn updateBounds(self: *ViewportState, x: f64, y: f64, w: f64, h: f64) void {
        self.bounds = .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn updateExclusions(self: *ViewportState, rects_json: []const u8) void {
        self.exclusions.clearRetainingCapacity();
        var parsed = std.json.parseFromSlice([]const [4]f64, self.allocator, rects_json, .{}) catch return;
        defer parsed.deinit();

        for (parsed.value) |r| {
            self.exclusions.append(self.allocator, .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] }) catch break;
        }
    }

    pub fn getState(self: *const ViewportState) struct { attached: bool, surfaceId: i64, bounds: Bounds } {
        return .{
            .attached = self.attached,
            .surfaceId = self.surface_id,
            .bounds = self.bounds,
        };
    }
};
