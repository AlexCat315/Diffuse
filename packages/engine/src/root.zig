//! Guava Engine: a Zig runtime for games, film/animation, and tooling.
//!
//! Guava Engine 是一个基于 Zig 语言的游戏引擎运行时，专注于以下领域：
//! - 游戏开发（Game Development）
//! - 影视动画制作（Film/Animation Production）
//! - 可视化工具（Visualization Tooling）
//!
//! ## 核心架构
//!
//! 引擎采用模块化设计，主要包含以下子系统：
//!
//! - **core** - 核心系统（应用管理、输入、层栈、平台抽象）
//! - **platform** - 平台层（窗口管理、进程管理）
//! - **rhi** - 渲染硬件接口（RHI，Render Hardware Interface）
//! - **render** - 渲染系统（渲染管线、后处理、Gizmo）
//! - **scene** - 场景系统（ECS、实体管理、组件系统）
//! - **assets** - 资源系统（资源注册表、导入、管理）
//! - **animation** - 动画系统（动画图、动画状态机）
//! - **physics** - 物理系统（刚体、碰撞检测、射线检测）
//! - **math** - 数学库（向量、矩阵、四元数）
//!
//! ## 快速开始
//!
//! ```zig
//! const guava = @import("guava");
//!
//! var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//! defer _ = gpa.deinit();
//! const allocator = gpa.allocator();
//!
//! // 创建应用配置
//! const config = guava.core.ApplicationConfig{
//!     .name = "My Game",
//!     .window_width = 1280,
//!     .window_height = 720,
//! };
//!
//! // 初始化并运行应用
//! var app = try guava.core.Application.init(allocator, config);
//! defer app.deinit();
//! _ = try app.run(0);
//! ```

const std = @import("std");

/// 核心系统模块
///
/// 提供应用程序生命周期管理、输入处理、层栈管理和平台抽象。
/// 这是构建 Guava Engine 应用的基础模块。
pub const core = struct {
    /// 应用程序主类，管理引擎生命周期和主循环
    pub const Application = @import("engine/core/application.zig").Application;
    /// 应用程序配置结构体
    pub const ApplicationConfig = @import("engine/core/application.zig").ApplicationConfig;
    /// 输入状态管理
    pub const InputState = @import("engine/core/input.zig").InputState;
    /// 引擎级命令定义
    pub const Command = @import("engine/core/command.zig").Command;
    /// 引擎级命令错误
    pub const CommandError = @import("engine/core/command.zig").CommandError;
    /// 命令审批状态（auto / previewed / user_approved / rejected）
    pub const CommandApprovalState = @import("engine/core/command.zig").ApprovalState;
    /// 命令审计元数据（actor/client/session/request/trace/base_revision）
    pub const CommandMeta = @import("engine/core/command.zig").CommandMeta;
    /// 创建实体命令参数
    pub const CreateEntitySpec = @import("engine/core/command.zig").CreateEntitySpec;
    /// 命令执行结果
    pub const CommandExecutionResult = @import("engine/core/command.zig").ExecutionResult;
    /// 引擎级命令队列
    pub const CommandQueue = @import("engine/core/command_queue.zig").CommandQueue;
    /// 轻量级实体查询引擎
    pub const QueryEngine = @import("engine/core/query_engine.zig");
    /// 键盘按键枚举
    pub const InputKey = @import("engine/core/input.zig").Key;
    /// 鼠标按钮枚举
    pub const MouseButton = @import("engine/core/input.zig").MouseButton;
    /// 输入修饰键（Shift、Ctrl、Alt 等）
    pub const InputModifiers = @import("engine/core/input.zig").Modifiers;
    /// 层接口，用于构建应用逻辑
    pub const Layer = @import("engine/core/layer.zig").Layer;
    /// 层上下文，提供给层的运行时信息
    pub const LayerContext = @import("engine/core/layer.zig").LayerContext;
    /// 多场景管理器
    pub const SceneManager = @import("engine/core/scene_manager.zig").SceneManager;
    /// 多场景管理回调
    pub const SceneManagerCallbacks = @import("engine/core/scene_manager.zig").Callbacks;
    /// 多场景加载状态快照
    pub const SceneLoadingState = @import("engine/core/scene_manager.zig").LoadingState;
    /// 播放状态（用于动画/游戏时间控制）
    pub const PlaybackState = @import("engine/core/layer.zig").PlaybackState;
    /// 播放控制器接口
    pub const PlaybackController = @import("engine/core/layer.zig").PlaybackController;
    /// 游戏运行时状态
    pub const GameState = @import("engine/core/layer.zig").GameState;
    /// 输入动作映射系统 (GR-6)
    pub const ActionMap = @import("engine/core/input_action.zig").ActionMap;
    /// 输入动作绑定
    pub const ActionBinding = @import("engine/core/input_action.zig").ActionBinding;
    /// 输入动作绑定类别
    pub const BindingKind = @import("engine/core/input_action.zig").BindingKind;
    /// 输入动作每帧状态
    pub const ActionFrameState = @import("engine/core/input_action.zig").ActionFrameState;
    /// 平台抽象
    pub const Platform = @import("engine/core/platform.zig").Platform;
    /// 检测当前运行平台
    pub const detectPlatform = @import("engine/core/platform.zig").detect;
    /// 获取平台名称
    pub const platformName = @import("engine/core/platform.zig").name;
};

