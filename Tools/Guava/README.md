# Guava CLI

新电脑安装流程见 [创建第一个应用](../../docs/getting-started.md)。安装器登记源码 SDK；`guava sdk install/use/list` 管理用户选择，`guava setup` 准备目标工具链，`doctor` 汇总缺项和安装方法。

`guava` 管理跨平台应用的创建、构建、运行、测试和开发会话。平台后端位于工具内部；业务代码不需要操作渲染设备、JNI 或诊断服务器。

## 安装与使用

已有源码 checkout 时无需下载 SDK，也无需先安装全局命令。从仓库根运行：

```sh
./guava doctor --mac
./guava setup --mac
./guava run GuavaUI/Examples --mac   # 组件 Gallery
./guava run Editor --mac             # GuavaStudio 工作站
./guava create app /path/to/MyApp
./guava run /path/to/MyApp --mac
```

在 `GuavaUI` 目录使用 `../guava run Examples --mac`。`GuavaUI` 本身是框架包，`run` 的目录必须包含应用的 `guava.json`。入口脚本用 Swift 构建并运行同一 checkout 的 CLI；需要 Swift 6.4.1。仓库移动或改名后若旧预编译缓存报路径不匹配，可从仓库根执行 `swift package --package-path Tools/Guava clean`。

若使用 Swiftly，但当前 shell 优先找到系统 Swift，可设置 `export GUAVA_SWIFT_EXECUTABLE="$HOME/.swiftly/bin/swift"`，再运行 `./guava doctor --mac`。也可以将它设置为已安装的 Swift 6.4.1 编译器绝对路径；源码入口和 CLI 的后续构建都会使用这个选择。

Windows 使用 `guava.cmd`。希望在任意目录输入 `guava` 时，安装独立命令：

```sh
Tools/Guava/install.sh                 # ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"
# Windows: Tools/Guava/install.ps1      # %LOCALAPPDATA%\Guava\bin
```

```sh
guava create app MyApp --id com.example.myapp --name 'My App'
# 或只创建需要的平台工程：--platforms mac,android
cd MyApp
guava run --devtools                   # 默认 Debug，自动连接 Inspector
guava run --android --devtools --device DEVICE_SERIAL
guava run --profile                    # 优化构建，开启诊断服务；按需采集
guava devtools                        # 连接当前项目的运行会话
guava build --android --release
guava test
guava clean
```

也可以从其他目录执行 `guava run /path/to/MyApp --mac --devtools`。平台选项互斥，默认当前主机；Debug / Profile / Release 互斥，默认 Debug。桌面需要对应主机，Android 交叉构建支持 macOS / Linux。Web 完整应用宿主尚未接入，CLI 会明确报错。

## 应用所有权

`guava.json` 管理公共身份、版本、SDK 路径和目标：

```json
{
  "application": { "id": "com.example.myapp", "name": "My App" },
  "version": { "name": "0.1.0", "build": 1 },
  "toolchain": { "enginePath": "../GuavaStudio" },
  "targets": {
    "platforms": ["mac", "win", "linux", "android", "ios"]
  }
}
```

- `Sources/AppContent`：共享业务视图与资源。
- 桌面启动包由 CLI 生成在 `.guava/build/desktop/launcher`；模板无需单独的可执行目标。
- `Platforms/Android`：应用自己的 Gradle 工程、Manifest、图标、Java/Kotlin 扩展和原生依赖。
- `Platforms/iOS`：应用自己的 Xcode 工程，使用同一 AppContent 和 SDL/UIKit 宿主。
- `Platforms/macOS`：Info.plist、Entitlements.plist、原生资源；可添加 Sources。
- `Platforms/Windows`：应用 manifest、原生资源；可添加 Sources。
- `Platforms/Linux`：desktop 集成配置、原生资源；可添加 Sources。
- `.guava/build`：生成文件、Swift / Gradle 缓存、打包产物与临时开发会话。

只生成启用平台的目录。构建不会改写应用的原生文件。公共身份/版本只在 guava.json 维护，Gradle 和桌面打包器从中读取；不要在 Info.plist / desktop 文件再声明由构建提供的字段。

桌面平台的 Sources（如果存在）编译成 PlatformSupport 模块，供 AppContent 按平台条件导入。macOS Resources/AppIcon.icns 自动作为图标，其他资源复制到应用包；entitlements 用于本地 ad-hoc 签名，Debug/Profile 自动允许调试器附加。Windows 使用 SDK 的 mt.exe 嵌入 Application.manifest；Linux 生成含 Name / Exec 的 .desktop 文件。Windows、Linux 的应用目录仍需对应主机验证和后续分发安装流程。

## Android 原生工程

打开 Platforms/Android 即可进入 Android Studio。应用模块依赖 SDK 中的 guavaRuntime library：框架 Activity / 输入 / SDL Java 代码由 SDK 持有，应用 Manifest 通过标准合并流程加入框架需求。

