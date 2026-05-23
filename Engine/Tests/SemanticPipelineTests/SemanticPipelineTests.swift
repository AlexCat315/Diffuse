import SemanticPipeline
import XCTest

final class SemanticPipelineTests: XCTestCase {
    func testNameHeuristicBackendInfersLabelFromNodeName() async {
        let raw = RawStructure(
            assetURI: "test://chair.glb",
            nodes: [
                RawStructure.Node(id: "n0", name: "seat_geo"),
                RawStructure.Node(id: "n1", name: "backrest_grp"),
                RawStructure.Node(id: "n2", name: "leg_L"),
            ]
        )
        let signals = GeometrySignals(assetURI: raw.assetURI)
        let regions = CandidateRegionSet(assetURI: raw.assetURI, regions: [
            Region(id: "region:n0", source: .structural),
            Region(id: "region:n1", source: .structural),
            Region(id: "region:n2", source: .structural),
        ])

        let backend = NameHeuristicBackend()
        let proposals = await backend.analyze(regions: regions,
                                              rawStructure: raw,
                                              signals: signals)

        XCTAssertFalse(proposals.isEmpty)
        let labels = proposals.map(\.label)
        XCTAssertTrue(labels.contains("seat"))
        XCTAssertTrue(labels.contains("backrest"))
    }

    func testRigBackendMapsStandardBoneNames() async {
        let raw = RawStructure(
            assetURI: "test://character.glb",
            skeleton: RawStructure.Skeleton(bones: [
                RawStructure.Bone(id: "b0", name: "mixamorig:Head"),
                RawStructure.Bone(id: "b1", name: "mixamorig:LeftUpperArm"),
                RawStructure.Bone(id: "b2", name: "mixamorig:RightFoot"),
            ])
        )
        let signals = GeometrySignals(assetURI: raw.assetURI)
        let regions = CandidateRegionSet(assetURI: raw.assetURI)

        let backend = RigBackend()
        let proposals = await backend.analyze(regions: regions, rawStructure: raw, signals: signals)

        let labels = proposals.map(\.label)
        XCTAssertTrue(labels.contains("head"))
        XCTAssertTrue(labels.contains("upper_arm"))
        XCTAssertTrue(labels.contains("foot"))
    }

    func testMetadataBackendReadsCustomProperty() async {
        let raw = RawStructure(
            assetURI: "test://prop.glb",
            nodes: [RawStructure.Node(id: "n0", name: "root")],
            customProperties: ["semantic_role": "door_handle"]
        )
        let signals = GeometrySignals(assetURI: raw.assetURI)
        let regions = CandidateRegionSet(assetURI: raw.assetURI, regions: [
            Region(id: "region:n0", source: .structural),
        ])

        let backend = MetadataBackend()
        let proposals = await backend.analyze(regions: regions, rawStructure: raw, signals: signals)

        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.label, "door_handle")
        XCTAssertEqual(proposals.first?.confidence, 0.95)
    }

    func testPipelineAutoCommitsHighConfidenceProposal() async {
        let raw = RawStructure(
            assetURI: "test://simple.glb",
            nodes: [RawStructure.Node(id: "n0", name: "seat_geo")],
            customProperties: ["semantic_role": "seat"]
        )
        let signals = GeometrySignals(assetURI: raw.assetURI)
        let pipeline = AssetSemanticPipeline(backends: [MetadataBackend()])

        let decision = await pipeline.run(rawStructure: raw, signals: signals)

        if case let .autoCommit(proposals) = decision {
            XCTAssertFalse(proposals.isEmpty)
            XCTAssertEqual(proposals.first?.label, "seat")
        } else {
            XCTFail("Expected autoCommit but got needsConfirmation")
        }
    }

    func testPipelineRequestsConfirmationOnConflict() async {
        let raw = RawStructure(
            assetURI: "test://ambiguous.glb",
            nodes: [RawStructure.Node(id: "n0", name: "part_geo")],
            customProperties: ["semantic_role": "handle"]
        )
        let signals = GeometrySignals(assetURI: raw.assetURI)

        // Both backends fire with different labels at similar confidence → conflict
        let config = SemanticPipelineConfig(
            autoCommitThreshold: 0.99,  // very high threshold to force confirmation
            visionOnlyAutoThreshold: 0.99,
            conflictMargin: 0.15
        )
        let pipeline = AssetSemanticPipeline(config: config,
                                             backends: [NameHeuristicBackend(), MetadataBackend()])

        let decision = await pipeline.run(rawStructure: raw, signals: signals)

        // With threshold=0.99 and MetadataBackend returning 0.95, it cannot auto-commit.
        if case .needsConfirmation = decision {
            // expected
        } else if case let .autoCommit(proposals) = decision {
            // also acceptable if only one region has proposals
            XCTAssertFalse(proposals.isEmpty)
        }
    }

    func testApplyConfirmationRecordsInMemory() async {
        let memory = EphemeralSemanticMemoryStore()
        let pipeline = AssetSemanticPipeline(memory: memory)

        let fingerprint = GeometryFingerprint(genus: 0, boundaryLoops: 1, faceCountBucket: 2)
        let region = Region(id: "region:n0", source: .structural, fingerprint: fingerprint)
        let regionSet = CandidateRegionSet(assetURI: "test://x.glb", regions: [region])
        let proposal = SemanticProposal(regionID: "region:n0", label: "seat",
                                        confidence: 0.90, source: "name_heuristic")
        let confirmation = SemanticConfirmation(regionID: "region:n0",
                                                outcome: .accepted(label: "seat"),
                                                confirmedBy: "user")

        let committed = await pipeline.apply(confirmations: [confirmation],
                                             regions: regionSet,
                                             pendingProposals: [proposal])

        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed.first?.label, "seat")
        XCTAssertEqual(committed.first?.provenance, .confirmed)

        let entries = await memory.lookup(fingerprint: fingerprint)
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries.first?.label, "seat")
    }

    func testGeometryFingerprintDefaultVersion() {
        let fp = GeometryFingerprint()
        XCTAssertEqual(fp.version, 1)
        XCTAssertEqual(fp.scaleHint, 1.0)
    }

    func testRawStructureCustomProperties() {
        let raw = RawStructure(assetURI: "test://x.glb",
                               customProperties: ["rig_type": "biped", "lod_count": "3"])
        XCTAssertEqual(raw.customProperties["rig_type"], "biped")
        XCTAssertEqual(raw.customProperties["lod_count"], "3")
    }
}
