# iOS / iPadOS

`guava build . --ios` 构建 iOS Simulator 应用，`guava run . --ios --simulator UDID` 安装并启动。`guava devices --ios` 列出模拟器和连接的设备。真机使用 `--device ID --team APPLE_TEAM_ID`，由 Xcode 自动签名。

需要 macOS、完整 Xcode、CMake、Ninja。内容与其他平台共用 `Sources/AppContent`。UIKit 生命周期由 SDL 接入，绘制使用 Metal。`Application.xcodeproj` 可直接打开；首次构建先运行 SDK 的 `swift run --package-path Tools/Developer guava-dev ios-native`，并设置 CLI 输出的原生依赖环境变量。
