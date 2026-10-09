import Foundation
import GuavaUIRuntime
import CardBattleRuntime

/// Main-thread observable model that bridges `BattleHUDSnapshot` to the
/// GuavaUI reactive system. Observers are notified synchronously on `update`.
public final class BattleHUDModel: _ObservableObject {
    private let publisher = _ObservablePublisher<BattleHUDModel>()

    public private(set) var snapshot: BattleHUDSnapshot

    public init(snapshot: BattleHUDSnapshot) {
        self.snapshot = snapshot
    }

    public func update(_ snapshot: BattleHUDSnapshot) {
        self.snapshot = snapshot
        publisher.send()
    }

    public func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable {
        publisher.register(on: self, handler: handler)
    }

    public func _unregisterObserver(_ token: AnyHashable) {
        publisher.unregister(token)
    }
}
