# 项目脚本

Guava 场景中的脚本绑定使用稳定字符串 ID，而不是仅在当前进程有效的数字句柄。Editor 和 GuavaPlayer 都会加载项目下的 `Scripts/scripts.json`，运行期间每秒检查一次文件变化；有效变更会替换脚本实例并依次触发旧实例的 `onDestroy` 与新实例的 `onStart`。

不创建配置文件也可以直接在 Inspector 的 **Add Component → Script** 中使用内置脚本。每个绑定可选择脚本、启用或禁用、填写 JSON 参数，并可增删多个绑定。缺失 ID 会在 Inspector 显示为 `Missing script`，同时写入 Editor Console 或 GuavaPlayer 标准错误。

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

当前项目目录是声明式脚本 preset 目录，不会在运行时编译任意 Swift 源码。需要原生自定义行为时，可在 Swift 代码中通过 `ScriptRuntime.register(named:_:)` 注册工厂，并在绑定中使用同一个稳定 ID。
