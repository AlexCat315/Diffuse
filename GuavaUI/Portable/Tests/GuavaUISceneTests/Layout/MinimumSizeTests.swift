import Foundation
import Testing
import GuavaUIScene

/// Yoga takes a fixed dimension as the flex basis without clamping it to the
/// minimum; a definite-width parent must still grow to the child's minimum.
@Suite("Minimum sizes in definite containers")
@MainActor
struct MinimumSizeTests {
    private func layout(fixedWidth: Bool, configure: (LayoutNode) -> Void) -> (container: CGRect, leaf: CGRect) {
        let root = LayoutNode(); root.flexDirection = .column; root.alignItems = .flexStart
        let container = LayoutNode(); container.flexDirection = .column; container.alignItems = .flexStart
        container.setPadding(16)
        if fixedWidth { container.width = 390 }
        let leaf = LayoutNode(); leaf.width = 18; leaf.height = 18
        configure(leaf)
        root.addChild(container); container.addChild(leaf)
        root.calculateLayout(availableWidth: 600, availableHeight: 400)
        return (container.frame, leaf.frame)
    }

    @Test(arguments: [false, true]) func authoredMinimumGrowsParent(_ fixedWidth: Bool) {
        let frames = layout(fixedWidth: fixedWidth) { $0.minWidth = 44; $0.minHeight = 44 }
        #expect(frames.leaf.size == CGSize(width: 44, height: 44))
        #expect(frames.container.height == 76)
    }

    @Test(arguments: [false, true]) func touchFloorGrowsParent(_ fixedWidth: Bool) {
        let frames = layout(fixedWidth: fixedWidth) { $0.setMinimumSizeFloor(CGSize(width: 44, height: 44)) }
        #expect(frames.leaf.size == CGSize(width: 44, height: 44))
        #expect(frames.container.height == 76)
    }

    @Test func removingFloorRestoresAuthoredSize() {
        let frames = layout(fixedWidth: true) {
            $0.setMinimumSizeFloor(CGSize(width: 44, height: 44)); $0.setMinimumSizeFloor(nil)
        }
        #expect(frames.leaf.size == CGSize(width: 18, height: 18))
        #expect(frames.container.height == 50)
    }
}
