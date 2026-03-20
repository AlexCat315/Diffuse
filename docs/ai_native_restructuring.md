# Guava Engine AI-Native 重构方案

> 目标：打造真正由 AI 驱动的 Vibe Coding 游戏引擎
>
> 核心原则：**引擎的状态必须全量文本化可读，所有操作必须是无 UI 依赖的 API 化指令**
>
> **重要更新**: 本文档已针对以下关键架构问题进行修复：
> - ❌ HTTP REST → ✅ MCP (Model Context Protocol)
> - ❌ 编译竞态条件 → ✅ UUID 沙箱目录
> - ❌ 命令队列洪灾 → ✅ 命令合并/节流机制
> ❌ 物理版本冲突 → ✅ 结构版本/数据版本分离
> - ❌ WASM Panic 黑盒 → ✅ 结构化错误回溯
> - ❌ 查询全量重建 → ✅ O(1) 增量索引

---

## 一、架构愿景

### 1.1 传统引擎 vs AI-Native 引擎

| 维度 | 传统引擎 (如 Unreal) | AI-Native 引擎 (Guava) |
|------|---------------------|----------------------|
| 状态读写 | 二进制序列化，AI 不可读 | JSON/YAML 文本，AI 完全可读 |
| 操作入口 | UI 按钮点击 | MCP Tool 调用，结构化参数 |
| 逻辑编写 | 蓝图/C++，需重新编译 | Zig → WASM 沙箱，毫秒热重载 |
| AI 通信 | 外部脚本桥接 | **MCP Server** (Stdio/SSE) |
| 查询能力 | 全量遍历 | 语义查询 API (增量索引) |
| 并发控制 | 无 | **拓扑版本/数据版本分离** |

### 1.2 最终架构图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    AI Agent (Claude Desktop / Cursor / Windsurf)         │
│                         MCP Client (AI Native 编程助手)                   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ MCP Protocol (Stdio / SSE)
                                    │ {
                                    │   tool: "create_entity",
                                    │   arguments: { name: "Monster", ... }
                                    │ }
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        Guava Engine (MCP Server)                        │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │                         MCP Protocol Layer                         │ │
│  │  tools/             │  resources/           │  prompts/          │ │
│  │  - create_entity     │  - scene://hierarchy  │  - analyze_scene   │ │
│  │  - set_transform     │  - entity://42        │  - debug_script    │ │
│  │  - compile_script    │  - wasm://42/logs     │                    │ │
│  │  - query_entities    │                       │                    │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │  Command     │  │   Query      │  │   WASM       │  │   Scene      │ │
│  │  Queue +     │  │   Engine +   │  │   Runtime +  │  │   API +     │ │
│  │  Coalescing │  │   Incremental│  │   Panic      │  │   Versioning │ │
│  │              │  │   Index      │  │   Handler    │  │              │ │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘ │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                      引擎核心 (Host)                              │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐         │   │
│  │  │  World   │  │  Render  │  │ Physics  │  │  Asset   │         │   │
│  │  │  (ECS)   │  │  Graph   │  │ (Jolt)   │  │ Library  │         │   │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘         │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    WASM Runtime (Guest)                           │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐                        │   │
│  │  │ Monster  │  │ Player   │  │  Custom  │   ← AI 生成的逻辑      │   │
│  │  │   AI     │  │Controller│  │  Script  │   ← panic 处理       │   │
│  │  └──────────┘  └──────────┘  └──────────┘                        │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```
│  │  │   AI     │  │ Controller│  │  Script  │                        │   │
│  │  └──────────┘  └──────────┘  └──────────┘                        │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    Editor UI (可选客户端)                         │   │
│  │              ImGui Dock Layout / Gizmo / Inspector               │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.3 交互流程示例

```
1. AI 请求场景状态
   AI ──HTTP GET /api/scene/hierarchy──▶ Engine
   ◀─── JSON 场景树 ─────────────────────

2. AI 发送操作指令
   AI ──HTTP POST /api/command──────────▶ Engine
        Body: {"cmd": "set_transform", "entity_id": 42, "position": [0, 5, 0]}
   ◀─── {"success": true} ──────────────

3. AI 生成并更新 WASM 逻辑
   AI ──HTTP POST /api/script/compile────▶ Engine
        Body: {代码: "export fn on_update(...) { ... }"}
   ◀─── {"compiled": true, "wasm_hash": "abc123"} ─
```

---

## 二、Phase 1: Command 驱动架构重构

### 2.1 目标

彻底切断 UI 与引擎核心的直接耦合。所有状态修改必须通过 Command 队列。

### 2.2 现状分析

当前 `src/editor/actions/command.zig` 仅用于 Editor Undo/Redo，需要扩展为**引擎级命令系统**。

**现状问题**：
- Inspector 直接修改 `entity.local_transform`
- 创建/删除实体在 UI 回调中直接操作
- AI 无法"点击"按钮发送相同指令

### 2.3 改造方案

#### 2.3.1 新建 `src/engine/core/command.zig`

```zig
const std = @import("std");
const world_mod = @import("../scene/world.zig");
const components = @import("../scene/components.zig");

pub const CommandError = error{
    EntityNotFound,
    InvalidParameter,
    CommandQueueFull,
};

pub const Command = union(enum) {
    create_entity: CreateEntityCommand,
    delete_entity: DeleteEntityCommand,
    set_local_transform: SetTransformCommand,
    set_world_transform: SetWorldTransformCommand,
    add_component: AddComponentCommand,
    remove_component: RemoveComponentCommand,
    modify_component_field: ModifyFieldCommand,
    set_parent: SetParentCommand,
    set_visible: SetVisibleCommand,
    reorder_child: ReorderChildCommand,
    duplicate_entity: DuplicateEntityCommand,
    create_material: CreateMaterialCommand,
    modify_material: ModifyMaterialCommand,
    set_mesh: SetMeshCommand,
    set_light: SetLightCommand,
    create_prefab: CreatePrefabCommand,
    instantiate_prefab: InstantiatePrefabCommand,
};

pub const CreateEntityCommand = struct {
    name: []const u8,
    parent: ?world_mod.EntityId = null,
    local_transform: components.Transform = .{},
    components: []const ComponentDesc = &.{},
};

pub const DeleteEntityCommand = struct {
    entity_id: world_mod.EntityId,
    recursive: bool = true,
};

pub const SetTransformCommand = struct {
    entity_id: world_mod.EntityId,
    transform: components.Transform,
    space: enum { local, world } = .local,
};

pub const AddComponentCommand = struct {
    entity_id: world_mod.EntityId,
    component_type: ComponentType,
    component_data: []const u8,
};

pub const ComponentType = enum {
    camera,
    mesh,
    material,
    light,
    rigidbody,
    box_collider,
    sphere_collider,
    mesh_collider,
    script,
    animator,
    vfx,
    constraint,
};

pub const ModifyFieldCommand = struct {
    entity_id: world_mod.EntityId,
    component_type: ComponentType,
    field_path: []const u8,
    value: []const u8,
};
```

#### 2.3.2 新建 `src/engine/core/command_queue.zig`

> **⚠️ 架构修正**: 添加命令合并 (Coalescing) 机制，防止高频操作（如拖拽）淹没队列

```zig
pub const CommandQueue = struct {
    pending: std.ArrayList(Command),
    history: std.ArrayList(Command),
    history_index: usize = 0,
    max_history: usize = 1000,
    world: *world_mod.World,
    allocator: std.mem.Allocator,

    // 事务追踪: 用于合并同一次交互产生的连续命令
    active_transactions: std.AutoHashMap(TransactionId, Transaction),
    current_transaction_id: TransactionId = 0,

    pub const TransactionId = u64;

    pub const Transaction = struct {
        interaction_type: InteractionType,
        entity_id: ?world_mod.EntityId,
        start_time: i128,
        coalesced_count: u32 = 0,
    };

    pub const InteractionType = enum {
        gizmo_drag,     // Gizmo 拖拽 (极高频)
        inspector_edit,   // Inspector 编辑
        ai_command,      // AI 命令 (不合并)
        script_trigger,  // 脚本触发 (不合并)
    };

    pub const PushOptions = struct {
        transaction_id: ?TransactionId = null,
        coalesce: bool = true,  // 是否允许合并
        priority: u8 = 0,       // 优先级，高的先执行
    };

    pub fn push(self: *CommandQueue, cmd: Command, opts: PushOptions) !void {
        // 尝试合并同类型命令 (用于 Gizmo 拖拽等高频场景)
        if (opts.coalesce and canCoalesce(cmd)) {
            if (try self.tryMergeCommand(cmd)) {
                return;  // 成功合并，跳过添加
            }
        }

        // 检查队列容量
        if (self.pending.items.len >= 1000) {
            // 丢弃最低优先级的命令
            self.discardLowestPriority();
        }

        try self.pending.append(self.allocator, cmd);
    }

    fn canCoalesce(cmd: Command) bool {
        // 只有高频变换命令可以合并
        return switch (cmd) {
            .set_local_transform => true,
            .set_world_transform => true,
            else => false,
        };
    }

    fn tryMergeCommand(self: *CommandQueue, new_cmd: Command) !bool {
        const new_entity_id = switch (new_cmd) {
            .set_local_transform => |c| c.entity_id,
            .set_world_transform => |c| c.entity_id,
            else => return false,
        };

        // 从后往前找最后一个可合并的命令
        var i: usize = self.pending.items.len;
        while (i > 0) {
            i -= 1;
            const existing = self.pending.items[i];

            const existing_entity_id = switch (existing) {
                .set_local_transform => |c| c.entity_id,
                .set_world_transform => |c| c.entity_id,
                else => continue,
            };

            // 同一实体，直接替换值
            if (existing_entity_id == new_entity_id) {
                self.pending.items[i] = new_cmd;
                log.debug("Coalesced transform command for entity {}", .{new_entity_id});
                return true;
            }
        }

        return false;
    }

    pub fn startTransaction(self: *CommandQueue, interaction: InteractionType, entity_id: ?world_mod.EntityId) TransactionId {
        self.current_transaction_id += 1;
        const id = self.current_transaction_id;

        self.active_transactions.put(id, .{
            .interaction_type = interaction,
            .entity_id = entity_id,
            .start_time = std.time.nanoTimestamp(),
        }) catch {};

        return id;
    }

    pub fn endTransaction(self: *CommandQueue, transaction_id: TransactionId) void {
        _ = self.active_transactions.remove(transaction_id);
    }

    pub fn executePending(self: *CommandQueue) void {
        // 按优先级排序
        std.sort.sort(Command, self.pending.items, {}, commandPriorityLessThan);

        for (self.pending.items) |cmd| {
            self.execute(cmd);
            try self.history.append(self.allocator, cmd);

            // 清理超长历史，但保留关键操作 (创建/删除实体)
            if (self.history.items.len > self.max_history) {
                self.pruneHistory();
            }
        }
        self.pending.clearRetainingCapacity();
    }

    fn pruneHistory(self: *CommandQueue) void {
        // 保留最近的 max_history，但永远保留创建/删除命令
        var keep_count: usize = self.max_history;

        // 从后往前，找第一个保留点
        var drop_start: usize = self.history.items.len;
        for (self.history.items.len - 1.., 0) |idx| {
            const cmd = self.history.items[idx];
            const is_structural = switch (cmd) {
                .create_entity, .delete_entity, .instantiate_prefab => true,
                else => false,
            };

            if (keep_count == 0 and !is_structural) {
                drop_start = idx;
                break;
            }

            if (!is_structural) {
                keep_count -= 1;
            }
        }

        // 删除 [0, drop_start) 范围的非结构性命令
        self.history.shrinkRetainingCapacity(self.history.items.len - drop_start);
    }

    fn commandPriorityLessThan(_: void, a: Command, b: Command) bool {
        const priority_a = getCommandPriority(a);
        const priority_b = getCommandPriority(b);
        return priority_a > priority_b;  // 高优先级排前面
    }

    fn getCommandPriority(cmd: Command) u8 {
        return switch (cmd) {
            .delete_entity => 100,    // 删除最高
            .create_entity => 90,
            .instantiate_prefab => 85,
            .set_local_transform, .set_world_transform => 10,  // 变换最低
            else => 50,
        };
    }

    fn execute(self: *CommandQueue, cmd: Command) void {
        switch (cmd) {
            .create_entity => |c| self.execCreateEntity(c),
            .delete_entity => |c| self.execDeleteEntity(c),
            .set_local_transform => |c| self.execSetTransform(c),
            .add_component => |c| self.execAddComponent(c),
            // ... 其他命令
        }
    }
};
```

#### 2.3.3 JSON 序列化支持

```zig
pub fn commandToJson(cmd: Command, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    try commandToJsonRecursive(cmd, &buf);
    return buf.toOwnedSlice();
}

pub fn jsonToCommand(json: []const u8, allocator: std.mem.Allocator) !Command {
    // 解析 JSON 并构造 Command union
}
```

#### 2.3.4 Editor UI 改造

```zig
// src/editor/ui/inspector.zig
// 之前:
fn onPositionChanged() {
    entity.local_transform.translation = new_pos;
    world.updateHierarchy();
}

