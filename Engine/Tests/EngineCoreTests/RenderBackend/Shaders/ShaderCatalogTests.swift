import Testing
@testable import RenderBackend

@Suite("ShaderCatalog")
struct ShaderCatalogTests {
    @Test("catalog resolves a WGSL-only shader inventory")
    func catalogResolvesPrograms() throws {
        let catalog = try ShaderCatalog()

        let mesh = try catalog.renderProgram(named: "mesh")
        let stylizedCharacter = try catalog.renderProgram(named: "stylized_character")
        let inkPaperPost = try catalog.renderProgram(named: "ink_paper_post")
        let skybox = try catalog.renderProgram(named: "skybox")
        let tonemap = try catalog.renderProgram(named: "tonemap")
        let fxaa = try catalog.renderProgram(named: "fxaa")
        let ssaoCompute = try catalog.computeProgram(named: "ssao_compute")

        #expect(mesh.vertex == "WGSL/mesh.wgsl")
        #expect(mesh.fragment == "WGSL/mesh.wgsl")
        #expect(stylizedCharacter.vertex == "WGSL/stylized_character.wgsl")
        #expect(inkPaperPost.fragment == "WGSL/ink_paper_post.wgsl")
        #expect(skybox.vertex == "WGSL/skybox.wgsl")
        #expect(tonemap.fragment == "WGSL/tonemap.wgsl")
        #expect(fxaa.vertex == "WGSL/fxaa.wgsl")
        #expect(ssaoCompute.compute == "WGSL/ssao_compute.wgsl")

        let meshModule = try catalog.loadWGSLRenderModule(named: "mesh")
        #expect(meshModule.contains("@vertex"))
        #expect(meshModule.contains("@fragment"))
        #expect(meshModule.contains("@group(0) @binding(3) var base_color_texture"))
        #expect(meshModule.contains("@group(0) @binding(4) var<uniform> scene_lights"))
        #expect(meshModule.contains("@group(0) @binding(5) var<uniform> shadow"))
        #expect(meshModule.contains("@group(0) @binding(7) var shadow_texture"))
        #expect(meshModule.contains("fn scene_lighting"))
        #expect(meshModule.contains("fn shadow_visibility"))
        #expect(meshModule.contains("fn shadow_depth_lit"))
        #expect(meshModule.contains("fn shadow_matrix"))
        #expect(meshModule.contains("fn shadow_params"))
        #expect(meshModule.contains("textureSample(base_color_texture"))
        #expect(meshModule.contains("textureSample(shadow_texture"))
        #expect(meshModule.contains("shadow.atlas_params.w"))
        let depthPrepassModule = try catalog.loadWGSLRenderModule(named: "depth_prepass")
        #expect(depthPrepassModule.contains("out.position = u.mvp"))
        #expect(depthPrepassModule.contains("clamp(in.depth, 0.0, 1.0)"))
        let shadowModule = try catalog.loadWGSLRenderModule(named: "shadow_pass")
        #expect(shadowModule.contains("@group(0) @binding(5) var<uniform> shadow_render"))
        #expect(shadowModule.contains("shadow_render.light_view_projection * world"))
        let stylizedModule = try catalog.loadWGSLRenderModule(named: "stylized_character")
        #expect(stylizedModule.contains("toon_ramp"))
        #expect(stylizedModule.contains("@group(0) @binding(1) var<uniform> style"))
        #expect(stylizedModule.contains("@group(0) @binding(3) var base_color_texture"))
        #expect(stylizedModule.contains("@group(0) @binding(4) var<uniform> scene_lights"))
        #expect(stylizedModule.contains("scene_lambert"))
        #expect(stylizedModule.contains("style.params.z"))
        #expect(stylizedModule.contains("textureSample(base_color_texture"))
        let outlineModule = try catalog.loadWGSLRenderModule(named: "outline")
        #expect(outlineModule.contains("style.params.w"))
        let inkPaperPostModule = try catalog.loadWGSLRenderModule(named: "ink_paper_post")
        #expect(inkPaperPostModule.contains("paper_hash"))
        #expect(inkPaperPostModule.contains("style.ink_wash_color"))

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

    @Test("shadow settings define the renderer shadow contract")
    func shadowSettingsDefineContract() {
        let settings = RenderShadowSettings(
            enabled: true,
            mapResolution: 99,
            depthBias: -0.5,
            strength: 2.0,
            maxShadowedDirectionalLights: -4
        )

        #expect(settings.enabled)
        #expect(settings.mapResolution == 128)
        #expect(settings.depthBias == 0)
        #expect(settings.strength == 1)
        #expect(settings.maxShadowedDirectionalLights == 0)

        var renderSettings = RenderSettings(
            stage: .r4LightingPBRShadow,
            shadowSettings: .directionalPreview
        )
        #expect(renderSettings.enableShadows)
        renderSettings.enableShadows = false
        #expect(!renderSettings.shadowSettings.enabled)
        #expect(RenderFramePlanner.makePlan(settings: renderSettings).passes == [.depthPrepass, .skybox, .basePass, .tonemap])
    }

    @Test("stylized character shading schedules outline after base pass")
    func plannerSchedulesStylizedOutline() {
        let plan = RenderFramePlanner.makePlan(
            settings: RenderSettings(
                stage: .r5PostProcess,
                enableBloom: true,
                enableStylizedCharacterShading: true
            )
        )

        #expect(plan.passes == [.depthPrepass, .skybox, .basePass, .outline, .inkPaperPost, .bloom, .tonemap])
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
