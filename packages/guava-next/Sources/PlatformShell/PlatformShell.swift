public protocol Shell {
    func initializeWindow(title: String)
    func pollEvents()
    func shutdown()
}

public struct MacShell: Shell {
    public init() {}

    public func initializeWindow(title: String) {
        print("[PlatformShell] initialize window: \(title)")
    }

    public func pollEvents() {
        // Placeholder for Cocoa event pump.
    }

    public func shutdown() {
        print("[PlatformShell] shutdown")
    }
}