/// 平台层模块
///
/// 提供跨平台的窗口管理和进程管理功能。
/// 支持 Windows、macOS 和 Linux 平台。
pub const platform = struct {
    /// 窗口管理类
    pub const Window = @import("engine/platform/window.zig").Window;
    /// 窗口配置结构体
    pub const WindowConfig = @import("engine/platform/window.zig").WindowConfig;
    /// 窗口事件枚举
    pub const WindowEvent = @import("engine/platform/window.zig").Event;
    /// 窗口事件类型
    pub const WindowEventKind = @import("engine/platform/window.zig").EventKind;
    /// SDL 平台支持
    pub const sdl = @import("engine/platform/sdl.zig");
    /// 获取进程驻留内存大小（字节）
    pub const processResidentMemoryBytes = @import("engine/platform/process.zig").residentMemoryBytes;
};

/// 影视/过场动画模块
///
/// 提供 Sequence 资产模型、轨道（Camera/Animation/Audio/Event/Property）、
/// 关键帧插值（Easing, Bézier, Catmull-Rom）、以及求值器（Evaluator）。
/// `.guava_sequence` 同时服务于游戏过场与离线影视渲染。
pub const cinematic = @import("engine/cinematic/mod.zig");

/// AI 行为树模块
///
/// 提供数据驱动的行为树运行时：Sequence/Selector/Parallel 组合节点、
/// Inverter/Repeater/Cooldown 装饰器、Action/Condition/Wait 叶节点、
/// 以及 per-entity Blackboard 和 Builder API。
pub const behavior = @import("engine/behavior/bt_system.zig");
pub const terrain = @import("engine/terrain/terrain.zig");
pub const terrain_renderer = @import("engine/terrain/terrain_renderer.zig");

/// 网络/多人系统
///
/// 纯 Zig 实现的 UDP 网络协议栈，包含可靠传输、会话管理与实体同步。
pub const network_protocol = @import("engine/network/protocol.zig");
pub const network_transport = @import("engine/network/transport.zig");
pub const network_session = @import("engine/network/session.zig");
pub const network = @import("engine/network/net_system.zig");

/// RTS 相机控制器
///
/// 提供俯瞰/斜视角 RTS 风格相机：WASD 平移、边缘滚动、滚轮缩放、
/// 中键拖拽、可选旋转、地图边界约束。
pub const rts_camera = @import("engine/camera/rts_camera.zig");

/// 战争迷雾系统
///
/// 提供 RTS/4X 风格的战争迷雾：CPU 端可见性网格 + GPU 渲染叠加。
/// 支持未探索/已探索/可见三态、多队伍视野、地图边界、可配置网格分辨率。
pub const fog_of_war = @import("engine/fog/fog_system.zig");

/// 资源/经济系统
///
/// 提供 RTS/4X 风格的经济框架：资源存储、采集、生产队列、供给/人口管理、交易。
pub const economy = @import("engine/economy/economy_system.zig");

/// 单位选择系统
///
/// 提供 RTS 风格的单位选择：点击、框选、双击选同类型、编组（Ctrl+1-3）、右键指令。
pub const selection = @import("engine/selection/selection_system.zig");

/// 运行时 UI 模块
///
/// 提供保留模式（retained-mode）的游戏 UI 系统。
/// 包含节点树、Flexbox 布局引擎、批量渲染器与 Canvas 公共 API。
pub const ui = @import("engine/ui/canvas.zig");

/// MCP 模块
///
/// 提供面向 AI 客户端的协议层、资源快照与服务端实现。
pub const mcp = @import("engine/mcp/mod.zig");

/// Editor RPC 模块
///
/// WebSocket JSON-RPC 2.0 服务器，供 Electron 编辑器前端连接。
/// 提供场景查询/修改、状态订阅、视口控制等 RPC 方法。
pub const editor_rpc = @import("engine/editor_rpc/mod.zig");

/// 脚本模块
///
/// 提供脚本运行时、C# NativeAOT gameplay VM 与参数反射工具。
pub const script = @import("engine/script/script.zig");

