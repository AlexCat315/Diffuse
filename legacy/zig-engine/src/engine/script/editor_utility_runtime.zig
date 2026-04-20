const std = @import("std");
const io_globals = @import("io_globals");
const handles = @import("../assets/handles.zig");
const script_resource_mod = @import("../assets/script_resource.zig");
const command_queue_mod = @import("../core/command_queue.zig");
const world_mod = @import("../scene/world.zig");
const context_mod = @import("./context.zig");
const types = @import("./types.zig");
const vm_mod = @import("./zig_backend.zig");

/// 编辑器工具的运行状态
///
/// 用于追踪每个编辑器工具脚本的生命周期状态，
/// 帮助诊断和显示工具的当前健康状况。
pub const Status = enum {
    /// 工具已就绪，可以正常运行
    ready,
    /// 加载阶段失败（脚本资源不存在或VM创建失败）
    load_error,
    /// 初始化阶段失败（调用init函数时出错）
    init_error,
    /// 更新阶段失败（调用update函数时出错）
    update_error,
};

/// 编辑器工具的快照信息
///
/// 用于序列化和导出工具的当前状态，供外部系统（如编辑器UI）使用。
/// 所有字符串字段都是独立分配的副本，调用者负责释放。
pub const Snapshot = struct {
    /// 脚本资源的唯一句柄
    handle: handles.ScriptHandle,
    /// 工具的显示名称
    name: []u8,
    /// 工具的功能描述
    description: []u8,
    /// 脚本源文件的路径
    source_path: []u8,
    /// 工具窗口是否处于打开状态
    open: bool,
    /// 工具的当前运行状态
    status: Status,
    /// 最近一次错误的详细信息（空字符串表示无错误）
    last_error: []u8,

    /// 释放快照占用的所有内存资源
    ///
    /// 此方法会释放所有字符串字段并将结构体重置为未定义状态。
    /// 调用后不应再使用此快照实例。
    fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.source_path);
        allocator.free(self.last_error);
        self.* = undefined;
    }
};

/// 释放快照数组及其所有内容
///
/// 遍历数组中的每个快照，释放其内部字符串资源，
/// 然后释放数组本身。此函数用于清理通过 listAlloc 创建的快照数组。
///
/// 参数:
///   allocator: 用于释放内存的分配器
///   snapshots: 要释放的快照数组
pub fn freeSnapshots(allocator: std.mem.Allocator, snapshots: []Snapshot) void {
    for (snapshots) |*snapshot| {
        snapshot.deinit(allocator);
    }
    allocator.free(snapshots);
}

/// 内部使用的工具条目
///
/// 存储单个编辑器工具的完整运行时状态，包括元数据和VM实例。
/// 此结构体仅供 EditorUtilityRuntime 内部使用。
const UtilityEntry = struct {
    /// 脚本资源的唯一句柄
    handle: handles.ScriptHandle,
    /// 工具的显示名称（拥有所有权）
    name: []u8,
    /// 工具的功能描述（拥有所有权）
    description: []u8,
    /// 脚本源文件路径（拥有所有权）
    source_path: []u8,
    /// 工具窗口是否应该打开
    open: bool,
    /// 当前运行状态
    status: Status = .ready,
    /// 最近一次错误的详细信息（拥有所有权）
    last_error: []u8 = &.{},
    /// 脚本虚拟机实例（加载成功后非空）
    vm: ?*vm_mod.ScriptVM = null,
    /// 脚本实例（初始化成功后非空）
    instance: ?*types.ScriptInstance = null,

    /// 释放条目占用的所有资源
    ///
    /// 包括销毁VM实例、释放所有字符串内存。
    /// 调用后条目处于未定义状态，不应再使用。
    fn deinit(self: *UtilityEntry, allocator: std.mem.Allocator) void {
        destroyLoadedState(self, allocator);
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.source_path);
        allocator.free(self.last_error);
        self.* = undefined;
    }
};

