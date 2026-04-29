import GuavaUICompose

/// `PanelDescriptor` 的注册表，按 `id` 唯一索引。
///
/// Workspace 通过 `id` 解析 `DockTab.userKey`：注册表里没有匹配项时返回空视图，
/// 避免 dock 布局里残留旧 tab 直接崩溃。注册表本身只持有描述符，不缓存
/// 面板视图实例。
///
/// 线程契约：`PanelRegistry` 不是 actor。所有 `register` / `unregister` / `make`
/// 调用都假设在主线程上完成，与 `View` 物化、`Recomposer.commitAll()` 同一线程。
public final class PanelRegistry {
    private var byID: [String: PanelDescriptor] = [:]
    private var order: [String] = []

    public init() {}

    public init(_ descriptors: [PanelDescriptor]) {
        for d in descriptors {
            register(d)
        }
    }

    /// 注册或覆盖同 id 的描述符。覆盖时保持原有顺序，方便热更新。
    public func register(_ descriptor: PanelDescriptor) {
        if byID[descriptor.id] == nil {
            order.append(descriptor.id)
        }
        byID[descriptor.id] = descriptor
    }

    public func updateDescriptor(id: String,
                                 _ update: (inout PanelDescriptor) -> Void) {
        guard var descriptor = byID[id] else { return }
        update(&descriptor)
        byID[id] = descriptor
    }

    public func unregister(id: String) {
        byID.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    public func descriptor(for id: String) -> PanelDescriptor? {
        byID[id]
    }

    /// 返回与 id 对应的视图；缺失时返回 `EmptyView`，由调用方决定是否提示。
    public func make(_ id: String) -> AnyView {
        guard let descriptor = byID[id] else {
            return AnyView(EmptyView())
        }
        return descriptor.factory()
    }

    public var ids: [String] { order }
    public var descriptors: [PanelDescriptor] { order.compactMap { byID[$0] } }
    public var isEmpty: Bool { byID.isEmpty }
    public var count: Int { byID.count }
}
