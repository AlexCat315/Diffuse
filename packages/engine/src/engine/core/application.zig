//! 应用程序核心模块
//!
//! 本模块提供应用程序的生命周期管理和主循环实现。
//! Application 是 Guava Engine 应用的主入口点，负责协调所有子系统。
//!
//! ## 主要功能
//!
//! - **生命周期管理** - 初始化、运行、清理
//! - **窗口管理** - 创建和管理主窗口
//! - **渲染器集成** - 初始化和管理渲染系统
//! - **场景管理** - 创建和管理场景世界
//! - **层栈系统** - 管理应用逻辑层
//! - **输入处理** - 处理键盘、鼠标输入
//! - **物理模拟** - 固定时间步进物理
//! - **脚本系统** - 脚本热重载和执行
//! - **动画系统** - 骨骼动画更新
//!
//! ## 使用示例
//!
//! ```zig
//! const guava = @import("guava");
//!
//! pub fn main() !void {
//!     // 创建应用配置
//!     const config = guava.core.ApplicationConfig{
//!         .name = "My Game",
//!         .window_width = 1920,
//!         .window_height = 1080,
//!     };
//!
//!     // 初始化应用
//!     var app = try guava.core.Application.init(allocator, config);
//!     defer app.deinit();
//!
//!     // 推送应用层
//!     try app.pushLayer(my_layer);
//!
//!     // 运行应用（0 表示无限循环）
//!     const report = try app.run(0);
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const animator_system = @import("../animation/animator_system.zig");

// macOS Mach kernel APIs for high-precision timing and thread priority.
const mach = if (builtin.os.tag == .macos) struct {
    const MachTimebaseInfo = extern struct { numer: u32, denom: u32 };
    extern "c" fn mach_absolute_time() u64;
    extern "c" fn mach_wait_until(deadline: u64) c_int;
    extern "c" fn mach_timebase_info(info: *MachTimebaseInfo) c_int;
    extern "c" fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) c_int;

    const QOS_CLASS_USER_INTERACTIVE: c_uint = 0x21;

    var timebase: MachTimebaseInfo = .{ .numer = 0, .denom = 0 };

    fn ensureTimebase() void {
        if (timebase.numer == 0) {
            _ = mach_timebase_info(&timebase);
        }
    }

    /// Convert nanoseconds to Mach absolute time units.
    fn nsToAbsolute(ns: u64) u64 {
        ensureTimebase();
        return ns * timebase.denom / timebase.numer;
    }
} else struct {};
const physics_system = @import("../physics/system.zig");
const nav_system_mod = @import("../navigation/nav_system.zig");
const debug_session_mod = @import("../script/debug_session.zig");
const editor_utility_runtime_mod = @import("../script/editor_utility_runtime.zig");
const script_system = @import("../script/script.zig");
const handles = @import("../assets/handles.zig");
const layer_mod = @import("layer.zig");
const layer_stack_mod = @import("layer_stack.zig");
const input_mod = @import("input.zig");
const input_action_mod = @import("input_action.zig");
const command_queue_mod = @import("command_queue.zig");
const scene_manager_mod = @import("scene_manager.zig");
const platform_mod = @import("platform.zig");
const renderer_mod = @import("../render/renderer.zig");
const render_types = @import("../render/types.zig");
const window_mod = @import("../platform/window.zig");
const scene_mod = @import("../scene/scene.zig");
const job_system_mod = @import("job_system.zig");
const audio_mod = @import("../audio/mod.zig");

/// 应用程序配置
///
/// 用于初始化应用程序时指定各种参数。
pub const ApplicationConfig = struct {
    /// 应用程序名称（显示在窗口标题栏）
    name: []const u8 = "Guava Engine",
    /// 窗口宽度（像素）
    window_width: u32 = 1280,
    /// 窗口高度（像素）
    window_height: u32 = 720,
    /// 是否无边框窗口
    window_borderless: bool = false,
    /// 是否启动时最大化窗口
    window_maximized: bool = true,
    /// 是否使用原生标题栏控件（macOS）
    window_native_titlebar_controls: bool = false,
    /// 是否隐藏窗口（editor-server 模式下使用）
    window_hidden: bool = false,
    /// 在 macOS 上隐藏进程的 Dock 图标和 Cmd-Tab 条目（editor-server 模式下使用）
    window_background_app: bool = false,
    /// 帧延迟（毫秒，用于限制帧率）
    frame_delay_ms: u32 = 16,
    /// 首选的图形后端列表
    preferred_backends: []const render_types.GraphicsAPI = render_types.defaultPreferredBackends,
    /// 后端选择策略
    backend_selection_policy: render_types.BackendSelectionPolicy = .explicit_order,
    /// 是否启用验证层（调试用）
    enable_validation: bool = true,
    /// 帧在飞数量（用于帧同步）
    frames_in_flight: u32 = 2,
    /// 线程数量（null 表示自动检测）
    thread_count: ?usize = null,
    /// 物理系统配置
    physics: physics_system.Config = .{},
    /// 脚本系统配置
    script: script_system.ScriptSystemConfig = .{},
};

/// 运行报告
///
/// 包含应用程序运行结束后的统计信息。
pub const RunReport = struct {
    /// 渲染的帧数
    frames: usize,
    /// 使用的图形后端
    backend: render_types.GraphicsAPI,
    /// 场景摘要
    scene: scene_mod.Summary,
    /// 渲染通道数量
    passes: usize,
    /// 运行时信息
    runtime: render_types.RuntimeInfo,
    /// 绘制调用次数
    draw_calls: usize,
    /// 绘制的三角形数量
    triangles_drawn: usize,
};

