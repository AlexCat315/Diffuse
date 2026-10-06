---
path: /zh/docs/project-scripting
title: 项目脚本
description: 使用稳定脚本 ID、项目级默认参数和热重载配置 Guava 场景行为。
locale: zh
translationKey: docs.project-scripting
category: 开始
order: 35
kind: doc
---

# 项目脚本

Guava 场景中的脚本绑定使用稳定字符串 ID，而不是仅在当前进程有效的数字句柄。Editor 和 GuavaPlayer 都会加载项目下的 `Scripts/scripts.json`，运行期间每秒检查一次文件变化；有效变更会替换脚本实例并依次触发旧实例的 `onDestroy` 与新实例的 `onStart`。

不创建配置文件也可以直接在 Inspector 的 **Add Component → Script** 中使用内置脚本。每个绑定以独立的行为分组显示，可启用或禁用、打开源码、恢复默认值和移除。点击 **Add Script** 选择要挂载的行为。声明的属性显示为对应类型的控件；原始 JSON 位于折叠的高级参数中。缺失 ID 会在 Inspector 显示为 `Missing script`，同时写入 Editor Console 或 GuavaPlayer 标准错误。

## 项目目录

`Scripts/scripts.json` 可以为内置行为声明项目级别的名称和默认参数：

```json
{
  "schemaVersion": 1,
  "scripts": [
    {
      "id": "game.fast-spin",
      "displayName": "Fast Spin",
      "preset": "rotator",
      "defaultParameters": {
        "speed": [0, 3.14, 0]
      }
    }
  ]
}
```

`id` 只能包含字母、数字、点、下划线和连字符，并且不能与内置或其他项目脚本重复。场景绑定中的参数会覆盖 `defaultParameters` 的同名字段，未覆盖字段仍保留目录默认值。项目导出时该文件会自动复制到便携目录和 `.app` 内。

## 可用 preset

| preset | 常用参数 |
|---|---|
| `rotator` | `speed: [x, y, z]`，弧度/秒 |
| `oscillator` | `axis`、`amplitude`、`frequency` |
| `mover` | `velocity: [x, y, z]` |
| `destroy-after` | `seconds` |
| `follower` | `targetEntityName` 或 `targetEntityID`、`speed`、`arrivalRadius` |
| `look-at` | `targetEntityName` 或 `targetEntityID` |
| `character-controller` | `moveSpeed`、`jumpSpeed`、`crouchAction` |
| `first-person-camera` | `moveSpeed`、`lookSensitivity` |
| `orbit-camera` | `target`、`distance`、`orbitSpeed`、`zoomSpeed`、`minDistance`、`maxDistance` |

内置 ID 使用 `guava.` 前缀，例如 `guava.rotator`、`guava.character-controller`。建议跨场景引用目标时使用 `targetEntityName`；运行时重新加载场景后，数字实体 ID 可能变化。

角色与相机 preset 会自动获得标准输入映射：WASD/方向键移动、Space 跳跃、Control 蹲伏、按住鼠标右键移动视角、滚轮缩放；手柄十字键、南键/东键与右摇杆也有对应映射。原生项目可以用自己的 `InputActionMap` 资源覆盖这些默认值。

`Scripts/*.swift` 可以在 Editor 的 Scripts 面板中编辑和编译。脚本通过 `ScriptRuntime` 的生命周期 API 定义行为：

```swift
import ScriptRuntime

struct GameScript: ScriptBehavior {
  mutating func onStart(_ context: ScriptContext) {
    // 初始化实体相关状态。
  }

  mutating func onUpdate(_ context: ScriptContext) {
    // context.deltaTime 是本帧经过的秒数。
    _ = context.deltaTime
  }
}
```

Editor 启动及场景重载时会重新编译这些源文件，并将其加入 Inspector 的脚本选择列表。项目必须先在 Scripts 面板中被明确标记为可信，才允许编译和运行原生脚本；项目文件不能自行授予信任。`Scripts/scripts.json` 仍用于声明式 preset 和默认参数。

每个文件定义一个 `GameScript: ScriptBehavior` 类型即可。Editor 会生成动态库入口并为每个实体绑定创建独立实例。Editor 需要能在 `PATH` 中找到 Swift 编译器 `swiftc`。

## 声明可编辑的行为属性

Swift 脚本可以同时遵循 `ScriptAuthoring`，通过静态 `definition` 声明可配置属性。构建并加载后，Inspector 为各绑定生成有类型的表单；数字范围、枚举选项、属性分组和默认值都来自同一份定义。

