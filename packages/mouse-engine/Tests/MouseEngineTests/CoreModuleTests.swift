import XCTest
@testable import MouseEngineCore

final class CoreModuleTests: XCTestCase {
    func testRenderGraphCompileOrder() {
        let graph = RenderGraph()
        graph.addPass(.init(name: "geometry"))
        graph.addPass(.init(name: "post"))
        let plan = graph.compile()
        XCTAssertEqual(plan.orderedPasses.map(\.name), ["geometry", "post"])
    }

    func testAssetRegistryDeduplicatesByPath() {
        let registry = AssetRegistry()
        let a = registry.register(path: "assets/mesh/a.mesh")
        let b = registry.register(path: "assets/mesh/a.mesh")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(registry.count, 1)
    }

    func testSceneManagerLoadAndUnload() {
        let manager = SceneManager()
        let scene = SceneDescriptor(name: "Main", path: "assets/scenes/main.scene")
        manager.load(scene: scene)
        XCTAssertEqual(manager.current, scene)
        manager.unload()
        XCTAssertNil(manager.current)
    }
}
