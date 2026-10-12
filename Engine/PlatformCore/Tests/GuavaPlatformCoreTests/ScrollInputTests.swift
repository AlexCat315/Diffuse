import Foundation
import Testing
import GuavaPlatformCore

@Suite("Scroll input contract")
struct ScrollInputTests {
    @Test("Units are converted once; precise points preserve fractional movement")
    func units() {
        let points = MouseWheelEvent(x: 0.25, y: -12.5, input: .init(unit: .points))
        #expect(points.displacement(lineStep: 30).x == 0.25)
        #expect(points.displacement(lineStep: 60).y == -12.5)
        let lines = MouseWheelEvent(x: 0.5, y: -2)
        #expect(lines.displacement(lineStep: 30).x == 15)
        #expect(lines.displacement(lineStep: 30).y == -60)
        let pages = MouseWheelEvent(x: 1, y: -1, input: .init(unit: .pages))
        #expect(pages.displacement(lineStep: 30, pageWidth: 200, pageHeight: 150).x == 200)
        #expect(pages.displacement(lineStep: 30, pageWidth: 200, pageHeight: 150).y == -150)
    }

    @Test("Full phase metadata survives InputEvent serialization, including a zero end packet")
    func serialization() throws {
        let metadata = ScrollInput(unit: .points, device: .continuous, phase: .ended,
                                   momentumPhase: .began, timestamp: 123.5)
        let input = InputEvent.mouseWheel(.init(x: 0, y: 0, mouseX: 40, mouseY: 60, input: metadata))
        let decoded = try JSONDecoder().decode(InputEvent.self, from: JSONEncoder().encode(input))
        guard case .mouseWheel(let wheel) = decoded else { Issue.record("Missing wheel event"); return }
        #expect(wheel.input == metadata)
        #expect(wheel.mouseX == 40 && wheel.mouseY == 60)
        #expect(wheel.x == 0 && wheel.y == 0)
    }
}
