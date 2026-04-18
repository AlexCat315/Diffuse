const device = @import("device.zig");

// Stable import facade for legacy GFX API. Callers should import this module
// instead of depending on the concrete file layout.
pub usingnamespace device;

// Semantic alias used while renaming engine-side symbols away from GFX wording.
pub const GfxDevice = device.GfxDevice;
