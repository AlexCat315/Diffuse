const rt_device_mod = @import("../rt/rhi_rt_device.zig");
const rt_backend = @import("../rt/rt_backend.zig");

pub const RtInitStatus = enum {
    ready,
    initialized,
    unavailable,
};

pub fn ensureRtDevice(rt_device: *?rt_device_mod.RtDevice) RtInitStatus {
    if (rt_device.* != null) return .ready;
    rt_device.* = rt_device_mod.RtDevice.initAvailable() orelse return .unavailable;
    return .initialized;
}

pub fn releaseRtDevice(rt_device: *?rt_device_mod.RtDevice) void {
    if (rt_device.*) |*dev| {
        dev.deinit();
    }
    rt_device.* = null;
}

pub fn rtBackendName() []const u8 {
    return rt_device_mod.RtDevice.backendName();
}

pub fn rtBuildAccelerationStructure(rt_device: *?rt_device_mod.RtDevice, triangles: []const rt_backend.RtTriangle) bool {
    if (rt_device.*) |*dev| return dev.buildAccelerationStructure(triangles);
    return false;
}

pub fn rtUploadTextures(rt_device: *?rt_device_mod.RtDevice, pixel_data: []const u8, meta: []const rt_backend.RtTextureMeta) bool {
    if (rt_device.*) |*dev| return dev.uploadTextures(pixel_data, meta);
    return false;
}

pub fn rtUploadSamplingTables(rt_device: *?rt_device_mod.RtDevice, table_data: []const u8, meta: []const rt_backend.RtSamplingTableMeta) bool {
    if (rt_device.*) |*dev| return dev.uploadSamplingTables(table_data, meta);
    return false;
}

pub fn rtTraceRays(rt_device: *?rt_device_mod.RtDevice, params: *const rt_backend.RtParams, output: []u8) bool {
    if (rt_device.*) |*dev| return dev.traceRays(params, output);
    return false;
}

pub fn rtTraceRaysAsync(rt_device: *?rt_device_mod.RtDevice, params: *const rt_backend.RtParams) bool {
    if (rt_device.*) |*dev| return dev.traceRaysAsync(params);
    return false;
}

pub fn rtIsTraceComplete(rt_device: *?rt_device_mod.RtDevice) bool {
    if (rt_device.*) |*dev| return dev.isTraceComplete();
    return true;
}

pub fn rtGetTraceResult(rt_device: *?rt_device_mod.RtDevice, output: []u8) bool {
    if (rt_device.*) |*dev| return dev.getTraceResult(output);
    return false;
}