```swift
import ScriptRuntime

struct GameScript: ScriptBehavior, ScriptAuthoring {
  static var definition: ScriptDefinition {
    ScriptDefinition(properties: [
      ScriptProperty("speed", label: "Speed", group: "Movement",
                     defaultValue: .number(5), minimum: 0, maximum: 20),
      ScriptProperty("mode", label: "Mode", defaultValue: .string("walk"),
                     options: [ScriptPropertyOption("walk"), ScriptPropertyOption("run")]),
    ])
  }

  mutating func onUpdate(_ context: ScriptContext) {
    let speed = context.floatParameter("speed") ?? 5
    _ = speed * Float(context.deltaTime)
  }
}
```

默认值依次被项目目录的 `defaultParameters` 和各场景绑定的属性覆盖。场景只保存覆盖值；恢复默认值会清除该绑定的覆盖。定义支持字符串、浮点数、整数、布尔值、三维向量和实体引用。编辑属性沿用场景事务，可以撤销、重做和保存。高级 JSON 中的未知键、错误类型、越界数字或无效枚举会显示参数问题；运行时对无效的已声明属性使用默认值。未声明属性的旧脚本仍可使用高级 JSON，旧场景无需迁移。

属性定义从动态库的独立元数据入口读取，不会为了显示 Inspector 而启动脚本或创建行为实例。尚未构建、源码尚未应用、等待热重载和运行中的状态分别显示。源码入口会定位对应的项目脚本。

原生宿主使用 `runtime.register(behavior: MyBehavior.self, named: "game.my-behavior")` 注册有 authoring 定义的行为；回调工厂可以通过 `register(named:definition:_:)` 显式传入定义。动态库必须包含工厂和属性元数据两个入口；更新引擎后重新构建脚本产物。不声明属性的行为会导出空定义。

CrystalRush 示例公开游戏标题、回合时长、初始生命、启动模式、移动速度和冲刺速度。这些属性参与实际玩法与 HUD；运行时创建的对象归属 Game Controller，并在行为销毁时清理，避免热重载遗留重复场景对象。

## 导出自定义玩法

macOS 和 Linux 的项目导出会重新编译 `Scripts/*.swift`，把动态库写入 `Scripts/Compiled/`，并生成 `Scripts/compiled-scripts.json`。目录记录稳定脚本 ID、重命名前的兼容别名、目标平台/架构和产物校验和。Player 启动时加载这些预编译库，每个绑定仍获得独立实例，玩家机器无需安装 Swift 编译器或保留脚本源文件。

导出使用当前宿主平台和架构，脚本 SDK、Swift 工具链与 GuavaPlayer 必须来自兼容的引擎构建。开发构建会从可执行文件旁发现 Engine 模块；独立安装的 SDK 可以由宿主设置 `GUAVA_ENGINE_MODULE_PATHS`、`GUAVA_ENGINE_CLANG_MODULE_MAP_PATHS`、`GUAVA_ENGINE_CLANG_INCLUDE_PATHS` 和 `GUAVA_SWIFTC_PATH`。没有 SDK、脚本编译失败、启用的绑定缺失或 Player 无法加载动态库时，导出明确失败，并保留上一次成功导出的游戏。

Windows 当前仍可导出内置 preset；自定义 Swift 脚本导出会报告不支持，等待补齐完整 Swift 宿主符号桥接。脚本按文件独立编译，多文件共享模块和断点调试尚未提供。

可在不打开窗口的情况下验证导出并模拟若干帧：

```bash
GuavaPlayer --validate-project --project /path/to/export --simulation-frames 120
```

## 在脚本中生成对象

`createEntity` 立即返回可配置的实体。`destroyEntity` 和 `destroySelf` 在下一次命令应用阶段执行。

```swift
import SceneRuntime
import ScriptRuntime
import SIMDCompat

struct GameScript: ScriptBehavior {
  mutating func onStart(_ context: ScriptContext) {
    let entity = context.createEntity(
      named: "Bullet",
      transform: LocalTransform(translation: SIMD3<Float>(0, 1, 0))
    )
    context.setComponent(
      Collider(shape: .sphere(radius: 0.15, center: .zero)),
      for: entity
    )
  }
}
```

原生宿主可用 `Prefab.captureFull(from:root:)` 捕获包含稳定脚本绑定的模板，再用 `prefab.instantiateFull(into:)` 创建实例；也可以把 `Prefab` 存入场景资源后，由脚本通过 `context.instantiate(prefab, parent: context.entity)` 创建实例。层级与组件会被恢复，各实例的脚本状态相互独立。新实体不会插入正在遍历的脚本列表，其行为在之后的执行阶段启动。普通 `Prefab.capture` 继续只捕获 SceneRuntime 组件。