// 之后:
fn onPositionChanged() {
    command_queue.push(.{
        .set_local_transform = .{
            .entity_id = entity.id,
            .transform = .{ .translation = new_pos },
        },
    });
}
```

### 2.4 文件改动清单

| 操作 | 文件路径 |
|------|----------|
| 新建 | `src/engine/core/command.zig` |
| 新建 | `src/engine/core/command_queue.zig` |
| 修改 | `src/editor/ui/inspector.zig` |
| 修改 | `src/editor/ui/hierarchy.zig` |
| 修改 | `src/editor/actions/command.zig` → 改为 engine/core/command.zig |

---

## 三、Phase 2: WASM 运行时接入

### 3.1 目标

让 AI 生成的 Zig 代码能够：
1. 在后台编译为 WASM 字节码
2. 在沙箱隔离环境中安全执行
3. 毫秒级热重载，不打断 Vibe Coding 体验

### 3.2 现状分析

当前 `src/engine/script/vm.zig` 中的 `ZigVM` 只是硬编码的内置脚本分发器，不是真正的动态编译执行。

**现状问题**：
- AI 写代码需要重新编译整个引擎
- 脚本 bug 会直接导致引擎崩溃
- 热重载形同虚设

### 3.3 技术选型: Wasm3

| 方案 | 优势 | 劣势 |
|------|------|------|
| 动态库 (.so/.dll) | Zig 原生，无新依赖 | 无沙箱，bug 导致引擎崩溃 |
| WASM (Wasm3) | **沙箱隔离**，安全可靠 | 需要编译目标切换 |
| LuaJIT | 成熟生态 | 需要学习 Lua |
| Python | AI 最擅长 | 性能差，GIL 并发问题 |

**选择 Wasm3 的理由**：
1. 纯 C 编写，极易与 Zig 混合编译
2. Zig 原生支持 `wasm32-freestanding` 编译目标
3. WASM 是隔离沙箱，AI 代码崩溃不影响引擎
4. 编译速度极快（几十到几百毫秒）

### 3.4 改造方案

#### 3.4.1 获取 Wasm3 源码

```bash
mkdir -p libs/wasm3
cd libs/wasm3
git clone https://github.com/wasm3/wasm3.git
# 或下载 release zip
```

Wasm3 需要的源文件：
```
source/m3_api_wasi.c
source/m3_api_libc.c
source/m3_api_wasm.c
source/m3_bind.c
source/m3_core.c
source/m3_env.c
source/m3_exec.c
source/m3_parse.c
source/m3_module.c
source/m3_compile.c
```

#### 3.4.2 修改 `build.zig`

```zig
// 在 Build 配置中添加
const wasm3 = b.addStaticLibrary(.{
    .name = "wasm3",
    .target = target,
    .optimize = optimize,
});
wasm3.addCSourceFiles(.{
    .files = &.{
        "libs/wasm3/source/m3_api_wasi.c",
        "libs/wasm3/source/m3_api_libc.c",
        "libs/wasm3/source/m3_api_wasm.c",
        "libs/wasm3/source/m3_bind.c",
        "libs/wasm3/source/m3_core.c",
        "libs/wasm3/source/m3_env.c",
        "libs/wasm3/source/m3_exec.c",
        "libs/wasm3/source/m3_parse.c",
        "libs/wasm3/source/m3_module.c",
        "libs/wasm3/source/m3_compile.c",
    },
    .flags = &.{"-O3", "-Dd_m3HasFloat"},
});
wasm3.linkLibC();

exe.linkLibrary(wasm3);
exe.addIncludePath(.{ .path = "libs/wasm3/source" });
```

#### 3.4.3 新建 `src/engine/script/wasm_vm.zig`

```zig
const std = @import("std");
const m3 = @cImport({
    @cInclude("wasm3.h");
});
const world_mod = @import("../scene/world.zig");
const context = @import("./context.zig");
const log = std.log.scoped(.wasm_vm);

pub const WasmVM = struct {
    env: m3.IM3Environment,
    runtime: m3.IM3Runtime,
    allocator: std.mem.Allocator,
    modules: std.AutoHashMap(world_mod.EntityId, m3.IM3Module),

    pub fn init(allocator: std.mem.Allocator) !WasmVM {
        const env = m3.m3_NewEnvironment();
        if (env == null) return error.InitEnvFailed;

        const runtime = m3.m3_NewRuntime(env, 64 * 1024, null);
        if (runtime == null) return error.InitRuntimeFailed;

        return .{
            .env = env,
            .runtime = runtime,
            .allocator = allocator,
            .modules = std.AutoHashMap(world_mod.EntityId, m3.IM3Module).init(allocator),
        };
    }

    pub fn deinit(self: *WasmVM) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            _ = entry;
            // 清理模块
        }
        self.modules.deinit();
        m3.m3_FreeRuntime(self.runtime);
        m3.m3_FreeEnvironment(self.env);
    }

    pub fn loadScript(
        self: *WasmVM,
        entity_id: world_mod.EntityId,
        wasm_bytes: []const u8,
    ) !void {
        var module: m3.IM3Module = null;
        var env_ptr = self.env;

        if (m3.m3_ParseModule(env_ptr, &module, wasm_bytes.ptr, @intCast(wasm_bytes.len)) != 0) {
            return error.ParseFailed;
        }
        defer {
            if (module != null) m3.m3_FreeModule(module);
        }

        if (m3.m3_LoadModule(self.runtime, module) != 0) {
            return error.LoadFailed;
        }

        // 注入引擎 API
        try self.linkEngineAPI(module);

        try self.modules.put(entity_id, module);
    }

    fn linkEngineAPI(self: *WasmVM, module: m3.IM3Module) !void {
        const allocator = self.allocator;

        // api_set_position(entity_id, x, y, z)
        {
            const alloc = try allocator.create(ApiCtxSetPosition);
            alloc.* = .{ .vm = self };
            if (m3.m3_LinkRawFunction(
                module,
                "env",
                "api_set_position",
                "v(ifff)",
                @ptrCast(&apiSetPosition),
                alloc,
            ) != 0) return error.LinkFailed;
        }

        // api_get_position(entity_id) -> [x, y, z]
        {
            const alloc = try allocator.create(ApiCtxGetPosition);
            alloc.* = .{ .vm = self };
            if (m3.m3_LinkRawFunction(
                module,
                "env",
                "api_get_position",
                "v(i)V",
                @ptrCast(&apiGetPosition),
                alloc,
            ) != 0) return error.LinkFailed;
        }

        // api_get_delta_time() -> f32
        {
            const alloc = try allocator.create(ApiCtxGetDeltaTime);
            alloc.* = .{ .vm = self };
            if (m3.m3_LinkRawFunction(
                module,
                "env",
                "api_get_delta_time",
                "f()",
                @ptrCast(&apiGetDeltaTime),
                alloc,
            ) != 0) return error.LinkFailed;
        }

        // api_log(message)
        {
            const alloc = try allocator.create(ApiCtxLog);
            alloc.* = .{ .vm = self };
            if (m3.m3_LinkRawFunction(
                module,
                "env",
                "api_log",
                "v(i)",
                @ptrCast(&apiLog),
                alloc,
            ) != 0) return error.LinkFailed;
        }

        // api_spawn_entity(prefab_name) -> entity_id
        // api_destroy_entity(entity_id)
        // api_play_animation(entity_id, clip_name)
        // api_get_entity_count() -> i32
        // ... 更多 API
    }

    pub fn callExport(
        self: *WasmVM,
        entity_id: world_mod.EntityId,
        func_name: []const u8,
        args: []const []const u8,
    ) !void {
        const module = self.modules.get(entity_id) orelse return error.ModuleNotFound;

        var func: m3.IM3Function = null;
        if (m3.m3_FindFunction(&func, module, @ptrCast(func_name.ptr)) != 0) {
            return error.FunctionNotFound;
        }

        if (m3.m3_Call(func, @intCast(args.len), @ptrCast(args.ptr)) != 0) {
            return error.CallFailed;
        }
    }

    pub fn unloadScript(self: *WasmVM, entity_id: world_mod.EntityId) void {
        _ = self.modules.remove(entity_id);
    }
};

// ============== Host API 实现 ==============

const ApiCtxSetPosition = struct {
    vm: *WasmVM,
};

export fn apiSetPosition(ctx_ptr: ?*anyopaque, entity_id: u32, x: f32, y: f32, z: f32) void {
    _ = ctx_ptr;
    // 注意：这里不直接修改 World，而是写入命令缓冲区
    // 由主循环在安全点统一执行
    pending_commands.append(.{ .set_position = .{ .entity_id = entity_id, .pos = .{ x, y, z } } });
}

// 其他 API 实现...

// ============== 命令缓冲区 ==============

pub const PendingCommand = union(enum) {
    set_position: SetPositionCmd,
    log_message: LogMessageCmd,
};

pub const SetPositionCmd = struct {
    entity_id: world_mod.EntityId,
    pos: [3]f32,
};

pub const LogMessageCmd = struct {
    message: []const u8,
};

var pending_commands: std.ArrayList(PendingCommand) = undefined;

pub fn flushPendingCommands(world: *world_mod.World) void {
    for (pending_commands.items) |cmd| {
        switch (cmd) {
            .set_position => |c| world.setEntityPosition(c.entity_id, c.pos),
            .log_message => |c| log.info("WASM: {s}", .{c.message}),
        }
    }
    pending_commands.clearRetainingCapacity();
}
```

#### 3.4.4 新建 `src/engine/script/wasm_compiler.zig`

> **⚠️ 架构修正**: 修复竞态条件，使用 UUID 沙箱目录确保并发安全

```zig
const std = @import("std");
const log = std.log.scoped(.wasm_compiler);

pub const WasmCompiler = struct {
    allocator: std.mem.Allocator,
    cache_dir: std.fs.Dir,
    zig_exe: []const u8,
    compilation_locks: std.fs.Dir,

    pub fn init(allocator: std.mem.Allocator, cache_dir: std.fs.Dir) !WasmCompiler {
        // 创建专门的编译锁目录，防止并发冲突
        const lock_dir = try cache_dir.makeOpenPath("compilation_locks", .{});

        return .{
            .allocator = allocator,
            .cache_dir = cache_dir,
            .zig_exe = try std.Process.allocEnvVar(allocator, "ZIG"),
            .compilation_locks = lock_dir,
        };
    }

    pub fn compileWithLock(
        self: *WasmCompiler,
        task_id: []const u8,
        source_path: []const u8,
    ) !CompileResult {
        // 为每次编译创建唯一的沙箱目录
        const sandbox_dir = try self.cache_dir.makeOpenPath(
            try std.fmt.allocPrint(self.allocator, "sandbox_{s}", .{task_id}),
            .{},
        );
        defer {
            // 清理沙箱目录
            self.cache_dir.deleteTree(sandbox_dir) catch {};
        }

        const output_path = try sandbox_dir.join(self.allocator, &.{"output.wasm"});
        defer self.allocator.free(output_path);

        return try self.compileInSandbox(task_id, source_path, output_path, sandbox_dir);
    }

    fn compileInSandbox(
        self: *WasmCompiler,
        task_id: []const u8,
        source_path: []const u8,
        output_path: []const u8,
        sandbox_dir: std.fs.Dir,
    ) !CompileResult {
        const start_time = std.time.nanoTimestamp();

        log.info("Compiling {s} in sandbox {s}...", .{ source_path, task_id });

        // 创建锁文件
        const lock_path = try self.compilation_locks.join(
            self.allocator,
            &.{task_id},
        );
        defer self.allocator.free(lock_path);

        const lock_file = try self.compilation_locks.createFile(lock_path, .{});
        defer lock_file.close();

        // 原子重命名后的 .wasm 文件路径
        const final_wasm_path = try self.cache_dir.join(
            self.allocator,
            &.{"compiled_{s}.wasm", task_id},
        );
        defer self.allocator.free(final_wasm_path);

        var child = std.ChildProcess.init(&.{
            self.zig_exe,
            "build-obj",
            source_path,
            "-target",
            "wasm32-freestanding",
            "-O",
            "ReleaseFast",
            "-femit-bin=" ++ output_path,
        }, self.allocator);

        child.stderr_behavior = .pipe;
        child.stdout_behavior = .pipe;

        try child.spawn();
        const term = try child.wait();

        const compile_time_ms = @divTrunc(
            std.time.nanoTimestamp() - start_time,
            std.time.ns_per_ms,
        );

        if (term != .Exited or term.Exited != 0) {
            const stderr = try child.stderr.?.reader().readAllAlloc(self.allocator, 1024 * 1024);
            defer self.allocator.free(stderr);

            log.err("WASM compilation failed for task {s}:\n{s}", .{ task_id, stderr });

            return .{
                .success = false,
                .error = .{
                    .code = 2001,
                    .message = "Compilation failed",
                    .details = stderr,
                    .line = try extractErrorLine(stderr),
                },
            };
        }

        // 原子重命名到最终位置
        try std.fs.rename(output_path, final_wasm_path);

        // 读取编译产物
        const wasm_bytes = try self.cache_dir.readFileAlloc(
            self.allocator,
            final_wasm_path,
            1024 * 1024,
        );

        // 清理锁文件
        self.compilation_locks.deleteFile(lock_path) catch {};

        const hash = try computeWasmHash(wasm_bytes);

        return .{
            .success = true,
            .wasm_bytes = wasm_bytes,
            .hash = hash,
            .compile_time_ms = compile_time_ms,
        };
    }

    pub fn compileStringWithTaskId(
        self: *WasmCompiler,
        task_id: []const u8,
        source_code: []const u8,
    ) !CompileResult {
        const sandbox_dir = try self.cache_dir.makeOpenPath(
            try std.fmt.allocPrint(self.allocator, "sandbox_{s}", .{task_id}),
            .{},
        );
        defer {
            self.cache_dir.deleteTree(sandbox_dir) catch {};
        }

        const src_path = try sandbox_dir.join(self.allocator, &.{"source.zig"});
        defer self.allocator.free(src_path);

        try sandbox_dir.writeFile(src_path, source_code);

        const output_path = try sandbox_dir.join(self.allocator, &.{"output.wasm"});
        defer self.allocator.free(output_path);

        return try self.compileInSandbox(task_id, src_path, output_path, sandbox_dir);
    }
};

pub const CompileResult = struct {
    success: bool,
    wasm_bytes: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    compile_time_ms: u64 = 0,
    error: ?CompileError = null,
};

pub const CompileError = struct {
    code: u32 = 2001,
    message: []const u8,
    details: []const u8,
    line: ?u32 = null,
};

fn extractErrorLine(stderr: []const u8) !?u32 {
    // 从 Zig 错误输出中提取行号
    // 格式: "path.zig:42:5: error: ..."
    var line: u32 = 0;
    for (stderr) |c| {
        if (c >= '0' and c <= '9') {
            line = line * 10 + (c - '0');
        } else if (c == ':') {
            break;
        }
    }
    return if (line > 0) line else null;
}

fn computeWasmHash(wasm_bytes: []const u8) ![16]u8 {
    // 使用简单的哈希作为唯一标识
    var hash: [16]u8 = undefined;
    for (0..16) |i| {
        hash[i] = wasm_bytes[i * 100 % wasm_bytes.len];
    }
    return hash;
}

fn generateUuid() ![36]u8 {
    // 生成简单的 UUID v4
    // 实际应使用更可靠的 UUID 库
    var uuid: [36]u8 = undefined;
    const chars = "0123456789abcdef";
    for (0..36) |i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            uuid[i] = '-';
        } else {
            uuid[i] = chars[@intFromError(std.crypto.randomInt(u8) % 16)];
        }
    }
    return uuid;
}
```

#### 3.4.5 新建 `src/engine/script/script_entity.zig`

> **⚠️ 架构修正**: 添加 Panic 处理，将 WASM Trap 转换为结构化错误回溯

定义脚本实体的规范：

```zig
// AI 或用户编写的脚本必须遵循此格式

