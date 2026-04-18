const device = @import("device.zig");

// Stable import facade for legacy RHI API. Callers should import this module
// instead of depending on the concrete file layout.
pub usingnamespace device;
