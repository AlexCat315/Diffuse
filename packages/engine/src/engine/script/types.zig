const std = @import("std");
const handles = @import("../assets/handles.zig");
const world_mod = @import("../scene/world.zig");

// 前向声明
pub const ScriptContext = @import("./context.zig").ScriptContext;

/// 实体 ID 类型
pub const EntityId = world_mod.EntityId;

/// 脚本语言类型
pub const ScriptLanguage = enum {
    zig, // 过渡期 gameplay builtin 脚本
    csharp, // gameplay 脚本前端 (NativeAOT)
};

/// VM 职责分层
pub const VmRole = enum {
    gameplay,
};

pub fn vmRoleForLanguage(language: ScriptLanguage) VmRole {
    _ = language;
    return .gameplay;
}

/// 脚本实例的唯一标识
pub const ScriptInstanceId = u64;

/// 脚本组件 - 附加到实体上
pub const Script = struct {
    /// 脚本资源句柄
    script_handle: ?handles.ScriptHandle = null,
    /// 脚本语言
    language: ScriptLanguage = .zig,
    /// 脚本实例 ID（运行时）
    instance_id: ?ScriptInstanceId = null,
    /// 是否启用
    enabled: bool = true,
    /// 脚本参数（JSON 格式，可序列化）
    parameters: []u8 = &.{},
};

/// 脚本资源 - 脚本源代码或字节码
pub const ScriptResource = struct {
    /// 脚本源码或字节码
    source: []const u8,
    /// 脚本语言
    language: ScriptLanguage = .zig,
    /// 入口函数名
    entry_fn: []const u8 = "main",
    /// 脚本描述
    description: []const u8 = "",
    /// 最后修改时间（用于热重载检测）
    last_modified: i128 = 0,
};

/// 脚本虚拟表 - 定义脚本的生命周期回调
pub const ScriptVTable = struct {
    /// 初始化回调 - 实体创建时调用
    onInit: ?*const fn (ctx: *ScriptContext) void = null,
    /// 更新回调 - 每帧调用
    onUpdate: ?*const fn (ctx: *ScriptContext, dt: f32) void = null,
    /// 销毁回调 - 实体销毁时调用
    onDestroy: ?*const fn (ctx: *ScriptContext) void = null,
    /// 物理更新回调 - 固定步长物理更新时调用
    onPhysicsUpdate: ?*const fn (ctx: *ScriptContext, dt: f32) void = null,
    /// 碰撞开始回调
    onCollisionEnter: ?*const fn (ctx: *ScriptContext, other: EntityId) void = null,
    /// 碰撞持续回调
    onCollisionStay: ?*const fn (ctx: *ScriptContext, other: EntityId) void = null,
    /// 碰撞结束回调
    onCollisionExit: ?*const fn (ctx: *ScriptContext, other: EntityId) void = null,
    /// 触发器进入回调
    onTriggerEnter: ?*const fn (ctx: *ScriptContext, other: EntityId) void = null,
    /// 触发器离开回调
    onTriggerExit: ?*const fn (ctx: *ScriptContext, other: EntityId) void = null,
};

/// 脚本实例状态
pub const ScriptInstanceState = enum {
    uninitialized,
    loading,
    ready,
    running,
    failed,
    destroyed,
};

/// 脚本实例 - 运行时的脚本对象
pub const ScriptInstance = struct {
    /// 实例 ID
    id: ScriptInstanceId,
    /// 关联的实体 ID
    entity_id: EntityId,
    /// 脚本资源句柄
    script_handle: handles.ScriptHandle,
    /// 脚本语言
    language: ScriptLanguage = .zig,
    /// 虚拟表
    vtable: ScriptVTable,
    /// 用户数据指针
    user_data: ?*anyopaque = null,
    /// 用户数据大小
    user_data_size: usize = 0,
    /// 语言后端自定义的用户数据标签
    user_data_tag: u32 = 0,
    /// 当前状态
    state: ScriptInstanceState = .uninitialized,
    /// 最后错误信息
    last_error: []u8 = &.{},
    /// 最后错误位置
    last_error_location: SourceLocation = .{},
    /// 初始化顺序（用于同实体多脚本排序）
    init_order: u32 = 0,
};

/// 脚本系统配置
pub const ScriptSystemConfig = struct {
    /// 最大同时运行的脚本实例数
    max_instances: usize = 1024,
    /// 热重载检测间隔（秒）
    hot_reload_interval: f32 = 0.5,
    /// 是否启用热重载
    enable_hot_reload: bool = true,
    /// 脚本搜索路径
    script_paths: []const []const u8 = &.{},
    /// 允许的语言
    allowed_languages: []const ScriptLanguage = &.{ .zig, .csharp },
};

/// 脚本错误类型
pub const ScriptError = error{
    CompileError,
    LoadError,
    InitError,
    UpdateError,
    NotFound,
    InvalidLanguage,
    OutOfMemory,
};

/// 脚本源码位置 - 用于错误定位
pub const SourceLocation = struct {
    /// 文件名（Guest 端源文件路径）
    file: []const u8 = &.{},
    /// 函数名
    function: []const u8 = &.{},
    /// 行号（1-indexed）
    line: u32 = 0,
    /// 列号（1-indexed）
    column: u32 = 0,

    pub fn format(
        self: SourceLocation,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (self.file.len > 0) {
            try writer.print("{s}", .{self.file});
            if (self.line > 0) {
                try writer.print(":{}", .{self.line});
                if (self.column > 0) {
                    try writer.print(":{}", .{self.column});
                }
            }
        } else {
            try writer.writeAll("<unknown>");
        }
    }
};
