import EditorCore
import Foundation

enum HierarchySearchDirection {
    case previous
    case next
}

/// Deterministic hierarchy derivations kept outside the view so search,
/// selection, and batch-operation behavior can be tested without rendering.
enum HierarchyPanelModel {
    static func allEntityIDs(in roots: [EditorSceneNode]) -> [UInt64] {
        roots.flatMap { node in
            [node.id] + allEntityIDs(in: node.children)
        }
    }

    static func matchingEntityIDs(in roots: [EditorSceneNode], query: String) -> [UInt64] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return allEntityIDs(in: roots) }
        return roots.flatMap { node -> [UInt64] in
            let own = node.name.range(of: needle, options: .caseInsensitive) == nil
                ? []
                : [node.id]
            return own + matchingEntityIDs(in: node.children, query: needle)
        }
    }

    static func searchDestination(in matchingIDs: [UInt64],
                                  currentID: UInt64?,
                                  direction: HierarchySearchDirection) -> UInt64? {
        guard !matchingIDs.isEmpty else { return nil }
        guard let currentID,
              let currentIndex = matchingIDs.firstIndex(of: currentID) else {
            return direction == .next ? matchingIDs.first : matchingIDs.last
        }
        switch direction {
        case .previous:
            return matchingIDs[(currentIndex - 1 + matchingIDs.count) % matchingIDs.count]
        case .next:
            return matchingIDs[(currentIndex + 1) % matchingIDs.count]
        }
    }

    static func descendantIDs(of selectedIDs: Set<UInt64>,
                              in roots: [EditorSceneNode],
                              includesSelection: Bool = false) -> Set<UInt64> {
        var result = includesSelection ? selectedIDs : []

        func walk(_ node: EditorSceneNode, isInsideSelection: Bool) {
            let selectedHere = selectedIDs.contains(node.id)
            let includeChildren = isInsideSelection || selectedHere
            if isInsideSelection {
                result.insert(node.id)
            }
            for child in node.children {
                walk(child, isInsideSelection: includeChildren)
            }
        }

        for root in roots {
            walk(root, isInsideSelection: false)
        }
        return result
    }

    static func ancestorIDs(of entityID: UInt64,
                            in roots: [EditorSceneNode]) -> [UInt64] {
        func find(_ nodes: [EditorSceneNode], path: [UInt64]) -> [UInt64]? {
            for node in nodes {
                if node.id == entityID { return path }
                if let hit = find(node.children, path: path + [node.id]) {
                    return hit
                }
            }
            return nil
        }
        return find(roots, path: []) ?? []
    }
}
