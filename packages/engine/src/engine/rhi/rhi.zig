// Compatibility shim: Guava re-exports RHI core from external guava-rhi.
pub const external = @import("guava_rhi");
pub usingnamespace @import("guava_rhi").rhi;
