import GuavaUIRuntime
import GuavaUIDevTools

@MainActor
struct ApplicationCallbacks {
    let events: PlatformEventBridge
    let tick: ((Double) -> Void)?
    let ready: ((AppDisplayHandle) -> Void)?
}
