import Testing
@testable import RenderBackend

@Suite("ShaderCatalog")
struct ShaderCatalogTests {
    @Test("catalog resolves a WGSL-only shader inventory")
    func catalogResolvesPrograms() throws {
        let catalog = try ShaderCatalog()

        let mesh = try catalog.renderProgram(named: "mesh")
        let stylizedCharacter = try catalog.renderProgram(named: "stylized_character")
        let skybox = try catalog.renderProgram(named: "skybox")
        let tonemap = try catalog.renderProgram(named: "tonemap")
        let fxaa = try catalog.renderProgram(named: "fxaa")
        let ssaoCompute = try catalog.computeProgram(named: "ssao_compute")

        #expect(mesh.vertex == "WGSL/mesh.wgsl")
        #expect(mesh.fragment == "WGSL/mesh.wgsl")
        #expect(stylizedCharacter.vertex == "WGSL/stylized_character.wgsl")
        #expect(skybox.vertex == "WGSL/skybox.wgsl")
        #expect(tonemap.fragment == "WGSL/tonemap.wgsl")
        #expect(fxaa.vertex == "WGSL/fxaa.wgsl")
        #expect(ssaoCompute.compute == "WGSL/ssao_compute.wgsl")

        let meshModule = try catalog.loadWGSLRenderModule(named: "mesh")
        #expect(meshModule.contains("@vertex"))
        #expect(meshModule.contains("@fragment"))
        let stylizedModule = try catalog.loadWGSLRenderModule(named: "stylized_character")
        #expect(stylizedModule.contains("toon_ramp"))

        #expect(catalog.manifest.programs.allSatisfy { $0.vertex.hasPrefix("WGSL/") && ($0.fragment?.hasPrefix("WGSL/") ?? true) })
        #expect(catalog.manifest.computePrograms.allSatisfy { $0.compute.hasPrefix("WGSL/") })
    }

    @Test("r4 and r5 planner order matches the HDR frame graph")
    func plannerOrdersHDRPasses() {
        let r4 = RenderFramePlanner.makePlan(
            settings: RenderSettings(
                stage: .r4LightingPBRShadow,
                enableShadows: true,
                enableOffscreenViewport: true
            )
        )
        let r5 = RenderFramePlanner.makePlan(
            settings: RenderSettings(
                stage: .r5PostProcess,
                enableFXAA: true,
                enableSSAO: true,
                enableSSR: true,
                enableTAA: true,
                enableBloom: true,
                enableOffscreenViewport: true
            )
        )

        let expectedR4: [RenderPassKind] = [.depthPrepass, .shadowPass, .skybox, .basePass, .tonemap, .viewportResolve]
        let expectedR5: [RenderPassKind] = [.depthPrepass, .skybox, .basePass, .ssao, .ssr, .taa, .bloom, .tonemap, .fxaa, .viewportResolve]

        #expect(r4.passes == expectedR4)
        #expect(r5.passes == expectedR5)
    }
}
