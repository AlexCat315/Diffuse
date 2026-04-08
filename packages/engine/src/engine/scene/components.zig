//! ECS 组件定义模块
//!
//! 本模块定义了 Guava Engine 的所有 ECS（Entity-Component-System）组件类型。
//! 组件是纯数据结构，用于描述实体的各种属性和行为。
//!
//! ## 核心组件类型
//!
//! - **Transform** - 变换（位置、旋转、缩放）
//! - **Camera** - 相机（投影、视口）
//! - **Mesh** - 网格（几何体）
//! - **Material** - 材质（着色、纹理）
//! - **Light** - 光源（方向光、点光源、聚光灯）
//! - **Rigidbody** - 刚体（物理模拟）
//! - **Collider** - 碰撞器（盒、球、网格）
//! - **Animator** - 动画器（骨骼动画）
//! - **Script** - 脚本（自定义逻辑）
//! - **Vfx** - 特效（粒子系统）
//!
//! ## 使用示例
//!
//! ```zig
//! // 创建带有变换和网格的实体
//! const entity = try world.createEntity(.{
//!     .name = "Cube",
//!     .local_transform = .{
//!         .translation = .{ 0, 1, 0 },
//!         .rotation = quat.fromEuler(.{ 0, 0.5, 0 }),
//!         .scale = .{ 2, 2, 2 },
//!     },
//!     .mesh = .{ .primitive = .cube },
//!     .material = .{ .base_color_factor = .{ 1, 0, 0, 1 } },
//! });
//! ```

const std = @import("std");
const handles = @import("../assets/handles.zig");
const world_mod = @import("../scene/world.zig");

/// 实体 ID 类型
pub const EntityId = world_mod.EntityId;
/// 2D 向量类型
pub const Vec2 = [2]f32;
/// 3D 向量类型
pub const Vec3 = [3]f32;
/// 四元数类型（用于表示旋转）
pub const Quat = [4]f32;

/// 变换组件
///
/// 描述实体在 3D 空间中的位置、旋转和缩放。
/// 这是几乎所有实体都需要的基础组件。
///
/// ## 字段
/// - `translation` - 位置偏移（世界坐标或相对于父实体）
/// - `rotation` - 旋转（四元数表示）
/// - `scale` - 缩放因子
///
/// ## 使用示例
///
/// ```zig
/// // 创建一个位于 (1, 2, 3) 的实体
/// const transform = Transform{
///     .translation = .{ 1.0, 2.0, 3.0 },
///     .rotation = quat.identity(),
///     .scale = .{ 1.0, 1.0, 1.0 },
/// };
/// ```
pub const Transform = struct {
    /// 位置偏移（默认原点）
    translation: Vec3 = .{ 0.0, 0.0, 0.0 },
    /// 旋转四元数（默认无旋转）
    rotation: Quat = .{ 0.0, 0.0, 0.0, 1.0 },
    /// 缩放因子（默认单位缩放）
    scale: Vec3 = .{ 1.0, 1.0, 1.0 },

    /// 返回单位变换（无位移、无旋转、单位缩放）
    pub fn identity() Transform {
        return .{};
    }

    /// 将变换转换为 4x4 矩阵
    ///
    /// 矩阵形式：T * R * S（先缩放，再旋转，最后平移）
    pub fn toMatrix(self: Transform) [16]f32 {
        const mat4 = @import("../math/mat4.zig");
        const quat = @import("../math/quat.zig");
        const t = mat4.translation(self.translation);
        const r = quat.toMat4(self.rotation);
        const s = mat4.scale(self.scale);
        return mat4.mul(t, mat4.mul(r, s));
    }
};

/// 相机投影类型
///
/// 支持透视投影和正交投影两种模式。
pub const CameraProjection = union(enum) {
    /// 透视投影（模拟人眼视角，有近大远小效果）
    perspective: struct {
        /// 垂直视野角度（弧度，默认约 60 度）
        fov_y_radians: f32 = 1.0471976,
        /// 近裁剪面距离
        near_clip: f32 = 0.1,
        /// 远裁剪面距离
        far_clip: f32 = 1000.0,
    },
    /// 正交投影（无透视变形，常用于 2D 游戏或编辑器）
    orthographic: struct {
        /// 视口大小
        size: f32 = 10.0,
        /// 近裁剪面距离
        near_clip: f32 = -1.0,
        /// 远裁剪面距离
        far_clip: f32 = 1.0,
    },
};