/// 应用程序主类
///
/// 管理引擎的所有子系统，提供主循环实现。
/// 这是构建 Guava Engine 应用的核心类。
///
/// ## 生命周期
///
/// 1. `init()` - 初始化所有子系统
/// 2. `pushLayer()` / `pushOverlay()` - 添加应用逻辑层
/// 3. `run()` - 运行主循环
/// 4. `deinit()` - 清理所有资源
///
/// ## 子系统
///
/// - **Window** - 窗口管理
/// - **Renderer** - 渲染系统
/// - **World** - 场景世界
/// - **JobSystem** - 作业系统
/// - **ScriptRuntime** - 脚本运行时
/// - **InputState** - 输入状态
/// - **LayerStack** - 层栈
pub const Application = struct {
    /// 内存分配器
    allocator: std.mem.Allocator,
    /// 应用程序配置
    config: ApplicationConfig,
    /// 平台信息
    platform: platform_mod.Platform,
    /// 主窗口
    window: window_mod.Window,
    /// 渲染器
    renderer: renderer_mod.Renderer,
    /// 引擎级命令队列
    command_queue: command_queue_mod.CommandQueue,
    /// 多场景管理器
    scene_manager: scene_manager_mod.SceneManager,
    /// 场景世界
    world: scene_mod.World,
    /// 层栈
    layers: layer_stack_mod.LayerStack,
    /// 作业系统
    job_system: *job_system_mod.JobSystem,
    /// 脚本运行时
    script_runtime: script_system.ScriptRuntime,
    /// 编辑器 Utility 运行时
    editor_utility_runtime: editor_utility_runtime_mod.EditorUtilityRuntime,
    /// 输入状态
    input: input_mod.InputState = .{},
    /// 播放控制器（用于暂停/步进）
    playback_controller: layer_mod.PlaybackController = .{},
    /// 是否已初始化
    initialized: bool = false,
    /// 高精度计时器
    timer: std.time.Timer,
    /// 全局时间（秒）
    global_time: f32 = 0.0,
    /// 时间缩放（用于慢动作、暂停等）
    time_scale: f32 = 1.0,
    /// 游戏运行时状态机
    game_state: layer_mod.GameState = .game_start,
    /// 播放模式快照（用于 Play/Stop 回滚）
    play_mode_snapshot: ?PlayModeSnapshot = null,
    /// 输入动作映射（GR-6）
    action_map: input_action_mod.ActionMap,
    /// 物理时间累积器
    physics_accumulator_seconds: f32 = 0.0,
    /// 物理状态实例（替代全局变量）
    physics_state: physics_system.PhysicsState,
    /// 导航系统状态
    nav_system: nav_system_mod.NavSystem,
    /// 脚本调试会话
    debug_session: debug_session_mod.DebugSession,
    /// 待处理的文件拖放路径（由 OS 文件拖放事件设置，由编辑器层消费）
    pending_file_drop: ?[:0]const u8 = null,
    /// 项目根目录（编辑器模式下由 main.zig 设置）
    project_root: ?[]const u8 = null,

    /// 初始化应用程序
    ///
    /// 创建窗口、渲染器、场景世界等所有子系统。
    ///
    /// ## 参数
    /// - `allocator` - 内存分配器
    /// - `config` - 应用程序配置
    ///
    /// ## 返回
    /// 初始化的 Application 实例
    ///
    /// ## 错误
    /// - `error.OutOfMemory` - 内存不足
    /// - `error.DeviceCreationFailed` - GPU 设备创建失败
    pub fn init(allocator: std.mem.Allocator, config: ApplicationConfig) !Application {
        const platform = platform_mod.detect();

        var window = try window_mod.Window.init(allocator, .{
            .title = config.name,
            .width = config.window_width,
            .height = config.window_height,
            .borderless = config.window_borderless,
            .maximized = config.window_maximized,
            .native_titlebar_controls = config.window_native_titlebar_controls,
            .hidden = config.window_hidden,
            .background_app = config.window_background_app,
        });
        errdefer window.deinit();

        const job_system = try job_system_mod.JobSystem.init(allocator, config.thread_count);
        errdefer job_system.deinit();

        var world = scene_mod.World.init(allocator, job_system);
        errdefer world.deinit();
        try world.bootstrap3D();

        const renderer = try renderer_mod.Renderer.init(allocator, platform, &window, .{
            .requested_backends = config.preferred_backends,
            .selection_policy = config.backend_selection_policy,
            .enable_validation = config.enable_validation,
            .frames_in_flight = config.frames_in_flight,
        });

        // 初始化脚本运行时
        var script_runtime = script_system.ScriptRuntime.init(allocator, config.script);
        try script_runtime.initVMs();

        // 初始化音频运行时（允许失败——无音频设备时引擎仍可运行）
        _ = audio_mod.AudioRuntime.init(allocator) catch |err| blk: {
            std.log.warn("audio: initialization failed ({s}); engine will run without audio", .{@errorName(err)});
            break :blk @as(?*audio_mod.AudioRuntime, null);
        };

        const timer = try std.time.Timer.start();

        return .{
            .allocator = allocator,
            .config = config,
            .platform = platform,
            .window = window,
            .renderer = renderer,
            .command_queue = command_queue_mod.CommandQueue.init(allocator),
            .scene_manager = scene_manager_mod.SceneManager.init(allocator),
            .world = world,
            .job_system = job_system,
            .script_runtime = script_runtime,
            .editor_utility_runtime = editor_utility_runtime_mod.EditorUtilityRuntime.init(allocator),
            .layers = layer_stack_mod.LayerStack.init(allocator),
            .input = .{},
            .timer = timer,
            .physics_state = physics_system.PhysicsState.init(allocator),
            .nav_system = nav_system_mod.NavSystem.init(allocator),
            .debug_session = debug_session_mod.DebugSession.init(allocator),
            .action_map = input_action_mod.ActionMap.init(allocator),
        };
    }

    /// 清理应用程序
    ///
    /// 释放所有子系统占用的资源。
    /// 调用此方法后，应用程序不再可用。
    ///
    /// ## 销毁顺序说明
    ///
    /// 资源销毁顺序至关重要，必须遵循以下依赖关系：
    /// 1. **Layer/Script 层** - 先销毁应用层和脚本，避免它们访问正在销毁的系统
    /// 2. **Physics 系统** - 物理世界必须在 World 资源之前销毁
    /// 3. **World (Resources)** - World 包含 ResourceLibrary，持有 GPU 纹理/网格等资源
    /// 4. **Renderer (Device)** - Renderer 拥有 RhiDevice，必须在 World 资源释放后销毁
    /// 5. **Window** - 窗口在 Renderer 之后销毁
    /// 6. **JobSystem** - 作业系统最后销毁
    ///
    /// 关键依赖：`Renderer.deinit()` 必须在 `World.deinit()` **之前**调用，因为：
    /// - World 的 ResourceLibrary 持有 GPU 纹理/网格资源
    /// - Renderer 的 RhiDevice 必须在这些资源释放前保持有效
    /// - 如果先销毁 World，ResourceLibrary 释放 GPU 资源时 RhiDevice 可能已被销毁
    pub fn deinit(self: *Application) void {
        self.bindRuntimeContext();
        self.script_runtime.callDestroyAll(&self.world);
        if (self.initialized) {
            self.detachLayers();
        }
        self.layers.deinit();
        if (self.play_mode_snapshot) |*snapshot| {
            snapshot.deinit(self.allocator);
            self.play_mode_snapshot = null;
        }
        self.scene_manager.deinit();
        self.editor_utility_runtime.deinit();
        self.script_runtime.deinit();
        self.action_map.deinit();
        if (audio_mod.get() catch null) |audio_runtime| {
            audio_runtime.deinit();
        }
        self.renderer.deinit();
        self.physics_state.deinitWorld(&self.world);
        self.physics_state.deinit();
        self.nav_system.deinit();
        self.debug_session.deinit();
        self.world.deinit();
        self.command_queue.deinit();
        self.window.deinit();
        self.job_system.deinit();
    }

    /// 推送层到层栈
    ///
    /// 层是应用逻辑的基本单位。层按顺序更新，
    /// 后推送的层在先推送的层之上。
    ///
    /// ## 参数
    /// - `layer` - 要推送的层
    pub fn pushLayer(self: *Application, layer: layer_mod.Layer) !void {
        try self.layers.pushLayer(layer);
        if (self.initialized) {
            var layer_context = self.makeLayerContext(0, 0.0);
            try layer.attach(&layer_context);
        }
    }

    /// 推送覆盖层到层栈
    ///
    /// 覆盖层总是在普通层之上渲染。
    /// 通常用于 UI 层。
    ///
    /// ## 参数
    /// - `overlay` - 要推送的覆盖层
    pub fn pushOverlay(self: *Application, overlay: layer_mod.Layer) !void {
        try self.layers.pushOverlay(overlay);
        if (self.initialized) {
            var layer_context = self.makeLayerContext(0, 0.0);
            try overlay.attach(&layer_context);
        }
    }

    /// 运行应用程序主循环
    ///
    /// 主循环持续运行直到窗口关闭或达到指定帧数。
    /// 每帧执行以下操作：
    /// 1. 处理输入事件
    /// 2. 更新动画系统
    /// 3. 步进物理模拟
    /// 4. 更新脚本系统
    /// 5. 更新层级变换
    /// 6. 更新所有层
    /// 7. 渲染帧
    ///
    /// ## 参数
    /// - `frame_count` - 要渲染的帧数（0 表示无限循环）
    ///
    /// ## 返回
    /// 运行报告，包含统计信息
    pub fn run(self: *Application, frame_count: usize) !RunReport {
        if (!self.initialized) {
            try self.attachLayers();
        }

        // Raise thread priority to reduce scheduling preemption during rendering.
        if (comptime builtin.os.tag == .macos) {
            _ = mach.pthread_set_qos_class_self_np(mach.QOS_CLASS_USER_INTERACTIVE, 0);
        }

        var frames_rendered: usize = 0;
        var last_frame = renderer_mod.FrameReport{
            .backend = self.renderer.backendApi(),
            .passes_executed = self.renderer.passCount(),
            .graph_resources = self.renderer.graph.resourceCount(),
            .scene = .{},
            .runtime = self.renderer.runtimeInfo(),
        };

        while ((frame_count == 0 or frames_rendered < frame_count) and !self.window.should_close) : (frames_rendered += 1) {
            self.input.beginFrame();
            try self.pumpEvents();

            // 每帧刷新输入动作映射状态（GR-6）
            self.action_map.update(&self.input);

            const elapsed_ns = self.timer.lap();
            var delta_seconds = @as(f32, @floatFromInt(elapsed_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s));
            delta_seconds = @min(delta_seconds, 0.1); // 最大帧间隔锁定为 0.1 秒
            self.renderer.device().recordFrame(@min(elapsed_ns, 100 * std.time.ns_per_ms));

            try self.scene_manager.pump(
                &self.world,
                &self.physics_state,
                &self.script_runtime,
                &self.command_queue,
                &self.renderer,
            );

            try self.applyPendingCommands();

            const should_advance_simulation = self.playback_controller.shouldAdvance();
            if (should_advance_simulation) {
                if (self.playback_controller.fixed_delta_seconds) |fixed_delta| {
                    delta_seconds = fixed_delta;
                }
            }

            // 更新全局时间
            self.global_time += delta_seconds * self.time_scale;

            // 同步 GameState 与 PlaybackController
            if (should_advance_simulation and self.game_state == .game_start) {
                self.game_state = .playing;
            }
            if (self.playback_controller.state == .stopped and self.game_state != .game_start) {
                self.game_state = .game_start;
            }

            self.syncPlayModeState();

            if (should_advance_simulation) {
                animator_system.update(&self.world, delta_seconds);
                self.advancePhysics(delta_seconds);
                // 更新导航系统（crowd agent 避障和位置同步）
                self.nav_system.update(&self.world, delta_seconds);
                // 更新脚本系统（传递时间和输入）
                self.updateScripts(delta_seconds);
                try self.applyPendingCommands();
            }

            // P1: Update hierarchy transforms and bounds once per frame
            self.world.updateHierarchy();

            if (should_advance_simulation) {
                if (audio_mod.get() catch null) |audio_runtime| {
                    audio_runtime.updateFromWorld(&self.world);
                }
            }

            var layer_context = self.makeLayerContext(frames_rendered, delta_seconds);
            for (self.layers.layers.items, 0..) |layer, index| {
                if (index < self.layers.overlay_start and !should_advance_simulation) {
                    continue;
                }
                layer.update(&layer_context) catch |err| {
                    std.log.err("layer '{s}' update failed: {s}", .{ layer.name, @errorName(err) });
                };
            }
            if (should_advance_simulation) {
                self.playback_controller.consumeAdvance();
            }

            last_frame = try self.renderer.drawFrame(&self.world, &self.physics_state);
            self.renderer.last_frame_report = last_frame;

            // Consume pending frame delay change from RPC.
            if (self.renderer.pending_frame_delay_ms) |new_delay| {
                self.config.frame_delay_ms = new_delay;
                self.renderer.pending_frame_delay_ms = null;
            }
            self.renderer.current_frame_delay_ms = self.config.frame_delay_ms;

            // Frame rate limiting.
            if (self.config.frame_delay_ms > 0) {
                const frame_ns = self.timer.read();
                const target_ns: u64 = @as(u64, self.config.frame_delay_ms) * std.time.ns_per_ms;
                if (frame_ns < target_ns) {
                    const remaining = target_ns - frame_ns;
                    if (comptime builtin.os.tag == .macos) {
                        // mach_wait_until: kernel-level precise timer, no busy-wait,
                        // no timer coalescing.  Sub-microsecond accuracy.
                        const deadline = mach.mach_absolute_time() + mach.nsToAbsolute(remaining);
                        _ = mach.mach_wait_until(deadline);
                    } else {
                        // Fallback: sleep + spin-wait for the final 0.2ms
                        const spin_margin: u64 = 200_000;
                        if (remaining > spin_margin) {
                            std.Thread.sleep(remaining - spin_margin);
                        }
                        while (self.timer.read() < target_ns) {
                            std.atomic.spinLoopHint();
                        }
                    }
                }
            }
        }

        const summary = self.world.summary();
        return .{
            .frames = frames_rendered,
            .backend = self.renderer.backendApi(),
            .scene = summary,
            .passes = self.renderer.passCount(),
            .runtime = last_frame.runtime,
            .draw_calls = last_frame.draw_calls,
            .triangles_drawn = last_frame.triangles_drawn,
        };
    }

    /// 附加所有层
    fn attachLayers(self: *Application) !void {
        // Auto-discover scripts in assets/scripts/ before initializing layers
        self.discoverScripts();

        var layer_context = self.makeLayerContext(0, 0.0);
        var attached_count: usize = 0;
        errdefer {
            // Detach any layers that were successfully attached (reverse order)
            while (attached_count > 0) {
                attached_count -= 1;
                self.layers.layers.items[attached_count].detach();
            }
        }
        for (self.layers.layers.items) |layer| {
            try layer.attach(&layer_context);
            attached_count += 1;
        }
        self.initialized = true;
    }

    /// 分离所有层
    fn detachLayers(self: *Application) void {
        var index = self.layers.layers.items.len;
        while (index > 0) {
            index -= 1;
            self.layers.layers.items[index].detach();
        }
        self.initialized = false;
    }

    /// 处理窗口事件
    fn pumpEvents(self: *Application) !void {
        while (try self.window.pollEvent()) |event| {
            switch (event.kind) {
                .resized, .pixel_size_changed, .metal_view_resized, .exposed => {
                    try self.renderer.handleResize(event.width, event.height);
                },
                .quit_requested, .close_requested => {
                    self.window.should_close = true;
                },
                .mouse_button_down => {
                    self.input.setModifiers(event.modifiers);
                    self.input.updateMousePosition(event.x, event.y);
                    if (event.button) |button| {
                        self.input.setMouseButton(button, true, event.clicks);
                    }
                },
                .mouse_button_up => {
                    self.input.setModifiers(event.modifiers);
                    self.input.updateMousePosition(event.x, event.y);
                    if (event.button) |button| {
                        self.input.setMouseButton(button, false, event.clicks);
                    }
                },
                .mouse_moved => {
                    self.input.setModifiers(event.modifiers);
                    self.input.addMouseDelta(event.x, event.y, event.delta_x, event.delta_y);
                },
                .mouse_wheel => {
                    self.input.setModifiers(event.modifiers);
                    self.input.updateMousePosition(event.x, event.y);
                    self.input.addMouseWheel(event.delta_x, event.delta_y);
                },
                .key_down => {
                    self.input.setModifiers(event.modifiers);
                    if (event.key) |key| {
                        self.input.setKey(key, true);
                    }
                },
                .key_up => {
                    self.input.setModifiers(event.modifiers);
                    if (event.key) |key| {
                        self.input.setKey(key, false);
                    }
                },
                .text_input => {},
                .gamepad_added => {
                    self.input.gamepad_connected = true;
                },
                .gamepad_removed => {
                    self.input.gamepad_connected = false;
                },
                .gamepad_button_down => {
                    if (event.gamepad_button) |btn| {
                        self.input.setGamepadButton(btn, true);
                    }
                },
                .gamepad_button_up => {
                    if (event.gamepad_button) |btn| {
                        self.input.setGamepadButton(btn, false);
                    }
                },
                .gamepad_axis_motion => {
                    if (event.gamepad_axis) |axis| {
                        self.input.setGamepadAxis(axis, event.axis_value);
                    }
                },
                .file_drop => {
                    // Free previous pending drop if any
                    if (self.pending_file_drop) |prev| {
                        std.heap.c_allocator.free(prev);
                    }
                    self.pending_file_drop = event.dropped_file_path;
                },
            }
        }
    }

    /// 创建层上下文
    fn makeLayerContext(self: *Application, frame_index: usize, delta_seconds: f32) layer_mod.LayerContext {
        return .{
            .world = &self.world,
            .scene = &self.world,
            .renderer = &self.renderer,
            .scene_manager = &self.scene_manager,
            .command_queue = &self.command_queue,
            .script_runtime = &self.script_runtime,
            .editor_utility_runtime = &self.editor_utility_runtime,
            .input = &self.input,
            .action_map = &self.action_map,
            .window = &self.window,
            .playback_controller = &self.playback_controller,
            .game_state = &self.game_state,
            .global_time = &self.global_time,
            .time_scale = &self.time_scale,
            .physics_accumulator_seconds = &self.physics_accumulator_seconds,
            .physics_state = &self.physics_state,
            .nav_system = &self.nav_system,
            .script_debug_session = &self.debug_session,
            .pending_file_drop = &self.pending_file_drop,
            .frame_index = frame_index,
            .delta_seconds = delta_seconds,
        };
    }

    /// 步进物理模拟
    ///
    /// 使用固定时间步进，确保物理模拟的稳定性。
    /// 支持多次子步进以处理帧率波动。
    fn advancePhysics(self: *Application, delta_seconds: f32) void {
        if (!self.config.physics.enabled or self.config.physics.fixed_timestep_seconds <= 0.0001) {
            return;
        }

        const max_window = self.config.physics.fixed_timestep_seconds *
            @as(f32, @floatFromInt(self.config.physics.max_substeps_per_frame));
        self.physics_accumulator_seconds = @min(self.physics_accumulator_seconds + delta_seconds, max_window);

        var substeps: u8 = 0;
        while (self.physics_accumulator_seconds + 0.000001 >= self.config.physics.fixed_timestep_seconds and
            substeps < self.config.physics.max_substeps_per_frame) : (substeps += 1)
        {
            _ = self.physics_state.step(&self.world, self.config.physics.fixed_timestep_seconds, self.config.physics);
            self.physics_accumulator_seconds -= self.config.physics.fixed_timestep_seconds;
        }

        if (substeps == self.config.physics.max_substeps_per_frame and
            self.physics_accumulator_seconds >= self.config.physics.fixed_timestep_seconds)
        {
            self.physics_accumulator_seconds = 0.0;
        }
    }

    /// 更新脚本系统
    ///
    /// 检查热重载，调用所有脚本的 OnUpdate 方法。
    fn updateScripts(self: *Application, delta_seconds: f32) void {
        self.bindRuntimeContext();

        // 检查热重载
        self.script_runtime.checkHotReload();
        self.script_runtime.reconcileWorld(&self.world);

        // 遍历存活实例，避免脚本在更新时修改 world.entities 破坏迭代。
        var instance_iter = self.script_runtime.instances.valueIterator();
        while (instance_iter.next()) |instance_ptr| {
            const instance = instance_ptr.*;
            const entity = self.world.getEntityConst(instance.entity_id) orelse continue;
            const script = entity.script orelse continue;
            const script_language: script_system.ScriptLanguage = @enumFromInt(@intFromEnum(script.language));
            if (!script.enabled or
                script.instance_id != instance.id or
                script.script_handle == null or
                script.script_handle.? != instance.script_handle or
                script_language != instance.language)
            {
                continue;
            }

            if (self.script_runtime.getVM(instance.language)) |vm| {
                var ctx = script_system.ScriptContext{
                    .entity = entity.id,
                    .world = &self.world,
                    .instance = instance,
                    .allocator = self.allocator,
                    .command_queue = &self.command_queue,
                    .input = &self.input,
                    .physics_state = &self.physics_state,
                    .time = self.global_time,
                    .delta_time = delta_seconds * self.time_scale,
                    .time_scale = self.time_scale,
                    .game_state = @intFromEnum(self.game_state),
                    .time_scale_ptr = &self.time_scale,
                    .game_state_ptr = @ptrCast(&self.game_state),
                    .action_map = &self.action_map,
                    .scene_manager_api = .{
                        .context = self,
                        .load_scene = scriptLoadScene,
                        .unload_scene = scriptUnloadScene,
                        .set_dont_destroy_on_load = scriptSetDontDestroyOnLoad,
                        .is_loading = scriptIsSceneLoading,
                    },
                };

                vm.callUpdate(instance, &ctx, delta_seconds) catch |err| {
                    std.log.err("Script update error for entity {}: {}", .{ entity.id, err });
                    self.script_runtime.recordEvent(.{
                        .script_handle = instance.script_handle,
                        .entity_id = entity.id,
                        .phase = .update,
                        .severity = .@"error",
                        .message = vm.getError(),
                    });
                    instance.state = .failed;
                };
            }
        }

        // 派发物理触发器与碰撞事件到脚本 (GR-4)
        self.dispatchPhysicsEvents();
    }

    /// 将物理触发器/碰撞事件派发给相关脚本实例
    fn dispatchPhysicsEvents(self: *Application) void {
        const trigger_events = self.physics_state.pollTriggerEvents();
        for (trigger_events) |event| {
            // 向事件双方各自派发（A→B, B→A）
            self.dispatchTriggerToEntity(event.entity_a, event.entity_b, event.kind);
            self.dispatchTriggerToEntity(event.entity_b, event.entity_a, event.kind);
        }
        self.physics_state.clearTriggerEvents();

        const collision_events = self.physics_state.pollCollisionEvents();
        for (collision_events) |event| {
            self.dispatchCollisionToEntity(event.entity_a, event.entity_b, event.kind);
            self.dispatchCollisionToEntity(event.entity_b, event.entity_a, event.kind);
        }
        self.physics_state.clearCollisionEvents();
    }

    fn dispatchTriggerToEntity(
        self: *Application,
        self_id: scene_mod.EntityId,
        other_id: scene_mod.EntityId,
        kind: physics_system.TriggerEventKind,
    ) void {
        const entity = self.world.getEntityConst(self_id) orelse return;
        const script = entity.script orelse return;
        const instance_id = script.instance_id orelse return;
        const instance = self.script_runtime.instances.get(instance_id) orelse return;
        if (!script.enabled or instance.state != .running) return;

        const script_language: script_system.ScriptLanguage = @enumFromInt(@intFromEnum(script.language));
        const vm = self.script_runtime.getVM(script_language) orelse return;

        var ctx = script_system.ScriptContext{
            .entity = self_id,
            .world = &self.world,
            .instance = instance,
            .allocator = self.allocator,
            .input = &self.input,
            .physics_state = &self.physics_state,
            .time = self.global_time,
            .delta_time = 0.0,
            .time_scale = self.time_scale,
            .action_map = &self.action_map,
            .scene_manager_api = .{
                .context = self,
                .load_scene = scriptLoadScene,
                .unload_scene = scriptUnloadScene,
                .set_dont_destroy_on_load = scriptSetDontDestroyOnLoad,
                .is_loading = scriptIsSceneLoading,
            },
        };

        switch (kind) {
            .enter => vm.callTriggerEnter(instance, &ctx, other_id),
            .exit => vm.callTriggerExit(instance, &ctx, other_id),
            .stay => {}, // stay 事件不转发（可按需添加）
        }
    }

    fn dispatchCollisionToEntity(
        self: *Application,
        self_id: scene_mod.EntityId,
        other_id: scene_mod.EntityId,
        kind: physics_system.CollisionEventKind,
    ) void {
        const entity = self.world.getEntityConst(self_id) orelse return;
        const script = entity.script orelse return;
        const instance_id = script.instance_id orelse return;
        const instance = self.script_runtime.instances.get(instance_id) orelse return;
        if (!script.enabled or instance.state != .running) return;

        const script_language: script_system.ScriptLanguage = @enumFromInt(@intFromEnum(script.language));
        const vm = self.script_runtime.getVM(script_language) orelse return;

        var ctx = script_system.ScriptContext{
            .entity = self_id,
            .world = &self.world,
            .instance = instance,
            .allocator = self.allocator,
            .input = &self.input,
            .physics_state = &self.physics_state,
            .time = self.global_time,
            .delta_time = 0.0,
            .time_scale = self.time_scale,
            .action_map = &self.action_map,
            .scene_manager_api = .{
                .context = self,
                .load_scene = scriptLoadScene,
                .unload_scene = scriptUnloadScene,
                .set_dont_destroy_on_load = scriptSetDontDestroyOnLoad,
                .is_loading = scriptIsSceneLoading,
            },
        };

        switch (kind) {
            .enter => vm.callCollisionEnter(instance, &ctx, other_id),
            .exit => vm.callCollisionExit(instance, &ctx, other_id),
        }
    }

    /// 加载脚本资源
    ///
    /// 从文件加载脚本并注册到资源系统。
    /// 支持热重载。
    ///
    /// ## 参数
    /// - `path` - 脚本文件路径
    ///
    /// ## 返回
    /// 脚本资源句柄
    pub fn loadScript(self: *Application, path: []const u8) !handles.ScriptHandle {
        self.bindRuntimeContext();
        const language = inferScriptLanguageFromPath(path);
        const is_binary_artifact = script_system.csharp_toolchain_mod.isSharedLibraryPath(path);

        // Read script source relative to project root (or CWD as fallback).
        var owned_base: ?std.fs.Dir = if (self.project_root) |root|
            (std.fs.openDirAbsolute(root, .{}) catch null)
        else
            null;
        defer if (owned_base) |*d| d.close();
        const base_dir: std.fs.Dir = owned_base orelse std.fs.cwd();

        const source_or_bytecode = if (is_binary_artifact)
            try base_dir.readFileAlloc(self.allocator, path, 16 * 1024 * 1024)
        else
            try base_dir.readFileAlloc(self.allocator, path, 1024 * 1024);
        defer self.allocator.free(source_or_bytecode);

        const script_resource = @import("../assets/script_resource.zig");
        const desc: script_resource.ScriptResourceDesc = .{
            .source = if (is_binary_artifact) @as([]const u8, "") else source_or_bytecode,
            .language = language,
            .entry_fn = "main",
            .description = path,
            .source_path = path,
            .artifact_path = if (script_system.csharp_toolchain_mod.isSharedLibraryPath(path)) path else @as([]const u8, ""),
        };

        const handle = try self.world.resources.createScript(desc);

        // Bind asset record so the script can be looked up by path in the editor
        const asset_registry = @import("../assets/registry.zig");
        const record: asset_registry.AssetRecord = .{
            .id = try self.allocator.dupe(u8, path),
            .type = .script,
            .source_path = try self.allocator.dupe(u8, path),
            .source_hash = try asset_registry.hashStringAlloc(self.allocator, path),
            .import_settings_hash = try asset_registry.defaultImportSettingsHashAlloc(self.allocator, .script),
            .import_version = @as(asset_registry.AssetType, .script).importVersion(),
            .dependency_ids = try self.allocator.alloc([]u8, 0),
            .outputs = try self.allocator.alloc(asset_registry.AssetOutput, 0),
            .metadata = .{
                .display_name = try self.allocator.dupe(u8, std.fs.path.basename(path)),
                .importer = try self.allocator.dupe(u8, @as(asset_registry.AssetType, .script).importerName()),
                .source_extension = try self.allocator.dupe(u8, std.fs.path.extension(path)),
            },
        };
        _ = try self.world.resources.bindScriptAssetRecord(handle, record);

        if (self.script_runtime.hot_reload) |*hr| {
            try hr.registerScript(path, handle);
        }
        return handle;
    }

    fn inferScriptLanguageFromPath(path: []const u8) script_system.ScriptLanguage {
        if (script_system.csharp_toolchain_mod.isDotnetProjectPath(path) or
            script_system.csharp_toolchain_mod.isCSharpSourcePath(path) or
            script_system.csharp_toolchain_mod.isSharedLibraryPath(path))
        {
            return .csharp;
        }
        return .zig;
    }

    /// Scan assets/scripts/ directory and auto-register any .zig/.cs scripts
    /// that are not already loaded in the resource library.
    fn discoverScripts(self: *Application) void {
        const scripts_dir = "assets/scripts";

        // Open scripts directory relative to project root (or CWD as fallback).
        var owned_base: ?std.fs.Dir = if (self.project_root) |root|
            (std.fs.openDirAbsolute(root, .{}) catch null)
        else
            null;
        defer if (owned_base) |*d| d.close();
        const base_dir: std.fs.Dir = owned_base orelse std.fs.cwd();

        var dir = base_dir.openDir(scripts_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var walker = dir.walk(self.allocator) catch return;
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            const is_zig = std.mem.endsWith(u8, entry.path, ".zig");
            const is_cs = std.mem.endsWith(u8, entry.path, ".cs");
            if (!is_zig and !is_cs) continue;

            const full_path = std.fs.path.join(self.allocator, &.{ scripts_dir, entry.path }) catch continue;
            defer self.allocator.free(full_path);

            // Skip if already registered by asset ID
            if (self.world.resources.script_handles_by_asset_id.get(full_path) != null) continue;

            _ = self.loadScript(full_path) catch |err| {
                std.log.warn("Failed to auto-discover script '{s}': {}", .{ full_path, err });
                continue;
            };
            std.log.info("Auto-discovered script: {s}", .{full_path});
        }
    }

    fn scriptLoadScene(context: *anyopaque, path: []const u8) void {
        const self: *Application = @ptrCast(@alignCast(context));
        self.scene_manager.requestLoadScene(self.job_system, path, .{}) catch |err| {
            std.log.warn("scene manager: failed to queue load for '{s}': {s}", .{ path, @errorName(err) });
        };
    }

    fn scriptUnloadScene(context: *anyopaque) void {
        const self: *Application = @ptrCast(@alignCast(context));
        self.scene_manager.requestUnloadScene(.{}) catch |err| {
            std.log.warn("scene manager: failed to queue unload: {s}", .{@errorName(err)});
        };
    }

    fn scriptSetDontDestroyOnLoad(context: *anyopaque, entity_id: scene_mod.EntityId, enabled: bool) void {
        const self: *Application = @ptrCast(@alignCast(context));
        _ = self.scene_manager.setDontDestroyOnLoad(&self.world, entity_id, enabled);
    }

    fn scriptIsSceneLoading(context: *anyopaque) bool {
        const self: *Application = @ptrCast(@alignCast(context));
        return self.scene_manager.isBusy();
    }

    fn applyPendingCommands(self: *Application) !void {
        if (self.command_queue.len() == 0) {
            return;
        }

        const results = try self.command_queue.executeAll(&self.world);
        defer self.allocator.free(results);

        for (results) |result| {
            if (result.err) |err| {
                std.log.warn("command queue execution failed for entity {any}: {s}", .{
                    result.entity_id,
                    @tagName(err),
                });
            }
        }
    }

    fn bindRuntimeContext(self: *Application) void {
        self.script_runtime.bindWorld(&self.world);
        self.script_runtime.bindCommandQueue(&self.command_queue);
    }

    fn syncPlayModeState(self: *Application) void {
        switch (self.playback_controller.state) {
            .playing => {
                if (self.play_mode_snapshot == null) {
                    self.enterPlayMode();
                } else {
                    self.game_state = .playing;
                }
            },
            .paused => {
                if (self.play_mode_snapshot != null) {
                    self.game_state = .paused;
                }
            },
            .stopped => {
                if (self.play_mode_snapshot) |_| {
                    self.exitPlayMode();
                } else {
                    self.game_state = .game_start;
                }
            },
        }
    }

    fn enterPlayMode(self: *Application) void {
        if (self.play_mode_snapshot != null) {
            return;
        }

        const selection = self.renderer.selectedEntities();
        const snapshot = capturePlayModeSnapshot(
            self.allocator,
            &self.world,
            selection,
            .{
                .global_time = self.global_time,
                .time_scale = self.time_scale,
                .physics_accumulator_seconds = self.physics_accumulator_seconds,
                .playback_state = @enumFromInt(@intFromEnum(self.playback_controller.state)),
                .game_state = @enumFromInt(@intFromEnum(self.game_state)),
            },
        ) catch |err| {
            std.log.err("play mode: failed to capture snapshot: {}", .{err});
            self.playback_controller.setState(.stopped);
            self.game_state = .game_start;
            return;
        };

        self.play_mode_snapshot = snapshot;
        self.game_state = .playing;
    }

    fn exitPlayMode(self: *Application) void {
        var snapshot = self.play_mode_snapshot orelse {
            self.game_state = .game_start;
            return;
        };

        const runtime_state = restorePlayModeWorld(
            self.allocator,
            &self.world,
            &self.physics_state,
            &self.script_runtime,
            &snapshot,
        ) catch |err| {
            std.log.err("play mode: failed to restore world snapshot: {}", .{err});
            self.game_state = .game_start;
            return;
        };

        if (self.renderer.replaceSelectionMany(snapshot.selection)) {
            self.global_time = runtime_state.global_time;
            self.time_scale = runtime_state.time_scale;
            self.game_state = @enumFromInt(@intFromEnum(runtime_state.game_state));
            self.physics_accumulator_seconds = runtime_state.physics_accumulator_seconds;
            self.playback_controller = snapshot.playback_controller;
            const max_pending = self.command_queue.max_pending;
            self.command_queue.deinit();
            self.command_queue = command_queue_mod.CommandQueue.init(self.allocator);
            self.command_queue.max_pending = max_pending;
            snapshot.deinit(self.allocator);
            self.play_mode_snapshot = null;
        } else |err| {
            std.log.err("play mode: failed to restore selection: {}", .{err});
            self.game_state = .game_start;
        }
    }
};