/// 渲染硬件接口（RHI）模块
///
/// 提供跨平台的 GPU 资源管理抽象。
/// 支持 Vulkan、Metal 和 DirectX 12 后端。
///
/// ## 主要功能
///
/// - 设备管理（Device）
/// - 缓冲区管理（Buffer）
/// - 纹理管理（Texture）
/// - 渲染管线（GraphicsPipeline）
/// - 着色器模块（ShaderModule）
/// - 采样器（Sampler）
/// - 绑定组（BindGroup）
///
/// ## 使用示例
///
/// ```zig
/// // 创建设备
/// var device = try rhi.Device.create(.{
///     .preferred_backends = &.{.vulkan, .metal},
/// });
///
/// // 创建纹理
/// const texture = try device.createTexture(.{
///     .width = 1024,
///     .height = 1024,
///     .format = .rgba8_unorm,
/// });
/// ```
pub const rhi = struct {
    /// 旧版 RHI 设备（基于 SDL3 GPU API，逐步迁移中）
    pub const LegacyDevice = @import("engine/rhi/device.zig").RhiDevice;
    /// GPU 缓冲区
    pub const Buffer = @import("engine/rhi/device.zig").Buffer;
    /// 绑定组，用于绑定资源到着色器
    pub const BindGroup = @import("engine/rhi/device.zig").BindGroup;
    /// 拷贝通道，用于资源拷贝操作
    pub const CopyPass = @import("engine/rhi/device.zig").CopyPass;
    /// GPU 围栏，用于同步
    pub const Fence = @import("engine/rhi/device.zig").Fence;
    /// 帧对象，表示一帧的渲染
    pub const Frame = @import("engine/rhi/device.zig").Frame;
    /// 图形渲染管线
    pub const GraphicsPipeline = @import("engine/rhi/device.zig").GraphicsPipeline;
    /// 图形渲染管线描述
    pub const GraphicsPipelineDesc = @import("engine/rhi/device.zig").GraphicsPipelineDesc;
    /// 纹理采样器
    pub const Sampler = @import("engine/rhi/device.zig").Sampler;
    /// 采样器描述
    pub const SamplerDesc = @import("engine/rhi/device.zig").SamplerDesc;
    /// 着色器模块
    pub const ShaderModule = @import("engine/rhi/device.zig").ShaderModule;
    /// 着色器模块描述
    pub const ShaderModuleDesc = @import("engine/rhi/device.zig").ShaderModuleDesc;
    /// GPU 纹理
    pub const Texture = @import("engine/rhi/device.zig").Texture;
    /// 纹理-采样器绑定
    pub const TextureSamplerBinding = @import("engine/rhi/device.zig").TextureSamplerBinding;
    /// 传输缓冲区，用于 CPU-GPU 数据传输
    pub const TransferBuffer = @import("engine/rhi/device.zig").TransferBuffer;
    /// 后端选择策略
    pub const BackendSelectionPolicy = @import("engine/rhi/types.zig").BackendSelectionPolicy;
    /// 比较操作（用于深度/模板测试）
    pub const CompareOp = @import("engine/rhi/types.zig").CompareOp;
    /// 剔除模式
    pub const CullMode = @import("engine/rhi/types.zig").CullMode;
    /// 填充模式
    pub const FillMode = @import("engine/rhi/types.zig").FillMode;
    /// 正面朝向定义
    pub const FrontFace = @import("engine/rhi/types.zig").FrontFace;
    /// 图形 API 枚举
    pub const GraphicsAPI = @import("engine/rhi/types.zig").GraphicsAPI;
    /// 设备配置
    pub const DeviceConfig = @import("engine/rhi/types.zig").DeviceConfig;
    /// 缓冲区用途
    pub const BufferUsage = @import("engine/rhi/types.zig").BufferUsage;
    /// 索引元素大小
    pub const IndexElementSize = @import("engine/rhi/types.zig").IndexElementSize;
    /// 图元类型
    pub const PrimitiveType = @import("engine/rhi/types.zig").PrimitiveType;
    /// 采样器寻址模式
    pub const SamplerAddressMode = @import("engine/rhi/types.zig").SamplerAddressMode;
    /// 采样器过滤模式
    pub const SamplerFilter = @import("engine/rhi/types.zig").SamplerFilter;
    /// 采样器 Mipmap 模式
    pub const SamplerMipmapMode = @import("engine/rhi/types.zig").SamplerMipmapMode;
    /// 着色器格式
    pub const ShaderFormat = @import("engine/rhi/types.zig").ShaderFormat;
    /// 着色器阶段
    pub const ShaderStage = @import("engine/rhi/types.zig").ShaderStage;
    /// 纹理用途
    pub const TextureUsage = @import("engine/rhi/types.zig").TextureUsage;
    /// 缓冲区描述
    pub const BufferDesc = @import("engine/rhi/types.zig").BufferDesc;
    /// 纹理描述
    pub const TextureDesc = @import("engine/rhi/types.zig").TextureDesc;
    /// 传输缓冲区描述
    pub const TransferBufferDesc = @import("engine/rhi/types.zig").TransferBufferDesc;
    /// 顶点元素格式
    pub const VertexElementFormat = @import("engine/rhi/types.zig").VertexElementFormat;
    /// 顶点输入速率
    pub const VertexInputRate = @import("engine/rhi/types.zig").VertexInputRate;
    /// 清除状态
    pub const ClearState = @import("engine/rhi/types.zig").ClearState;
    /// 运行时信息
    pub const RuntimeInfo = @import("engine/rhi/types.zig").RuntimeInfo;
    /// 获取图形 API 名称
    pub const graphicsApiName = @import("engine/rhi/types.zig").graphicsApiName;

    /// RHI 设备抽象（显式队列 + 软件命令缓冲）
    pub const Device = @import("engine/rhi/rhi.zig").Device;
    /// RHI 能力查询
    pub const Capabilities = @import("engine/rhi/rhi.zig").Capabilities;
    /// RHI 软件命令缓冲
    pub const CommandBuffer = @import("engine/rhi/rhi.zig").CommandBuffer;
    /// RHI 资源状态追踪
    pub const StateTracker = @import("engine/rhi/rhi.zig").StateTracker;
    /// RHI 队列类型
    pub const QueueClass = @import("engine/rhi/rhi.zig").QueueClass;
    /// RHI 提交描述
    pub const SubmitDesc = @import("engine/rhi/rhi.zig").SubmitDesc;
    /// RHI 上传环分配器
    pub const UploadRing = @import("engine/rhi/upload_ring.zig").UploadRing;
    /// Metal 原生后端
    pub const MetalBackend = @import("engine/rhi/metal/metal_backend.zig").MetalBackend;
};

