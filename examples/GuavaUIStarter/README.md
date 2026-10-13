# Guava application

共享业务代码与资源在 `Sources/AppContent`。每个启用平台的原生配置和扩展由本项目的 `Platforms` 目录持有；SDK 只提供公共运行时。

```sh
guava run --devtools                   # Debug，自动打开 Inspector
guava run --android --devtools --device DEVICE_SERIAL
guava run --profile                    # Release 优化，保留按需诊断
guava devtools                        # 连接已有会话；多会话时 --session ID
guava build --release
guava build --android --release
guava test
guava clean
```

先在 SDK 仓库运行 `Tools/Guava/install.sh`（Windows 为 install.ps1），将安装目录 bin 加入 PATH；也可直接调用仓库的 guava / guava.cmd。

`guava.json` 是应用 ID、名称、版本、SDK 位置和目标的唯一来源。移动项目或 SDK 后修改 enginePath，或设置 GUAVA_ENGINE_ROOT。设备、端口、认证令牌和运行诊断属于临时会话，不写回配置。

平台定制：

- Android：在 Android Studio 打开 Platforms/Android。app/src/main 的 Manifest、res、Java 扩展和 app/build.gradle.kts 原生依赖由应用持有。Kotlin 扩展需添加对应 Gradle 插件。Gradle 通过 SDK guavaRuntime library 使用公共宿主，按变体准备 Swift 库和资源，再执行标准打包。
- macOS：Info.plist 配置权限说明 / URL schemes，Entitlements.plist 配置权限，Resources/AppIcon.icns 设置图标。公共应用身份和版本由构建提供，避免重复声明。
- Windows：Application.manifest 由 Windows SDK mt.exe 嵌入可执行文件。
- Linux：Application.desktop 配置平台集成；Name / Exec 由构建提供。
- 桌面平台可添加 Sources 目录，其 Swift 代码编译为 PlatformSupport；需要时由 AppContent 按平台条件导入。

构建不会覆盖平台源文件。`.guava/build` 保存生成文件、缓存、产物及开发会话；clean 保留平台工程、其他作者数据和 Package.resolved。项目外 --output 与 SDK 共享缓存不由应用 clean 删除。

Android 需要 Swift 6.4.1 release、匹配 Swift SDK、NDK r30、Android SDK 36 / build-tools 36.1.0、JDK 21、CMake 和 Ninja；Gradle wrapper 负责固定 Gradle / AGP。桌面需要对应主机及 SDK 原生依赖。iOS / Web 完整应用宿主尚未实现。

DevTools 使用动态端口和临时会话令牌。`--no-open` 保留服务但不打开浏览器。Android 使用 ADB 转发，CLI 保持会话，Ctrl+C 后停止应用并清理转发。Profile 使用优化后的 Swift 构建并保留诊断；Release 不启用 CLI 诊断入口。时间线记录 CPU spans，GPU / 实际呈现分析需相应后端测量；Android 目前不提供画面镜像。

未指定签名时 APK 使用 SDK 开发密钥，包括 Release 验证包。生产签名：

```sh
guava build --android --release \
  --keystore /absolute/path/to/release.keystore --key-alias myapp \
  --store-password-env GUAVA_ANDROID_STORE_PASSWORD \
  --key-password-env GUAVA_ANDROID_KEY_PASSWORD
```

这里提供本地构建与运行；公证、安装程序、商店发布和代码热重载仍需要进一步接入。详细工具说明见 SDK 的 Tools/Guava/README.md。
