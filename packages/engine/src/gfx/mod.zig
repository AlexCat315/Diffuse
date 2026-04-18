const device = @import("device.zig");

// Stable import facade for current engine GFX API. Callers should import this module
// instead of depending on the concrete file layout.
pub usingnamespace device;

// Primary device alias for engine-side GFX code.
pub const GfxDevice = device.GfxDevice;