/// 相机组件
///
/// 用于渲染场景视角。一个场景可以有多个相机，
/// 但通常只有一个主相机（`is_primary = true`）。
pub const Camera = struct {
    /// 投影类型（透视或正交）
    projection: CameraProjection = .{ .perspective = .{} },
    /// 是否为主相机（主相机用于最终渲染）
    is_primary: bool = false,
};

/// 几何体类型
///
/// 用于快速创建基本几何体，无需加载外部模型文件。
pub const Primitive = enum {
    /// 立方体
    cube,
    /// 球体
    sphere,
    /// 平面
    plane,
    /// 自定义（使用外部模型）
    custom,
};

/// 网格组件
///
/// 定义实体的几何形状。可以使用内置几何体（Primitive）
/// 或加载外部模型文件（通过 MeshHandle）。
pub const Mesh = struct {
    /// 网格资源句柄（null 表示使用 primitive）
    handle: ?handles.MeshHandle = null,
    /// 几何体类型（当 handle 为 null 时使用）
    primitive: Primitive = .custom,
};

/// 蒙皮网格组件
///
/// 用于骨骼动画的网格。包含对骨骼和蒙皮数据的引用。
pub const SkinnedMesh = struct {
    /// 网格资源句柄
    mesh_handle: ?handles.MeshHandle = null,
    /// 几何体类型
    primitive: Primitive = .custom,
    /// 骨骼资源句柄
    skeleton_handle: ?handles.SkeletonHandle = null,
    /// 蒙皮资源句柄
    skin_handle: ?handles.SkinHandle = null,
};

/// 动画器组件
///
/// 控制骨骼动画的播放。支持动画片段播放、混合和过渡。
pub const Animator = struct {
    /// 骨骼资源句柄
    skeleton_handle: ?handles.SkeletonHandle = null,
    /// 默认动画片段句柄
    default_clip_handle: ?handles.AnimationClipHandle = null,
    /// 当前动画时间（秒）
    time_seconds: f32 = 0.0,
    /// 下一个动画片段句柄（用于过渡）
    next_clip_handle: ?handles.AnimationClipHandle = null,
    /// 下一个动画的时间位置
    next_time_seconds: f32 = 0.0,
    /// 混合持续时间（秒）
    blend_duration_seconds: f32 = 0.0,
    /// 当前混合进度（秒）
    blend_time_seconds: f32 = 0.0,
    /// 播放速度（1.0 为正常速度）
    speed: f32 = 1.0,
    /// 是否正在播放
    playing: bool = true,
    /// 是否循环播放
    looping: bool = true,
};

/// 刚体运动类型
///
/// 定义刚体在物理模拟中的行为方式。
pub const RigidbodyMotionType = enum {
    /// 静态（不受力影响，不会移动）
    static,
    /// 动态（受力和碰撞影响）
    dynamic,
    /// 运动学（不受力影响，但可以通过代码控制移动）
    kinematic,
};

/// 刚体组件
///
/// 使实体参与物理模拟。需要配合碰撞器组件使用。
pub const Rigidbody = struct {
    /// 运动类型
    motion_type: RigidbodyMotionType = .dynamic,
    /// 质量（千克）
    mass: f32 = 1.0,
    /// 线速度（米/秒）
    linear_velocity: Vec3 = .{ 0.0, 0.0, 0.0 },
    /// 角速度（弧度/秒）
    angular_velocity: Vec3 = .{ 0.0, 0.0, 0.0 },
    /// 重力缩放（1.0 为正常重力）
    gravity_scale: f32 = 1.0,
    /// 线性阻尼（模拟空气阻力）
    linear_damping: f32 = 0.04,
    /// 角阻尼
    angular_damping: f32 = 0.04,
    /// 是否允许休眠（优化静止物体的计算）
    allow_sleep: bool = true,
};