Swift 准备任务按 Debug / Profile / Release 分开，生成库和资源到 `.guava/build/android/generated/<mode>`；Gradle 负责 Java 编译、资源、Manifest 合并、变体和 APK 签名打包。CLI 不再自行拼装 APK。Gradle wrapper 固定 8.14，并校验官方发行包 SHA-256；AGP 固定 8.11.1。添加 Kotlin 扩展时，在应用 Gradle 工程应用对应 Kotlin 插件。

Android Studio / Gradle 的 preBuild 会调用 SDK 的 `guava internal android-prepare`，CLI 也使用同一准备实现。命令行 SDK 选择顺序为 --engine-root、GUAVA_ENGINE_ROOT、guava.json；直接使用 Gradle 时可设置 GUAVA_ENGINE_ROOT，其他情况下读取 guava.json。需要 Swift 6.4.1 release、匹配 Android Swift SDK、NDK r30、Android SDK 36 / build-tools 36.1.0、JDK 21、CMake、Ninja。

Swift 6.4.1 Android 构建使用 SwiftPM native 后端，工具在 SDK 缓存中建立绑定选定 NDK 的独立 Swift SDK 视图，显式配置 sysroot、Clang 和静态库搜索路径；不改写已安装 Swift SDK / NDK。该后端目前被 SwiftPM 标为 deprecated，后续迁回默认后端需验证 NDK 环境隔离。

CLI 未指定签名时使用 SDK 开发密钥，包括 Release 验证包。生产签名：

```sh
guava build --android --release \
  --keystore /path/to/release.keystore --key-alias app \
  --store-password-env GUAVA_ANDROID_STORE_PASSWORD \
  --key-password-env GUAVA_ANDROID_KEY_PASSWORD
```

密码通过环境变量交给 Gradle，命令中只有变量名。原生工程可自行配置发布变体、AAB 和签名；CLI 当前默认输出 APK，不代替商店发布流程。

## 开发会话

`run --devtools` 为每个进程生成独立会话和访问令牌，运行时监听 loopback 动态端口并发布实际端点。CLI 自动打开现有 Inspector 并连接；`--no-open` 保留服务而不打开浏览器，便于自动化。

Android 使用启动参数传递临时配置，不依赖电脑环境变量。CLI 建立 ADB 动态端口转发，保持运行会话；应用结束或 Ctrl+C 后清理转发与本地记录。后台/Surface 暂停期间，场景诊断请求仍通过 Android 主线程 Handler 处理。

`guava devtools [directory] --session ID` 可选择已有会话，`--mac` / `--android` 可过滤平台。状态和会话记录都在 `.guava/build/devtools`，不会写回 guava.json 或场景 checkpoint。

Profile 使用 Swift Release 优化并定义 GUAVA_PROFILE，保留诊断服务；Android Profile 允许 ADB 调试访问，普通 Release 不启用此入口。树、时间线和镜像仍按订阅采集。当前时间线是 CPU spans，帧 timing 包括主机渲染提交与等待，不代表 GPU 执行或实际显示 FPS。Android 暂无画面镜像，按 capabilities 隐藏该功能。

Inspector 的源码断点接入现有 VS Code/LLDB 工作流；CLI 尚未提供完整 LLDB 启动/附加编排，也不提供保留状态的代码热重载。

## 清理与验证

`clean` 只删除 .guava/build，保留平台工程、其他 .guava 作者数据和 Package.resolved。SDK 共享原生依赖/Swift SDK 视图缓存、IDE 自己的缓存及项目外 --output 不属于应用清理范围。

```sh
swift test --package-path Tools/Guava
swift run --package-path Tools/Developer guava-dev boundaries
# 已启动带 --devtools 的应用后，验证真实协议及认证：
swift run --package-path Tools/Developer guava-dev validate session /path/to/MyApp mac
swift run --package-path Tools/Developer guava-dev validate session /path/to/MyApp android
```

Editor 也使用 guava.json 和应用自己的平台目录：`./guava run Editor --devtools`。SDK 当前来自源码 checkout，原生依赖初始化仍由 `guava-dev native-bootstrap` 负责；预编译 SDK 下载、公证和商店发布不在本轮工具中。


默认项目包含 `Platforms/iOS/Application.xcodeproj`，与桌面和 Android 共用 AppContent。`guava devices --ios` 列出目标，`guava run MyApp --ios --simulator UDID` 使用模拟器，真机使用 `--device ID --team TEAM_ID`。Xcode 工程通过 CLI 自动设置共享包和原生库路径；依赖构建输出位于 SDK 的 `Engine/build/ios-*/` 与 `GuavaUI/build/ios-*/`，不会替换桌面库。构建需要完整 Xcode、Ninja、CMake 和已安装相应 iOS target 的 Rust。