/// 渲染系统模块
///
/// 提供完整的渲染管线实现，包括：
/// - 基础渲染通道（Base Pass）
/// - 阴影渲染（Shadow Pass）
/// - 后处理效果（Bloom、FXAA、色调映射）
/// - Gizmo 渲染
/// - ID 拾取（用于编辑器选择）
///
/// ## 渲染管线流程
///
/// 1. Depth Prepass - 深度预通道
/// 2. Shadow Pass - 阴影贴图渲染
/// 3. Base Pass - 主渲染通道
/// 4. Post Processing - 后处理（Bloom、FXAA、色调映射）
/// 5. Gizmo Pass - Gizmo 渲染（仅编辑器）
/// 6. Outline Pass - 选中物体轮廓（仅编辑器）
pub const render = struct {
    /// 图形 API 枚举
    pub const GraphicsAPI = @import("engine/render/types.zig").GraphicsAPI;
    /// 后端选择策略
    pub const BackendSelectionPolicy = @import("engine/render/types.zig").BackendSelectionPolicy;
    /// 运行时信息
    pub const RuntimeInfo = @import("engine/render/types.zig").RuntimeInfo;
    /// 默认首选后端列表
    pub const defaultPreferredBackends = @import("engine/render/types.zig").defaultPreferredBackends;
    /// 默认后端顺序
    pub const defaultBackendOrder = @import("engine/render/types.zig").defaultBackendOrder;
    /// 编辑器视口渲染模式
    pub const EditorViewportRenderMode = @import("engine/render/types.zig").EditorViewportRenderMode;
    /// 编辑器视口 LUT 预设
    pub const EditorViewportLutPreset = @import("engine/render/types.zig").EditorViewportLutPreset;
    /// 编辑器视口状态
    pub const EditorViewportState = @import("engine/render/types.zig").EditorViewportState;
    /// 渲染器主类，管理整个渲染管线
    pub const Renderer = @import("engine/render/renderer.zig").Renderer;
    /// 渲染器配置
    pub const RendererConfig = @import("engine/render/renderer.zig").RendererConfig;
    /// 帧报告，包含渲染统计信息
    pub const FrameReport = @import("engine/render/renderer.zig").FrameReport;
    /// 网格场景缓存
    pub const MeshSceneCache = @import("engine/render/passes/mesh_pass.zig").MeshSceneCache;
    /// 准备好的场景数据
    pub const PreparedScene = @import("engine/render/passes/mesh_pass.zig").PreparedScene;
    /// ID 拾取通道（用于编辑器物体选择）
    pub const IdPass = @import("engine/render/passes/id_pass.zig").IdPass;
    /// 基础渲染通道
    pub const BasePass = @import("engine/render/passes/base_pass.zig").BasePass;
    /// 基础渲染通道（Golden 测试版本）
    pub const BasePassGolden = @import("engine/render/passes/base_pass_golden.zig");
    /// 深度预通道
    pub const DepthPrepass = @import("engine/render/passes/depth_prepass.zig").DepthPrepass;
    /// Gizmo 渲染通道
    pub const GizmoPass = @import("engine/render/passes/gizmo_pass.zig").GizmoPass;
    /// 轮廓渲染通道（用于选中物体高亮）
    pub const OutlinePass = @import("engine/render/passes/outline_pass.zig").OutlinePass;
    /// 选择历史管理
    pub const SelectionHistory = @import("engine/render/selection_history.zig").SelectionHistory;
    /// 选择更新模式
    pub const SelectionUpdateMode = @import("engine/render/selection_history.zig").SelectionUpdateMode;
    /// 获取图形 API 名称
    pub const graphicsApiName = @import("engine/render/types.zig").graphicsApiName;
};