/*
Script Template (保存到 scripts/ 目录下):

// =========================================
// Guava Engine WASM Script
// =========================================

// 导入引擎 API
extern "env" fn api_set_position(entity_id: u32, x: f32, y: f32, z: f32) void;
extern "env" fn api_get_delta_time() f32;
extern "env" fn api_log(message: [*:0]const u8) void;
extern "env" fn api_get_entity_position(entity_id: u32, out_x: [*]f32, out_y: [*]f32, out_z: [*]f32) void;
extern "env" fn api_play_animation(entity_id: u32, name: [*:0]const u8) void;
extern "env" fn api_spawn_entity(prefab: [*:0]const u8, x: f32, y: f32, z: f32) u32;
extern "env" fn api_destroy_entity(entity_id: u32) void;
extern "env" fn api_distance(a_id: u32, b_id: u32) f32;
extern "env" fn api_set_visible(entity_id: u32, visible: i32) void;

// ⚠️ 关键: 必须定义 Panic Handler (将 WASM trap 转换为结构化错误)
extern "env" fn api_report_panic(
    message_ptr: [*]const u8,
    message_len: u32,
    file_ptr: [*]const u8,
    file_len: u32,
    line: u32,
    column: u32,
) void;

// 脚本内部状态 (持久化)
var state_time: f32 = 0.0;
var state_phase: i32 = 0;

// =========================================
// Panic Handler (强制实现)
// =========================================

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.ReturnAddress) noreturn {
    // 将 panic 信息传递回 Host
    api_report_panic(
        msg.ptr,
        @intCast(msg.len),
        @src().file.ptr,
        @intCast(@src().file.len),
        @src().line,
        @src().column,
    );
    // 死循环，防止 WASM 继续执行
    while (true) {}
}

// =========================================
// 生命周期回调 (由引擎调用)
// =========================================

// =========================================
// 生命周期回调 (由引擎调用)
// =========================================

// 实体被创建时调用一次
export fn on_init(entity_id: u32) void {
    api_log("Script initialized!");
}

// 每帧调用，dt = 帧时间
export fn on_update(entity_id: u32, dt: f32) void {
    state_time += dt;
    
    // 示例：简单上下浮动
    const amplitude: f32 = 2.0;
    const frequency: f32 = 2.0;
    const base_y: f32 = 1.0;
    const offset = @sin(state_time * frequency) * amplitude;
    
    api_set_position(entity_id, 0.0, base_y + offset, 0.0);
}

// 实体被销毁时调用
export fn on_destroy(entity_id: u32) void {
    api_log("Script cleanup!");
}

// =========================================
// 可选：碰撞回调
// =========================================

export fn on_trigger_enter(entity_id: u32, other_id: u32) void {
    // 碰撞进入
}

export fn on_trigger_exit(entity_id: u32, other_id: u32) void {
    // 碰撞离开
}
*/
```

#### 3.4.6 修改 `src/engine/script/hot_reload.zig`

```zig
const std = @import("std");
const wasm_vm = @import("./wasm_vm.zig");
const wasm_compiler = @import("./wasm_compiler.zig");
const log = std.log.scoped(.hot_reload);

pub const ScriptHotReloadManager = struct {
    allocator: std.mem.Allocator,
    wasm_vm: *wasm_vm.WasmVM,
    compiler: *wasm_compiler.WasmCompiler,
    watched_files: std.StringHashMap(WatchedScript),
    pending_reload: std.ArrayList(ScriptReloadTask),
    cache_dir: std.fs.Dir,

    pub const WatchedScript = struct {
        entity_id: world_mod.EntityId,
        source_path: []const u8,
        last_mtime: i128,
        compiled_wasm: ?[]const u8,
    };

    pub const ScriptReloadTask = struct {
        entity_id: world_mod.EntityId,
        source_path: []const u8,
        new_wasm: ?[]const u8,
        error: ?[]const u8,
    };

    pub fn checkForChanges(self: *ScriptHotReloadManager) void {
        var it = self.watched_files.iterator();
        while (it.next()) |entry| {
            const watched = entry.value_ptr;
            const current_mtime = getFileMtime(watched.source_path) catch continue;

            if (current_mtime > watched.last_mtime) {
                log.info("Script file changed: {s}", .{watched.source_path});
                watched.last_mtime = current_mtime;

                // 后台编译
                self.compileScriptInBackground(watched.entity_id, watched.source_path);
            }
        }
    }

    fn compileScriptInBackground(self: *ScriptHotReloadManager, entity_id: world_mod.EntityId, source_path: []const u8) void {
        // 在 JobSystem 中异步执行编译
        job_system.schedule(.script_compile, .{
            .entity_id = entity_id,
            .source_path = source_path,
        });
    }

    pub fn processPendingReload(self: *ScriptHotReloadManager) void {
        for (self.pending_reload.items) |task| {
            if (task.new_wasm) |wasm_bytes| {
                self.wasm_vm.unloadScript(task.entity_id);
                self.wasm_vm.loadScript(task.entity_id, wasm_bytes) catch |err| {
                    log.err("Failed to reload script for entity {}: {}", .{ task.entity_id, err });
                };
            }
        }
        self.pending_reload.clearRetainingCapacity();
    }
};
```

### 3.5 文件改动清单

| 操作 | 文件路径 | 说明 |
|------|----------|------|
| 新建 | `libs/wasm3/` | Wasm3 源码目录 |
| 修改 | `build.zig` | 添加 Wasm3 链接 |
| 新建 | `src/engine/script/wasm_vm.zig` | Wasm3 运行时封装 |
| 新建 | `src/engine/script/wasm_compiler.zig` | Zig → WASM 编译工具 |
| 新建 | `src/engine/script/script_entity.zig` | 脚本编写规范 |
| 修改 | `src/engine/script/hot_reload.zig` | 支持 WASM 热重载 |
| 删除 | `src/engine/script/vm.zig` | 旧的 ZigVM 存根 |

---

## 四、Phase 3: MCP 通信服务 (Model Context Protocol)

> **⚠️ 架构修正**: 原 HTTP REST 方案已被废弃，替换为 MCP (Model Context Protocol)
>
> **原因**: 让 LLM 写 curl 命令极易产生 JSON 转义错误。现代 AI 编程助手 (Cursor, Claude Desktop, Windsurf) 原生支持 MCP，通过结构化的 Tool 调用而非 shell 命令操作。

### 4.1 为什么选择 MCP

| 方案 | LLM 感知方式 | 错误率 | 生态支持 |
|------|-------------|--------|----------|
| HTTP REST + curl | LLM 必须生成 Bash 命令 + JSON 转义 | **极高** | LangChain 等框架 |
| **MCP** | LLM 原生调用结构化 Tool，传入 JSON 参数 | **极低** | Claude Desktop, Cursor, Windsurf |

**MCP 优势**:
- AI 直接调用 `tools/create_entity({ name: "Monster" })` 而非拼接 curl 命令
- 参数类型由 schema 声明，AI 不会传错
- 支持服务端推送 (Server Notifications)
- 双向通信，支持 streaming

### 4.2 MCP 协议架构

```
┌──────────────────────────────────────────────────────────────┐
│                      MCP Client (AI 编程助手)                  │
│  Claude Desktop / Cursor / Windsurf / 自定义 Agent           │
└──────────────────────────────────────────────────────────────┘
                              │
                              │ JSON-RPC 2.0 over Stdio or SSE
                              │ {
                              │   "jsonrpc": "2.0",
                              │   "id": 1,
                              │   "method": "tools/call",
                              │   "params": {
                              │     "name": "create_entity",
                              │     "arguments": { "name": "Monster", ... }
                              │   }
                              │ }
                              ▼
┌──────────────────────────────────────────────────────────────┐
│              Guava Engine (MCP Server)                       │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                   MCP Protocol Layer                    │  │
│  │                                                       │  │
│  │  Tools Registry:                                       │  │
│  │  - create_entity    { name, transform, components }    │  │
│  │  - set_transform    { entity_id, transform }            │  │
│  │  - delete_entity    { entity_id }                      │  │
│  │  - add_component    { entity_id, component }           │  │
│  │  - compile_script   { entity_id, source }               │  │
│  │  - query_entities   { filter, spatial }                │  │
│  │  - get_entity       { entity_id }                       │  │
│  │                                                       │  │
│  │  Resources:                                            │  │
│  │  - scene://hierarchy   (场景树快照)                     │  │
│  │  - entity://{id}       (实体详情)                       │  │
│  │  - wasm://{id}/logs    (WASM 执行日志)                 │  │
│  │  - wasm://{id}/stats   (WASM 性能统计)                 │  │
│  │                                                       │  │
│  │  Notifications:                                        │  │
│  │  - entity_created, entity_deleted, script_error        │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### 4.3 改造方案

#### 4.3.1 新建 `src/engine/mcp/mod.zig`

```zig
pub const mcp = struct {
    pub usingnamespace @import("protocol.zig");
    pub usingnamespace @import("server.zig");
    pub usingnamespace @import("tools/mod.zig");
    pub usingnamespace @import("resources/mod.zig");
    pub usingnamespace @import("notifications.zig");
};
```

#### 4.3.2 新建 `src/engine/mcp/protocol.zig` (MCP JSON-RPC 协议)

```zig
const std = @import("std");

pub const McpJsonRpcVersion = "2.0";

pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = McpJsonRpcVersion,
    id: ?RequestId = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const JsonRpcResponse = struct {
    jsonrpc: []const u8 = McpJsonRpcVersion,
    id: RequestId,
    result: ?std.json.Value = null,
    error: ?JsonRpcError = null,
};

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const RequestId = union(enum) {
    number: i64,
    string: []const u8,
    null,
};

pub const Notification = struct {
    method: []const u8,
    params: ?std.json.Value = null,
};

pub fn createToolCallRequest(
    tool_name: []const u8,
    arguments: std.json.Value,
    id: i64,
) JsonRpcRequest {
    return .{
        .id = .{ .number = id },
        .method = "tools/call",
        .params = .{
            .object = &.{
                .{ .tuple = .{ "name", arguments } },
                .{ .tuple = .{ "arguments", arguments } },
            },
        },
    };
}
```

#### 4.3.3 新建 `src/engine/mcp/server.zig` (MCP Server 主循环)

```zig
const std = @import("std");
const protocol = @import("protocol.zig");
const tools = @import("tools/mod.zig");
const resources = @import("resources/mod.zig");
const notifications = @import("notifications.zig");
const log = std.log.scoped(.mcp_server);

pub const McpServer = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    tools_registry: tools.Registry,
    resources_registry: resources.Registry,
    command_queue: *CommandQueue,
    query_engine: *QueryEngine,
    wasm_runtime: *WasmRuntime,

    pub const Transport = enum {
        stdio,    // 标准输入输出 (Claude Desktop)
        sse,      // Server-Sent Events (Web)
        websocket, // WebSocket (自建 Agent)
    };

    pub fn init(
        allocator: std.mem.Allocator,
        transport: Transport,
        command_queue: *CommandQueue,
        query_engine: *QueryEngine,
        wasm_runtime: *WasmRuntime,
    ) !McpServer {
        return .{
            .allocator = allocator,
            .transport = transport,
            .tools_registry = try tools.Registry.init(allocator),
            .resources_registry = try resources.Registry.init(allocator),
            .command_queue = command_queue,
            .query_engine = query_engine,
            .wasm_runtime = wasm_runtime,
        };
    }

    pub fn run(self: *McpServer) !void {
        switch (self.transport) {
            .stdio => try self.runStdio(),
            .sse => try self.runSSE(),
            .websocket => try self.runWebSocket(),
        }
    }

    fn runStdio(self: *McpServer) !void {
        const stdin = std.io.getStdIn();
        const stdout = std.io.getStdOut();
        var reader = stdin.reader();
        var writer = stdout.writer();

        // MCP 握手: 发送 Server 能力
        try self.sendInitializedNotification(&writer);

        // 主循环
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = reader.read(&buf) catch break;
            if (n == 0) break;

            const request_text = buf[0..n];
            const response = self.handleMessage(request_text) catch {
                // 发送错误响应
                try self.sendError(&writer, 0, -32600, "Invalid Request");
                continue;
            };

            try writer.writeAll(response);
            try writer.writeAll("\n");
        }
    }

    fn handleMessage(self: *McpServer, message: []const u8) ![]u8 {
        const request = try std.json.parseFromSlice(
            protocol.JsonRpcRequest,
            self.allocator,
            message,
            .{},
        );
        defer request.deinit();

        if (request.id == null) {
            // 通知 (notification)
            try self.handleNotification(request);
            return "";
        }

        const id = request.id.?;
        const result = self.handleRequest(request) catch |err| {
            return try self.formatError(id, err);
        };

        return try self.formatResponse(id, result);
    }

    fn handleRequest(self: *McpServer, req: protocol.JsonRpcRequest) !std.json.Value {
        const method = req.method;

        if (std.mem.startsWith(u8, method, "tools/")) {
            const tool_method = method["tools/".len..];
            return try self.handleToolRequest(tool_method, req.params);
        }

        if (std.mem.startsWith(u8, method, "resources/")) {
            const resource_method = method["resources/".len..];
            return try self.handleResourceRequest(resource_method, req.params);
        }

        return error.MethodNotFound;
    }

    fn handleToolRequest(self: *McpServer, tool: []const u8, params: ?std.json.Value) !std.json.Value {
        inline for (@typeInfo(tools.Registry).Struct.fields) |field| {
            if (std.mem.eql(u8, field.name, tool)) {
                const handler = @field(self.tools_registry, field.name);
                return try handler(params);
            }
        }
        return error.ToolNotFound;
    }

    fn formatResponse(self: *McpServer, id: protocol.RequestId, result: std.json.Value) ![]u8 {
        const response = protocol.JsonRpcResponse{
            .id = id,
            .result = result,
        };
        return try std.json.stringifyAlloc(self.allocator, response, .{});
    }
};
```

#### 4.3.4 新建 `src/engine/mcp/tools/mod.zig` (Tools 注册表)

