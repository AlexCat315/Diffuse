# Crystal Rush / 晶体冲刺

用 Guava Engine 的真实 Swift 脚本、输入、实体、灯光和 HUD 实现的小型游戏。源码写入、脚本编译、场景草稿、脚本绑定、场景保存、播放查询和独立导出均已通过真实 `GuavaMCP` stdio 服务执行。

## 试玩

当前机器的导出位于 `export/CrystalRush.app`，双击运行，或在仓库根目录执行：

```bash
open examples/CrystalRush/export/CrystalRush.app
```

- 空格：开始；首次启动不会自动计时。
- WASD：移动；Shift：加速。
- 50 秒内收集 8 块黄绿色晶体，避开红色守卫；碰撞扣除一颗心，短暂闪烁期间免伤。
- 收集完全部晶体获胜，生命耗尽或超时失败。
- R：重开。

当前导出已在 macOS arm64 验证。导出包含编译后的脚本与 Player，运行不需要 Swift 编译器。导出文件、缓存和验证日志不纳入版本控制。

Android ARM64 / Vulkan 真机也已接入。完成 [Android 工具链安装](../../Android/README.md)后，在仓库根目录导出并安装：

```bash
swift run --package-path Android/Tools GuavaAndroid export-game \
  --project examples/CrystalRush \
  --application-id com.guava.game.crystalrush \
  --output Engine/build/android-validation/CrystalRush.apk \
  --install --serial DEVICE_SERIAL
```

屏幕底部提供移动、加速、开始和重开按钮。项目脚本与播放器静态链接，场景、资源和中文 GuavaUI HUD 一起打包；暂停与旋转保留当前游戏会话。`scripts/android/verify-game.py` 验收真实场景绘制、触摸输入和生命周期，Release 与生产签名选项见 Android 接入说明。

## 编辑与重新导出

在仓库根目录启动项目：

```bash
swift run --package-path Editor EditorApp --project-dir "$PWD/examples/CrystalRush"
```

在 Scripts 面板信任此项目后编译 `CrystalRush.swift`，然后播放。场景中保存的是带有稳定脚本 ID 的 `Game Controller`，其 `onStart` 创建完整游戏世界。停止播放恢复编辑场景。

无需模型 API Key 也可以执行完整的 MCP 验证：

```bash
swift build --package-path Editor
swift build --package-path guava-mcp
python3 scripts/check-guava-mcp-protocol.py
python3 scripts/validate-crystal-rush-mcp.py
```

验证脚本会为这个样例启动独立的无窗口编辑器，显式信任样例脚本、确认可撤销的场景草稿，在随机本机端口上通过 MCP 编译和导出，最后让打包后的 Player 模拟 120 帧。完整请求和结果保存在 `validation/mcp-transcript.json`。

玩法测试会重新编译本目录源码，删除临时项目源码后运行编译产物，检验键盘输入、收集胜利、三次受伤失败、超时失败、场地边界和重开：

```bash
swift test --package-path Editor --filter CrystalRushGameplayTests
```

此例使用平面距离判断收集与受伤，没有涵盖引擎所有物理、动画、音频或网络系统。内置 AI 的实际远程推理需要在设置中配置服务商和 Key；样例 MCP 验证不代表远程模型已经连通。
