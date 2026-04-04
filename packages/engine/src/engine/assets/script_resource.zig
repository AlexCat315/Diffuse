const std = @import("std");
const script_types = @import("../script/types.zig");

/// 脚本资源
pub const ScriptResource = struct {
    /// 脚本源码
    source: []const u8,
    /// 脚本语言
    language: script_types.ScriptLanguage = .zig,
    /// 入口函数名
    entry_fn: []const u8 = "main",
    /// 脚本描述
    description: []const u8 = "",
    /// 源文件路径（用于热重载）
    source_path: []const u8 = "",
    /// 编译产物路径（NativeAOT 共享库等）
    artifact_path: []const u8 = "",
    /// 最后修改时间
    last_modified: i128 = 0,
    /// 编译后的字节码（可选）
    bytecode: []const u8 = &.{},
    /// 用户数据（用于脚本参数）
    user_data: []const u8 = &.{},
};

/// 脚本资源描述
pub const ScriptResourceDesc = struct {
    source: []const u8,
    language: script_types.ScriptLanguage = .zig,
    entry_fn: []const u8 = "main",
    description: []const u8 = "",
    source_path: []const u8 = "",
    artifact_path: []const u8 = "",
    last_modified: i128 = 0,
    bytecode: []const u8 = &.{},
    user_data: []const u8 = &.{},
};

/// 克隆脚本资源
pub fn clone(allocator: std.mem.Allocator, desc: ScriptResourceDesc) !ScriptResource {
    return .{
        .source = try allocator.dupe(u8, desc.source),
        .language = desc.language,
        .entry_fn = try allocator.dupe(u8, desc.entry_fn),
        .description = try allocator.dupe(u8, desc.description),
        .source_path = try allocator.dupe(u8, desc.source_path),
        .artifact_path = try allocator.dupe(u8, desc.artifact_path),
        .last_modified = desc.last_modified,
        .bytecode = try allocator.dupe(u8, desc.bytecode),
        .user_data = try allocator.dupe(u8, desc.user_data),
    };
}

/// 释放脚本资源
pub fn deinit(resource: *ScriptResource, allocator: std.mem.Allocator) void {
    allocator.free(resource.source);
    allocator.free(resource.entry_fn);
    allocator.free(resource.description);
    allocator.free(resource.source_path);
    allocator.free(resource.artifact_path);
    allocator.free(resource.bytecode);
    allocator.free(resource.user_data);
}
