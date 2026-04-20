pub const MeshHandle = enum(u32) {
    invalid = 0,
    _,
};

pub const MaterialHandle = enum(u32) {
    invalid = 0,
    _,
};

pub const TextureHandle = enum(u32) {
    invalid = 0,
    _,
};

pub const SkeletonHandle = enum(u32) {
    invalid = 0,
    _,
};

pub const SkinHandle = enum(u32) {
    invalid = 0,
    _,
};

pub const AnimationClipHandle = enum(u32) {
    invalid = 0,
    _,
};

pub const ScriptHandle = enum(u32) {
    invalid = 0,
    _,
};

pub const AudioClipHandle = enum(u32) {
    invalid = 0,
    _,
};

pub fn isValid(handle: anytype) bool {
    return @intFromEnum(handle) != 0;
}

pub fn indexOf(handle: anytype) usize {
    return @intFromEnum(handle) - 1;
}

pub fn meshHandle(index: usize) MeshHandle {
    return @enumFromInt(index + 1);
}

pub fn materialHandle(index: usize) MaterialHandle {
    return @enumFromInt(index + 1);
}

pub fn textureHandle(index: usize) TextureHandle {
    return @enumFromInt(index + 1);
}

pub fn skeletonHandle(index: usize) SkeletonHandle {
    return @enumFromInt(index + 1);
}

pub fn skinHandle(index: usize) SkinHandle {
    return @enumFromInt(index + 1);
}

pub fn animationClipHandle(index: usize) AnimationClipHandle {
    return @enumFromInt(index + 1);
}

pub fn scriptHandle(index: usize) ScriptHandle {
    return @enumFromInt(index + 1);
}

pub fn audioClipHandle(index: usize) AudioClipHandle {
    return @enumFromInt(index + 1);
}