/// 资源系统模块
///
/// 提供完整的资源管理功能，包括：
/// - 资源注册表（Asset Registry）
/// - 资源导入（GLTF、纹理、材质等）
/// - 资源句柄（类型安全的资源引用）
/// - 资源验证
///
/// ## 资源类型
///
/// - Mesh - 网格
/// - Material - 材质
/// - Texture - 纹理
/// - Skeleton - 骨骼
/// - Skin - 蒙皮
/// - AnimationClip - 动画片段
/// - Script - 脚本
///
/// ## 使用示例
///
/// ```zig
/// // 获取资源库
/// var library = world.resources;
///
/// // 加载网格
/// const mesh_handle = library.ensurePrimitiveMesh(.cube);
///
/// // 加载材质
/// const material_handle = library.ensureDefaultMaterial();
/// ```
pub const assets = struct {
    /// 资源句柄定义
    pub const handles = @import("engine/assets/handles.zig");
    /// 资源注册表，管理所有资源元数据
    pub const AssetRegistry = @import("engine/assets/registry.zig").AssetRegistry;
    /// 资源记录
    pub const AssetRecord = @import("engine/assets/registry.zig").AssetRecord;
    /// 资源类型枚举
    pub const AssetType = @import("engine/assets/registry.zig").AssetType;
    /// 资源输出信息
    pub const AssetOutput = @import("engine/assets/registry.zig").AssetOutput;
    /// 资源元数据
    pub const AssetMetadata = @import("engine/assets/registry.zig").AssetMetadata;
    /// 创建派生资源 ID
    pub const makeDerivedAssetIdAlloc = @import("engine/assets/registry.zig").makeDerivedAssetIdAlloc;
    /// 计算字符串 SHA256 哈希
    pub const hashStringAlloc = @import("engine/assets/registry.zig").hashStringAlloc;
    /// 获取默认导入设置哈希
    pub const defaultImportSettingsHashAlloc = @import("engine/assets/registry.zig").defaultImportSettingsHashAlloc;
    /// 资源库，运行时资源管理
    pub const ResourceLibrary = @import("engine/assets/library.zig").ResourceLibrary;
    /// 资源验证问题
    pub const AssetValidationIssue = @import("engine/assets/validator.zig").ValidationIssue;
    /// 资源验证报告
    pub const AssetValidationReport = @import("engine/assets/validator.zig").ValidationReport;
    /// 验证项目资源
    pub const validateProjectAssetsAlloc = @import("engine/assets/validator.zig").validateProjectAlloc;
    /// 验证注册表资源
    pub const validateRegistryAssetsAlloc = @import("engine/assets/validator.zig").validateRegistryAlloc;
    /// 网格句柄
    pub const MeshHandle = @import("engine/assets/handles.zig").MeshHandle;
    /// 材质句柄
    pub const MaterialHandle = @import("engine/assets/handles.zig").MaterialHandle;
    /// 纹理句柄
    pub const TextureHandle = @import("engine/assets/handles.zig").TextureHandle;
    /// 骨骼句柄
    pub const SkeletonHandle = @import("engine/assets/handles.zig").SkeletonHandle;
    /// 蒙皮句柄
    pub const SkinHandle = @import("engine/assets/handles.zig").SkinHandle;
    /// 动画片段句柄
    pub const AnimationClipHandle = @import("engine/assets/handles.zig").AnimationClipHandle;
    /// 脚本句柄
    pub const ScriptHandle = @import("engine/assets/handles.zig").ScriptHandle;
    /// 网格资源
    pub const MeshResource = @import("engine/assets/mesh_resource.zig").MeshResource;
    /// 网格顶点格式
    pub const MeshVertex = @import("engine/assets/mesh_resource.zig").Vertex;
    /// 网格资源描述
    pub const MeshResourceDesc = @import("engine/assets/mesh_resource.zig").MeshResourceDesc;
    /// 计算网格局部包围盒
    pub const computeMeshLocalBounds = @import("engine/assets/mesh_resource.zig").computeLocalBounds;
    /// 材质资源
    pub const MaterialResource = @import("engine/assets/material_resource.zig").MaterialResource;
    /// 材质资源描述
    pub const MaterialResourceDesc = @import("engine/assets/material_resource.zig").MaterialResourceDesc;
    /// 材质实例父链元数据
    pub const MaterialInheritanceInfo = @import("engine/assets/material_model.zig").MaterialInheritanceInfo;
    /// 材质图通道语义
    pub const MaterialGraphChannel = @import("engine/assets/material_model.zig").MaterialChannel;
    /// 材质图节点
    pub const MaterialGraphNode = @import("engine/assets/material_model.zig").MaterialGraphNode;
    /// 材质图
    pub const MaterialGraph = @import("engine/assets/material_model.zig").MaterialGraph;
    /// 复制材质图
    pub const cloneMaterialGraphAlloc = @import("engine/assets/material_model.zig").cloneGraphAlloc;
    /// 材质编辑工具（usage count、ensure editable、sync component）
    pub const material_editing = @import("engine/assets/material_editing.zig");
    /// 销毁材质图
    pub const deinitMaterialGraph = @import("engine/assets/material_model.zig").deinitGraph;
    /// 材质 AST 纹理槽
    pub const MaterialAstTextureSlots = @import("engine/assets/material_ast.zig").TextureSlots;
    /// 材质 AST（渲染器无关中间层）
    pub const MaterialAst = @import("engine/assets/material_ast.zig").MaterialAst;
    /// 序列化材质资源到文本
    pub const serializeMaterialAlloc = @import("engine/assets/material_resource.zig").serializeAlloc;
    /// 从文本反序列化材质资源
    pub const deserializeMaterialFromSlice = @import("engine/assets/material_resource.zig").deserializeFromSlice;
    /// 保存材质资源到路径
    pub const saveMaterialToPath = @import("engine/assets/material_resource.zig").saveToPath;
    /// 从路径加载材质资源
    pub const loadMaterialFromPath = @import("engine/assets/material_resource.zig").loadFromPath;
    /// 纹理资源
    pub const TextureResource = @import("engine/assets/texture_resource.zig").TextureResource;
    /// 纹理资源描述
    pub const TextureResourceDesc = @import("engine/assets/texture_resource.zig").TextureResourceDesc;
    /// 骨骼资源
    pub const SkeletonResource = @import("engine/assets/skeleton_resource.zig").SkeletonResource;
    /// 骨骼资源描述
    pub const SkeletonResourceDesc = @import("engine/assets/skeleton_resource.zig").SkeletonResourceDesc;
    /// 蒙皮资源
    pub const SkinResource = @import("engine/assets/skin_resource.zig").SkinResource;
    /// 蒙皮资源描述
    pub const SkinResourceDesc = @import("engine/assets/skin_resource.zig").SkinResourceDesc;
    /// 动画片段资源
    pub const AnimationClipResource = @import("engine/assets/animation_clip_resource.zig").AnimationClipResource;
    /// 动画片段资源描述
    pub const AnimationClipResourceDesc = @import("engine/assets/animation_clip_resource.zig").AnimationClipResourceDesc;
    /// 动画插值模式
    pub const AnimationInterpolation = @import("engine/assets/animation_clip_resource.zig").Interpolation;
    /// 解码后的图像
    pub const DecodedImage = @import("engine/assets/image_decoder.zig").DecodedImage;
    /// 解码图像为 RGBA8
    pub const decodeImageRgba8 = @import("engine/assets/image_decoder.zig").decodeRgba8;
    /// 光栅化后的 SVG
    pub const RasterizedSvg = @import("engine/assets/svg_decoder.zig").RasterizedSvg;
    /// SVG 光栅化选项
    pub const SvgRasterizeOptions = @import("engine/assets/svg_decoder.zig").RasterizeOptions;
    /// 光栅化 SVG 为 BGRA8
    pub const rasterizeSvgBgra8 = @import("engine/assets/svg_decoder.zig").rasterizeBgra8;
    /// 确保纹理已烹饪
    pub const ensureCookedTexture = @import("engine/assets/texture_import.zig").ensureCookedTexture;
    /// 验证已烹饪的纹理资源
    pub const validateCookedTextureAsset = @import("engine/assets/texture_import.zig").validateCookedTextureAsset;
    /// 加载纹理资源
    pub const loadTextureAsset = @import("engine/assets/texture_import.zig").loadTextureAsset;
    /// GLTF 导入报告
    pub const GltfImportReport = @import("engine/assets/gltf_import.zig").ImportReport;
    /// 确保模型资源已烹饪
    pub const ensureCookedModelAsset = @import("engine/assets/gltf_import.zig").ensureCookedModelAsset;
    /// 验证已烹饪的模型资源
    pub const validateCookedModelAsset = @import("engine/assets/gltf_import.zig").validateCookedModelAsset;
    /// 导入 GLTF 静态模型资源
    pub const importGltfStaticModelAsset = @import("engine/assets/gltf_import.zig").importStaticModelAsset;
    /// 导入 GLTF 静态模型资源实例
    pub const importGltfStaticModelAssetInstance = @import("engine/assets/gltf_import.zig").importStaticModelAssetInstance;
};

