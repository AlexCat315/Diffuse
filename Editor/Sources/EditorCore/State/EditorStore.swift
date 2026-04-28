import Foundation
import GuavaUIRuntime

/// 编辑器状态的可观察容器。
///
/// 把 `EditorState` 与 `EditorReducer` 包成一个 store 风格的对象：
/// 调用方只通过 `dispatch(_:)` 改写状态，并通过 `subscribe(_:)` 监听变化。
/// `version` 单调递增，每次 dispatch 后 +1，UI 层用它驱动 `@State` 失效。
///
/// 与 `DockController` 同样的线程契约：所有 API 假设在主线程上调用，
/// 内部不加锁。`@unchecked Sendable` 仅用于穿过 nonisolated 闭包，
/// 调用方不应把这个对象交给后台线程。
public final class EditorStore: @unchecked Sendable {
    public private(set) var state: EditorState
    public private(set) var version: UInt64 = 0

    public struct SubscriptionToken: Hashable, Sendable {
        let raw: UInt64
    }

    private var subscribers: [SubscriptionToken: (EditorStore) -> Void] = [:]
    private var nextSubscriberID: UInt64 = 0

    public init(state: EditorState = EditorState()) {
        self.state = state
    }

    public func dispatch(_ action: EditorAction) {
        EditorReducer.reduce(state: &state, action: action)
        version &+= 1
        for handler in subscribers.values {
            handler(self)
        }
    }

    @discardableResult
    public func subscribe(_ handler: @escaping (EditorStore) -> Void) -> SubscriptionToken {
        nextSubscriberID &+= 1
        let token = SubscriptionToken(raw: nextSubscriberID)
        subscribers[token] = handler
        return token
    }

    public func unsubscribe(_ token: SubscriptionToken) {
        subscribers.removeValue(forKey: token)
    }
}

extension EditorStore: _ObservableObject {
    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable {
        let token = subscribe { _ in handler() }
        return AnyHashable(token)
    }

    public func _unregisterObserver(_ tok: AnyHashable) {
        guard let token = tok.base as? SubscriptionToken else { return }
        unsubscribe(token)
    }
}

extension EditorStore {
    public var connected: Bool { state.connected }
    public var sceneRevision: UInt64 { state.sceneRevision }
    public var frameIndex: UInt64 { state.frameIndex }
    public var selectedEntityID: UInt64? { state.selectedEntityID }
    public var selectedEntityIDsCount: Int { state.selectedEntityIDs.count }
    public var aiStatusMessage: String? { state.aiStatusMessage }
    public var playbackState: PlaybackState { state.playbackState }
    public var workspaceMode: EditorWorkspaceMode { state.workspaceMode }
    public var activeLayoutPreset: EditorLayoutPreset { state.activeLayoutPreset }
    public var themeMode: EditorThemeMode { state.themeMode }
}