/// 盒碰撞器组件
///
/// 定义轴对齐的盒形碰撞区域。
pub const BoxCollider = struct {
    /// 半尺寸（从中心到各面的距离）
    half_extents: Vec3 = .{ 0.5, 0.5, 0.5 },
    /// 中心偏移（相对于实体原点）
    center: Vec3 = .{ 0.0, 0.0, 0.0 },
    /// 是否为触发器（触发器不产生物理响应，只检测进入/离开）
    is_trigger: bool = false,
    /// 碰撞层 ID
    layer_id: u16 = 0,
    /// 碰撞层组掩码（定义可以与哪些层碰撞）
    layer_group: u16 = 0xFFFF,
};

/// 球碰撞器组件
///
/// 定义球形碰撞区域。
pub const SphereCollider = struct {
    /// 半径
    radius: f32 = 0.5,
    /// 中心偏移（相对于实体原点）
    center: Vec3 = .{ 0.0, 0.0, 0.0 },
    /// 是否为触发器
    is_trigger: bool = false,
    /// 碰撞层 ID
    layer_id: u16 = 0,
    /// 碰撞层组掩码
    layer_group: u16 = 0xFFFF,
};

/// 网格碰撞器组件
///
/// 使用网格几何体作为碰撞形状。
/// 注意：网格碰撞器通常只用于静态物体，因为动态网格碰撞计算开销较大。
pub const MeshCollider = struct {
    /// 是否使用附加的 Mesh 组件作为碰撞形状
    use_attached_mesh: bool = true,
    /// 是否为触发器
    is_trigger: bool = false,
    /// 碰撞层 ID
    layer_id: u16 = 0,
    /// 碰撞层组掩码
    layer_group: u16 = 0xFFFF,
};

/// 约束类型
///
/// 用于连接两个刚体的物理约束。
pub const ConstraintType = enum(u8) {
    /// 点对点约束（限制两个点的距离）
    point_to_point,
    /// 铰链约束（允许绕轴旋转）
    hinge,
    /// 滑块约束（允许沿轴滑动）
    slider,
    /// 距离约束（保持固定距离）
    distance,
};

/// 约束组件
///
/// 将两个实体通过物理约束连接起来。
pub const Constraint = struct {
    /// 约束类型
    constraint_type: ConstraintType = .point_to_point,
    /// 实体 A 的 ID
    entity_a: EntityId,
    /// 实体 B 的 ID
    entity_b: EntityId,
    /// 在实体 A 局部空间中的约束点
    pivot_a: Vec3 = .{ 0.0, 0.0, 0.0 },
    /// 在实体 B 局部空间中的约束点
    pivot_b: Vec3 = .{ 0.0, 0.0, 0.0 },
    /// 实体 A 的约束轴
    axis_a: Vec3 = .{ 0.0, 1.0, 0.0 },
    /// 实体 B 的约束轴
    axis_b: Vec3 = .{ 0.0, 1.0, 0.0 },
    /// 最小限制（角度或距离）
    min_limit: f32 = 0.0,
    /// 最大限制（角度或距离）
    max_limit: f32 = 0.0,
    /// 是否启用
    is_enabled: bool = true,
};

/// 着色模型
///
/// 定义材质的光照计算方式。
pub const ShadingModel = enum {
    /// 无光照（仅使用基础颜色）
    unlit,
    /// Lambert 漫反射模型
    lambert,
    /// PBR 金属度/粗糙度模型（默认）
    pbr_metallic_roughness,
};

/// 材质组件
///
/// 定义物体表面的视觉属性。
pub const Material = struct {
    /// 材质资源句柄
    handle: ?handles.MaterialHandle = null,
    /// 着色模型
    shading: ShadingModel = .pbr_metallic_roughness,
    /// 基础颜色（RGBA）
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    /// 自发光颜色（RGB）
    emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    /// 金属度（0.0 = 非金属，1.0 = 金属）
    metallic_factor: f32 = 1.0,
    /// 粗糙度（0.0 = 光滑，1.0 = 粗糙）
    roughness_factor: f32 = 1.0,
    /// Alpha 裁剪阈值（用于透明裁剪）
    alpha_cutoff: f32 = 0.5,
    /// 是否双面渲染
    double_sided: bool = false,
};

