import GuavaUIRuntime
import PlatformShell

struct PresentationControls {
    var setRuntimeTargetFrameRate: (@MainActor (Double?) -> Void)? = nil
    var setRuntimeFrameRateMode: (@MainActor (PlatformFrameRateMode) -> Void)? = nil
    var setRuntimeVSyncEnabled: (@MainActor (Bool) -> Void)? = nil
    var currentRuntimeDisplayRefreshRate: (@MainActor () -> Double?)? = nil
}

struct MainWindowControls {
    var minimizeMainWindowAction: (@MainActor () -> Void)? = nil
    var maximizeMainWindowAction: (@MainActor () -> Void)? = nil
    var restoreMainWindowAction: (@MainActor () -> Void)? = nil
    var hideMainWindowAction: (@MainActor () -> Void)? = nil
    var showMainWindowAction: (@MainActor () -> Void)? = nil
    var closeMainWindowAction: (@MainActor () -> Void)? = nil
    var mainWindowMaximizedQuery: (@MainActor () -> Bool)? = nil
    var setMainWindowChromeHitTestAction: (@MainActor (WindowChromeHitTest?) -> Void)? = nil
}

struct WindowControls {
    var minimizeWindowByIDAction: (@MainActor (WindowID) -> Void)? = nil
    var maximizeWindowByIDAction: (@MainActor (WindowID) -> Void)? = nil
    var restoreWindowByIDAction: (@MainActor (WindowID) -> Void)? = nil
    var closeWindowByIDAction: (@MainActor (WindowID) -> Void)? = nil
    var windowMaximizedByIDQuery: (@MainActor (WindowID) -> Bool)? = nil
    var showWindowSystemMenuAction: (@MainActor (WindowID, Float, Float) -> Void)? = nil
}