/// 动画系统模块
///
/// 提供动画播放和管理功能：
/// - 动画状态机
/// - 动画混合
/// - 动画事件
///
/// ## 使用示例
///
/// ```zig
/// // 播放动画片段
/// try guava.animation.playClip(animator, .{
///     .clip = clip_handle,
///     .loop = true,
///     .speed = 1.0,
/// });
/// ```
pub const animation = struct {
    /// 更新所有动画器
    pub const updateAnimators = @import("engine/animation/animator_system.zig").update;
    /// 播放动画选项
    pub const PlayClipOptions = @import("engine/animation/animator_system.zig").PlayClipOptions;
    /// 播放动画片段
    pub const playClip = @import("engine/animation/animator_system.zig").playClip;
    /// 在编辑器中按指定时间预览动画（不推进时间轴，用于动画编辑器 scrub/play 预览）
    pub const sampleEntityAtTime = @import("engine/animation/animator_system.zig").sampleEntityAtTime;
    /// 动画图模块
    pub const animation_graph = @import("engine/animation/animation_graph.zig");
};

/// 物理系统模块
///
/// 提供物理模拟功能：
/// - 刚体动力学
/// - 碰撞检测
/// - 射线检测
/// - AABB 查询
///
/// ## 支持的后端
///
/// - Builtin - 内置轻量级物理
/// - Jolt - Jolt Physics（完整物理模拟）
///
/// ## 使用示例
///
/// ```zig
/// // 配置物理
/// const physics_config = guava.physics.Config{
///     .backend = .jolt,
///     .gravity = .{ 0, -9.8, 0 },
/// };
///
/// // 执行物理步进
/// const stats = guava.physics.step(world, delta_time, physics_config);
///
/// // 射线检测
/// const hit = guava.physics.raycast(world, .{
///     .origin = .{ 0, 10, 0 },
///     .direction = .{ 0, -1, 0 },
/// });
/// ```
pub const physics = struct {
    /// 轴对齐包围盒
    pub const AABB = @import("engine/math/aabb.zig").AABB;
    /// 物理后端枚举
    pub const Backend = @import("engine/physics/system.zig").Backend;
    /// 物理配置
    pub const Config = @import("engine/physics/system.zig").Config;
    /// 物理步进统计
    pub const StepStats = @import("engine/physics/system.zig").StepStats;
    /// 射线查询
    pub const RayQuery = @import("engine/physics/system.zig").RayQuery;
    /// 查询过滤器
    pub const QueryFilter = @import("engine/physics/system.zig").QueryFilter;
    /// 射线检测结果
    pub const RaycastHit = @import("engine/physics/system.zig").RaycastHit;
    /// 重叠检测结果
    pub const OverlapHit = @import("engine/physics/system.zig").OverlapHit;
    /// 扫掠检测结果
    pub const SweepHit = @import("engine/physics/system.zig").SweepHit;
    /// 从中心和半尺寸创建 AABB
    pub const aabbFromCenterHalfExtents = @import("engine/physics/system.zig").aabbFromCenterHalfExtents;
    /// 释放世界的物理资源
    pub const deinitWorld = @import("engine/physics/system.zig").deinitWorld;
    /// 执行射线检测
    pub const raycast = @import("engine/physics/system.zig").raycast;
    /// 执行 AABB 重叠查询
    pub const overlapAabb = @import("engine/physics/system.zig").overlapAabb;
    /// 执行 AABB 扫掠查询
    pub const sweepAabb = @import("engine/physics/system.zig").sweepAabb;
    /// 执行物理步进
    pub const step = @import("engine/physics/system.zig").step;
};