const PlayModeSnapshot = struct {
    world: []u8,
    selection: []scene_mod.EntityId,
    runtime_state: scene_mod.SceneRuntimeState,
    playback_controller: layer_mod.PlaybackController,

    fn deinit(self: *PlayModeSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.world);
        allocator.free(self.selection);
        self.* = undefined;
    }
};

fn capturePlayModeSnapshot(
    allocator: std.mem.Allocator,
    world: *const scene_mod.World,
    selection: []const scene_mod.EntityId,
    runtime_state: scene_mod.SceneRuntimeState,
) !PlayModeSnapshot {
    const world_snapshot = try scene_mod.serializeWorldWithRuntimeStateAlloc(allocator, world, runtime_state);
    errdefer allocator.free(world_snapshot);

    const selection_snapshot = try allocator.dupe(scene_mod.EntityId, selection);
    errdefer allocator.free(selection_snapshot);

    return .{
        .world = world_snapshot,
        .selection = selection_snapshot,
        .runtime_state = runtime_state,
        .playback_controller = .{
            .state = .stopped,
            .pending_steps = 0,
        },
    };
}

fn restorePlayModeWorld(
    allocator: std.mem.Allocator,
    world: *scene_mod.World,
    physics_state: *physics_system.PhysicsState,
    script_runtime: ?*script_system.ScriptRuntime,
    snapshot: *const PlayModeSnapshot,
) !scene_mod.SceneRuntimeState {
    physics_state.deinitWorld(world);
    if (script_runtime) |runtime| {
        runtime.callDestroyAll(world);
    }
    var runtime_state: scene_mod.SceneRuntimeState = .{};
    try scene_mod.deserializeWorldWithRuntimeStateFromSlice(allocator, world, snapshot.world, &runtime_state);
    return runtime_state;
}