/// 编辑器工具运行时管理器
///
/// 负责管理所有编辑器工具脚本的生命周期，包括加载、卸载、
/// 状态追踪和UI绘制。提供线程安全的操作接口。
///
/// 使用流程:
/// 1. 调用 init() 创建实例
/// 2. 调用 upsertCompiled() 注册和更新工具
/// 3. 调用 deinit() 销毁实例
pub const EditorUtilityRuntime = struct {
    /// 内存分配器，用于所有内部分配
    allocator: std.mem.Allocator,
    /// 线程安全保护锁，保护 utilities 列表的并发访问
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// 已注册的工具条目列表
    utilities: std.ArrayList(UtilityEntry) = .empty,
    /// 请求宿主打开工具窗口的标志（一次性触发器）
    request_host_open: bool = false,

    /// 初始化编辑器工具运行时
    ///
    /// 创建一个新的运行时实例，准备接收工具注册。
    ///
    /// 参数:
    ///   allocator: 用于所有内部内存分配的分配器
    ///
    /// 返回:
    ///   初始化完成的 EditorUtilityRuntime 实例
    pub fn init(allocator: std.mem.Allocator) EditorUtilityRuntime {
        return .{
            .allocator = allocator,
        };
    }

    /// 销毁运行时实例并释放所有资源
    ///
    /// 释放所有已注册工具的资源，包括VM实例和字符串内存。
    /// 此方法会自动处理单线程和多线程环境的差异。
    ///
    /// 注意:
    /// - 在单线程环境中直接清理
    /// - 在多线程环境中尝试获取锁，避免潜在的死锁
    /// - 调用后实例处于未定义状态，不应再使用
    pub fn deinit(self: *EditorUtilityRuntime) void {
        // 在测试环境中，避免使用线程锁，因为测试可能在单线程中运行
        // 使用简单的错误处理来避免线程断言失败

        // 简化方法：直接尝试获取锁，如果失败则说明可能已经持有锁
        // 在单线程环境中，我们不需要担心死锁问题
        if (@import("builtin").single_threaded) {
            // 单线程环境，直接清理
            for (self.utilities.items) |*entry| {
                entry.deinit(self.allocator);
            }
            self.utilities.deinit(self.allocator);
        } else {
            // 多线程环境，正常获取锁
            // 使用 tryLock 来避免可能的死锁情况
            if (self.mutex.tryLock()) {
                defer self.mutex.unlock(io_globals.global_io);
                for (self.utilities.items) |*entry| {
                    entry.deinit(self.allocator);
                }
                self.utilities.deinit(self.allocator);
            } else {
                // 如果无法立即获取锁，可能当前线程已经持有锁
                // 在这种情况下，我们直接清理（假设调用者知道他们在做什么）
                for (self.utilities.items) |*entry| {
                    entry.deinit(self.allocator);
                }
                self.utilities.deinit(self.allocator);
            }
        }
        self.* = undefined;
    }

    /// 注册或更新已编译的编辑器工具
    ///
    /// 如果指定句柄的工具已存在，则更新其信息并重新加载；
    /// 如果不存在，则创建新的工具条目。
    ///
    /// 参数:
    ///   self: 运行时实例指针
    ///   world: 游戏世界实例，用于获取脚本资源
    ///   command_queue: 命令队列，传递给脚本初始化（可选）
    ///   handle: 脚本资源的唯一句柄
    ///   utility_name: 工具的显示名称
    ///   open: 是否应该打开工具窗口
    ///
    /// 返回:
    ///   成功时返回 void，失败时返回错误
    ///
    /// 错误:
    ///   error.ScriptNotFound: 指定句柄的脚本资源不存在
    ///   其他错误: 内存分配失败或脚本加载失败
    pub fn upsertCompiled(
        self: *EditorUtilityRuntime,
        world: *world_mod.World,
        command_queue: ?*command_queue_mod.CommandQueue,
        handle: handles.ScriptHandle,
        utility_name: []const u8,
        open: bool,
    ) !void {
        self.mutex.lockUncancelable(io_globals.global_io);
        defer self.mutex.unlock(io_globals.global_io);

        // 获取脚本资源，如果不存在则返回错误
        const resource = world.resources.script(handle) orelse return error.ScriptNotFound;
        const index = findIndexByHandle(self.utilities.items, handle);

        // 如果工具需要打开，设置一次性请求标志
        if (open) {
            self.request_host_open = true;
        }

        // 检查是否已存在相同句柄的工具
        if (index) |resolved_index| {
            // 更新现有条目
            var entry = &self.utilities.items[resolved_index];
            try replaceOwnedSlice(self.allocator, &entry.name, utility_name);
            try replaceOwnedSlice(self.allocator, &entry.description, resource.description);
            try replaceOwnedSlice(self.allocator, &entry.source_path, resource.source_path);
            entry.open = open;
            // 销毁旧的加载状态并重新加载
            destroyLoadedState(entry, self.allocator);
            try loadEntry(self.allocator, entry, world, command_queue);
            return;
        }

        // 创建新的工具条目
        var entry = UtilityEntry{
            .handle = handle,
            .name = try self.allocator.dupe(u8, utility_name),
            .description = try self.allocator.dupe(u8, resource.description),
            .source_path = try self.allocator.dupe(u8, resource.source_path),
            .open = open,
        };
        errdefer entry.deinit(self.allocator);

        // 加载脚本并初始化
        try loadEntry(self.allocator, &entry, world, command_queue);
        try self.utilities.append(self.allocator, entry);
    }

    /// 获取并重置宿主打开请求标志
    ///
    /// 此方法实现了一次性触发器模式：首次调用返回 true，
    /// 后续调用返回 false，直到下次设置 request_host_open。
    /// 用于通知宿主应用程序打开工具窗口。
    ///
    /// 参数:
    ///   self: 运行时实例指针
    ///
    /// 返回:
    ///   如果自上次调用以来有打开请求则返回 true，否则返回 false
    pub fn takeHostOpenRequest(self: *EditorUtilityRuntime) bool {
        self.mutex.lockUncancelable(io_globals.global_io);
        defer self.mutex.unlock(io_globals.global_io);

        const requested = self.request_host_open;
        self.request_host_open = false;
        return requested;
    }

    /// 移除指定的编辑器工具
    ///
    /// 从运行时中移除指定句柄的工具，释放其所有资源。
    /// 如果工具不存在，则不做任何操作。
    ///
    /// 参数:
    ///   self: 运行时实例指针
    ///   handle: 要移除的工具句柄
    ///
    /// 返回:
    ///   如果找到并移除了工具则返回 true，否则返回 false
    pub fn remove(
        self: *EditorUtilityRuntime,
        handle: handles.ScriptHandle,
    ) bool {
        self.mutex.lockUncancelable(io_globals.global_io);
        defer self.mutex.unlock(io_globals.global_io);

        const index = findIndexByHandle(self.utilities.items, handle) orelse return false;
        var removed = self.utilities.swapRemove(index);
        removed.deinit(self.allocator);
        return true;
    }

    /// 设置工具窗口的打开状态
    ///
    /// 更新指定工具的 open 标志，控制其窗口是否应该显示。
    /// 如果工具不存在，则不做任何操作。
    ///
    /// 参数:
    ///   self: 运行时实例指针
    ///   handle: 目标工具的句柄
    ///   open: true 表示打开窗口，false 表示关闭窗口
    pub fn setOpen(self: *EditorUtilityRuntime, handle: handles.ScriptHandle, open: bool) void {
        self.mutex.lockUncancelable(io_globals.global_io);
        defer self.mutex.unlock(io_globals.global_io);

        const index = findIndexByHandle(self.utilities.items, handle) orelse return;
        self.utilities.items[index].open = open;
    }

    /// 分配并返回所有工具的快照数组
    ///
    /// 创建当前所有工具状态的快照副本，供外部系统使用。
    /// 调用者负责使用 freeSnapshots 释放返回的数组。
    ///
    /// 参数:
    ///   self: 运行时实例指针（const，但内部需要获取锁）
    ///   allocator: 用于分配快照数组的分配器
    ///
    /// 返回:
    ///   成功时返回快照数组，失败时返回分配错误
    ///
    /// 注意:
    ///   返回的数组必须使用 freeSnapshots 函数释放
    pub fn listAlloc(self: *const EditorUtilityRuntime, allocator: std.mem.Allocator) ![]Snapshot {
        // 需要移除 const 以获取锁，但不修改数据
        const mutable: *EditorUtilityRuntime = @constCast(self);
        mutable.mutex.lockUncancelable(io_globals.global_io);
        defer mutable.mutex.unlock(io_globals.global_io);

        var snapshots = try allocator.alloc(Snapshot, mutable.utilities.items.len);
        errdefer freeSnapshots(allocator, snapshots);

        // 复制每个条目的信息到快照
        for (mutable.utilities.items, 0..) |entry, index| {
            snapshots[index] = .{
                .handle = entry.handle,
                .name = try allocator.dupe(u8, entry.name),
                .description = try allocator.dupe(u8, entry.description),
                .source_path = try allocator.dupe(u8, entry.source_path),
                .open = entry.open,
                .status = entry.status,
                .last_error = try allocator.dupe(u8, entry.last_error),
            };
        }
        return snapshots;
    }

    /// 获取指定工具的最后错误信息
    ///
    /// 返回指定工具的 last_error 字段的副本。
    /// 如果工具不存在，返回 null。
    ///
    /// 参数:
    ///   self: 运行时实例指针（const，但内部需要获取锁）
    ///   allocator: 用于分配错误字符串的分配器
    ///   handle: 目标工具的句柄
    ///
    /// 返回:
    ///   成功时返回错误字符串副本（可能为空字符串），
    ///   工具不存在时返回 null
    ///
    /// 注意:
    ///   返回的字符串由调用者负责释放
    pub fn lastErrorAlloc(
        self: *const EditorUtilityRuntime,
        allocator: std.mem.Allocator,
        handle: handles.ScriptHandle,
    ) !?[]u8 {
        const mutable: *EditorUtilityRuntime = @constCast(self);
        mutable.mutex.lockUncancelable(io_globals.global_io);
        defer mutable.mutex.unlock(io_globals.global_io);

        const index = findIndexByHandle(mutable.utilities.items, handle) orelse return null;
        return try allocator.dupe(u8, mutable.utilities.items[index].last_error);
    }

    /// 构建工具状态的 JSON 表示
    ///
    /// 生成包含所有工具状态的 JSON 字符串，用于调试和状态报告。
    /// JSON 格式包含工具数量和每个工具的详细信息。
    ///
    /// 参数:
    ///   self: 运行时实例指针
    ///   allocator: 用于分配 JSON 字符串的分配器
    ///
    /// 返回:
    ///   成功时返回 JSON 字符串，失败时返回错误
    ///
    /// 注意:
    ///   返回的字符串由调用者负责释放
    pub fn buildStatusJsonAlloc(self: *const EditorUtilityRuntime, allocator: std.mem.Allocator) ![]u8 {
        const snapshots = try self.listAlloc(allocator);
        defer freeSnapshots(allocator, snapshots);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        // 使用缩进格式化 JSON，便于阅读
        try std.json.Stringify.value(.{
            .utility_count = snapshots.len,
            .utilities = snapshots,
        }, .{ .whitespace = .indent_2 }, &out.writer);
        try out.writer.writeByte('\n');
        return out.toOwnedSlice();
    }
};