/// 导航寻路模块
///
/// 提供 NavMesh 构建、寻路查询和群体避障功能。
/// 基于 Recast/Detour 导航库。
pub const navigation = struct {
    pub const NavMesh = @import("engine/navigation/navigation.zig").NavMesh;
    pub const NavMeshParams = @import("engine/navigation/navigation.zig").NavMeshParams;
    pub const Crowd = @import("engine/navigation/navigation.zig").Crowd;
    pub const AgentParams = @import("engine/navigation/navigation.zig").AgentParams;
    pub const NavSystem = @import("engine/navigation/nav_system.zig").NavSystem;
};

/// 音频系统模块
///
/// 提供完整的音频播放、3D 空间音效、混音器控制和脚本接口。
/// 基于 SoLoud 音频引擎，支持 WAV/OGG 格式。
pub const audio = @import("engine/audio/mod.zig");

/// 数学库模块
///
/// 提供游戏开发常用的数学类型和运算：
/// - 向量（Vec3）
/// - 矩阵（Mat4）
/// - 四元数（Quat）
/// - 角度转换
/// - 坐标轴定义
///
/// ## 使用示例
///
/// ```zig
/// // 向量运算
/// const v1 = guava.math.vec3.new(1, 2, 3);
/// const v2 = guava.math.vec3.new(4, 5, 6);
/// const v3 = guava.math.vec3.add(v1, v2);
///
/// // 矩阵变换
/// const m = guava.math.mat4.identity();
/// const translated = guava.math.mat4.translate(m, .{ 1, 2, 3 });
///
/// // 四元数旋转
/// const q = guava.math.quat.fromEuler(.{ 0, std.math.pi / 2, 0 });
/// ```
pub const math = struct {
    /// 角度转换工具
    pub const angle = @import("engine/math/angle.zig");
    /// 坐标轴定义
    pub const axis = @import("engine/math/axis.zig");
    /// 4x4 矩阵
    pub const mat4 = @import("engine/math/mat4.zig");
    /// 3D 向量
    pub const vec3 = @import("engine/math/vec3.zig");
    /// 四元数
    pub const quat = @import("engine/math/quat.zig");
};

