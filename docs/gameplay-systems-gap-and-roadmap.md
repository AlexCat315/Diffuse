# 游戏系统缺口与路线图

> 基于 2026-06-14 的代码级审计(逐文件阅读,非蓝图)。覆盖动画 / 物理 / 音频 / 粒子 / 脚本五大系统。
> 总路线图见 [roadmap.md](roadmap.md);本文是其中"游戏运行时深度"的细化与勘误。
>
> **重要勘误**:实际物理后端是 **Jolt**(`JoltPhysicsBackend` + `CJoltBridge` C++ FFI + `libJolt.a`),**不是 PhysX**。
> 蓝图里写的多数动画/粒子/音频特性属于"规划",代码里尚未实现。

---

## 总览

| 系统 | 实际完成度 | 状态 |
|------|----------|------|
| 物理 | ~70% | 唯一接近可用;Jolt 真集成,查询走自研、关节缺 2 种 |
| 脚本 | ~35% | 运行时绑定可用,但无编辑器 / LSP / 热重载 / 外部脚本文件 |
| 音频 | ~25% | 能放 WAV + 粗距离衰减;无真 3D、无流式、无多通道 |
| 动画 | ~15% | 只有单 clip 蒙皮播放;混合 / 事件 / IK / morph 全无 |
| 粒子 | ~10% | 仅 CPU 模拟原型,**未接渲染**,屏幕上不可见 |

---

## 1. 动画系统 — ~15%

**相关文件**:[Animation.swift](../Engine/Sources/SceneRuntime/Animation.swift)、[AnimationRuntime.swift](../Engine/Sources/ScriptRuntime/AnimationRuntime.swift)

已实现:
- `AnimationPlayer` 组件(单 clip:clipName / speed / loop / time)
- GLTF clip 评估:TRS 线性插值 + 四元数 slerp + 节点世界矩阵链
- `JointPaletteMap` → `RenderPacket` → GPU 顶点着色器蒙皮(`mesh.wgsl` binding 8)

缺失:
- [ ] **1D / 2D 混合(Blend Space)**
- [ ] **加法动画(additive)**
- [ ] **动画状态机 / 过渡**
- [ ] **动画事件(events)**
- [ ] **根骨骼动画(root motion)**
- [ ] **动画插槽(slots)、后处理钩子**
- [ ] **IK(逆向运动学)**
- [ ] **混合形状 / morph / 面部动画** — `weights` 通道在 `AnimationRuntime.swift` 中直接 `break`,未实现
- [ ] **多目标混合**
- [ ] **多线程评估 / clip 评估 GPU 化** — 当前单线程 CPU(蒙皮在 GPU,评估在 CPU)

> 现状只能"播一个骨骼动画"。让它成为动画系统的核心(混合、状态机、事件、IK)一个都没有。

## 2. 物理系统 — ~70%

**相关文件**:[Physics.swift](../Engine/Sources/SceneRuntime/Physics.swift)、[JoltPhysicsBackend.swift](../Engine/Sources/SceneRuntime/JoltPhysicsBackend.swift)、[SpatialQueries.swift](../Engine/Sources/SceneRuntime/SpatialQueries.swift)、[CharacterController.swift](../Engine/Sources/ScriptRuntime/CharacterController.swift)

已实现:
- Jolt 真集成(submodule + C++ bridge + 静态库 + FFI)
- `PhysicsBackend` 抽象接口(`NullPhysicsBackend` / `JoltPhysicsBackend`)
- 刚体:static / dynamic / kinematic,mass、linear/angular damping、gravityScale、sleep
- 碰撞体:box / sphere / capsule / mesh / convex
- 触发器(`isTrigger` + [TriggerDetection.swift](../Engine/Sources/SceneRuntime/TriggerDetection.swift))
- 碰撞过滤(layerID / layerMask)
- 运动学角色控制器(脚本级)

