import Testing
import NativeRHI
@testable import RenderBackend

@Suite("ShaderCatalog")
struct ShaderCatalogTests {
    @Test("editor grid follows screen-space lighting and precedes particles")
    func editorGridPassOrdering() throws {
        #expect(!RenderSettings().enableEditorGrid)
        var settings = RenderSettings(enableSSAO: true,
                                      enableSSR: true, enableTAA: true,
                                      enableOffscreenViewport: true)
        #expect(!RenderFramePlanner.makePlan(settings: settings).passes.contains(.editorGrid))
        settings.enableEditorGrid = true
        let passes = RenderFramePlanner.makePlan(settings: settings).passes
        let gridIndex = try #require(passes.firstIndex(of: .editorGrid))
        let particleIndex = try #require(passes.firstIndex(of: .particles))
        #expect(gridIndex < particleIndex)
        #expect(RenderPassKind.opaquePasses.contains(.editorGrid))
        for pass in [RenderPassKind.basePass, .ssao, .ssr] {
            if let index = passes.firstIndex(of: pass) { #expect(index < gridIndex) }
        }
        if let taa = passes.firstIndex(of: .taa) { #expect(gridIndex < taa) }
    }

    @Test("bundled native shader inventory has code and reflected entry points")
    func catalogResolvesPrograms() throws {
        let render = ["editor_grid", "opaque_mesh", "shadow_mesh", "skybox", "tonemap",
            "stylized_character", "outline", "particles", "ssao", "ssr", "taa", "bloom", "fxaa", "ink_paper_post"]
        let compute = ["particle_cull_compact", "particle_simulate", "particle_spawn_append",
            "particle_state_clear", "particle_state_compact", "particle_metadata_reset", "particle_state_finalize",
            "particle_sort_prepare", "particle_sort_bitonic", "particle_sim_to_instance"]
        for api in [GraphicsAPI.metal, .vulkan] {
            for name in render {
                for stage in [ShaderStage.vertex, .fragment] {
                    let shader = try NativeShaderLibrary.artifact(name: name, api: api, stage: stage)
                    #expect(!shader.code.isEmpty)
                    #expect(!shader.entryPoint.isEmpty)
                    #expect(shader.stage == stage)
                }
            }
            for name in compute {
                let shader = try NativeShaderLibrary.artifact(name: name, api: api, stage: .compute)
                #expect(!shader.code.isEmpty)
                #expect(shader.interface.threadgroupSize.x > 0)
            }
        }
    }

    @Test("capability switches assemble the HDR frame graph in the correct order")
    func plannerOrdersHDRPasses() {
        let shadowed = RenderFramePlanner.makePlan(
            settings: RenderSettings(
                enableShadows: true,
                enableOffscreenViewport: true
            )
        )
        let withPost = RenderFramePlanner.makePlan(
            settings: RenderSettings(
                enableFXAA: true,
                enableSSAO: true,
                enableSSR: true,
                enableTAA: true,
                enableBloom: true,
                enableOffscreenViewport: true
            )
        )

        let expectedShadowed: [RenderPassKind] = [.depthPrepass, .shadowPass, .skybox, .basePass, .transparentMeshes, .particles, .tonemap, .viewportResolve]
        let expectedWithPost: [RenderPassKind] = [.depthPrepass, .skybox, .basePass, .ssao, .ssr, .taa, .transparentMeshes, .particles, .bloom, .tonemap, .fxaa, .viewportResolve]

        #expect(shadowed.passes == expectedShadowed)
        #expect(withPost.passes == expectedWithPost)
    }

    @Test("progressive refinement drops SSR only while the opaque scene is moving")
    func motionRefinementDropsSSR() {
        let full: [RenderPassKind] = [.depthPrepass, .skybox, .basePass, .ssao, .ssr, .taa, .transparentMeshes, .particles, .bloom, .tonemap, .viewportResolve]

        // Settled: full quality, SSR present.
        #expect(RenderFramePlanner.motionRefinedPasses(full, opaqueMoving: false) == full)

        // Moving: SSR dropped for responsiveness; every other pass preserved in order.
        let moving = RenderFramePlanner.motionRefinedPasses(full, opaqueMoving: true)
        #expect(!moving.contains(.ssr))
        #expect(moving == full.filter { $0 != .ssr })
        // SSAO and TAA are kept (only SSR is dropped).
        #expect(moving.contains(.ssao))
        #expect(moving.contains(.taa))
    }

    @Test("shadow settings define the renderer shadow contract")
    func shadowSettingsDefineContract() {
        let settings = RenderShadowSettings(
            enabled: true,
            mapResolution: 99,
            depthBias: -0.5,
            strength: 2.0,
            maxShadowedDirectionalLights: -4,
            directionalCascadeCount: 99,
            directionalCascadeSplitLambda: -1
        )

        #expect(settings.enabled)
        #expect(settings.mapResolution == 128)
        #expect(settings.depthBias == 0)
        #expect(settings.strength == 1)
        #expect(settings.maxShadowedDirectionalLights == 0)
        #expect(settings.directionalCascadeCount == 4)
        #expect(settings.directionalCascadeSplitLambda == 0)

        var renderSettings = RenderSettings(
            shadowSettings: .directionalPreview
        )
        #expect(renderSettings.enableShadows)
        renderSettings.enableShadows = false
        #expect(!renderSettings.shadowSettings.enabled)
        #expect(RenderFramePlanner.makePlan(settings: renderSettings).passes == [.depthPrepass, .skybox, .basePass, .transparentMeshes, .particles, .tonemap])
    }

    @Test("stylized character shading schedules outline after base pass")
    func plannerSchedulesStylizedOutline() {
        let plan = RenderFramePlanner.makePlan(
            settings: RenderSettings(
                enableBloom: true,
                enableStylizedCharacterShading: true
            )
        )

        #expect(plan.passes == [.depthPrepass, .skybox, .basePass, .outline, .inkPaperPost, .transparentMeshes, .particles, .bloom, .tonemap])
    }

    @Test("stylized character settings carry card ink style parameters")
    func stylizedCharacterSettingsCarryStyleParameters() {
        let style = StylizedCharacterStyle(
            toonThresholds: .init(0.2, 0.6, 0.0, 0.0),
            toonLevels: .init(0.25, 0.55, 1.0, 0.0),
            inkWashColor: .init(0.8, 0.75, 0.65, 1.0),
            paperGrainStrength: 0.04,
            rimStrength: 0.22,
            materialBiasStrength: 0.09,
            outlineWidth: 0.02
        )
        let settings = RenderSettings(
            enableStylizedCharacterShading: true,
            stylizedCharacterStyle: style
        )

        #expect(settings.enableStylizedCharacterShading)
        #expect(settings.stylizedCharacterStyle == style)
        #expect(RenderSettings().stylizedCharacterStyle == .colorfulInkCard)
    }
}
