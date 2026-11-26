# Crystal Rush / 晶体冲刺

玩法和 HUD 位于 [Scripts/src/lib.rs](Scripts/src/lib.rs)。脚本通过 `diffuse-script-api` 接入 Diffuse 的实体、输入和渲染。保存的场景绑定了稳定的脚本 ID，启动后由 `Game Controller` 建立游戏世界。

- 空格开始，WASD 移动，Shift 加速，R 重开。
- 50 秒内收集 8 块晶体。守卫碰撞扣除一颗心，闪烁期间免伤。
- 集齐晶体获胜，生命耗尽或超时失败。

在仓库根目录编译脚本：

```bash
cargo build --release --manifest-path examples/CrystalRush/Scripts/Cargo.toml
```

运行导出回归测试：

```bash
cargo test -p diffuse-game-runtime crystal_rush_gameplay_tests -- --test-threads=1
```

测试将脚本编译进临时导出，删除临时项目的源码，再从导出的动态库启动游戏，检查输入、胜利、伤害、超时、边界和重开。Android APK 的游戏宿主接线见 [迁移记录](../../.migration/cove-gaps.md#g2-android-host-only-accepts-application-mode-content)。
