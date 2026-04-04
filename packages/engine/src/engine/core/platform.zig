const builtin = @import("builtin");
const std = @import("std");

pub const Platform = enum {
    windows,
    macos,
    linux,
    ios,
    android,
    unknown,
};

pub fn detect() Platform {
    return fromTarget(builtin.target);
}

pub fn fromTarget(target: std.Target) Platform {
    if (target.abi.isAndroid()) {
        return .android;
    }

    return fromOsTag(target.os.tag);
}

pub fn fromOsTag(tag: std.Target.Os.Tag) Platform {
    return switch (tag) {
        .windows => .windows,
        .macos => .macos,
        .linux => .linux,
        .ios => .ios,
        else => .unknown,
    };
}

pub fn name(platform: Platform) []const u8 {
    return switch (platform) {
        .windows => "Windows",
        .macos => "macOS",
        .linux => "Linux",
        .ios => "iOS",
        .android => "Android",
        .unknown => "Unknown",
    };
}
