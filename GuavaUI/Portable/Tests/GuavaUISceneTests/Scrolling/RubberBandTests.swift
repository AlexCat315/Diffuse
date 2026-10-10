import Testing
import GuavaUIScene

@Suite struct RubberBandTests {

    @Test("First point past the bound travels at the configured compliance")
    func initialSlope() {
        let first = RubberBand.project(overscroll: 1, extent: 100, compliance: 0.55)
        #expect(abs(first - 0.55) < 0.01)

        // A stiffer band moves proportionally less.
        let stiff = RubberBand.project(overscroll: 1, extent: 100, compliance: 0.2)
        #expect(stiff < first)
    }

    @Test("Growth is monotonic but always shorter than the viewport extent")
    func saturatesBelowExtent() {
        var previous: Float = -1
        for raw in stride(from: 0 as Float, through: 2_000, by: 50) {
            guard raw > 0 else { continue }
            let visible = RubberBand.project(overscroll: raw, extent: 120, compliance: 0.55)
            #expect(visible > previous)
            #expect(visible < 120)
            previous = visible
        }
    }

    @Test("Compression is symmetric around both bounds")
    func symmetric() {
        let down = RubberBand.project(overscroll: 60, extent: 100, compliance: 0.55)
        let up = RubberBand.project(overscroll: -60, extent: 100, compliance: 0.55)
        #expect(down > 0)
        #expect(up == -down)
    }

    @Test("No viewport or zero compliance leaves nothing to stretch against")
    func degenerateInputs() {
        #expect(RubberBand.project(overscroll: 40, extent: 0, compliance: 0.55) == 0)
        #expect(RubberBand.project(overscroll: 0, extent: 100, compliance: 0.55) == 0)
        #expect(RubberBand.project(overscroll: 40, extent: 100, compliance: 0) == 0)
    }

    @Test("Unproject inverts project, including near the asymptote")
    func unprojectIsTheInverse() {
        for raw in [1, 5, 40, 120, 400] as [Float] {
            let visible = RubberBand.project(overscroll: raw, extent: 150, compliance: 0.55)
            let recovered = RubberBand.unproject(visibleOverscroll: visible,
                                                 extent: 150,
                                                 compliance: 0.55)
            #expect(abs(recovered - raw) < 0.01)
        }
    }

    @Test("Unproject refuses displacements the curve can never reach")
    func unprojectBeyondAsymptote() {
        #expect(RubberBand.unproject(visibleOverscroll: 0, extent: 100, compliance: 0.55) == 0)
        #expect(RubberBand.unproject(visibleOverscroll: 100, extent: 100, compliance: 0.55) == 0)
        #expect(RubberBand.unproject(visibleOverscroll: 140, extent: 100, compliance: 0.55) == 0)
    }

    @Test("Excess reports the signed overflow of both bounds")
    func excess() {
        #expect(RubberBand.excess(of: -12, maximum: 100) == -12)
        #expect(RubberBand.excess(of: 40, maximum: 100) == 0)
        #expect(RubberBand.excess(of: 112, maximum: 100) == 12)
    }
}
