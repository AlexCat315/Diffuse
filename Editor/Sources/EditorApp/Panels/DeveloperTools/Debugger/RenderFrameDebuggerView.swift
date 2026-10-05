import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

struct RenderFrameDebuggerView: View {
    let frameStats: EditorFrameStats
    let renderStats: RenderFrameStats
    let issues: [DeveloperDiagnosticIssue]
    let onOpenTarget: (DeveloperDiagnosticTarget) -> Void

    var body: some View {
        let passes = makeDeveloperRenderPassBreakdown(renderStats: renderStats)
        ScrollView(.vertical) {
            Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 12) {
                Column(alignment: .leading, spacing: 8) {
                    if !issues.isEmpty {
                        DeveloperIssueQueue(issues: issues,
                                            title: "Render Issues",
                                            onOpenTarget: onOpenTarget)
                    }
                    RenderPipelineSummary(frameStats: frameStats,
                                          renderStats: renderStats)
                }
                .flex(1, shrink: 1, basis: 250)

                RenderPassBreakdownView(passes: passes,
                                        renderStats: renderStats)
                    .flex(1.5, shrink: 1, basis: 360)
            }
            .framePercent(width: 100, minWidth: 0)
            .padding(horizontal: 12, vertical: 10)
        }
    }
}

private struct RenderPipelineSummary: View {
    let frameStats: EditorFrameStats
    let renderStats: RenderFrameStats

    var body: some View {
        Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 12) {
            StatGroup(title: "Frame Encode") {
                StatRow(label: "Render Frame", value: renderStats.frameIndex >= 0 ? "\(renderStats.frameIndex)" : "--")
                StatRow(label: "Prepare", value: formatNs(renderStats.cpuPrepareNS))
                StatRow(label: "Encode", value: formatNs(renderStats.cpuEncodeNS))
                StatRow(label: "Submit", value: formatNs(renderStats.cpuSubmitNS))
                StatRow(label: "Total", value: formatNs(renderStats.cpuFrameTotalNS))
                StatRow(label: "Present", value: formatMs(frameStats.gpuPresentSeconds * 1000))
            }
            .flex(1, shrink: 1, basis: 150)

            StatGroup(title: "Scene Work") {
                StatRow(label: "Passes", value: "\(renderStats.passCount)")
                StatRow(label: "Draw Calls", value: "\(renderStats.drawCallCount)")
                StatRow(label: "Bundles", value: "\(renderStats.renderBundleCount)")
                StatRow(label: "Bundle Jobs", value: "\(renderStats.renderBundleParallelJobs)")
                StatRow(label: "Settings Gen", value: "\(renderStats.settingsGeneration)")
            }
            .flex(1, shrink: 1, basis: 150)

            StatGroup(title: "Deformable Meshes") {
                StatRow(label: "Meshes", value: "\(renderStats.deformableMeshCount)")
                StatRow(label: "Vertices", value: "\(renderStats.deformableVertexCount)")
                StatRow(label: "Triangles", value: "\(renderStats.deformableTriangleCount)")
                StatRow(label: "Upload", value: formatNs(renderStats.deformableUploadNS))
                StatRow(label: "Uploaded", value: formatByteCount(renderStats.deformableUploadedBytes))
                StatRow(label: "Rejected", value: "\(renderStats.deformableRejectedMeshCount)")
            }
            .flex(1, shrink: 1, basis: 175)
        }
    }
}

private struct RenderPassBreakdownView: View {
    let passes: [DeveloperRenderPassInspection]
    let renderStats: RenderFrameStats

    var body: some View {
        Column(alignment: .leading, spacing: 8) {
            Text("Pass Debugger")
                .font(.bodyStrong)
                .foregroundColor(.onSurface)
                .padding(horizontal: 10, vertical: 8)

            if passes.isEmpty {
                StatWrappedValue(label: "Passes", value: "No render pass stats have been reported for this frame.")
            } else {
                Column(alignment: .leading, spacing: 6) {
                    for pass in passes {
                        RenderPassInspectionRow(pass: pass)
                    }
                }
                .padding(horizontal: 8, vertical: 0)
            }

            Box(direction: .row, alignItems: .flexStart, wrap: .wrap, spacing: 12) {
                StatGroup(title: "Shadow") {
                    StatRow(label: "Lights", value: "\(renderStats.shadowedLightCount)")
                    StatRow(label: "Tiles", value: "\(renderStats.shadowTileCount)")
                    StatRow(label: "Cascades", value: "\(renderStats.shadowCascadeCount)")
                    StatRow(label: "Map", value: renderStats.shadowMapResolution > 0 ? "\(renderStats.shadowMapResolution)" : "--")
                    StatRow(label: "Atlas", value: renderStats.shadowAtlasResolution > 0 ? "\(renderStats.shadowAtlasResolution)" : "--")
                }
                .flex(1, shrink: 1, basis: 180)

                StatGroup(title: "GPU Particles") {
                    StatRow(label: "Sim Batches", value: "\(renderStats.gpuParticleSimulationBatchCount)")
                    StatRow(label: "Sim Particles", value: "\(renderStats.gpuParticleSimulationParticleCount)")
                    StatRow(label: "Render Instances", value: "\(renderStats.gpuParticleRenderInstanceCount)")
                    StatRow(label: "Indirect Draws", value: "\(renderStats.gpuParticleIndirectDrawCount)")
                    StatRow(label: "Workgroups", value: "\(gpuParticleWorkgroupTotal(renderStats))")
                    StatRow(label: "Sort Padding", value: formatPercent(
                        renderStats.gpuParticleSortPaddedItemCount - renderStats.gpuParticleSortItemCount,
                        renderStats.gpuParticleSortPaddedItemCount
                    ))
                }
                .flex(1, shrink: 1, basis: 220)
            }
        }
    }
}

private struct RenderPassInspectionRow: View {
    let pass: DeveloperRenderPassInspection

    var body: some View {
        Column(alignment: .leading, spacing: 4) {
            Row(alignment: .center, spacing: 8) {
                Text(pass.name)
                    .lineLimit(1)
                    .font(.bodyStrong)
                    .foregroundColor(.onSurface)
                    .flex(1, shrink: 1)
                Text(formatNs(pass.encodeNS))
                    .lineLimit(1)
                    .font(.mono)
                    .foregroundColor(renderPassEncodeColor(pass.encodeNS))
                Text("\(pass.drawCallCount) draws")
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            }
            Text(pass.signal)
                .lineLimit(1)
                .font(.caption)
                .foregroundColor(.onSurface)
            Text(pass.recommendation)
                .lineLimit(2)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
        }
        .padding(horizontal: 10, vertical: 8)
        .background(.surfaceSunken)
        .cornerRadius(6)
        .border(renderPassEncodeBorder(pass.encodeNS), width: 1)
    }
}
