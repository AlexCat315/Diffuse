import EngineKernel
import Foundation

public enum EditorSelectionReducer {
    public static func merge(base: Set<UInt64>,
                             picked: Set<UInt64>,
                             modifiers: KeyModifiers,
                             commandBehavior: SelectionCommandBehavior) -> Set<UInt64> {
        if modifiers.contains(.shift) {
            return base.union(picked)
        }
        if modifiers.contains(.ctrl) || modifiers.contains(.gui) {
            switch commandBehavior {
            case .subtract:
                return base.subtracting(picked)
            case .toggle:
                var next = base
                for item in picked {
                    if next.contains(item) {
                        next.remove(item)
                    } else {
                        next.insert(item)
                    }
                }
                return next
            }
        }
        return picked
    }

    public static func mergeSingle(base: Set<UInt64>,
                                   picked: UInt64?,
                                   modifiers: KeyModifiers,
                                   commandBehavior: SelectionCommandBehavior) -> Set<UInt64> {
        guard let picked else {
            if modifiers.contains(.shift) || modifiers.contains(.ctrl) || modifiers.contains(.gui) {
                return base
            }
            return []
        }
        return merge(base: base,
                     picked: [picked],
                     modifiers: modifiers,
                     commandBehavior: commandBehavior)
    }
}
