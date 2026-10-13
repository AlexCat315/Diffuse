import Testing
@testable import GuavaUI

private struct ConsumerView: View {
    @State private var count = 0
    @State private var name: TextBuffer = "Guava"

    var body: some View {
        Column {
            Text("Hello, \(name.stringValue)")
            TextField("Name", text: $name)
            Button("Count: \(count)") { count += 1 }
        }.padding(20)
    }
}

@Test func applicationDefaultsAreIdleAndConfigurationGroupsAreIndependent() {
    let original = ApplicationConfiguration()
    #expect(original.frames.policy == .eventDriven)
    #expect(original.rendering.vsync)
    let customized = ApplicationConfiguration(title: "Consumer") {
        $0.window.showsDockIcon = false
        $0.typography.fontSize = 18
        $0.frames.targetRate = 120
    }
    #expect(customized.window.title == "Consumer")
    #expect(customized.frames.validatedTargetRate == 120)
    #expect(customized.rendering.sampleCount == original.rendering.sampleCount)
    #expect(original.window.showsDockIcon)
    _ = ConsumerView()
}

@Test func invalidFrameRatesUseTheDisplayCadence() {
    for value in [Double.nan, .infinity, 0, -1] {
        let config = ApplicationConfiguration { $0.frames.targetRate = value }
        #expect(config.frames.validatedTargetRate == nil)
    }
    #expect(ApplicationConfiguration { $0.frames.targetRate = 1000 }.frames.validatedTargetRate == 240)
}
