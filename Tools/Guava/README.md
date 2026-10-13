# Guava CLI

`guava` 是整个 SDK 的应用工具入口。它依赖 Swift 标准库 / Foundation 和轻量 Android 启动契约，不链接 GuavaUI、Editor 或引擎二进制。平台后端位于 `Sources/GuavaCLI/Platforms`，应用创建、项目模型和命令解析属于工具本身。

在 SDK 仓库中可直接使用 `./guava`，Windows 使用 `guava.cmd`。macOS / Linux 安装独立命令：

```sh
Tools/Guava/install.sh                 # 默认 ~/.local/bin
# 或 Tools/Guava/install.sh /chosen/prefix
export PATH="$HOME/.local/bin:$PATH"
guava --help
```

Windows 可执行 `Tools/Guava/install.ps1`（默认 `%LOCALAPPDATA%\Guava\bin`），再将该目录加入 PATH。安装命令连同模板资源包一起复制。当前 SDK 仍来自源码 checkout，工具在编译时记录来源；移动 / 分发 SDK 时设置 `GUAVA_ENGINE_ROOT` 或在项目 `guava.json` 中指定 enginePath。尚无预编译 SDK 下载器。

```sh
guava create app MyApp --id com.example.myapp --name 'My App'
cd MyApp
guava run                             # 当前桌面主机 + Debug
guava build --mac --release            # 在 macOS 主机生成 .app
guava build --win --release            # 在 Windows 主机生成应用目录
guava build --linux --release          # 在 Linux 主机生成应用目录
guava run --android --device DEVICE_SERIAL
guava build --android --release
guava test
guava clean
```

也可从任意目录执行 `guava build /path/to/MyApp --android --release`。Debug / Release 是互斥选项，默认 Debug；平台选项互斥，默认当前主机。平台参数支持 mac、win、linux、android、ios、web；iOS / Web 尚无完整应用宿主，选择时立即报出缺失能力。当前只在匹配主机构建桌面目标，Android 交叉编译主机支持 macOS / Linux。

`guava.json` 是应用元数据的唯一来源：

```json
{
  "application": { "id": "com.example.myapp", "name": "My App" },
  "toolchain": { "enginePath": "../Guava-Engine" },
  "targets": {
    "platforms": ["mac", "win", "linux", "android"],
    "desktopProduct": "DesktopApp"
  }
}
```

SwiftPM 的 `Package.swift` 描述模块、资源和测试；模板直接读取该 manifest 的 SDK 路径。`AppContent` 提供共享 View，DesktopApp 只负责调用 Application.run，Android 平台宿主由 CLI 选择。同一项目不需要另写 android.swift 或维护 Android 专用身份配置。Editor 也提供 guava.json，可执行 `./guava build Editor --mac` / `./guava run Editor --mac`；Editor 当前仅声明桌面目标。

构建缓存和默认产物统一位于项目 `.guava/build`。`clean` 验证项目后只清理此目录，保留源文件、Package.resolved 和其他 `.guava` 作者数据；SDK 共享的原生依赖缓存不属于应用清理范围。项目外 `--output` 也不会被清理。桌面打包复制可执行文件和 SwiftPM 资源包；这里提供本地运行产物，未包含公证、安装程序或商店发布。

`guava test` 在主机运行应用 SwiftPM 单元测试，支持 `--filter TEST`，不是 Android / iOS 仪器测试。`guava doctor --android` 检查 Swift 6.4.1、Swift SDK、NDK r30、Android SDK 36 / build-tools 36.1.0、JDK 工具和原生构建命令；`guava devices` 列出 ADB 设备。桌面原生依赖的 checkout 初始化仍由仓库 bootstrap.py 负责。

Android 签名参数和运行边界见 [Android 文档](../../Platforms/Android/README.md)。框架验收用 `guava showcase gallery --android`；游戏打包用 `guava export game PROJECT --android --id com.example.game`。`internal android-compile` 只供仓库验证脚本调用，业务应用不需要使用。

```sh
swift test --package-path Tools/Guava
python3 scripts/check-module-boundaries.py
```