```zig
const std = @import("std");
const command = @import("../../core/command.zig");
const query_engine = @import("../../core/query_engine.zig");
const wasm_runtime = @import("../../script/wasm_runtime.zig");
const log = std.log.scoped(.mcp_tools);

pub const Registry = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Registry { ... }

    pub fn create_entity(self: *Registry, params: ?std.json.Value) !std.json.Value {
        const world = getCurrentWorld();
        const args = params.?.object;

        const cmd = command.Command{
            .create_entity = .{
                .name = args["name"].string,
                .parent = if (args.get("parent_id")) |p| p.integer else null,
                .local_transform = parseTransform(args.get("transform")),
                .components = try parseComponents(self.allocator, args.get("components")),
            },
        };

        try self.command_queue.push(cmd);
        self.command_queue.executePending();

        return .{ .object = &.{
            .{ .tuple = .{ "entity_id", .{ .integer = @intCast(cmd.create_entity.entity_id) } } },
            .{ .tuple = .{ "success", .{ .bool = true } } },
        }};
    }

    pub fn set_transform(self: *Registry, params: ?std.json.Value) !std.json.Value {
        const args = params.?.object;
        const entity_id = @intCast(args["entity_id"].integer);
        const transform = parseTransform(args.get("transform"));

        const cmd = command.Command{
            .set_local_transform = .{
                .entity_id = entity_id,
                .transform = transform,
            },
        };

        try self.command_queue.push(cmd, .{
            .coalesce = true,  // 允许合并同类型命令
        });

        return .{ .object = &.{
            .{ .tuple = .{ "success", .{ .bool = true } } },
        }};
    }

    pub fn compile_script(self: *Registry, params: ?std.json.Value) !std.json.Value {
        const args = params.?.object;
        const entity_id = @intCast(args["entity_id"].integer);
        const source = args["source"].string;

        // 使用 UUID 沙箱目录防止并发冲突
        const task_id = try generateUuid();
        const result = try self.wasm_runtime.compileAndLoad(task_id, entity_id, source);

        if (result.error) |err| {
            return .{ .object = &.{
                .{ .tuple = .{ "success", .{ .bool = false } } },
                .{ .tuple = .{ "error", .{
                    .object = &.{
                        .{ .tuple = .{ "code", .{ .integer = 2001 } } },
                        .{ .tuple = .{ "message", .{ .string = "Compilation failed" } } },
                        .{ .tuple = .{ "details", .{ .string = err.details } } },
                        .{ .tuple = .{ "source_line", .{ .integer = err.line } } },
                    },
                } } },
            } };
        }

        return .{ .object = &.{
            .{ .tuple = .{ "success", .{ .bool = true } } },
            .{ .tuple = .{ "wasm_hash", .{ .string = result.hash } } },
            .{ .tuple = .{ "compile_time_ms", .{ .integer = result.compile_time_ms } } },
        }};
    }

    pub fn query_entities(self: *Registry, params: ?std.json.Value) !std.json.Value {
        const args = params.?.object;
        const filter = try parseQueryFilter(self.allocator, args.get("filter"));

        const results = try self.query_engine.query(filter);

        return try std.json.stringifyAlloc(self.allocator, results, .{});
    }

    pub fn get_entity(self: *Registry, params: ?std.json.Value) !std.json.Value {
        const entity_id = @intCast(params.?.object["entity_id"].integer);
        return try getEntitySnapshot(entity_id);
    }
};
```

#### 4.3.5 新建 `src/engine/mcp/resources/mod.zig` (Resources 资源系统)

```zig
pub const Registry = struct {
    resources: std.StringHashMap(ResourceHandler),
};

pub const ResourceHandler = *const fn (uri: []const u8, allocator: std.mem.Allocator) anyerror!ResourceData;

pub const ResourceUri = struct {
    scheme: []const u8,
    authority: []const u8,
    path: []const u8,

    pub fn parse(uri: []const u8) !ResourceUri {
        // 解析 mcp://entity/42 或 mcp://wasm/42/logs 等
    }
};

pub fn registerStandardResources(self: *Registry) !void {
    // scene://hierarchy - 返回完整场景树
    try self.register("scene://hierarchy", handleSceneHierarchy);

    // entity://{id} - 返回实体详情 (包含结构版本号)
    try self.register("entity://{id}", handleEntity);

    // wasm://{id}/logs - 返回 WASM 执行日志
    try self.register("wasm://{id}/logs", handleWasmLogs);

    // wasm://{id}/stats - 返回 WASM 性能统计
    try self.register("wasm://{id}/stats", handleWasmStats);
}

pub fn handleSceneHierarchy(uri: ResourceUri, allocator: std.mem.Allocator) !ResourceData {
    const world = getCurrentWorld();
    const hierarchy = try buildHierarchySnapshot(world, allocator);

    return .{
        .mime_type = "application/json",
        .contents = hierarchy,
        .blob = false,
    };
}

pub fn handleEntity(uri: ResourceUri, allocator: std.mem.Allocator) !ResourceData {
    const entity_id = try parseEntityIdFromUri(uri);
    const world = getCurrentWorld();
    const entity = world.getEntityConst(entity_id) orelse return error.NotFound;

    return .{
        .mime_type = "application/json",
        .contents = try std.json.stringifyAlloc(allocator, .{
            .id = entity.id,
            .name = entity.name,
            .topology_version = entity.topology_version,  // 结构版本
            .transform = entity.local_transform,
            .components = entity.components,
            .parent = entity.parent,
            .children = entity.children,
            .tags = entity.tags,
        }, .{}),
        .blob = false,
    };
}
```

#### 4.3.6 新建 `src/engine/mcp/notifications.zig` (服务端推送)

```zig
pub const ServerNotification = struct {
    method: []const u8,
    params: ?std.json.Value,
};

pub const NotificationType = enum {
    entity_created,
    entity_deleted,
    component_added,
    component_removed,
    transform_changed,
    script_error,
    script_log,
};

pub fn sendNotification(
    writer: anytype,
    notification: ServerNotification,
) !void {
    const msg = try std.json.stringifyAlloc(
        std.heap.page_allocator,
        notification,
        .{},
    );
    defer std.heap.page_allocator.free(msg);
    try writer.writeAll(msg);
    try writer.writeAll("\n");
}

pub fn notifyEntityCreated(writer: anytype, entity_id: EntityId, name: []const u8) !void {
    try sendNotification(writer, .{
        .method = "entity_created",
        .params = .{
            .object = &.{
                .{ .tuple = .{ "entity_id", .{ .integer = @intCast(entity_id) } } },
                .{ .tuple = .{ "name", .{ .string = name } } },
            },
        },
    });
}

pub fn notifyScriptError(writer: anytype, entity_id: EntityId, error: ScriptError) !void {
    try sendNotification(writer, .{
        .method = "script_error",
        .params = .{
            .object = &.{
                .{ .tuple = .{ "entity_id", .{ .integer = @intCast(entity_id) } } },
                .{ .tuple = .{ "error", .{
                    .object = &.{
                        .{ .tuple = .{ "message", .{ .string = error.message } } },
                        .{ .tuple = .{ "call_stack", .{
                            .array = try toJsonArray(error.call_stack),
                        } } },
                        .{ .tuple = .{ "line", .{ .integer = error.line } } },
                    },
                } } },
            },
        },
    });
}
```

### 4.4 MCP 工具定义 (AI 可直接调用)

```json
{
  "tools": [
    {
      "name": "create_entity",
      "description": "创建新实体",
      "inputSchema": {
        "type": "object",
        "properties": {
          "name": { "type": "string", "description": "实体名称" },
          "parent_id": { "type": "integer", "description": "父实体 ID" },
          "transform": { "$ref": "#/definitions/transform" },
          "components": { "$ref": "#/definitions/components" },
          "tags": { "type": "array", "items": { "type": "string" } }
        },
        "required": ["name"]
      }
    },
    {
      "name": "set_transform",
      "description": "设置实体变换 (支持命令合并，高频调用自动优化)",
      "inputSchema": {
        "type": "object",
        "properties": {
          "entity_id": { "type": "integer", "description": "实体 ID" },
          "transform": { "$ref": "#/definitions/transform" },
          "topology_version": { "type": "integer", "description": "拓扑版本号 (可选，用于冲突检测)" }
        },
        "required": ["entity_id", "transform"]
      }
    },
    {
      "name": "compile_script",
      "description": "编译并加载 WASM 脚本",
      "inputSchema": {
        "type": "object",
        "properties": {
          "entity_id": { "type": "integer", "description": "目标实体 ID" },
          "source": { "type": "string", "description": "Zig 源码" }
        },
        "required": ["entity_id", "source"]
      }
    },
    {
      "name": "query_entities",
      "description": "查询实体 (O(1) 增量索引)",
      "inputSchema": {
        "type": "object",
        "properties": {
          "filter": {
            "type": "object",
            "properties": {
              "tag": { "type": "string" },
              "has_component": { "type": "string" },
              "name_contains": { "type": "string" }
            }
          },
          "spatial": {
            "type": "object",
            "properties": {
              "center": { "type": "array", "items": { "type": "number" } },
              "radius": { "type": "number" }
            }
          },
          "limit": { "type": "integer", "default": 100 }
        }
      }
    }
  ],
  "definitions": {
    "transform": {
      "type": "object",
      "properties": {
        "translation": { "type": "array", "items": { "type": "number" } },
        "rotation": { "type": "array", "items": { "type": "number" } },
        "scale": { "type": "array", "items": { "type": "number" } }
      }
    },
    "components": {
      "type": "object",
      "properties": {
        "mesh": { "$ref": "#/definitions/mesh_component" },
        "rigidbody": { "$ref": "#/definitions/rigidbody_component" },
        "script": { "$ref": "#/definitions/script_component" }
      }
    }
  }
}
```

### 4.5 AI 使用示例 (Claude Desktop / Cursor)

```python
# Claude Desktop MCP 配置 (.mcp.json)
{
  "mcpServers": {
    "guava-engine": {
      "command": "/path/to/guava",
      "args": ["--mcp", "--mode", "stdio"]
    }
  }
}
```

```python
# Claude Code / Cursor 中的使用

# 1. 创建实体
await mcp.create_entity({
    name: "EnemySoldier",
    transform: { translation: [0, 0, 0] },
    components: {
        mesh: { primitive: "cube" },
        rigidbody: { motion_type: "dynamic", mass: 80 }
    },
    tags: ["Enemy", "Combat"]
})

# 2. 添加巡逻脚本
await mcp.compile_script({
    entity_id: 42,
    source: `
        var patrol_index: u32 = 0;
        var time_accum: f32 = 0.0;
        
        export fn on_init(eid: u32) void {
            api_log("Patrol AI initialized");
        }
        
        export fn on_update(eid: u32, dt: f32) void {
            time_accum += dt;
            if (time_accum > 2.0) {
                patrol_index = (patrol_index + 1) % 4;
                time_accum = 0.0;
            }
            // 简单的矩形巡逻
            const positions = [4][3]f32{
                .{ 0, 0, 0 },
                .{ 10, 0, 0 },
                .{ 10, 0, 10 },
                .{ 0, 0, 10 }
            };
            api_set_position(eid, positions[patrol_index][0], 0, positions[patrol_index][2]);
        }
    `
})

# 3. 查询所有敌人
const enemies = await mcp.query_entities({
    filter: { tag: "Enemy" },
    limit: 50
})

# 4. 获取实体详情 (包含拓扑版本)
const entity = await mcp.get_entity({ entity_id: 42 })
# entity.topology_version 用于冲突检测
```

### 4.6 与 Claude Desktop 的集成

```bash
#!/bin/bash
# scripts/start-mcp-server.sh

# 启动 Guava Engine 作为 MCP Server
./zig-out/bin/guava editor \
    --mcp \
    --transport stdio \
    --scene "projects/demo.scene"
```

```json
// Claude Desktop 配置
{
  "mcpServers": {
    "guava-engine": {
      "command": "/absolute/path/to/scripts/start-mcp-server.sh",
      "env": {
        "RUST_LOG": "info"
      }
    }
  }
}
```

### 4.7 文件改动清单

| 操作 | 文件路径 |
|------|----------|
| 新建 | `src/engine/mcp/mod.zig` |
| 新建 | `src/engine/mcp/protocol.zig` |
| 新建 | `src/engine/mcp/server.zig` |
| 新建 | `src/engine/mcp/tools/mod.zig` |
| 新建 | `src/engine/mcp/tools/command_tools.zig` |
| 新建 | `src/engine/mcp/tools/script_tools.zig` |
| 新建 | `src/engine/mcp/tools/query_tools.zig` |
| 新建 | `src/engine/mcp/resources/mod.zig` |
| 新建 | `src/engine/mcp/notifications.zig` |
| 修改 | `src/main.zig` (添加 `--mcp` 启动参数) |

---

## 五、Phase 4: 资产序列化文本化

### 5.1 目标

- 逻辑数据/元数据 → JSON 文本
- 重型二进制数据（顶点、纹理）→ 保持二进制
- AI 能够读取和修改场景/Prefab/材质文件

### 5.2 现状分析

当前 `src/engine/assets/library.zig` 和 `src/engine/scene/scene_io.zig` 的序列化格式需要评估。

### 5.3 改造方案

#### 5.3.1 双态资产管线

```
开发期 (Editor Mode):
  .scene    → JSON (人类可读, AI可读)
  .prefab   → JSON
  .material → JSON
  mesh.bin  → 原始顶点 (快速加载)
  texture.ktx2 → 压缩纹理

发布期 (Build Mode):
  .scene    → 二进制烘焙 (小体积, 快加载)
  mesh.bin  → .mesh (优化布局)
  texture   → .ktx2 (GPU直接读取)
```

#### 5.3.2 场景 JSON 格式

```json
{
  "version": "1.0",
  "entities": [
    {
      "id": 1,
      "name": "Player",
      "transform": {
        "translation": [0, 1.0, 0],
        "rotation": [0, 0, 0, 1],
        "scale": [1, 1, 1]
      },
      "components": {
        "mesh": {
          "handle": "cube.mesh",
          "primitive": "cube"
        },
        "material": {
          "handle": "default_mat.material"
        },
        "rigidbody": {
          "motion_type": "dynamic",
          "mass": 1.0
        },
        "box_collider": {
          "half_extents": [0.5, 1.0, 0.5]
        },
        "script": {
          "source": "scripts/player_controller.zig"
        }
      },
      "tags": ["Player", "Controllable"]
    },
    {
      "id": 2,
      "name": "Floor",
      "transform": {
        "translation": [0, 0, 0]
      },
      "components": {
        "mesh": {
          "handle": "plane.mesh",
          "primitive": "plane"
        },
        "rigidbody": {
          "motion_type": "static"
        }
      },
      "tags": ["Environment"]
    }
  ],
  "prefabs": [
    {
      "name": "Enemy",
      "source": "prefabs/enemy.prefab.json"
    }
  ]
}
```

#### 5.3.3 材质 JSON 格式

```json
{
  "name": "PBR_Metal",
  "base_color": {
    "r": 0.8,
    "g": 0.2,
    "b": 0.1,
    "a": 1.0
  },
  "metallic": 0.9,
  "roughness": 0.3,
  "emissive": {
    "r": 0,
    "g": 0,
    "b": 0,
    "a": 1
  },
  "textures": {
    "albedo": "textures/metal_albedo.ktx2",
    "normal": "textures/metal_normal.ktx2",
    "metallic_roughness": "textures/metal_mr.ktx2"
  }
}
```

