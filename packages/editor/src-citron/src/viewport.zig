const std = @import("std");
const citron = @import("citron");

const overlay = citron.handlers.iosurface_overlay;
const globals = citron.globals;

/// Viewport state for managing the engine rendering surface connection.
///
/// Uses the Citron IOSurface overlay module to create a zero-copy native
/// overlay window (child NSWindow with CALayer + CVDisplayLink) that
/// displays the engine's rendered frames directly from IOSurface.
pub const ViewportState = struct {
    attached: bool = false,
    surface_id: i64 = 0,
    shm_name: ?[]u8 = null,
    bounds: Bounds = .{},
    exclusions: std.ArrayList(Rect) = std.ArrayList(Rect).empty,
    allocator: std.mem.Allocator,
    overlay_created: bool = false,

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

        // Attach to the IOSurface by ID
        if (surface_id > 0) {
            const sid: u32 = @intCast(@as(u64, @bitCast(surface_id)));
            if (!overlay.attach(sid)) {
                return false;
            }
        }

        self.attached = true;

        // Notify frontend
        const payload = std.json.Stringify.valueAlloc(self.allocator, .{
            .attached = true,
            .surfaceId = surface_id,
            .bounds = .{ .x = x, .y = y, .w = w, .h = h },
        }, .{}) catch return true;
        defer self.allocator.free(payload);
        citron.ipc.enqueueEventJson("viewport.stateChanged", payload);

        return true;
    }

    /// Create the native overlay window. Must be called from the browser process
    /// after attachSurface, with a valid CEF browser reference.
    pub fn createNativeOverlay(self: *ViewportState, browser: *citron.cef.cef_browser_t) bool {
        if (!self.attached) return false;
        if (self.overlay_created) return true;

        if (overlay.createOverlay(browser)) {
            self.overlay_created = true;
            // Apply current bounds
            overlay.updateBounds(self.bounds.x, self.bounds.y, self.bounds.w, self.bounds.h);
            // Notify frontend that overlay is active
            citron.ipc.enqueueEventJson("viewport.overlayActive", "{\"active\":true}");
            return true;
        }
        return false;
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

        // Update the IOSurface overlay
        if (surface_id > 0) {
            const sid: u32 = @intCast(@as(u64, @bitCast(surface_id)));
            _ = overlay.updateSurface(sid);
        }
    }

    pub fn detach(self: *ViewportState) void {
        if (!self.attached) return;
        self.attached = false;
        self.surface_id = 0;
        self.overlay_created = false;

        // Destroy native overlay
        overlay.detach();

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
        if (self.overlay_created) {
            overlay.updateBounds(x, y, w, h);
        }
    }

    pub fn updateExclusions(self: *ViewportState, rects_json: []const u8) void {
        self.exclusions.clearRetainingCapacity();
        var parsed = std.json.parseFromSlice([]const [4]f64, self.allocator, rects_json, .{}) catch return;
        defer parsed.deinit();

        for (parsed.value) |r| {
            self.exclusions.append(self.allocator, .{ .x = r[0], .y = r[1], .w = r[2], .h = r[3] }) catch break;
        }

        if (self.overlay_created) {
            overlay.updateExclusions(parsed.value);
        }
    }

    pub fn getState(self: *const ViewportState) struct { attached: bool, surfaceId: i64, bounds: Bounds, overlayActive: bool } {
        return .{
            .attached = self.attached,
            .surfaceId = self.surface_id,
            .bounds = self.bounds,
            .overlayActive = self.overlay_created,
        };
    }
};