/// 获取选择列表中的主要（第一个）实体
///
/// 从编辑器选择列表中提取第一个实体作为"主要"选择。
/// 用于确定脚本上下文中的当前实体。
///
/// 参数:
///   selection: 实体ID列表
///
/// 返回:
///   如果列表非空返回第一个实体ID，否则返回 null
fn primarySelection(selection: []const world_mod.EntityId) ?world_mod.EntityId {
    if (selection.len == 0) {
        return null;
    }
    return selection[0];
}

/// 加载工具条目的脚本并初始化
///
/// 执行完整的脚本加载流程：
/// 1. 获取脚本资源
/// 2. 创建虚拟机
/// 3. 加载脚本字节码
/// 4. 创建脚本实例
/// 5. 调用初始化函数
///
/// 任何步骤失败都会更新条目的状态和错误信息。
///
/// 参数:
///   allocator: 内存分配器
///   entry: 要加载的工具条目（会被修改）
///   world: 游戏世界实例
///   command_queue: 命令队列（可选）
fn loadEntry(
    allocator: std.mem.Allocator,
    entry: *UtilityEntry,
    world: *world_mod.World,
    command_queue: ?*command_queue_mod.CommandQueue,
) !void {
    // 步骤1: 获取脚本资源
    const resource = world.resources.script(entry.handle) orelse {
        entry.status = .load_error;
        try replaceOwnedSlice(allocator, &entry.last_error, "editor utility script resource no longer exists");
        return;
    };

    // 步骤2: 创建虚拟机
    const script_vm = vm_mod.createGameplayVM(.zig, allocator) catch |err| {
        entry.status = .load_error;
        try replaceOwnedSlice(allocator, &entry.last_error, @errorName(err));
        return;
    };

    // 步骤3: 加载脚本字节码
    script_vm.load(resource) catch |err| {
        entry.status = .load_error;
        const message = if (script_vm.getError().len != 0) script_vm.getError() else @errorName(err);
        try replaceOwnedSlice(allocator, &entry.last_error, message);
        script_vm.deinit(allocator);
        allocator.destroy(script_vm);
        return;
    };

    // 准备脚本上下文（用于实例创建）
    var bootstrap_instance: types.ScriptInstance = undefined;
    var script_context = context_mod.ScriptContext{
        .entity = 0,
        .world = world,
        .instance = &bootstrap_instance,
        .allocator = allocator,
        .command_queue = command_queue,
    };

    // 步骤4: 创建脚本实例
    const instance = script_vm.createInstance(&script_context) catch |err| {
        entry.status = .load_error;
        const message = if (script_vm.getError().len != 0) script_vm.getError() else @errorName(err);
        try replaceOwnedSlice(allocator, &entry.last_error, message);
        script_vm.deinit(allocator);
        allocator.destroy(script_vm);
        return;
    };

    // 步骤5: 调用初始化函数
    script_context.instance = instance;
    script_vm.callInit(instance, &script_context) catch |err| {
        entry.status = .init_error;
        const message = if (script_vm.getError().len != 0) script_vm.getError() else @errorName(err);
        try replaceOwnedSlice(allocator, &entry.last_error, message);
        script_vm.destroyInstance(instance);
        script_vm.deinit(allocator);
        allocator.destroy(script_vm);
        return;
    };

    // 加载成功，更新条目状态
    entry.vm = script_vm;
    entry.instance = instance;
    entry.status = .ready;
    try replaceOwnedSlice(allocator, &entry.last_error, "");
}