#### 5.3.4 Prefab JSON 格式

```json
{
  "name": "EnemySoldier",
  "components": {
    "mesh": {
      "handle": "soldier.mesh"
    },
    "rigidbody": {
      "motion_type": "dynamic",
      "mass": 80.0
    },
    "box_collider": {
      "half_extents": [0.4, 1.8, 0.4]
    },
    "script": {
      "source": "scripts/enemy_ai.zig"
    },
    "animator": {
      "graph": "animations/soldier_graph.anim"
    }
  },
  "children": [
    {
      "name": "Weapon",
      "transform": {
        "translation": [0.5, 1.2, 0]
      },
      "components": {
        "mesh": {
          "handle": "rifle.mesh"
        }
      }
    }
  ]
}
```

### 5.4 文件改动清单

| 操作 | 文件路径 |
|------|----------|
| 新建 | `src/engine/assets/scene_writer_json.zig` |
| 新建 | `src/engine/assets/scene_reader_json.zig` |
| 新建 | `src/engine/assets/material_writer_json.zig` |
| 新建 | `src/engine/assets/material_reader_json.zig` |
| 新建 | `src/engine/assets/prefab_writer_json.zig` |
| 新建 | `src/engine/assets/prefab_reader_json.zig` |
| 修改 | `src/engine/assets/library.zig` |
| 修改 | `src/engine/scene/scene_io.zig` |

---

## 六、Phase 5: 语义查询接口

### 6.1 目标

解决 AI 上下文窗口限制，提供类数据库的查询能力。

### 6.2 查询能力矩阵

| 查询类型 | 示例 | 返回 |
|----------|------|------|
| 按 ID | `entity/42` | 单个实体详情 |
| 按标签 | `tag:Enemy` | 所有 Enemy 标签实体 |
| 按组件 | `has:Mesh, has:Rigidbody` | 所有有 Mesh 和 Rigidbody 的实体 |
| 空间查询 | `within_distance(0,0,0, 50)` | 距离原点 50 单位内所有实体 |
| 组合查询 | `tag:Enemy, distance<100, health<20` | 附近的低血量敌人 |
| 名称搜索 | `name_contains:"portal"` | 名称含 portal 的实体 |

### 6.3 查询引擎实现

> **⚠️ 架构修正**: 废弃全量重建，改用 O(1) 增量索引

```zig
pub const QueryEngine = struct {
    world: *world_mod.World,
    allocator: std.mem.Allocator,

    // 增量索引: 每个实体的标签/组件变更只更新相关倒排索引
    // O(1) 时间复杂度，而非 O(N) 全量重建
    by_tag: std.StringHashMap(std.ArrayListUnmanaged(world_mod.EntityId)),
    by_component_type: std.EnumArray(ComponentType, std.ArrayListUnmanaged(world_mod.EntityId)),
    by_name_substring: std.StringHashMap(std.ArrayListUnmanaged(world_mod.EntityId)),

    // 实体到其索引位置的映射，用于 O(1) 删除
    entity_tags: std.AutoHashMapUnmanaged(world_mod.EntityId, []const []const u8),
    entity_components: std.AutoHashMapUnmanaged(world_mod.EntityId, ComponentTypeSet),

    pub fn init(allocator: std.mem.Allocator) !QueryEngine {
        var qe = QueryEngine{
            .world = undefined,
            .allocator = allocator,
            .by_tag = std.StringHashMap(std.ArrayListUnmanaged(world_mod.EntityId)).init(allocator),
            .by_name_substring = std.StringHashMap(std.ArrayListUnmanaged(world_mod.EntityId)).init(allocator),
            .entity_tags = std.AutoHashMapUnmanaged(world_mod.EntityId, []const []const u8).init(allocator),
            .entity_components = std.AutoHashMapUnmanaged(world_mod.EntityId, ComponentTypeSet).init(allocator),
        };

        inline for (@typeInfo(ComponentType).Enum.fields) |field| {
            qe.by_component_type.set(@enumFromInt(field.value), .empty);
        }

        return qe;
    }

    // ============================================================
    // 增量更新: 由 Command 系统在执行命令时调用
    // ============================================================

    pub fn onEntityCreated(self: *QueryEngine, entity: *const world_mod.Entity) !void {
        // 索引标签
        if (entity.tags) |tags| {
            for (tags) |tag| {
                const list = try self.by_tag.getOrPutValue(tag, .empty);
                try list.value_ptr.append(self.allocator, entity.id);
            }
            try self.entity_tags.put(self.allocator, entity.id, tags);
        }

        // 索引组件
        var component_set = ComponentTypeSet{};
        if (entity.mesh) |_| { component_set.insert(.mesh); }
        if (entity.rigidbody) |_| { component_set.insert(.rigidbody); }
        if (entity.light) |_| { component_set.insert(.light); }
        if (entity.script) |_| { component_set.insert(.script); }
        // ... 其他组件

        for (component_set) |comp_type| {
            const list = self.by_component_type.get(comp_type);
            try list.append(self.allocator, entity.id);
        }
        try self.entity_components.put(self.allocator, entity.id, component_set);

        // 索引名称 (按字符 n-gram 索引，支持子串搜索)
        try self.indexEntityName(entity.id, entity.name);
    }

    pub fn onEntityDeleted(self: *QueryEngine, entity_id: world_mod.EntityId) void {
        // O(1) 从各索引中移除
        if (self.entity_tags.get(entity_id)) |tags| {
            for (tags) |tag| {
                if (self.by_tag.get(tag)) |list| {
                    const idx = std.mem.indexOfScalar(world_mod.EntityId, list.items, entity_id);
                    if (idx) |i| {
                        _ = list.swapRemove(i);
                    }
                }
            }
            _ = self.entity_tags.remove(entity_id);
        }

        if (self.entity_components.get(entity_id)) |comp_set| {
            for (comp_set) |comp_type| {
                if (self.by_component_type.get(comp_type)) |list| {
                    const idx = std.mem.indexOfScalar(world_mod.EntityId, list.items, entity_id);
                    if (idx) |i| {
                        _ = list.swapRemove(i);
                    }
                }
            }
            _ = self.entity_components.remove(entity_id);
        }

        self.removeEntityNameIndex(entity_id);
    }

    pub fn onComponentAdded(self: *QueryEngine, entity_id: world_mod.EntityId, comp_type: ComponentType) void {
        // O(1) 添加到组件索引
        const list = self.by_component_type.get(comp_type);
        try list.append(self.allocator, entity_id);

        // 更新实体组件映射
        if (self.entity_components.getPtr(entity_id)) |set| {
            set.insert(comp_type);
        }
    }

    pub fn onComponentRemoved(self: *QueryEngine, entity_id: world_mod.EntityId, comp_type: ComponentType) void {
        // O(1) 从组件索引移除
        if (self.by_component_type.get(comp_type)) |list| {
            const idx = std.mem.indexOfScalar(world_mod.EntityId, list.items, entity_id);
            if (idx) |i| {
                _ = list.swapRemove(i);
            }
        }

        if (self.entity_components.getPtr(entity_id)) |set| {
            set.remove(comp_type);
        }
    }

    // ============================================================
    // 查询执行: 使用倒排索引加速
    // ============================================================

    pub fn query(self: *QueryEngine, req: QueryRequest) QueryResult {
        var candidate_ids = std.ArrayListUnmanaged(world_mod.EntityId){};
        var limit = req.limit orelse 100;

        // 选择最小的候选集作为初始集合
        if (req.filter.tag) |tag| {
            if (self.by_tag.get(tag)) |ids| {
                candidate_ids.appendSlice(self.allocator, ids.items[0..@min(ids.items.len, limit)]) catch {};
            }
        } else if (req.filter.component) |comp| {
            const comp_type = std.meta.stringToEnum(ComponentType, comp) orelse return emptyResult();
            if (self.by_component_type.get(comp_type)) |ids| {
                candidate_ids.appendSlice(self.allocator, ids.items[0..@min(ids.items.len, limit)]) catch {};
            }
        } else {
            // 无过滤条件，返回所有实体 (但限制数量)
            for (self.entity_components.keys()) |entity_id| {
                if (candidate_ids.items.len >= limit) break;
                candidate_ids.append(self.allocator, entity_id) catch break;
            }
        }

        // 进一步过滤
        var results = std.ArrayListUnmanaged(EntitySnapshot){};
        for (candidate_ids.items) |entity_id| {
            if (results.items.len >= limit) break;

            const entity = self.world.getEntityConst(entity_id) orelse continue;

            // 名称过滤
            if (req.filter.name_contains) |substr| {
                if (!std.mem.containsAtLeast(u8, entity.name, 1, substr)) {
                    continue;
                }
            }

            // 空间过滤 (使用场景的 BVH)
            if (req.spatial) |sp| {
                const center = sp.center orelse blk: {
                    const center_entity = self.world.getEntityConst(sp.center_entity.?) orelse break :blk;
                    break :blk center_entity.worldTransformConst().translation;
                };
                const entity_pos = entity.worldTransformConst().translation;
                const dist = vec3.distance(center, entity_pos);
                if (dist > sp.radius) continue;
            }

            try results.append(self.allocator, snapshot(entity));
        }

        return .{ .entities = results };
    }

    fn indexEntityName(self: *QueryEngine, entity_id: world_mod.EntityId, name: []const u8) !void {
        // 简单的 n-gram 索引
        const n = 3;
        var i: usize = 0;
        while (i + n <= name.len) : (i += 1) {
            const gram = name[i..i+n];
            const list = try self.by_name_substring.getOrPutValue(gram, .empty);
            try list.value_ptr.append(self.allocator, entity_id);
        }
    }
};
```

### 6.4 Command 系统与 QueryEngine 的集成

```zig
// 在 CommandQueue 执行时，自动触发 QueryEngine 增量更新

pub fn execute(self: *CommandQueue, cmd: Command) void {
    switch (cmd) {
        .create_entity => |c| {
            self.execCreateEntity(c);
            // 增量更新 QueryEngine
            const entity = self.world.getEntity(c.entity_id).?;
            self.query_engine.onEntityCreated(entity) catch {};
        },
        .delete_entity => |c| {
            // 增量更新 QueryEngine
            self.query_engine.onEntityDeleted(c.entity_id);
            self.execDeleteEntity(c);
        },
        .add_component => |c| {
            self.execAddComponent(c);
            self.query_engine.onComponentAdded(c.entity_id, c.component_type);
        },
        .remove_component => |c| {
            self.query_engine.onComponentRemoved(c.entity_id, c.component_type);
            self.execRemoveComponent(c);
        },
        // 变换命令不触发 QueryEngine 更新
        .set_local_transform, .set_world_transform => {
            self.execTransform(cmd);
        },
    }
}
```

---

## 七、实现顺序与依赖关系

```
Phase 1: Command 架构 ─────────────────┐
    │                                   │
    ▼                                   │
Phase 2: WASM 运行时 ──────────────────┤  (独立)
    │                                   │
    ▼                                   │
Phase 3: MCP 服务 ──────────────────────┼──► (依赖 Phase 1 Command)
    │                                   │
    ▼                                   │
Phase 4: 序列化文本化 ──────────────────┤
    │                                   │
    ▼                                   │
Phase 5: 语义查询 ──────────────────────┘  (依赖 Phase 3 MCP)
```

### 7.1 详细里程碑

| 阶段 | 步骤 | 文件改动 | 测试验收 |
|------|------|----------|----------|
| **Phase 1** | 1.1 定义 Command 枚举 | `core/command.zig` | |
| | 1.2 实现 CommandQueue + 合并 | `core/command_queue.zig` | |
| | 1.3 JSON 序列化 | `core/command_json.zig` | |
| | 1.4 UI 改造 | `editor/ui/*.zig` | |
| | 1.5 验收 | - | 拖拽 60fps 不淹没队列 |
| **Phase 2** | 2.1 接入 Wasm3 | `build.zig`, `libs/wasm3/` | |
| | 2.2 实现 WasmVM + Panic Handler | `script/wasm_vm.zig` | |
| | 2.3 UUID 沙箱编译 | `script/wasm_compiler.zig` | |
| | 2.4 热重载管线 | `script/hot_reload.zig` | |
| | 2.5 验收 | - | 并发编译不冲突，panic 有回溯 |
| **Phase 3** | 3.1 MCP Server | `mcp/server.zig` | |
| | 3.2 MCP Tools 注册 | `mcp/tools/mod.zig` | |
| | 3.3 MCP Resources | `mcp/resources/mod.zig` | |
| | 3.4 验收 | - | Claude Desktop 能调用 Tool |
| **Phase 4** | 4.1 JSON Scene 读写 | `assets/scene_*_json.zig` | |
| | 4.2 JSON Material 读写 | `assets/material_*_json.zig` | |
| | 4.3 JSON Prefab 读写 | `assets/prefab_*_json.zig` | |
| | 4.4 验收 | - | AI 能读取 .scene 文件 |
| **Phase 5** | 5.1 增量索引 | `core/query_engine.zig` | |
| | 5.2 Query API | `mcp/tools/query_tools.zig` | |
| | 5.3 验收 | - | 10000 实体查询 <20ms |

---

## 八、AI 集成工作流

### 8.1 完整 Vibe Coding 流程

```
┌──────────────────────────────────────────────────────────────┐
│                     AI Agent                                  │
│  "创建一个会巡逻的敌人"                                        │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  HTTP POST /api/scene/hierarchy                               │
│  获取当前场景状态                                              │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  AI 分析场景，决定创建实体和脚本                                │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  HTTP POST /api/command                                       │
│  {"cmd":"create_entity", "name":"Enemy", "components":[...]}  │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  HTTP POST /api/script/compile                                │
│  {                                                            │
│    "entity_id": 42,                                          │
│    "source": "export fn on_update(eid, dt) { ... }"          │
│  }                                                            │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  引擎后台编译 Zig → WASM (约 100-500ms)                        │
│  引擎热重载 WASM 模块                                          │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  引擎下一帧执行新脚本                                          │
│  敌人开始巡逻                                                  │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  AI HTTP GET /api/scene/entity/42                             │
│  验证巡逻效果                                                  │
└──────────────────────────────────────────────────────────────┘
```

### 8.2 AI Prompt 模板

