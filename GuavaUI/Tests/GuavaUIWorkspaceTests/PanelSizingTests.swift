import XCTest
import GuavaUICompose
@testable import GuavaUIWorkspace

final class PanelSizingTests: XCTestCase {
    func testSizingDefaultsNormalizationAndDocumentRoundTrip() throws {
        let invalid = WorkspaceAxisSizing(minimum: -10, preferred: .infinity, maximum: .nan)
        XCTAssertEqual(invalid, .init())
        XCTAssertEqual(WorkspaceAxisSizing(minimum: 100, preferred: 10, maximum: 80),
                       .init(minimum: 100, preferred: 100, maximum: 100))
        let decoded = try JSONDecoder().decode(WorkspacePanelSizing.self,
            from: Data(#"{"width":{"minimum":180,"preferred":500,"maximum":320}}"#.utf8))
        XCTAssertEqual(decoded.width, .init(minimum: 180, preferred: 320, maximum: 320))
        XCTAssertEqual(decoded.height, .init())
        let panel = WorkspacePanel(id: "inspector", title: "Inspector", sizing: decoded)
        let descriptor = WorkspacePanelDescriptor(id: "inspector", title: "Inspector", sizing: decoded) { EmptyView() }
        XCTAssertEqual(descriptor.panel, panel)
        let document = WorkspaceDocument(panels: [panel.id: panel],
            groups: ["inspector": .init(id: "inspector", panels: [panel.id])],
            slots: WorkspaceSlot.standardEditorSlots(trailing: .group("inspector")))
        let data = try JSONEncoder().encode(document)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceDocument.self, from: data), document)
        XCTAssertNil(document.splitFractions.leading)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("measuredExtent"))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(panel)) as? [String: Any])
        fields.removeValue(forKey: "sizing")
        fields.removeValue(forKey: "isClosable")
        let missing = try JSONDecoder().decode(WorkspacePanel.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(missing.sizing, .init())
        XCTAssertTrue(missing.isClosable)
    }

    func testInactiveTabsNestedSplitsAndCollapsedGroupsOwnTheirBounds() {
        var document = WorkspaceDocument(panels: [
            "a": .init(id: "a", title: "A", sizing: .init(width: .init(minimum: 100, maximum: 500))),
            "b": .init(id: "b", title: "B", sizing: .init(width: .init(minimum: 220, maximum: 350))),
            "c": .init(id: "c", title: "C", sizing: .init(width: .init(minimum: 80, maximum: 200))),
        ], groups: ["ab": .init(id: "ab", panels: ["a", "b"], activePanelID: "a"),
                    "c": .init(id: "c", panels: ["c"])], slots: [
            .center: .init(id: .center, layout: .split(axis: .horizontal, fraction: 0.5,
                first: .group("ab"), second: .group("c")))])
        let sizing = WorkspaceSizingResolver(document: document)
        XCTAssertEqual(sizing.group("ab", axis: .horizontal), .init(minimum: 220, maximum: 350))
        XCTAssertEqual(sizing.slot(.center, axis: .horizontal), .init(minimum: 312, maximum: 562))
        XCTAssertEqual(sizing.slot(.center, axis: .vertical).minimum, 34)
        document.groups["c"]?.isCollapsed = true
        XCTAssertEqual(WorkspaceSizingResolver(document: document).slot(.center, axis: .horizontal),
                       .init(minimum: 220, maximum: 350))
    }

    func testFloatingFramesUseThePanelBoundsAndPersistTheClampedSize() {
        let panel = WorkspacePanel(id: "inspector", title: "Inspector", sizing: .init(
            width: .init(minimum: 200, preferred: 260, maximum: 320),
            height: .init(minimum: 120, preferred: 180, maximum: 240)))
        let document = WorkspaceDocument(panels: [panel.id: panel],
            groups: ["inspector": .init(id: "inspector", panels: [panel.id])],
            slots: WorkspaceSlot.standardEditorSlots(trailing: .group("inspector")))
        let controller = WorkspaceController(document: document)
        _ = controller.dispatch(.floatGroup("inspector", windowID: "float", frame: .init(width: 900, height: 900)))
        XCTAssertEqual(controller.document.floatingWindows.first?.frame.width, 320)
        XCTAssertEqual(controller.document.floatingWindows.first?.frame.height, 304)
        _ = controller.dispatch(.moveFloatingWindow("float", frame: .init(width: 160, height: 120)))
        XCTAssertEqual(controller.document.floatingWindows.first?.frame.width, 200)
        XCTAssertEqual(controller.document.floatingWindows.first?.frame.height, 184)
    }

    func testSplitMaximumsAndImpossibleBoundsAreDeterministic() {
        let constraints = SplitConstraints(fraction: 0...1, minimumFirst: 100, minimumSecond: 150,
            maximumFirst: 260, maximumSecond: 360)
        let feasible = constraints.range(available: 500)
        XCTAssertEqual(feasible.lowerBound, 0.28, accuracy: 0.00001)
        XCTAssertEqual(feasible.upperBound, 0.52, accuracy: 0.00001)
        XCTAssertEqual(constraints.range(available: 100), 0.4...0.4)
        let extra = constraints.range(available: 1000)
        XCTAssertEqual(extra.lowerBound, 260 / 620, accuracy: 0.00001)
        XCTAssertEqual(extra.lowerBound, extra.upperBound)
        XCTAssertFalse(WorkspaceController(document: .init(panels: [:], groups: [:], slots: [:]))
            .dispatch(.resizeSplit("leading", fraction: .nan)).didChange)
    }
}