/// 场景系统模块
///
/// 提供 ECS（Entity-Component-System）架构的场景管理：
/// - 实体（Entity）管理
/// - 组件（Component）系统
/// - 场景序列化/反序列化
/// - Prefab 系统
///
/// ## 核心概念
///
/// - **World** - 场景世界，包含所有实体
/// - **Entity** - 实体，组件的容器
/// - **Component** - 组件，存储数据（Transform、Mesh、Light 等）
/// - **Prefab** - 预制体，可复用的实体模板
///
/// ## 使用示例
///
/// ```zig
/// // 创建世界
/// var world = guava.scene.World.init(allocator, null);
/// defer world.deinit();
///
/// // 创建实体
/// const entity = try world.createEntity(.{
///     .name = "Player",
///     .local_transform = .{
///         .translation = .{ 0, 1, 0 },
///     },
/// });
///
/// // 添加组件
/// try world.addMeshComponent(entity, .{ .handle = mesh_handle });
/// try world.addRigidbodyComponent(entity, .{ .motion_type = .dynamic });
///
/// // 保存场景
/// try guava.scene.saveWorldToPath(&world, "scene.guava");
/// ```
pub const scene = struct {
    /// 场景类
    pub const Scene = @import("engine/scene/scene.zig").Scene;
    /// 场景世界
    pub const World = @import("engine/scene/scene.zig").World;
    /// 实体
    pub const Entity = @import("engine/scene/scene.zig").Entity;
    /// 实体 ID
    pub const EntityId = @import("engine/scene/scene.zig").EntityId;
    /// 实体描述
    pub const EntityDesc = @import("engine/scene/scene.zig").EntityDesc;
    /// 场景摘要
    pub const Summary = @import("engine/scene/scene.zig").Summary;
    /// 射线
    pub const Ray = @import("engine/scene/scene.zig").Ray;
    /// 表面射线检测结果
    pub const SurfaceRaycastHit = @import("engine/scene/scene.zig").SurfaceRaycastHit;
    /// 序列化世界
    pub const serializeWorldAlloc = @import("engine/scene/scene.zig").serializeWorldAlloc;
    /// 序列化世界及运行时状态
    pub const serializeWorldWithRuntimeStateAlloc = @import("engine/scene/scene.zig").serializeWorldWithRuntimeStateAlloc;
    /// 从字节切片反序列化世界
    pub const deserializeWorldFromSlice = @import("engine/scene/scene.zig").deserializeWorldFromSlice;
    /// 从字节切片反序列化世界及运行时状态
    pub const deserializeWorldWithRuntimeStateFromSlice = @import("engine/scene/scene.zig").deserializeWorldWithRuntimeStateFromSlice;
    /// 保存世界到路径
    pub const saveWorldToPath = @import("engine/scene/scene.zig").saveWorldToPath;
    /// 保存世界及运行时状态到路径
    pub const saveWorldWithRuntimeStateToPath = @import("engine/scene/scene.zig").saveWorldWithRuntimeStateToPath;
    /// 从路径加载世界
    pub const loadWorldFromPath = @import("engine/scene/scene.zig").loadWorldFromPath;
    /// 从路径加载世界及运行时状态
    pub const loadWorldWithRuntimeStateFromPath = @import("engine/scene/scene.zig").loadWorldWithRuntimeStateFromPath;
    /// 存档系统
    pub const SaveSystem = @import("engine/scene/save_system.zig").SaveSystem;
    /// 存档元数据
    pub const SaveMeta = @import("engine/scene/save_system.zig").SaveMeta;
    /// 存档选项
    pub const SaveOptions = @import("engine/scene/save_system.zig").SaveOptions;
    /// 变换组件
    pub const Transform = @import("engine/scene/components.zig").Transform;
    /// 相机组件
    pub const Camera = @import("engine/scene/components.zig").Camera;
    /// 网格组件
    pub const Mesh = @import("engine/scene/components.zig").Mesh;
    /// 蒙皮网格组件
    pub const SkinnedMesh = @import("engine/scene/components.zig").SkinnedMesh;
    /// 动画器组件
    pub const Animator = @import("engine/scene/components.zig").Animator;
    /// 刚体组件
    pub const Rigidbody = @import("engine/scene/components.zig").Rigidbody;
    /// 刚体运动类型
    pub const RigidbodyMotionType = @import("engine/scene/components.zig").RigidbodyMotionType;
    /// 盒碰撞器组件
    pub const BoxCollider = @import("engine/scene/components.zig").BoxCollider;
    /// 球碰撞器组件
    pub const SphereCollider = @import("engine/scene/components.zig").SphereCollider;
    /// 网格碰撞器组件
    pub const MeshCollider = @import("engine/scene/components.zig").MeshCollider;
    /// 材质组件
    pub const Material = @import("engine/scene/components.zig").Material;
    /// 光源组件
    pub const Light = @import("engine/scene/components.zig").Light;
    /// 特效组件
    pub const Vfx = @import("engine/scene/components.zig").Vfx;
    /// 脚本组件
    pub const Script = @import("engine/scene/components.zig").Script;
    /// 脚本语言
    pub const ScriptLanguage = @import("engine/scene/components.zig").ScriptLanguage;
    /// 特效类型
    pub const VfxKind = @import("engine/scene/components.zig").VfxKind;
    /// 默认特效参数
    pub const defaultVfx = @import("engine/scene/components.zig").defaultVfx;
    /// 运行时粒子
    /// 音频总线
    pub const AudioBus = @import("engine/scene/components.zig").AudioBus;
    /// 音频源组件
    pub const AudioSource = @import("engine/scene/components.zig").AudioSource;
    /// 音频监听器组件
    pub const AudioListener = @import("engine/scene/components.zig").AudioListener;
    /// 音频剪辑句柄类型
    pub const AudioClipHandle = @import("engine/scene/components.zig").AudioClipHandle;
    /// 导航代理组件
    pub const NavAgent = @import("engine/scene/components.zig").NavAgent;
    /// 场景运行时状态快照
    pub const SceneRuntimeState = @import("engine/scene/scene.zig").SceneRuntimeState;
    pub const VfxRuntimeParticle = @import("engine/scene/scene.zig").VfxRuntimeParticle;
    /// 运行时发射器
    pub const VfxRuntimeEmitter = @import("engine/scene/scene.zig").VfxRuntimeEmitter;
    /// 几何体类型
    pub const Primitive = @import("engine/scene/components.zig").Primitive;
    /// 着色模型
    pub const ShadingModel = @import("engine/scene/components.zig").ShadingModel;
    /// 光源类型
    pub const LightKind = @import("engine/scene/components.zig").LightKind;
    /// Prefab 系统
    pub const prefab = @import("engine/scene/prefab.zig");
    /// 插件系统
    pub const plugin = @import("engine/plugin/plugin.zig");
};

test {
    std.testing.refAllDecls(@This());
}