/// 光源类型
///
/// 定义光源的发光方式。
pub const LightKind = enum {
    /// 方向光（模拟太阳光，无限远，平行光线）
    directional,
    /// 点光源（向所有方向发光，如灯泡）
    point,
    /// 聚光灯（锥形发光区域，如手电筒）
    spot,
};

/// 光源组件
///
/// 使实体成为光源，照亮场景中的其他物体。
pub const Light = struct {
    /// 光源类型
    kind: LightKind = .directional,
    /// 光源颜色（RGB）
    color: Vec3 = .{ 1.0, 1.0, 1.0 },
    /// 光源强度
    intensity: f32 = 1.0,
    /// 影响范围（仅点光源和聚光灯）
    range: f32 = 10.0,
};

/// 特效类型
///
/// 内置的粒子特效类型。
pub const VfxKind = enum {
    /// 喷泉效果（粒子向上喷射）
    fountain,
    /// 轨道效果（粒子环绕旋转）
    orbit,
};

/// 特效组件
///
/// 粒子系统配置，用于创建视觉效果。
pub const Vfx = struct {
    /// 特效类型
    kind: VfxKind = .fountain,
    /// 是否循环播放
    looping: bool = true,
    /// 发射速率（粒子/秒）
    emission_rate: f32 = 18.0,
    /// 粒子生命周期（秒）
    particle_lifetime: f32 = 1.25,
    /// 粒子速度
    speed: f32 = 2.2,
    /// 最大粒子数量
    max_particles: u16 = 24,
    /// 发射半径
    radius: f32 = 0.55,
    /// 扩散角度
    spread: f32 = 0.35,
    /// 粒子大小
    size: f32 = 0.12,
    /// 粒子颜色（RGB）
    color: Vec3 = .{ 1.0, 0.58, 0.26 },
};

/// 脚本语言类型
///
/// 支持的脚本编程语言。
pub const ScriptLanguage = enum(u8) {
    /// Zig 语言
    zig,
    /// C# 语言
    csharp,
};

/// 脚本组件 - 附加到实体上运行脚本逻辑
///
/// 允许使用脚本语言编写自定义行为逻辑。
/// 脚本可以访问和修改实体的组件数据。
pub const Script = struct {
    /// 脚本资源句柄
    script_handle: ?handles.ScriptHandle = null,
    /// 脚本语言
    language: ScriptLanguage = .zig,
    /// 脚本实例 ID（运行时分配）
    instance_id: ?u64 = null,
    /// 是否启用
    enabled: bool = true,
    /// 脚本参数（序列化数据）
    parameters: []const u8 = &.{},
};

/// 获取默认特效配置
///
/// 根据特效类型返回预设的参数配置。
///
/// ## 参数
/// - `kind` - 特效类型
///
/// ## 返回
/// 预设的特效配置
pub fn defaultVfx(kind: VfxKind) Vfx {
    return switch (kind) {
        .fountain => .{
            .kind = .fountain,
            .looping = true,
            .emission_rate = 18.0,
            .particle_lifetime = 1.2,
            .speed = 2.6,
            .max_particles = 28,
            .radius = 0.42,
            .spread = 0.38,
            .size = 0.11,
            .color = .{ 1.0, 0.58, 0.26 },
        },
        .orbit => .{
            .kind = .orbit,
            .looping = true,
            .emission_rate = 12.0,
            .particle_lifetime = 1.8,
            .speed = 1.2,
            .max_particles = 20,
            .radius = 0.72,
            .spread = 0.18,
            .size = 0.1,
            .color = .{ 0.42, 0.82, 1.0 },
        },
    };
}

/// 音频源组件
///
/// 使实体成为音频播放源。支持 2D 或 3D 空间音效。
pub const AudioBus = enum(u8) {
    /// 主总线
    master = 0,
    /// 音乐总线
    music = 1,
    /// 音效总线
    sfx = 2,
};

