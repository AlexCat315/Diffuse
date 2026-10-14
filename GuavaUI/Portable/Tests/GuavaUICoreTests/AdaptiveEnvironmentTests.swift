import Testing
import GuavaUICore

@Test func surfaceAdaptsToSpaceAndInputIndependently() {
    var environment = UIEnvironment()
    #expect(environment.viewport.widthClass == .expanded)
    environment.viewport.width = 390
    #expect(environment.viewport.widthClass == .compact)
    environment.viewport.width = 768
    environment.input = [.touch, .keyboard]
    #expect(environment.viewport.widthClass == .medium)
    #expect(environment.minimumControlExtent == 44)
    environment.input = [.pointer, .keyboard]
    #expect(environment.minimumControlExtent == 28)
}
