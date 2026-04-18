const rt_backend = @import("../rt/rt_backend.zig");

/// RHI-level Ray Tracing abstraction.
///
/// Wraps the platform-specific RT backend (Metal RT on macOS, future Vulkan RT)
/// behind a unified interface that integrates with the rest of the RHI.
/// The renderer uses this instead of directly touching rt_metal.zig.
pub const RtDevice = struct {
    backend: ?rt_backend.HardwareRtBackend = null,
    initialized: bool = false,

    pub const SceneSyncDesc = struct {
        triangles: ?[]const rt_backend.RtTriangle = null,
        texture_data: []const u8 = &.{},
        texture_meta: []const rt_backend.RtTextureMeta = &.{},
        sampling_table_data: []const u8 = &.{},
        sampling_table_meta: []const rt_backend.RtSamplingTableMeta = &.{},
    };

    pub fn init() RtDevice {
        var self = RtDevice{};
        self.backend = rt_backend.HardwareRtBackend.init();
        self.initialized = self.backend != null;
        return self;
    }

    pub fn initAvailable() ?RtDevice {
        var self = RtDevice.init();
        if (!self.isAvailable()) {
            self.deinit();
            return null;
        }
        return self;
    }

    pub fn deinit(self: *RtDevice) void {
        if (self.backend) |*b| b.deinit();
        self.* = .{};
    }

    pub fn isAvailable(self: *const RtDevice) bool {
        if (self.backend) |*b| return b.isSupported();
        return false;
    }

    pub fn backendName() []const u8 {
        return rt_backend.backendName();
    }

    /// Build or rebuild the bottom-level acceleration structure from triangle data.
    pub fn buildAccelerationStructure(self: *RtDevice, triangles: []const rt_backend.RtTriangle) bool {
        var b = self.backend orelse return false;
        return b.buildAccelerationStructure(triangles);
    }

    /// Upload texture atlas data for use in RT shaders.
    pub fn uploadTextures(self: *RtDevice, pixel_data: []const u8, meta: []const rt_backend.RtTextureMeta) bool {
        var b = self.backend orelse return false;
        return b.uploadTextures(pixel_data, meta);
    }

    /// Upload environment-importance and emissive-light sampling tables.
    pub fn uploadSamplingTables(self: *RtDevice, table_data: []const u8, meta: []const rt_backend.RtSamplingTableMeta) bool {
        var b = self.backend orelse return false;
        return b.uploadSamplingTables(table_data, meta);
    }

    /// Synchronize scene-side RT resources behind a single RHI-level call.
    pub fn syncScene(self: *RtDevice, desc: SceneSyncDesc) bool {
        if (desc.triangles) |triangles| {
            if (!self.buildAccelerationStructure(triangles)) return false;
        }
        if (!self.uploadTextures(desc.texture_data, desc.texture_meta)) return false;
        if (!self.uploadSamplingTables(desc.sampling_table_data, desc.sampling_table_meta)) return false;
        return true;
    }

    /// Trace rays with the given parameters, writing BGRA8 pixels to output.
    pub fn traceRays(self: *RtDevice, params: *const rt_backend.RtParams, output: []u8) bool {
        var b = self.backend orelse return false;
        return b.traceRays(params, output);
    }

    /// Dispatch async trace (returns immediately, GPU works in background).
    pub fn traceRaysAsync(self: *RtDevice, params: *const rt_backend.RtParams) bool {
        var b = self.backend orelse return false;
        return b.traceRaysAsync(params);
    }

    /// Non-blocking poll: is the previous async trace complete?
    pub fn isTraceComplete(self: *RtDevice) bool {
        var b = self.backend orelse return true;
        return b.isTraceComplete();
    }

    /// Read the async trace result into output. Call only after isTraceComplete() == true.
    pub fn getTraceResult(self: *RtDevice, output: []u8) bool {
        var b = self.backend orelse return false;
        return b.getTraceResult(output);
    }
};