/// 销毁工具条目的加载状态
///
/// 安全地销毁VM实例和脚本实例，释放相关资源。
/// 如果实例不存在，则不做任何操作。
///
/// 参数:
///   entry: 要清理的工具条目
///   allocator: 用于释放VM的分配器
fn destroyLoadedState(entry: *UtilityEntry, allocator: std.mem.Allocator) void {
    if (entry.vm) |script_vm| {
        // 先销毁脚本实例
        if (entry.instance) |instance| {
            script_vm.destroyInstance(instance);
            entry.instance = null;
        }
        // 然后销毁虚拟机
        script_vm.deinit(allocator);
        allocator.destroy(script_vm);
        entry.vm = null;
    }
}

/// 在条目列表中查找指定句柄的索引
///
/// 线性搜索条目数组，返回匹配句柄的索引。
///
/// 参数:
///   entries: 条目数组
///   handle: 要查找的句柄
///
/// 返回:
///   找到时返回索引，未找到返回 null
fn findIndexByHandle(entries: []const UtilityEntry, handle: handles.ScriptHandle) ?usize {
    for (entries, 0..) |entry, index| {
        if (entry.handle == handle) {
            return index;
        }
    }
    return null;
}

/// 替换已拥有的切片
///
/// 释放目标切片的旧内存，然后复制新内容。
/// 用于更新字符串字段。
///
/// 参数:
///   allocator: 内存分配器
///   target: 要替换的目标切片指针
///   next: 新的内容
///
/// 返回:
///   成功时返回 void，失败时返回分配错误
fn replaceOwnedSlice(allocator: std.mem.Allocator, target: *[]u8, next: []const u8) !void {
    allocator.free(target.*);
    target.* = try allocator.dupe(u8, next);
}

test "editor utility runtime status json lists utilities" {
    var runtime = EditorUtilityRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    try runtime.utilities.append(std.testing.allocator, .{
        .handle = handles.scriptHandle(1),
        .name = try std.testing.allocator.dupe(u8, "Selection Tools"),
        .description = try std.testing.allocator.dupe(u8, "Selection panel"),
        .source_path = try std.testing.allocator.dupe(u8, "assets/editor/selection_tools.zig"),
        .open = true,
        .status = .ready,
        .last_error = try std.testing.allocator.dupe(u8, ""),
    });

    const json = try runtime.buildStatusJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"utility_count\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Selection Tools\"") != null);
}

test "editor utility runtime host open request is one-shot" {
    var runtime = EditorUtilityRuntime.init(std.testing.allocator);
    defer runtime.deinit();

    runtime.request_host_open = true;

    try std.testing.expect(runtime.takeHostOpenRequest());
    try std.testing.expect(!runtime.takeHostOpenRequest());
}
