import EngineKernel
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import Testing
#if os(Windows)
import WinSDK
#endif

enum WorkbenchUITestSupport {
    private static let lock = NSRecursiveLock()

    static func setEnvironmentValue(_ value: String?, for key: String) -> Bool {
        #if os(Windows)
        return key.withCString(encodedAs: UTF16.self) { name in
            if let value {
                return value.withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW(name, $0) }
            }
            return SetEnvironmentVariableW(name, nil)
        }
        #else
        if let value { return setenv(key, value, 1) == 0 }
        return unsetenv(key) == 0
        #endif
    }

    static func withEnvironment<T>(_ work: (InteractionRegistry, FocusChain) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let fontPath = ["/System/Library/Fonts/Helvetica.ttc",
                        "C:\\Windows\\Fonts\\segoeui.ttf",
                        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
            .first { FileManager.default.fileExists(atPath: $0) }
        let atlas = FontAtlas(width: 512, height: 512)
        atlas.loadFont(path: try #require(fontPath), size: 12)
        let shaper = TextShaper()
        if let face = atlas.freetypeFace { shaper.setFont(ftFace: face, size: 12) }
        let previousText = TextEnvironmentHolder.current
        let previousRegistry = InteractionRegistryHolder.current
        let previousFocus = FocusChainHolder.current
        let registry = InteractionRegistry()
        let focus = FocusChain()
        TextEnvironmentHolder.current = TextEnvironment(
            atlas: atlas, shaper: shaper, atlasTextureID: 1,
            defaultLineHeight: 16, defaultColor: .black,
            defaultFont: .system(size: 12),
            fontResolver: TextFontResolver(primaryFontName: "Arial", atlas: atlas))
        InteractionRegistryHolder.current = registry
        FocusChainHolder.current = focus
        defer {
            TextEnvironmentHolder.current = previousText
            InteractionRegistryHolder.current = previousRegistry
            FocusChainHolder.current = previousFocus
        }
        return try work(registry, focus)
    }

    static func firstNode(_ root: Node?, matching predicate: (Node) -> Bool) -> Node? {
        guard let root else { return nil }
        if predicate(root) { return root }
        for child in root.children {
            if let node = firstNode(child, matching: predicate) { return node }
        }
        return nil
    }

    static func named(_ name: String, in root: Node?) throws -> Node {
        try #require(firstNode(root) { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
    }

    static func activate(_ name: String, in root: Node?, registry: InteractionRegistry) throws {
        let subtree = try named(name, in: root)
        let button = try #require(firstNode(subtree) { registry.handlers(for: $0).key != nil })
        let handler = try #require(registry.handlers(for: button).key)
        #expect(handler(KeyEvent(scancode: 40, keycode: 0, modifiers: [], isRepeat: false), .target) == .handled)
    }
}