pub const AudioSource = struct {
    /// 音频剪辑资源句柄
    clip_handle: ?handles.AudioClipHandle = null,
    /// 音频剪辑资源路径（用于序列化/持久化）
    clip_asset_path: ?[]const u8 = null,
    /// 输出总线路由
    bus: AudioBus = .sfx,
    /// 音量（0.0 - 1.0）
    volume: f32 = 1.0,
    /// 是否启用 3D 空间音效
    spatial: bool = false,
    /// 是否循环播放
    looping: bool = false,
    /// 是否在启动时自动播放
    play_on_awake: bool = true,
    /// 3D 音效最小距离（仅在 spatial=true 时有效）
    min_distance: f32 = 1.0,
    /// 3D 音效最大距离（仅在 spatial=true 时有效）
    max_distance: f32 = 100.0,
    /// 多普勒因子（0.0 禁用多普勒，1.0 正常）
    doppler_factor: f32 = 1.0,
    /// 运行时语音句柄（不序列化）
    _voice_handle: ?u32 = null,
    /// 是否正在播放
    _is_playing: bool = false,
    /// 是否已经消费过启动时自动播放
    _play_on_awake_consumed: bool = false,
};

/// 音频监听器组件
///
/// 定义 3D 音效的监听点（通常附加到相机）。
/// 场景中应最多有一个活跃的音频监听器。
pub const AudioListener = struct {
    /// 是否启用此监听器
    enabled: bool = true,
};

/// 导航代理组件
///
/// 标记实体参与导航寻路和避障。当 NavSystem 激活时，
/// 拥有此组件的实体会被自动注册到 Detour Crowd 中，
/// 每帧由 crowd simulation 更新其位置。
pub const NavAgent = struct {
    /// 代理半径
    radius: f32 = 0.6,
    /// 代理高度
    height: f32 = 2.0,
    /// 最大加速度
    max_acceleration: f32 = 8.0,
    /// 最大速度
    max_speed: f32 = 3.5,
    /// 移动目标位置（null = 无目标）
    target: ?Vec3 = null,
    /// 运行时 crowd agent 索引（不序列化）
    _crowd_idx: ?u32 = null,
    /// 是否已注册到 crowd（不序列化）
    _registered: bool = false,
};

/// 胶囊碰撞器组件
///
/// 定义胶囊形碰撞区域（常用于角色）。
/// 胶囊由圆柱体加两端半球构成，总高度 = 2 * radius + 2 * half_height。
pub const CapsuleCollider = struct {
    /// 球体半径
    radius: f32 = 0.4,
    /// 圆柱体半高（不含端部球体）
    half_height: f32 = 0.5,
    /// 中心偏移（相对于实体原点）
    center: Vec3 = .{ 0.0, 0.0, 0.0 },
    /// 是否为触发器
    is_trigger: bool = false,
    /// 碰撞层 ID
    layer_id: u16 = 0,
    /// 碰撞层组掩码
    layer_group: u16 = 0xFFFF,
};

/// 角色控制器组件
///
/// 基于 Jolt CharacterVirtual，为角色提供步进式碰撞响应、
/// 上坡检测和下楼梯支撑。需要配合 CapsuleCollider 使用。
pub const CharacterController = struct {
    /// 可攀爬的最大坡度（弧度，默认约 50°）
    max_slope_angle: f32 = 0.872,
    /// 最大推力（牛顿）
    max_strength: f32 = 100.0,
    /// 与地面的间距（防止 z-fighting）
    padding: f32 = 0.02,
    /// 质量（千克）
    mass: f32 = 70.0,
    /// 期望速度（每帧由逻辑层设置）
    move_velocity: Vec3 = .{ 0.0, 0.0, 0.0 },
    /// 上方向（通常为 Y+）
    up_direction: Vec3 = .{ 0.0, 1.0, 0.0 },
    /// 是否站在地面上（只读，由物理系统更新）
    is_grounded: bool = false,
};

/// 标签组件
///
/// 为实体附加一个字符串标签，用于游戏逻辑中的分类与查询。
pub const Tag = struct {
    const max_len = 63;
    _buf: [max_len + 1]u8 = [_]u8{0} ** (max_len + 1),

    /// 从切片构建 Tag（超出部分截断）
    pub fn fromSlice(s: []const u8) Tag {
        var t = Tag{};
        const n = @min(s.len, max_len);
        @memcpy(t._buf[0..n], s[0..n]);
        t._buf[n] = 0;
        return t;
    }

    /// 返回标签字符串切片（不含 null 终止符）
    pub fn asSlice(self: *const Tag) []const u8 {
        var len: usize = 0;
        while (len < max_len and self._buf[len] != 0) : (len += 1) {}
        return self._buf[0..len];
    }

    /// 与切片比较是否相等
    pub fn eql(self: *const Tag, other: []const u8) bool {
        return std.mem.eql(u8, self.asSlice(), other);
    }
};

