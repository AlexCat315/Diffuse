# Guava application

这一项目共享 `Sources/AppContent` 根视图与资源，桌面与 Android 使用同一份业务代码。

先在 Guava SDK 仓库运行 `Tools/Guava/install.sh`，将安装目录的 `bin` 加入 PATH；也可以使用仓库根目录的 `./guava`（Windows 为 `guava.cmd`）。

```sh
guava run                         # 当前主机，默认 Debug
guava build --release              # macOS .app / Windows、Linux 应用目录
guava run --android --device DEVICE_SERIAL
guava build --android --release
guava test
guava clean
```

- `guava.json`：application 管理 ID / 名称，toolchain 管理 SDK 位置，targets 管理平台与桌面产品。移动项目或 SDK 后只需修改 enginePath，或设置 `GUAVA_ENGINE_ROOT`。
- `Sources/AppContent/App.swift`：`makeApplicationContent()` 返回共享 View。
- `Sources/AppContent/Assets`：共享资源；资源测试同时验证打包后的文本可读。
- `Sources/DesktopApp/main.swift`：桌面入口，只调用 `Application.run`。
- `.guava/build`：SwiftPM 缓存与应用产物。`guava clean` 只删除这一生成目录，保留其他 `.guava` 数据。

默认目标为 mac、win、linux、android。桌面构建需要对应主机及 SDK 原生依赖；Android 需要 Swift 6.4.1 release、匹配的 Swift Android SDK、NDK r30、Android SDK 36 / build-tools 36.1.0、JDK 21、CMake 和 Ninja。iOS / Web 应用宿主尚未实现，相关命令会明确报错。

Android Debug 与 Release 均使用相同资源定位规则。未指定签名时 APK 使用开发密钥；生产签名使用环境变量传入密码：

```sh
guava build --android --release \
  --keystore /absolute/path/to/release.keystore --key-alias myapp \
  --store-password-env GUAVA_ANDROID_STORE_PASSWORD \
  --key-password-env GUAVA_ANDROID_KEY_PASSWORD
```

`--output` 可指定产物位置；项目外的输出不由 `guava clean` 删除。CLI 目前生成本地桌面应用与 APK，不提供商店发布、macOS 公证、AAB 或自动热重载。
