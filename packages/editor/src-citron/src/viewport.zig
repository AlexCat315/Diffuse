const std = @import("std");
const citron = @import("citron");

const osr_module = citron.osr;
const globals = citron.globals;

/// Viewport state for managing the engine rendering surface connection.
///
/// Uses the Citron OSR module to display the engine's 3D scene on a CALayer
/// underneath the browser's CALayer.  The browser viewport area is transparent
/// (CSS background: transparent + CEF background_color = 0), so the scene
/// shows through.  React overlays render naturally on top as part of the
/// browser's composited content.
pub const ViewportState = struct {
    attached: bool = false,
    surface_id: i64 = 0,
    shm_name: ?[]u8 = null,
    bounds: Bounds = .{},
    allocator: std.mem.Allocator,
    scene_active: bool = false,

    pub const Bounds = struct {
        x: f64 = 0,
        y: f64 = 0,
        w: f64 = 0,
        h: f64 = 0,
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

        // Attach the IOSurface to the OSR scene layer
        std.debug.print("[viewport] attachSurface called: sid={d} bounds=({d:.0},{d:.0},{d:.0},{d:.0})\n", .{ surface_id, x, y, w, h });
        if (surface_id > 0) {
            const sid: u32 = @intCast(@as(u64, @bitCast(surface_id)));
            std.debug.print("[viewport] calling osr_module.attachSceneSurface({d})\n", .{sid});
            if (!osr_module.attachSceneSurface(sid)) {
                std.debug.print("[viewport] attachSceneSurface FAILED\n", .{});
                return false;
            }
            std.debug.print("[viewport] attachSceneSurface OK\n", .{});
            self.scene_active = true;
        }

        self.attached = true;

        // Apply bounds to position the scene layer
        osr_module.updateSceneBounds(x, y, w, h);

        // Notify frontend
        const payload = std.json.Stringify.valueAlloc(self.allocator, .{
            .attached = true,
            .surfaceId = surface_id,
            .bounds = .{ .x = x, .y = y, .w = w, .h = h },
        }, .{}) catch return true;
        defer self.allocator.free(payload);
        citron.ipc.enqueueEventJson("viewport.stateChanged", payload);

        // Notify that overlay is active
        citron.ipc.enqueueEventJson("viewport.overlayActive", "{\"active\":true}");

        return true;
    }

    /// Create the native overlay — now a no-op since OSR handles it.
    pub fn createNativeOverlay(self: *ViewportState, browser: *citron.cef.cef_browser_t) bool {
        _ = browser;
        if (!self.attached) return false;
        // In OSR mode, the scene layer is already managed by the OSR module.
        // Just notify the frontend.
        if (!self.scene_active and self.surface_id > 0) {
            const sid: u32 = @intCast(@as(u64, @bitCast(self.surface_id)));
            if (osr_module.attachSceneSurface(sid)) {
                self.scene_active = true;
                osr_module.updateSceneBounds(self.bounds.x, self.bounds.y, self.bounds.w, self.bounds.h);
                citron.ipc.enqueueEventJson("viewport.overlayActive", "{\"active\":true}");
            }
        }
        return self.scene_active;
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

        // Update the scene IOSurface
        if (surface_id > 0) {
            const sid: u32 = @intCast(@as(u64, @bitCast(surface_id)));
            _ = osr_module.updateSceneSurface(sid);
        }
    }

    pub fn detach(self: *ViewportState) void {
        if (!self.attached) return;
        self.attached = false;
        self.surface_id = 0;
        self.scene_active = false;

        // Detach scene from OSR
        osr_module.detachScene();

        if (self.shm_name) |name| {
            self.allocator.free(name);
            self.shm_name = null;
        }

        const payload = std.json.Stringify.valueAlloc(self.allocator, .{
            .attached = false,
        }, .{}) catch return;
        defer self.allocator.free(payload);
        citron.ipc.enqueueEventJson("viewport.stateChanged", payload);
    }

    pub fn updateBounds(self: *ViewportState, x: f64, y: f64, w: f64, h: f64) void {
        self.bounds = .{ .x = x, .y = y, .w = w, .h = h };
        if (self.scene_active) {
            osr_module.updateSceneBounds(x, y, w, h);
        }
    }

    pub fn getState(self: *const ViewportState) struct { attached: bool, surfaceId: i64, bounds: Bounds, overlayActive: bool } {
        return .{
            .attached = self.attached,
            .surfaceId = self.surface_id,
            .bounds = self.bounds,
            .overlayActive = self.scene_active,
        };
    }
};