```markdown
你正在与 Guava Engine 交互。

引擎提供以下 HTTP API：
- GET  /api/scene/hierarchy - 获取场景
- POST /api/command - 执行命令
- POST /api/script/compile - 编译脚本
- POST /api/query - 执行查询

所有请求和响应都是 JSON 格式。

示例 - 创建敌人并添加巡逻脚本：
```bash
# 1. 创建敌人实体
curl -X POST http://localhost:8080/api/command -d '{
  "cmd": "create_entity",
  "name": "PatrolEnemy",
  "transform": {"translation": [0, 0, 0]},
  "components": {"mesh": {"primitive": "cube"}, "rigidbody": {"motion_type": "static"}}
}'

# 2. 添加巡逻脚本
curl -X POST http://localhost:8080/api/script/compile -d '{
  "entity_id": 2,
  "source": "export fn on_update(eid: u32, dt: f32) void { ... }"
}'
```

请继续你的指令。
```

---

## 九、安全考虑

### 9.1 WASM 沙箱限制

- **内存限制**：每个脚本 64KB 栈空间
- **无文件系统访问**：脚本无法读写文件
- **无网络访问**：脚本无法发起网络请求
- **CPU 时间限制**：单帧执行超时则终止

### 9.2 RPC 安全

- **本地连接**：仅监听 127.0.0.1，不暴露公网
- **速率限制**：防止恶意请求淹没引擎
- **命令审计**：所有命令写入日志

### 9.3 沙箱逃逸防御

```zig
// Host API 实现中，禁止传递指针
export fn api_set_position(entity_id: u32, x: f32, y: f32, z: f32) void {
    // 只通过 ID 和基础类型通信
    // 绝不让 WASM 访问裸指针
    pending_commands.append(.{ .set_position = .{ .entity_id = entity_id, .pos = .{x, y, z} } });
}
```

---

## 十、验收标准

### Phase 1 验收

- [ ] `curl -X POST http://localhost:8080/api/command` 能创建实体
- [ ] Inspector 修改坐标产生的效果与 curl 发送命令相同
- [ ] Undo/Redo 正常

### Phase 2 验收

- [ ] AI 输出 Zig 代码 → 100ms 内编译完成
- [ ] 脚本运行时崩溃不影响引擎
- [ ] 热重载后脚本状态保持或正确重置

### Phase 3 验收

- [ ] `curl http://localhost:8080/api/scene/hierarchy` 返回正确 JSON
- [ ] `curl http://localhost:8080/api/health` 返回 OK
- [ ] 并发请求不崩溃

### Phase 4 验收

- [ ] `.scene` 文件是纯 JSON
- [ ] AI 能读取 `.scene` 并理解场景结构
- [ ] 保存/加载保持数据一致

### Phase 5 验收

- [ ] `curl -X POST http://localhost:8080/api/query -d '{"tag":"Enemy"}'` 返回所有 Enemy
- [ ] 空间查询返回正确距离范围内的实体
- [ ] 组合查询正确交集

---

## 十一、FAQ

### Q: 为什么选择 Wasm3 而不是 Wasmtime？

Wasm3 是解释器，执行速度略慢但启动极快。Wasmtime 是 JIT，编译开销大。对于脚本热重载场景，Wasm3 更合适。

### Q: 为什么不用 Rust 来写 WASM 脚本？

可以！Rust 可以编译到 `wasm32-unknown-unknown`。Zig 是因为与引擎同语言，编译最顺畅。

### Q: JSON 序列化性能问题？

开发期不在意性能。发布期可以烘焙为二进制。JSON 仅用于 Editor 模式和 AI 通信。

### Q: 如何防止恶意 AI 代码？

1. WASM 沙箱隔离
2. Host API 仅传递 ID 和基础类型
3. 命令队列限流
4. 沙箱 CPU 时间限制

### Q: 多人协作支持？

Phase 3 RPC 服务天然支持多客户端。后续可加入 OT/CRDT 算法实现多人编辑。

---

## 十二、附录

### A. 推荐的目录结构

```
src/
├── engine/
│   ├── core/
│   │   ├── command.zig
│   │   ├── command_queue.zig
│   │   ├── command_json.zig
│   │   ├── query_engine.zig
│   │   └── query_index.zig
│   ├── rpc/
│   │   ├── mod.zig
│   │   ├── server.zig
│   │   ├── router.zig
│   │   └── handlers/
│   │       ├── mod.zig
│   │       ├── scene.zig
│   │       ├── command.zig
│   │       ├── script.zig
│   │       └── query.zig
│   ├── script/
│   │   ├── wasm_vm.zig
│   │   ├── wasm_compiler.zig
│   │   ├── hot_reload.zig
│   │   └── script_entity.zig
│   └── assets/
│       ├── scene_writer_json.zig
│       ├── scene_reader_json.zig
│       ├── material_writer_json.zig
│       ├── material_reader_json.zig
│       ├── prefab_writer_json.zig
│       └── prefab_reader_json.zig
libs/
└── wasm3/
    └── source/
```

### B. 参考资源

- Wasm3: https://github.com/wasm3/wasm3
- Zig WASM: https://ziglang.org/documentation/master/#WebAssembly
- JSON-RPC 2.0: https://www.jsonrpc.org/specification

---

## 十三、错误处理规范

### 13.1 错误码体系

所有错误采用**分段错误码**设计：

| 错误码范围 | 分类 | 说明 |
|------------|------|------|
| 1000-1999 | **场景/实体错误** | 实体不存在、组件类型无效等 |
| 2000-2999 | **WASM 运行时错误** | 编译失败、运行时崩溃、超时等 |
| 3000-3999 | **命令队列错误** | 队列满、命令无效等 |
| 4000-4999 | **并发冲突错误** | 版本冲突、锁等待等 |
| 5000-5999 | **资产错误** | 资源不存在、加载失败等 |
| 9000-9999 | **系统错误** | 内存不足、IO错误等 |

### 13.2 详细错误码表

#### 场景/实体错误 (1000-1999)

| 错误码 | 含义 | HTTP 状态码 | 解决方案 |
|--------|------|-------------|----------|
| 1001 | 实体不存在 | 404 | 检查 entity_id 是否正确 |
| 1002 | 实体名称已存在 | 400 | 使用唯一名称重试 |
| 1003 | 父实体不存在 | 404 | 检查 parent_id |
| 1004 | 组件类型无效 | 400 | 使用有效的 ComponentType |
| 1005 | 实体已有此组件 | 400 | 使用 modify_component 而非 add_component |
| 1006 | 组件不存在 | 404 | 先添加组件 |
| 1007 | 子实体不存在 | 404 | 检查 children 列表 |
| 1008 | 循环层级检测 | 400 | 不能将实体设为自己的后代 |

#### WASM 运行时错误 (2000-2999)

| 错误码 | 含义 | HTTP 状态码 | 解决方案 |
|--------|------|-------------|----------|
| 2001 | WASM 编译失败 | 400 | 检查 Zig 语法错误 |
| 2002 | WASM 解析失败 | 400 | 检查 .wasm 文件是否损坏 |
| 2003 | WASM 链接失败 | 500 | 检查 Host API 签名 |
| 2004 | WASM 运行时崩溃 | 500 | 检查脚本逻辑，查看错误日志 |
| 2005 | WASM 执行超时 | 500 | 减少脚本计算量 |
| 2006 | WASM 内存溢出 | 500 | 减少脚本内存使用 |
| 2007 | 导出函数不存在 | 400 | 实现必需的 on_init/on_update |
| 2008 | Host API 调用失败 | 500 | 检查参数是否有效 |

#### 命令队列错误 (3000-3999)

| 错误码 | 含义 | HTTP 状态码 | 解决方案 |
|--------|------|-------------|----------|
| 3001 | 命令队列已满 | 503 | 等待后重试 |
| 3002 | 命令格式无效 | 400 | 检查 JSON 格式 |
| 3003 | 命令参数缺失 | 400 | 检查必需参数 |
| 3004 | 命令参数类型错误 | 400 | 检查参数类型 |
| 3005 | 命令不支持 | 400 | 检查 cmd 字段 |

#### 并发冲突错误 (4000-4999)

| 错误码 | 含义 | HTTP 状态码 | 解决方案 |
|--------|------|-------------|----------|
| 4001 | 实体版本冲突 | 409 | 使用最新版本号重试 |
| 4002 | 场景版本冲突 | 409 | 获取最新场景快照后重试 |
| 4003 | 批量命令部分失败 | 207 | 查看 details 了解详情 |

### 13.3 错误响应格式

所有 API 错误响应遵循统一格式：

```json
{
  "success": false,
  "error": {
    "code": 2001,
    "message": "WASM compilation failed",
    "details": "line 42: undefined identifier 'foo'\nDid you mean 'foo'?\n",
    "context": {
      "entity_id": 42,
      "source_line": 42
    }
  },
  "request_id": "req_abc123"
}
```

### 13.4 重试机制

#### 客户端重试策略

```zig
pub const RetryConfig = struct {
    max_retries: u32 = 3,
    initial_delay_ms: u32 = 100,
    max_delay_ms: u32 = 5000,
    backoff_multiplier: f32 = 2.0,
};

pub fn retryWithBackoff(
    comptime op: anytype,
    config: RetryConfig,
) !@TypeOf(op).ReturnType {
    var delay = config.initial_delay_ms;
    var last_error: anyerror = undefined;
    
    for (0..config.max_retries) |attempt| {
        if (op()) catch |err| {
            last_error = err;
            
            // 检查是否是可重试的错误
            if (!isRetryable(err)) {
                return err;
            }
            
            if (attempt < config.max_retries - 1) {
                std.Thread.sleep(std.time.ns_per_ms * delay);
                delay = @min(
                    @as(u32, @intFromFloat(@as(f32, @floatFromInt(delay)) * config.backoff_multiplier)),
                    config.max_delay_ms,
                );
            }
            continue;
        };
        return op();
    }
    
    return last_error;
}

fn isRetryable(err: anyerror) bool {
    return switch (err) {
        error.CommandQueueFull => true,
        error.SystemBusy => true,
        error.WasmCompileInProgress => true,
        else => false,
    };
}
```

#### 可重试 vs 不可重试错误

| 可重试 | 不可重试 |
|--------|----------|
| CommandQueueFull | EntityNotFound |
| SystemBusy | InvalidCommandFormat |
| WasmCompileInProgress | CompilationError |
| Timeout | RuntimeCrash |
| ConnectionReset | VersionConflict |

### 13.5 超时处理

```zig
pub const TimeoutConfig = struct {
    rpc_read_timeout_ms: u32 = 5000,
    rpc_write_timeout_ms: u32 = 5000,
    wasm_execution_timeout_ms: u32 = 1000,
    compilation_timeout_ms: u32 = 30000,
    scene_serialization_timeout_ms: u32 = 10000,
};

pub fn withTimeout(
    comptime deadline_ms: u32,
    comptime op: anytype,
) !@TypeOf(op).ReturnType {
    const start = std.time.nanoTimestamp();
    const deadline_ns = @as(i128, deadline_ms) * std.time.ns_per_ms;
    
    while (true) {
        if (op()) |result| {
            return result;
        } else |err| {
            const elapsed = std.time.nanoTimestamp() - start;
            if (elapsed > deadline_ns) {
                return error.Timeout;
            }
            // 检查是否还有其他工作要做
            if (isFinalError(err)) {
                return err;
            }
        }
    }
}
```

---

## 十四、性能基准

### 14.1 性能目标矩阵

| 操作 | 目标延迟 | 最大延迟 | 验收标准 |
|------|----------|----------|----------|
| WASM 编译 (100行) | <200ms | <500ms | P99 < 500ms |
| WASM 热重载 | <100ms | <300ms | 包括编译+替换 |
| RPC 请求往返 | <10ms | <50ms | P99 < 50ms |
| 场景序列化 (1000实体) | <50ms | <200ms | P99 < 200ms |
| 场景反序列化 (1000实体) | <100ms | <500ms | P99 < 500ms |
| 语义查询 (<100结果) | <5ms | <20ms | P99 < 20ms |
| 命令入队 | <1ms | <10ms | 同步完成 |
| 命令执行 | <10ms | <50ms | 每帧累计 |

### 14.2 性能测试工具

```zig
// src/engine/core/bench.zig
pub const PerformanceBenchmark = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayList(BenchmarkResult),

    pub const BenchmarkResult = struct {
        name: []const u8,
        iterations: u32,
        total_ns: i128,
        p50_ns: i128,
        p95_ns: i128,
        p99_ns: i128,
    };

    pub fn run(
        self: *PerformanceBenchmark,
        name: []const u8,
        iterations: u32,
        op: *const fn () anyerror!void,
    ) !void {
        var timings = try std.ArrayList(i128).initCapacity(self.allocator, iterations);
        defer timings.deinit();

        // 预热
        for (0..10) |_| { _ = op() catch {}; }

        // 测量
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            _ = op() catch {};
            const elapsed = std.time.nanoTimestamp() - start;
            timings.appendAssumeCapacity(elapsed);
        }

        std.sort.sort(i128, timings.items, {}, std.sort.asc(i128));

        const p50 = timings.items[timings.items.len * 50 / 100];
        const p95 = timings.items[timings.items.len * 95 / 100];
        const p99 = timings.items[timings.items.len * 99 / 100];

        try self.results.append(.{
            .name = name,
            .iterations = iterations,
            .total_ns = std.mem.fold(i128, timings.items, 0, std.add),
            .p50_ns = p50,
            .p95_ns = p95,
            .p99_ns = p99,
        });
    }

    pub fn report(self: *PerformanceBenchmark) void {
        std.debug.print("\n=== Performance Benchmark Results ===\n", .{});
        for (self.results.items) |result| {
            std.debug.print(
                \\{s}:
                \\  Iterations: {d}
                \\  Total: {d:.2}ms
                \\  P50: {d:.2}ms
                \\  P95: {d:.2}ms
                \\  P99: {d:.2}ms
                \\
            , .{
                result.name,
                result.iterations,
                @as(f64, @floatFromInt(result.total_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(result.p50_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(result.p95_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(result.p99_ns)) / std.time.ns_per_ms,
            });
        }
    }
};
```

### 14.3 性能监控端点

```bash
# 获取引擎性能统计
curl http://localhost:8080/api/debug/stats

# 响应
{
  "uptime_seconds": 3600,
  "wasm_compilations": {
    "total": 42,
    "failed": 1,
    "avg_duration_ms": 150
  },
  "commands": {
    "total": 1234,
    "pending": 0,
    "queue_capacity": 1000
  },
  "queries": {
    "total": 5000,
    "avg_duration_ms": 2.5
  },
  "memory": {
    "wasm_allocated_kb": 512,
    "wasm_peak_kb": 1024,
    "entity_count": 156
  }
}
```

---

## 十五、并发模型

> **⚠️ 架构修正**: 分离结构版本 (Topology Version) 与数据版本 (Data Version)，解决物理引擎导致的 100% 拒绝率问题

