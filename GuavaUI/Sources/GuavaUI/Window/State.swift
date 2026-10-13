import GuavaUIRuntime
import PlatformShell

@MainActor
final class MainWindowState {
    var drawableW: UInt32 = 0
    var drawableH: UInt32 = 0
    var logicalW: UInt32 = 0
    var logicalH: UInt32 = 0
    var didInstallRoot = false
    var lastFrameTime: Double = 0
    var isVSyncEnabled = true
    let mainWindowChromeHitTestCollector = WindowChromeHitTestCollector()
    var lastMainWindowChromeHitTest: WindowChromeHitTest?
}