缺失 / 不足:
- [ ] **不是 PhysX,是 Jolt** — 若产品要求 PhysX,此项为 0
- [ ] **关节只有 4/6**:有 pointToPoint(球形)/ hinge / slider / distance,**缺 fixed(固定) 与 D6**
- [ ] **场景查询是自研、不走 Jolt**:raycast / overlap / sweep 在 `SpatialQueries.swift` 内实现;且 **sweep 仅 AABB 扫描,非任意形状 sweep**
- [ ] **角色控制器是脚本级 kinematic**,非基于 Jolt sweep 的真 CC(无台阶 / 斜坡 / 自动爬升)
- [ ] **Jolt 内部 job system 多线程未确认开启**(物理本身跑在独立 Simulation 线程)

## 3. 音频系统 — ~25%

**相关文件**:[AudioEngine.swift](../Engine/Sources/AudioRuntime/AudioEngine.swift)、[SDL3AudioBackend.swift](../Engine/Sources/AudioRuntime/Backends/SDL3AudioBackend.swift)、[Audio.swift](../Engine/Sources/SceneRuntime/Audio.swift)

已实现:
- `AudioSource` / `AudioListener` 组件
- BGM(循环)/ SFX(一次性)播放
- 按距离的音量衰减 + spatialBlend

缺失:
- [ ] **真 3D 音频**:衰减是写死的线性 `1 - dist/50`;**无声像定位(panning)、无多普勒**
- [ ] **流式 / 实时解压**:`SDL_LoadWAV` 整文件进内存,**仅支持 WAV**(mp3/ogg 在注释里标为 TODO)
- [ ] **多通道 7.1**
- [ ] **分屏多监听器** — `resolveListener` 只取第一个 listener
- [ ] 真实距离模型(线性 / 对数 / 自定义曲线)、衰减半径可配

## 4. 粒子系统 — ~10%

**相关文件**:[Particles.swift](../Engine/Sources/SceneRuntime/Particles.swift)

已实现(CPU 模拟原型):
- `ParticleEmitter` 组件:重力积分、生命周期老化 / 剔除、连续 + 突发发射、确定性 PRNG

缺失:
- [ ] **未接渲染管线** — `ParticleEmitter` 不被任何 RenderBackend / RenderExtraction 消费,**屏幕上看不到粒子**(最关键)
- [ ] **GPU 模拟、多线程 CPU 模拟**
- [ ] **发射器类型** — 仅球形 spawn,无 box / cone / static mesh / skinned mesh
- [ ] **属性分布** — 仅 start→end 线性 lerp,无曲线 / 随机范围
- [ ] **碰撞**(world / plane / depth buffer)
- [ ] **渲染特性**:billboard / 3D 粒子 / 软粒子 / 纹理动画 / 排序
- [ ] **矢量场**

> 当前是孤立的模拟原型,作为可见功能 ≈ 0。

## 5. 脚本系统 — ~35%

**相关文件**:[ScriptRuntime.swift](../Engine/Sources/ScriptRuntime/ScriptRuntime.swift)、[ScriptComponent.swift](../Engine/Sources/ScriptRuntime/ScriptComponent.swift)、[ScriptContext.swift](../Engine/Sources/ScriptRuntime/ScriptContext.swift)

已实现(运行时):
- `Script` 闭包模型(onStart / onTick / onDestroy)
- `ScriptComponent` 绑定(handle + parametersJSON)
- 丰富的 `ScriptContext`:transform / 组件读写 / 输入 / 物理查询 / drawUI
- 内置预设(角色控制器、相机控制器)

缺失(也就是"Swift 脚本 + LSP"的大头):
- [ ] **非外部脚本文件** — 脚本是编译进引擎的 Swift 闭包,用 `register()` 注册,运行时不能加载 `.swift`
- [ ] **无热重载**
- [ ] **无脚本编辑器** — `Editor/Sources` 内无任何脚本相关面板
- [ ] **无 LSP / 语法高亮 / sourcekit 集成**

