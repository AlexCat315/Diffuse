# iOS / iPadOS

`guava build . --ios` 构建 iOS Simulator 应用，`guava run . --ios --simulator UDID` 安装并启动。`guava devices --ios` 列出模拟器和连接的设备。真机使用 `--device ID --team APPLE_TEAM_ID`，由 Xcode 自动签名。

需要 macOS、完整 Xcode、CMake、Ninja。内容与其他平台共用 `Sources/AppContent`。使用 `guava build . --ios` 或 `guava run . --ios` 构建和启动；CLI 负责原生依赖及 Xcode 工程配置。