test "play mode snapshot restores world and selection" {
    var job_system = try job_system_mod.JobSystem.init(std.testing.allocator, 0);
    defer job_system.deinit();

    var world = scene_mod.World.init(std.testing.allocator, job_system);
    defer world.deinit();
    try world.bootstrap3D();

    const entity_id = try world.createEntity(.{ .name = "Play Mode Entity" });
    {
        const entity = world.getEntity(entity_id).?;
        entity.local_transform.translation = .{ 1.0, 2.0, 3.0 };
        entity.visible = true;
        world.markDirty(entity_id);
    }

    const selection = [_]scene_mod.EntityId{entity_id};
    var snapshot = try capturePlayModeSnapshot(
        std.testing.allocator,
        &world,
        selection[0..],
        .{
            .global_time = 12.5,
            .time_scale = 0.75,
            .physics_accumulator_seconds = 0.25,
            .game_state = .paused,
        },
    );
    defer snapshot.deinit(std.testing.allocator);

    {
        const entity = world.getEntity(entity_id).?;
        entity.local_transform.translation = .{ 42.0, 24.0, 12.0 };
        entity.visible = false;
        world.markDirty(entity_id);
    }

    var physics_state = physics_system.PhysicsState.init(std.testing.allocator);
    defer physics_state.deinit();

    const runtime_state = try restorePlayModeWorld(
        std.testing.allocator,
        &world,
        &physics_state,
        null,
        &snapshot,
    );

    const restored = world.getEntityConst(entity_id).?;
    try std.testing.expectEqualSlices(f32, &.{ 1.0, 2.0, 3.0 }, restored.local_transform.translation[0..]);
    try std.testing.expect(restored.visible);
    try std.testing.expectEqualSlices(scene_mod.EntityId, selection[0..], snapshot.selection);
    try std.testing.expectApproxEqAbs(@as(f32, 12.5), runtime_state.global_time, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), runtime_state.time_scale, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), runtime_state.physics_accumulator_seconds, 0.0001);
    try std.testing.expectEqual(@as(u32, @intFromEnum(layer_mod.GameState.paused)), @as(u32, @intFromEnum(runtime_state.game_state)));
}

