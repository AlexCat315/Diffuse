import Foundation
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIDevTools
import NativeRHI

public enum AppWindowTitleBarStyle: Sendable, Equatable {
    case standard
    case hiddenInset
}

public enum AppFrameDrivePolicy: Sendable, Equatable {
    /// Redraw when input, state, animations or an explicit request changes the UI.
    case eventDriven
    /// Redraw at display cadence, for games and explicit benchmarks.
    case continuous
}

/// Application defaults are owned by the subsystem that consumes them.
/// Configure only the groups your application needs; native GPU setup is optional.
public struct ApplicationConfiguration: Sendable {
    public struct Window: Sendable {
        public var title = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "GuavaUI"
        public var width: Int32 = 1280
        public var height: Int32 = 720
        public var titleBarStyle = AppWindowTitleBarStyle.standard
        public var showsDockIcon = true
        public init() {}
    }

    public struct Typography: Sendable {
        public var primaryFontName = SystemFontDefaults.primaryFontName
        public var fontSize: Float = 14
        public var lineHeight: Float = 20
        public var scaler = TextScaler.identity
        public init() {}
    }

    public struct Rendering: Sendable {
        public var clearColor = SIMD4<Float>(0.05, 0.06, 0.08, 1)
        public var device = DeviceConfig()
        public var sampleCount: UInt32 = 4
        public var vsync = true
        public init() {}
    }

    public struct Frames: Sendable {
        public var policy = AppFrameDrivePolicy.eventDriven
        public var targetRate: Double? = nil
        public init() {}

        var validatedTargetRate: Double? {
            guard let targetRate, targetRate.isFinite, targetRate > 0 else { return nil }
            return min(240, max(1, targetRate))
        }
    }

    public struct Diagnostics: Sendable {
        public var devTools: DevToolsConfig? = nil
        public var showsPerformanceHUD = false
        public init() {}
    }

    public var window = Window()
    public var typography = Typography()
    public var rendering = Rendering()
    public var frames = Frames()
    public var diagnostics = Diagnostics()

    public init(title: String? = nil, configure: (inout Self) -> Void = { _ in }) {
        if let title { window.title = title }
        diagnostics.devTools = DevToolsConfig.fromEnvironment(appTitle: window.title)
        configure(&self)
    }
}
