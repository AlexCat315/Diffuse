import EditorCore
import Foundation

enum HierarchySearchDirection {
    case previous
    case next
}

struct HierarchyDropDestination: Equatable {
    let parentID: UInt64?
    let index: Int
}

enum HierarchyDropPosition {
    case before
    case inside
    case after
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

    static func canMoveSelectionToRoot(_ selectedIDs: Set<UInt64>,
                                       in roots: [EditorSceneNode]) -> Bool {
        let topLevelSelection = selectedIDs.filter { entityID in
            !ancestorIDs(of: entityID, in: roots).contains(where: selectedIDs.contains)
        }
        return topLevelSelection.contains { entityID in
            !ancestorIDs(of: entityID, in: roots).isEmpty
        }
    }

    static func dropDestination(for targetID: UInt64,
                                position: HierarchyDropPosition,
                                in roots: [EditorSceneNode]) -> HierarchyDropDestination? {
        guard let target = locateNode(targetID, in: roots) else { return nil }
        switch position {
        case .before:
            return HierarchyDropDestination(parentID: target.parentID,
                                            index: target.index)
        case .inside:
            return HierarchyDropDestination(parentID: target.node.id,
                                            index: target.node.children.count)
        case .after:
            return HierarchyDropDestination(parentID: target.parentID,
                                            index: target.index + 1)
        }
    }

    static func canDrop(entityID sourceID: UInt64,
                        on targetID: UInt64,
                        position: HierarchyDropPosition,
                        in roots: [EditorSceneNode]) -> Bool {
        guard sourceID != targetID,
              let destination = dropDestination(for: targetID,
                                                position: position,
                                                in: roots),
              let source = locateNode(sourceID, in: roots) else {
            return false
        }
        guard let parentID = destination.parentID else { return true }
        return !subtreeContains(parentID, in: source.node)
    }

    private static func locateNode(_ id: UInt64,
                                  in nodes: [EditorSceneNode],
                                  parentID: UInt64? = nil) -> HierarchyNodeLocation? {
        for (index, node) in nodes.enumerated() {
            if node.id == id {
                return HierarchyNodeLocation(node: node,
                                             parentID: parentID,
                                             index: index)
            }
            if let child = locateNode(id, in: node.children, parentID: node.id) {
                return child
            }
        }
        return nil
    }

    private static func subtreeContains(_ id: UInt64,
                                        in node: EditorSceneNode) -> Bool {
        if node.id == id { return true }
        return node.children.contains { subtreeContains(id, in: $0) }
    }

    private struct HierarchyNodeLocation {
        let node: EditorSceneNode
        let parentID: UInt64?
        let index: Int
    }
}