---

## 路线图

按投入产出排序(G = Gameplay,区别于 roadmap.md 的 M 里程碑)。

### G1 — 粒子接渲染 ✦ 最划算

模拟已写好,只差出图。完成后 10% → 可用。

任务:
- `RenderExtraction` 收集 `ParticleEmitter.particles` → 新增 `ParticleBatch` 进 `RenderPacket`
- `RenderBackend` 新增 billboard 管线(instanced quad + `particles.wgsl`):面向相机、按 size/color 着色、alpha blend
- SimulationThread tick 调用 `advanceParticles(deltaTime:)`(已存在)
- 排序:按到相机距离做 back-to-front(透明正确性)

验收:场景里放一个 emitter,运行模式下看到喷射并随生命周期淡出;FPS 不掉。

### G2 — 动画混合 + 状态机

让角色动画可用。

任务:
- `AnimationGraph` / `BlendTree`:1D 混合(按参数在多 clip 间插值)
- `AnimationStateMachine`:状态 + 过渡条件 + 过渡时长(交叉淡入)
- 加法层(additive)与根骨骼动画(root motion → 驱动 transform)
- 动画事件:在归一化时间点回调脚本
- (后续)IK two-bone solver、morph target(填上 `weights` 分支)

验收:Idle/Walk/Run 随速度参数平滑混合;Jump 状态机过渡;落地事件触发脚本回调。

### G3 — 音频真 3D + 压缩格式

任务:
- 声像定位:按 listener 朝向算左右声道增益(constant-power pan)
- 距离模型:线性 / 对数可选,minDistance / maxDistance 可配(替换写死的 `/50`)
- 多普勒:用 source/listener 相对速度调 pitch
- 解码桥:接 dr_mp3 / stb_vorbis(或 SDL_mixer)支持 mp3/ogg
- (后续)流式加载长 BGM、多监听器(分屏)

验收:移动音源有左右声像与音高变化;能播 mp3/ogg。

### G4 — 物理打磨

任务:
- 补 fixed、D6 关节(bridge + `ConstraintType` + Jolt 映射)
- 形状 sweep(capsule/sphere sweep,走 Jolt query 而非自研 AABB)
- 基于 Jolt CharacterVirtual 的真角色控制器(台阶 / 斜坡 / 自动爬升)
- 确认并开启 Jolt job system 多线程

验收:吊桥(hinge)/ 滑轨(slider)/ 焊接(fixed)demo;角色能上台阶、走斜坡。

### G5 — 脚本创作端(大工程,需单独立项)

当前只有"运行时绑定",创作体验为零。先做技术选型再投入:

- **方案 A(Swift 脚本)**:嵌入 swiftc / sourcekit-lsp,做外部 `.swift` 编译 + 动态加载 + LSP。成本高,热重载难。
- **方案 B(嵌入式脚本语言,推荐评估)**:接 Lua / JS(QuickJS),天生适合热重载,LSP 生态成熟,沙箱安全。需把 `ScriptContext` 暴露为绑定 API。

无论哪种,都要:脚本编辑器面板(`Editor/Sources/EditorApp/panels/ScriptEditorPanel.swift`)+ 语法高亮 + 错误诊断 + 热重载。

验收:在编辑器里改脚本 → 保存 → 运行时立即生效,无需重编引擎。

---

## 优先级速查

| 阶段 | 系统 | ROI | 备注 |
|------|------|-----|------|
| G1 | 粒子 | 最高 | 模拟已就绪,只差渲染 |
| G2 | 动画 | 高 | 角色游戏刚需 |
| G3 | 音频 | 中 | 3D 化 + 格式支持 |
| G4 | 物理 | 中 | 打磨,非阻塞 |
| G5 | 脚本 | 低/大 | 需先做选型,可能改用 Lua/JS |
