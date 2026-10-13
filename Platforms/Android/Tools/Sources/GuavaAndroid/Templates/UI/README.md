# {{APP_NAME}}

独立 GuavaUI Swift Package。业务代码只需提供普通函数 `makeApplicationContent() -> some View`；Android 宿主负责窗口、Vulkan、字体、触摸、IME 和前后台 / 旋转生命周期。

```sh
swift run DesktopApp
swift android.swift
swift android.swift --install --serial DEVICE_SERIAL
swift android.swift --configuration release --output build/Application-release.apk
```

默认输出为本项目 `build/Application.apk`，旁边的 JSON 记录应用 ID、构建配置、签名类型及源码位置。Swift 6.4.1 release、匹配 Android Swift SDK、NDK r30、Android SDK、JDK 21、CMake 和 Ninja 的准备步骤见 Guava-Engine 的 `Platforms/Android/README.md`。创建、构建、打包和安装均由 Swift 工具完成，无需 Python 或验证脚本。

- `Sources/AppContent/App.swift`：根视图入口及示例状态、按钮、文本输入。可将 `RootView()` 替换为已有共享 UI 模块中的视图，并在 `Package.swift` 声明该模块依赖。
- `guava-android.json`：应用 ID 与显示名称。`--application-id` / `--name` 可临时覆盖，不改写该文件。
- `Sources/AppContent/Assets`：SwiftPM 资源，自动随 APK 安装。使用 `AppResources.bundle` 查找；Release 的资源定位不要使用 SwiftPM 默认 `Bundle.module`。
- `android.swift`：调用引擎的 Swift 构建入口，接受其全部参数。移动此项目或引擎仓库后，可设置 `GUAVA_ENGINE_ROOT=/absolute/path/to/Guava-Engine`，供 launcher 和 SwiftPM 使用。

已有包接入时需要导出名为 `AppContent` 的 library product / module，以及 `public func makeApplicationContent() -> some View`。包目录名称可以自定义。入口在宿主提供的 Compose / 文本环境中调用；不要自行创建 Device、Surface 或事件循环。根视图可以复用桌面组件，但依赖 macOS / Windows 专用 API 的业务模块需要由使用方提供 Android 实现。

Debug 和 Release 默认使用本机开发签名。正式签名传入：

```sh
swift android.swift --configuration release \
  --keystore /absolute/path/to/release.keystore --key-alias myapp \
  --store-password-env GUAVA_ANDROID_STORE_PASSWORD \
  --key-password-env GUAVA_ANDROID_KEY_PASSWORD
```

密码从指定环境变量读取。Release 禁用宿主的调试广播、快照写盘和 Android `debuggable`。

当前导出目标为 arm64-v8a / Android API 28+，GPU 需满足 NativeRHI 的 Vulkan 与时间线信号量要求。暂停和旋转保留存活进程中的根视图状态；进程被系统回收后的业务状态恢复由应用自己实现。系统权限、图标、通知、TalkBack 与 AAB 发布目前需要额外集成。

