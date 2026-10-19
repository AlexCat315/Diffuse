import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Select over enumerations")
struct SelectEnumerationTests {
    private enum Trigger: CaseIterable { case none, death, collision }

    @Test("CaseIterable values become every option, in order, with caller labels")
    func casesBecomeOptions() {
        let plain = Select(selection: .constant(Trigger.none))
        #expect(plain.options.map(\.label) == ["none", "death", "collision"])
        #expect(plain.options.allSatisfy(\.isEnabled) && plain.placeholder == "Select")
        let labeled = Select(selection: .constant(Trigger.death), width: 112) { $0 == .none ? "None" : "\($0)".capitalized }
        #expect(labeled.options.map(\.label) == ["None", "Death", "Collision"])
        #expect(labeled.options.map(\.value) == Trigger.allCases && labeled.width == 112)
    }
}