test "play mode snapshot drops play-only entities and clears script runtime on stop" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const script_handle = try world.resources.createScript(.{
        .source = "//!guava builtin=rotate axis=y speed_deg=90 local=true\n",
        .language = .zig,
    });
    const scripted_entity = try world.createEntity(.{
        .name = "Scripted During Play",
        .script = .{
            .script_handle = script_handle,
            .language = .zig,
        },
    });

    const selection = [_]scene_mod.EntityId{scripted_entity};
    var snapshot = try capturePlayModeSnapshot(
        std.testing.allocator,
        &world,
        selection[0..],
        .{
            .global_time = 0.0,
            .time_scale = 1.0,
            .physics_accumulator_seconds = 0.0,
            .game_state = .playing,
        },
    );
    defer snapshot.deinit(std.testing.allocator);

    var runtime = script_system.ScriptRuntime.init(std.testing.allocator, .{
        .enable_hot_reload = false,
    });
    defer runtime.deinit();
    try runtime.initVMs();
    runtime.bindWorld(&world);
    runtime.reconcileWorld(&world);
    try std.testing.expectEqual(@as(usize, 1), runtime.instances.count());
    try std.testing.expect(world.getEntityConst(scripted_entity).?.script.?.instance_id != null);

    _ = try world.createEntity(.{ .name = "Play Only Entity" });
    world.getEntity(scripted_entity).?.local_transform.translation = .{ 9.0, 3.0, -2.0 };
    world.markDirty(scripted_entity);

    var physics_state = physics_system.PhysicsState.init(std.testing.allocator);
    defer physics_state.deinit();

    const runtime_state = try restorePlayModeWorld(
        std.testing.allocator,
        &world,
        &physics_state,
        &runtime,
        &snapshot,
    );

    try std.testing.expectEqual(@as(usize, 0), runtime.instances.count());
    try std.testing.expectEqual(@as(usize, 1), world.entities.items.len);
    try std.testing.expect(world.getEntityConst(scripted_entity) != null);
    try std.testing.expect(world.getEntityConst(scripted_entity).?.script.?.instance_id == null);
    try std.testing.expectEqual(@as(u32, @intFromEnum(layer_mod.GameState.playing)), @as(u32, @intFromEnum(runtime_state.game_state)));
    try std.testing.expectEqualSlices(
        f32,
        &.{ 0.0, 0.0, 0.0 },
        world.getEntityConst(scripted_entity).?.local_transform.translation[0..],
    );
}