### 15.1 问题分析

**原方案的问题**：

带物理组件的实体，每帧 (16ms) 会被物理引擎修改 Transform。如果 AI 获取快照时 version=5，花 2 秒思考后发送修改指令，此时 version=125，指令被永久拒绝。

```
游戏运行: frame 1 → frame 2 → ... → frame 125
              ↓        ↓              ↓
Transform:  v=5      v=10  ...  v=125
                              ↓
AI 发送指令 (预期 v=5)  →  409 Conflict!
```

### 15.2 双版本系统

```zig
pub const Entity = struct {
    id: EntityId,
    name: []u8,

    // ============================================================
    // 结构版本 (Topology Version) - AI 修改结构时检查
    // ============================================================
    // 实体层级变化、组件增删时递增
    topology_version: u64 = 0,

    // ============================================================
    // 数据版本 (Data Version) - AI 修改数据时检查 (可选)
    // ============================================================
    // Transform 被物理引擎修改时递增
    // AI 可以选择忽略此版本 (allow_stale_data = true)
    data_version: u64 = 0,

    // 组件...
    mesh: ?Mesh = null,
    rigidbody: ?Rigidbody = null,
    // ...
};

pub const VersionedEntitySnapshot = struct {
    id: EntityId,
    name: []u8,

    // 用于 AI 修改结构时检查版本
    topology_version: u64,

    // 用于 AI 修改数据时检查版本 (可选)
    data_version: u64,

    // 实际数据
    transform: Transform,
    components: ComponentMap,

    // AI 是否应该关心 data_version
    data_is_authoritative: bool,  // true = 物理引擎 authoritative
};
```

### 15.3 版本检查策略

```zig
pub const CommandContext = struct {
    // 命令来源
    source: CommandSource,

    // 是否允许陈旧数据 (对于 AI，通常允许)
    allow_stale_data: bool,

    // 是否强制覆盖 (用于物理引擎等系统命令)
    force_override: bool,

    pub const CommandSource = enum {
        ai_agent,
        editor_ui,
        physics_engine,
        animation_system,
        script_runtime,
    },
};

pub fn executeWithVersionCheck(
    queue: *CommandQueue,
    cmd: Command,
    ctx: CommandContext,
) !void {
    switch (cmd) {
        // 结构修改: 永远检查 topology_version
        .create_entity, .delete_entity, .add_component, .remove_component => |c| {
            const entity = queue.world.getEntity(c.entity_id) orelse return error.EntityNotFound;

            if (ctx.force_override) {
                // 物理引擎等系统命令绕过检查
            } else if (ctx.source == .ai_agent) {
                // AI 修改结构，检查 topology_version
                if (c.expected_topology_version) |expected| {
                    if (entity.topology_version != expected) {
                        return error.TopologyVersionConflict;
                    }
                }
                entity.topology_version += 1;
            }
        },

        // 数据修改: 根据配置决定是否检查 data_version
        .set_local_transform, .set_world_transform => |c| {
            const entity = queue.world.getEntity(c.entity_id) orelse return error.EntityNotFound;

            if (entity.rigidbody != null and !entity.data_is_authoritative) {
                // 有物理组件，且数据由物理引擎 authoritative
                // AI 应该忽略 data_version，让物理引擎处理
                // 但这里允许 AI 直接设置 (命令被排队，在物理 step 前执行)
            } else if (ctx.allow_stale_data) {
                // AI 允许陈旧数据，直接执行
            } else {
                // 检查 data_version
                if (c.expected_data_version) |expected| {
                    if (entity.data_version != expected) {
                        return error.DataVersionConflict;
                    }
                }
            }

            entity.data_version += 1;
        },
    }

    try queue.execute(cmd);
}
```

### 15.4 实体快照与版本报告

```zig
pub fn getEntitySnapshot(
    world: *World,
    entity_id: EntityId,
    ctx: CommandContext,
) !EntitySnapshot {
    const entity = world.getEntity(entity_id) orelse return error.NotFound;

    return .{
        .id = entity.id,
        .name = entity.name,
        .topology_version = entity.topology_version,
        .data_version = entity.data_version,

        // AI 应该知道这个实体是否被物理引擎控制
        .data_is_authoritative = entity.rigidbody != null,
        .physics_controlled = entity.rigidbody != null,

        .transform = entity.local_transform,
        .world_transform = entity.world_transform_cache,

        // 如果有 rigidbody，报告物理引擎的当前状态
        .physics_state = if (entity.rigidbody) |rb| blk: {
            break :blk world.physics.getBodyState(entity_id);
        } else null,

        .components = try serializeComponents(entity, world.allocator),
    };
}
```

### 15.5 MCP 响应中的版本信息

```json
// MCP Resource: entity://42
{
  "id": 42,
  "name": "PlayerCube",
  "topology_version": 5,
  "data_version": 1234,

  "data_is_authoritative": false,
  "physics_controlled": true,

  "transform": {
    "translation": [0, 5.0, 0],
    "rotation": [0, 0.707, 0, 0.707],
    "scale": [1, 1, 1]
  },

  "physics_state": {
    "velocity": [0, -0.5, 0],
    "angular_velocity": [0, 0.2, 0],
    "is_kinematic": false
  },

  "components": {
    "mesh": { "handle": "cube.mesh" },
    "rigidbody": { "motion_type": "dynamic" },
    "box_collider": { "half_extents": [0.5, 0.5, 0.5] }
  },

  "_ai_guidance": {
    "note": "This entity is physics-controlled. Setting transform via 'set_transform' will be queued and may be overridden by physics.",
    "recommended_approach": "Use 'apply_force' or 'set_kinematic' instead."
  }
}
```

### 15.6 冲突解决策略

```zig
pub const ConflictResolution = enum {
    reject,        // 拒绝命令
    merge,         // 尝试合并
    queue,         // 排队等待
    override,      // 强制覆盖
};

pub fn resolveConflict(
    cmd: Command,
    current_entity: *Entity,
    ctx: CommandContext,
) ConflictResolution {
    switch (cmd) {
        .create_entity, .delete_entity => {
            // 结构冲突，不允许合并
            return .reject;
        },
        .add_component, .remove_component => {
            // 组件冲突通常是安全的
            return .merge;
        },
        .set_local_transform, .set_world_transform => {
            if (current_entity.physics_controlled) {
                // 物理控制实体，变换命令排队
                return .queue;
            }
            return .merge;
        },
    }
}
```

### 15.7 命令批次原子性

```zig
pub const BatchCommand = struct {
    id: []const u8,
    commands: []Command,
    atomic: bool = true,
};

pub fn executeBatch(
    queue: *CommandQueue,
    batch: BatchCommand,
) !BatchResult {
    var executed: std.ArrayList(Command) = .empty;
    defer executed.deinit();

    for (batch.commands) |cmd| {
        executeWithVersionCheck(queue, cmd, .{
            .source = .ai_agent,
            .allow_stale_data = true,
            .force_override = false,
        }) catch |err| {
            if (err == error.TopologyVersionConflict or
                err == error.DataVersionConflict) {
                // 冲突处理
                const resolution = resolveConflict(cmd, queue.world.getEntity(cmd.entity_id).?, .ai_agent);
                switch (resolution) {
                    .reject, .override => return BatchResult{
                        .success = false,
                        .failed_at = executed.items.len,
                        .error = err,
                    },
                    .queue, .merge => {
                        // 继续执行
                        executed.append(cmd) catch {};
                        continue;
                    },
                }
            }
        };
        executed.append(cmd) catch {};
    }

    return .{ .success = true, .executed_count = executed.items.len };
}
```

### 15.8 物理引擎暂停机制

```zig
pub fn pausePhysicsForCommand(
    queue: *CommandQueue,
    cmd: Command,
) void {
    // 对于复杂的结构修改，可以暂停特定实体的物理
    const entity = queue.world.getEntity(cmd.entity_id) orelse return;

    if (entity.rigidbody) |rb| {
        // 通知物理系统：下一个 tick 不要更新此实体
        queue.world.physics.pauseEntity(cmd.entity_id, 1);
    }
}

pub const PauseRequest = struct {
    entity_id: EntityId,
    pause_duration_ticks: u32,
};
```

### 15.9 悲观锁 (用于长时间操作)

```zig
pub const LockManager = struct {
    locks: std.AutoHashMap(EntityId, EntityLock),
    allocator: std.mem.Allocator,

    pub fn acquireForAI(
        self: *LockManager,
        entity_id: EntityId,
        agent_id: []const u8,
        reason: []const u8,
    ) !void {
        const deadline = std.time.nanoTimestamp() + 30 * std.time.ns_per_s;  // 30 秒超时

        while (true) {
            if (self.locks.get(entity_id)) |existing| {
                if (std.mem.eql(u8, existing.locked_by, agent_id)) {
                    return;  // 已持有
                }
                // 被占用，等待
                std.Thread.sleep(std.time.ns_per_ms * 100);
                if (std.time.nanoTimestamp() > deadline) {
                    return error.LockTimeout;
                }
                continue;
            }

            try self.locks.put(entity_id, .{
                .entity_id = entity_id,
                .locked_by = agent_id,
                .reason = reason,
                .locked_at = std.time.nanoTimestamp(),
            });
            return;
        }
    }
};
```
        };
        executed.appendAssumeCapacity(cmd);
    }

    return .{ .success = true, .executed_count = executed.items.len };
}
```

---

## 十六、调试支持

### 16.1 日志 API

```zig
// WASM 脚本中可用的日志函数
extern "env" fn api_log(message: [*:0]const u8) void;
extern "env" fn api_log_level(level: u32, message: [*:0]const u8) void;
extern "env" fn api_log_entity(entity_id: u32, message: [*:0]const u8) void;
extern "env" fn api_log_vec3(x: f32, y: f32, z: f32) void;

// 日志级别
const LOG_DEBUG: u32 = 0;
const LOG_INFO: u32 = 1;
const LOG_WARN: u32 = 2;
const LOG_ERROR: u32 = 3;
```

#### 使用示例

```zig
// 在 WASM 脚本中
export fn on_update(entity_id: u32, dt: f32) void {
    api_log("Update called");
    
    api_log_level(LOG_DEBUG, "Debug info");
    api_log_level(LOG_INFO, "Entity moving");
    api_log_level(LOG_WARN, "Approaching boundary");
    api_log_level(LOG_ERROR, "Critical failure");
    
    api_log_entity(entity_id, "State changed");
}
```

### 16.2 日志聚合端点

```bash
# 获取脚本日志
curl http://localhost:8080/api/script/logs/42

# 响应
{
  "entity_id": 42,
  "logs": [
    {"level": 1, "message": "Update called", "timestamp": 1699999999},
    {"level": 1, "message": "Entity moving", "timestamp": 1699999999},
    {"level": 2, "message": "Approaching boundary", "timestamp": 1700000000}
  ],
  "total_count": 156,
  "offset": 0,
  "limit": 100
}

# 实时日志流 (Server-Sent Events)
curl -N http://localhost:8080/api/script/logs/stream/42
```

### 16.3 性能分析

```bash
# 获取脚本执行统计
curl http://localhost:8080/api/script/stats/42

# 响应
{
  "entity_id": 42,
  "compilations": {
    "count": 5,
    "last_at": 1699999999,
    "last_duration_ms": 142
  },
  "executions": {
    "total": 1500,
    "avg_duration_us": 45,
    "p95_duration_us": 120,
    "p99_duration_us": 200,
    "max_duration_us": 500
  },
  "api_calls": {
    "api_set_position": 750,
    "api_get_delta_time": 1500,
    "api_log": 45
  },
  "errors": {
    "count": 2,
    "last_at": 1699999900,
    "last_error": "Division by zero at line 42"
  }
}
```

### 16.4 断点支持 (未来扩展)

```zig
// 断点 API (未来版本)
extern "env" fn api_set_breakpoint(line: u32) void;
extern "env" fn api_clear_breakpoint(line: u32) void;
extern "env" fn api_step() void;
extern "env" fn api_continue() void;
extern "env" fn api_get_local_vars(out_ptr: [*]u8, max_size: u32) u32;

// 调试检查点
extern "env" fn api_checkpoint(name: [*:0]const u8) void;

// 在脚本中使用
export fn on_update(entity_id: u32, dt: f32) void {
    api_set_breakpoint(10);  // 在第10行设置断点
    
    const x = computeSomething();  // 行10
    api_checkpoint("after_compute");  // 检查点
    
    api_set_position(entity_id, x, 0, 0);
}
```

### 16.5 错误回溯

```bash
# 获取详细的错误回溯
curl http://localhost:8080/api/script/trace/42

# 响应
{
  "error": "Runtime panic",
  "message": "Array index out of bounds",
  "timestamp": 1699999999,
  "call_stack": [
    {"function": "on_update", "file": "monster.zig", "line": 42},
    {"function": "move_towards", "file": "monster.zig", "line": 38},
    {"function": "patrol", "file": "monster.zig", "line": 20},
    {"function": "on_init", "file": "monster.zig", "line": 5}
  ],
  "local_vars": [
    {"name": "index", "value": "42"},
    {"name": "array_len", "value": "10"},
    {"name": "entity_id", "value": "42"}
  ]
}
```

---

## 十七、版本兼容性

### 17.1 JSON Schema 版本

所有 JSON 配置文件包含 `version` 字段：

```json
{
  "version": "1.0",
  "entities": [...]
}
```

### 17.2 版本历史

| 版本 | 说明 | 兼容策略 |
|------|------|----------|
| 1.0 | 初始版本 | - |
| 1.1 | 添加 tags 字段 | 向后兼容 |
| 2.0 | 重大重构组件格式 | 需要迁移工具 |

### 17.3 自动迁移

```zig
pub const SceneMigrator = struct {
    allocator: std.mem.Allocator,

    pub fn migrate(self: *SceneMigrator, json: []const u8) ![]u8 {
        const parsed = try std.json.parseFromSlice(
            SceneDocument,
            self.allocator,
            json,
            .{},
        );
        defer parsed.deinit();

        var doc = parsed.value;

        // 按顺序应用迁移
        while (doc.version < target_version) {
            doc = try self.applyMigration(doc);
        }

        return try std.json.stringifyAlloc(
            self.allocator,
            doc,
            .{},
        );
    }

    fn applyMigration(self: *SceneMigrator, doc: SceneDocument) !SceneDocument {
        return switch (doc.version) {
            1.0 => self.migrate1_0to1_1(doc),
            1.1 => self.migrate1_1to2_0(doc),
            else => doc,
        };
    }

    fn migrate1_0to1_1(self: *SceneMigrator, doc: SceneDocument) !SceneDocument {
        // 添加 tags 字段（可选）
        var new_doc = doc;
        new_doc.version = 1.1;
        
        for (new_doc.entities.items) |*entity| {
            if (entity.tags == null) {
                entity.tags = &.{};
            }
        }
        
        return new_doc;
    }
};
```

### 17.4 迁移工具

```bash
# 迁移场景文件
./guava migrate --input scene_v1.scene --output scene_v2.scene --to-version 2.0