/// 天空/环境组件
///
/// 为场景指定 HDR 环境贴图，控制天空盒渲染和 IBL 光照。
/// 场景中最多一个有效 Sky 实体（取第一个）。
pub const Sky = struct {
    pub const max_id_len = 255;
    _asset_id_buf: [max_id_len + 1]u8 = [_]u8{0} ** (max_id_len + 1),

    /// 环境光强度倍率（影响天空盒亮度和 IBL 强度）
    intensity: f32 = 1.0,

    /// 是否启用天空盒渲染
    enabled: bool = true,

    /// 从 asset ID 切片构建（超出部分截断）
    pub fn fromAssetId(s: []const u8) Sky {
        var sky = Sky{};
        const n = @min(s.len, max_id_len);
        @memcpy(sky._asset_id_buf[0..n], s[0..n]);
        sky._asset_id_buf[n] = 0;
        return sky;
    }

    /// 返回 asset ID 切片（不含 null 终止符）
    pub fn assetIdSlice(self: *const Sky) []const u8 {
        var len: usize = 0;
        while (len < max_id_len and self._asset_id_buf[len] != 0) : (len += 1) {}
        return self._asset_id_buf[0..len];
    }
};

/// 行为树组件 — 将行为树挂载到实体上，由 bt_system 每帧驱动。
pub const BehaviorTreeComponent = @import("../behavior/bt_system.zig").BehaviorTreeComponent;

/// 地形组件 — 引用一个 Terrain 实例（由 Renderer 持有）。
pub const TerrainComponent = struct {
    /// 地形世界大小 (X, Z).
    world_size: [2]f32 = .{ 256, 256 },
    /// 高度图分辨率 (width = height).
    resolution: u32 = 128,
    /// 最大高度.
    max_height: f32 = 50,
    /// 是否启用.
    enabled: bool = true,
};

/// 网络身份组件 — 标记实体参与网络同步。
pub const NetworkIdentity = @import("../network/net_system.zig").NetworkIdentity;

/// 网络变换组件 — 通过网络同步实体变换，包含插值。
pub const NetworkTransform = @import("../network/net_system.zig").NetworkTransform;

/// RTS 相机组件 — 俯瞰/斜视角相机控制器。
pub const RtsCamera = @import("../camera/rts_camera.zig").RtsCamera;
/// RTS 相机配置。
pub const RtsCameraConfig = @import("../camera/rts_camera.zig").Config;

/// 战争迷雾视野组件 — 挂载在提供视野的实体上。
pub const FogVision = @import("../fog/fog_system.zig").FogVision;
/// 战争迷雾全局配置组件 — 挂载在管理实体上。
pub const FogOfWarConfig = @import("../fog/fog_system.zig").FogOfWarConfig;

// ─────── 经济系统组件 ───────
const economy_mod = @import("../economy/economy_system.zig");
/// 资源储备组件 — 挂载在玩家/基地实体上。
pub const ResourceStorage = economy_mod.ResourceStorage;
/// 资源采集者组件 — 挂载在采集单位上。
pub const ResourceHarvester = economy_mod.ResourceHarvester;
/// 资源节点组件 — 挂载在矿山/树木等可采集物上。
pub const ResourceNode = economy_mod.ResourceNode;
/// 供给提供者组件 — 挂载在房屋/基地等建筑上。
pub const SupplyProvider = economy_mod.SupplyProvider;
/// 供给消费者组件 — 挂载在需要人口的单位上。
pub const SupplyConsumer = economy_mod.SupplyConsumer;
/// 生产队列组件 — 挂载在生产建筑上。
pub const ProductionQueue = economy_mod.ProductionQueue;
/// 交易报价组件 — 挂载在市场建筑上。
pub const TradeOffer = economy_mod.TradeOffer;
