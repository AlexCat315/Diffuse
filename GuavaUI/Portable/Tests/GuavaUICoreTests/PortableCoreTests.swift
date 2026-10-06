import Testing
import GuavaUICore

@Test
func bindingWritesInvalidateTheSameStateStorage() {
    let state = State(wrappedValue: 0)
    var writes = 0
    state._setOnChange { writes += 1 }
    let binding = state.projectedValue
    binding.wrappedValue = 3
    #expect(state.wrappedValue == 3)
    #expect(writes == 1)
    state.wrappedValue = 5
    #expect(binding.wrappedValue == 5)
    #expect(writes == 2)
}

@Test
func cachedGeometryKeepsClippingWhenTranslated() {
    let source = DrawList()
    source.pushClip(UIRect(x: 10, y: 10, width: 40, height: 40))
    source.addRect(UIRect(x: 12, y: 14, width: 10, height: 10), color: .white)
    let destination = DrawList()
    destination.append(source, vertexTranslationX: 7, vertexTranslationY: -5)
    #expect(destination.vertices[0].posX == 19)
    #expect(destination.vertices[0].posY == 9)
    #expect(destination.batches[0].scissor == source.batches[0].scissor)
    #expect(destination.indices == source.indices)
}

@Test
func portableGeometryUsesDesktopVertexLayoutAndBatching() {
    #expect(MemoryLayout<UIVertex>.stride == 20)
    let list = DrawList()
    list.addRoundedRect(UIRect(x: 0, y: 0, width: 100, height: 50), radius: 10, color: .white)
    list.addRect(UIRect(x: 120, y: 0, width: 10, height: 10), color: .black)
    #expect(list.batches.count == 1)
    #expect(list.indices.allSatisfy { Int($0) < list.vertices.count })
    #expect(list.batches[0].indexCount == UInt32(list.indices.count))
    #expect(Color(red: 0x12, green: 0x34, blue: 0x56, alpha: 0x78).rgba8 == 0x78563412)
}
