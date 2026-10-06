import Testing
import GuavaUIDevTools

@Test
func timingPublisherKeepsSkippedFramesDistinctFromPresentedFrames() {
    let publisher = TimingPublisher()
    var frames: [TimingFramePayload] = []
    publisher.record(layoutMs: 1, drawMs: 2, presentMs: 0, totalMs: 3, nodeCount: 4, batchCount: 1)
    publisher.deliver = { frames.append($0) }
    publisher.record(layoutMs: 1, drawMs: 2, presentMs: 1, totalMs: 4, nodeCount: 4, batchCount: 1)
    publisher.record(layoutMs: 1, drawMs: 2, presentMs: 0, totalMs: 3, nodeCount: 4, batchCount: 1, presented: false)
    #expect(frames.map(\.frame) == [1, 2])
    #expect(frames.map(\.presented) == [true, false])
    #expect(frames[1].presentMs == 0 && frames[1].drawMs == 2)
}