# 检查版本
./guava validate scene.scene

# 批量迁移
./guava migrate-batch --glob "assets/scenes/*.scene" --to-version 2.0
```

---

## 十八、资源配额

### 18.1 WASM 沙箱配置

```zig
pub const WasmConfig = struct {
    // 内存配置
    stack_size_kb: u32 = 64,           // WASM 栈大小，用户可自行调整
    heap_size_kb: u32 = 256,          // WASM 堆大小，用户可自行调整
    max_memory_kb: u32 = 512,         // 总内存限制，用户可自行调整
    
    // 执行配置
    max_instructions_per_frame: u64 = 1_000_000,  // 每帧最大指令数，用户可自行调整
    execution_timeout_ms: u32 = 1000,  // 单次执行超时，用户可自行调整
    max_call_depth: u32 = 64,         // 最大调用深度，用户可自行调整
    
    // 编译配置
    max_compilation_time_ms: u32 = 30_000,  // 最大编译时间
    enable_optimizations: bool = true,  // 启用优化
    
    // 沙箱限制
    allow_floating_point: bool = true, // 允许浮点运算
    allow_simd: bool = false,         // 禁止 SIMD，用户可选择在设置中开启
    
    pub const default_config = WasmConfig{
        .stack_size_kb = 64,
        .heap_size_kb = 256,
        .max_memory_kb = 512,
        .max_instructions_per_frame = 1_000_000,
        .execution_timeout_ms = 1000,
        .max_call_depth = 64,
        .max_compilation_time_ms = 30_000,
        .enable_optimizations = true,
        .allow_floating_point = true,
        .allow_simd = false,
    };
};
```

### 18.2 RPC 服务配置

```zig
pub const RpcConfig = struct {
    // 网络配置
    port: u16 = 8080,
    bind_address: []const u8 = "127.0.0.1",  // 仅本地
    
    // 超时配置
    connection_timeout_ms: u32 = 5000,
    read_timeout_ms: u32 = 5000,
    write_timeout_ms: u32 = 5000,
    
    // 限流配置
    max_requests_per_second: u32 = 1000,
    max_concurrent_connections: u32 = 50,
    burst_size: u32 = 100,
    
    // 请求限制
    max_request_body_size: usize = 1024 * 1024,  // 1MB，用户可自行调整
    max_response_body_size: usize = 10 * 1024 * 1024,  // 10MB，用户可自行调整
    
    pub const default_config = RpcConfig{
        .port = 8080,
        .bind_address = "127.0.0.1",
        .connection_timeout_ms = 5000,
        .read_timeout_ms = 5000,
        .write_timeout_ms = 5000,
        .max_requests_per_second = 1000,
        .max_concurrent_connections = 50,
        .burst_size = 100,
        .max_request_body_size = 1024 * 1024,
        .max_response_body_size = 10 * 1024 * 1024,
    };
};
```

### 18.3 命令队列配置

```zig
pub const CommandQueueConfig = struct {
    max_pending: usize = 1000,        // 最大待执行命令数，用户可自行调整
    max_history: usize = 10_000,      // 历史记录数，用户可自行调整
    max_batch_size: usize = 100,     // 单批次最大命令数，用户可自行调整
    
    // 执行配置
    max_execution_time_ms: u32 = 50,  // 单命令最大执行时间
    enable_parallel_execution: bool = false,  // 是否并行执行，用户可自行调整
    
    // 内存配置
    max_command_size_bytes: usize = 64 * 1024,  // 单命令最大大小，用户可自行调整
    
    pub const default_config = CommandQueueConfig{
        .max_pending = 1000,
        .max_history = 10_000,
        .max_batch_size = 100,
        .max_execution_time_ms = 50,
        .enable_parallel_execution = false,
        .max_command_size_bytes = 64 * 1024,
    };
};
```

### 18.4 配置文件格式

```json
// config/ai_native.json
{
  "version": "1.0",
  "wasm": {
    "stack_size_kb": 64,
    "heap_size_kb": 256,
    "max_instructions_per_frame": 1000000,
    "execution_timeout_ms": 1000
  },
  "rpc": {
    "port": 8080,
    "bind_address": "127.0.0.1",
    "max_requests_per_second": 1000
  },
  "command_queue": {
    "max_pending": 1000,
    "max_batch_size": 100
  }
}
```

---

## 十九、测试策略

### 19.1 测试分层

```
┌─────────────────────────────────────────────────┐
│            集成测试 (Integration Tests)           │
│  端到端测试整个 AI → RPC → Engine → WASM 流程    │
└─────────────────────────────────────────────────┘
                       │
┌─────────────────────────────────────────────────┐
│              组件测试 (Component Tests)           │
│  测试 CommandQueue、QueryEngine、WasmVM 等组件    │
└─────────────────────────────────────────────────┘
                       │
┌─────────────────────────────────────────────────┐
│              单元测试 (Unit Tests)               │
│  测试 Command 序列化、JSON 解析、版本迁移等        │
└─────────────────────────────────────────────────┘
```

### 19.2 单元测试模板

```zig
// src/engine/core/command_test.zig
const std = @import("std");
const testing = std.testing;
const command = @import("command.zig");

test "Command serialization roundtrip" {
    const original = Command{
        .set_transform = .{
            .entity_id = 42,
            .transform = .{
                .translation = .{ 1.0, 2.0, 3.0 },
                .rotation = .{ 0, 0, 0, 1 },
                .scale = .{ 1, 1, 1 },
            },
        },
    };

    const json = try commandToJson(original, testing.allocator);
    defer testing.allocator.free(json);

    const parsed = try jsonToCommand(json, testing.allocator);
    defer parsed.deinit(testing.allocator);

    try testing.expect(std.meta.eql(original, parsed));
}

test "Invalid command returns error" {
    const invalid_json = "{\"cmd\":\"nonexistent\"}";
    try testing.expectError(
        error.InvalidCommand,
        jsonToCommand(invalid_json, testing.allocator),
    );
}
```

### 19.3 组件测试模板

```zig
// src/engine/script/wasm_vm_test.zig
const std = @import("std");
const testing = std.testing;
const wasm_vm = @import("wasm_vm.zig");

test "WasmVM loads and executes script" {
    const allocator = testing.allocator;
    var vm = try wasm_vm.WasmVM.init(allocator);
    defer vm.deinit();

    // 编译简单脚本
    const source = 
        \\export fn on_update(entity_id: u32, dt: f32) void {
        \\    // 简单逻辑
        \\}
    ;
    
    const wasm = try wasm_compiler.compileString(allocator, source);
    defer allocator.free(wasm);

    // 加载脚本
    try vm.loadScript(1, wasm);

    // 执行
    try vm.callExport(1, "on_update", &.{});
}

test "WasmVM isolates crashes" {
    const allocator = testing.allocator;
    var vm = try wasm_vm.WasmVM.init(allocator);
    defer vm.deinit();

    // 加载会导致崩溃的脚本
    const crash_source = 
        \\export fn on_update(entity_id: u32, dt: f32) void {
        \\    @panic("intentional crash");
        \\}
    ;
    
    const wasm = try wasm_compiler.compileString(allocator, crash_source);
    defer allocator.free(wasm);

    try vm.loadScript(1, wasm);

    // 崩溃不应该影响引擎
    try testing.expectError(
        error.ExecutionFailed,
        vm.callExport(1, "on_update", &.{}),
    );

    // VM 应该仍然可用
    try testing.expect(vm.modules.size() == 1);
}
```

### 19.4 集成测试模板

```zig
// src/test/ai_integration_test.zig
const std = @import("std");
const testing = std.testing;
const rpc = @import("engine/rpc/mod.zig");
const command = @import("engine/core/command.zig");

test "Full AI workflow: create entity and add script" {
    const allocator = testing.allocator;
    
    // 启动 RPC 服务器
    var server = try rpc.startRpcServer(allocator, 0);  // 随机端口
    defer server.stop();

    const base_url = try std.fmt.allocPrint(
        allocator,
        "http://localhost:{}",
        .{server.port},
    );
    defer allocator.free(base_url);

    // 1. 创建实体
    {
        const response = try sendRpcRequest(allocator, base_url, "POST", "/api/command", .{
            .cmd = "create_entity",
            .name = "TestEntity",
        });
        defer allocator.free(response);

        const result = try std.json.parseFromSlice(
            RpcResponse,
            allocator,
            response,
            .{},
        );
        defer result.deinit();

        try testing.expect(result.value.success == true);
    }

    // 2. 添加脚本
    {
        const response = try sendRpcRequest(allocator, base_url, "POST", "/api/script/compile", .{
            .entity_id = 1,
            .source = "export fn on_update(eid: u32, dt: f32) void {}",
        });
        defer allocator.free(response);

        const result = try std.json.parseFromSlice(
            RpcResponse,
            allocator,
            response,
            .{},
        );
        defer result.deinit();

        try testing.expect(result.value.success == true);
    }

    // 3. 验证实体有脚本
    {
        const response = try sendRpcRequest(allocator, base_url, "GET", "/api/scene/entity/1", null);
        defer allocator.free(response);

        const entity = try std.json.parseFromSlice(
            EntityData,
            allocator,
            response,
            .{},
        );
        defer entity.deinit();

        try testing.expect(entity.value.components.script != null);
    }
}
```

### 19.5 CI/CD 配置

```yaml
# .github/workflows/ai-native-tests.yml
name: AI Native Tests

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install Zig
        uses: correction/zig-action@v1
        with:
          version: 0.15.0
      
      - name: Unit Tests
        run: zig build test --test-filter "unit"
      
      - name: Component Tests  
        run: zig build test --test-filter "component"
      
      - name: Integration Tests
        run: zig build test --test-filter "integration"
        
      - name: Performance Benchmarks
        run: zig build benchmark --release=safe
        continue-on-error: true  # 性能基准不阻塞 PR

  wasm-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install Zig
        uses: correction/zig-action@v1
        with:
          version: 0.15.0
      
      - name: WASM Compilation Tests
        run: zig build test --test-filter "wasm_compile"
      
      - name: WASM Execution Tests
        run: zig build test --test-filter "wasm_exec"
      
      - name: Hot Reload Tests
        run: zig build test --test-filter "hot_reload"

  rpc-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install Zig
        uses: correction/zig-action@v1
        with:
          version: 0.15.0
      
      - name: RPC Tests
        run: zig build test --test-filter "rpc"
      
      - name: Concurrency Tests
        run: zig build test --test-filter "concurrency"
      
      - name: Load Tests
        run: zig build test --test-filter "load"
```

### 19.6 性能回归检测

```bash
#!/bin/bash
# scripts/performance_check.sh

set -e

echo "=== Performance Regression Check ==="

# 运行性能基准测试
zig build benchmark --release=safe --output=benchmark_results.json

# 比较结果
python3 scripts/compare_performance.py \
  --baseline benchmarks/baseline.json \
  --current benchmark_results.json \
  --threshold 0.1  # 10% 阈值

if [ $? -ne 0 ]; then
  echo "WARNING: Performance regression detected!"
  echo "Please review the changes before merging."
  exit 1
fi

echo "Performance check passed!"
```

---

## 二十、运行与验证

### 20.1 快速启动

```bash
# 1. 克隆并构建
git clone https://github.com/your-repo/guava-engine.git
cd guava-engine
zig build

# 2. 启动编辑器模式（自动开启 RPC）
./zig-out/bin/guava editor --rpc --port 8080

# 3. 使用 curl 测试基本功能
curl http://localhost:8080/health
# 应返回: {"status":"ok","version":"1.0"}
```

### 20.2 验证清单

#### Phase 1: Command 架构 ✅

- [ ] RPC 服务启动成功
- [ ] `/api/command` 能创建实体
- [ ] Inspector 修改产生相同效果
- [ ] Undo/Redo 正常

#### Phase 2: WASM 运行时 ✅

- [ ] WASM 编译成功 (<500ms)
- [ ] 脚本运行时崩溃被隔离
- [ ] 热重载生效
- [ ] 日志能正常输出

#### Phase 3: RPC 通信 ✅

- [ ] 所有 API 端点可用
- [ ] 并发请求不崩溃
- [ ] 错误返回正确格式

#### Phase 4: 序列化 ✅

- [ ] `.scene` 文件是纯 JSON
- [ ] AI 能读取和理解场景
- [ ] 保存/加载数据一致

#### Phase 5: 语义查询 ✅

- [ ] 标签查询正常
- [ ] 空间查询正确
- [ ] 组合查询交集正确

### 20.3 常见问题排查

| 问题 | 可能原因 | 解决方案 |
|------|----------|----------|
| RPC 连接失败 | 端口被占用 | 检查 `lsof -i :8080` |
| WASM 编译失败 | Zig 语法错误 | 查看 `/api/script/compile` 响应 |
| 命令不生效 | 队列满 | 等待或增加 `max_pending` |
| 版本冲突 | 多 Agent 同时修改 | 使用乐观锁重试 |
| 脚本不执行 | 缺少 `on_update` | 实现必需的导出函数 |

---

## 二十一、总结

### 21.1 架构优势

| 特性 | 传统引擎 | Guava AI-Native |
|------|----------|-----------------|
| AI 可见性 | 黑盒 | **全量文本化** |
| AI 操作入口 | 无 | **API 驱动** |
| 逻辑热重载 | 秒级 | **毫秒级 WASM** |
| 安全隔离 | 无 | **沙箱执行** |
| 并发控制 | 无 | **版本控制** |
| 调试支持 | 外部工具 | **内置日志/追踪** |

### 21.2 下一步行动

1. **立即开始**: Phase 1 Command 架构
2. **并行进行**: Phase 2 WASM 接入
3. **后续阶段**: 按依赖顺序实现

### 21.3 长期愿景

最终，Guava Engine 将成为：
- **AI-First**: 引擎核心设计从第一天就考虑 AI
- **Vibe Coding Native**: AI 生成 → 毫秒反馈 → 持续迭代
- **安全沙箱**: AI 生成的代码安全隔离
- **人类与 AI 对等**: 双方使用相同的 API 和工具

---

*文档版本: 1.0*
*最后更新: 2026-03-20*
*维护者: Guava Engine Team*
