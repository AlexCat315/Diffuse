// NativeRHITests — SubmissionPlanner: barrier synthesis, duplicate-transition
// merging, and cross-queue release/acquire splitting.

import XCTest
@testable import NativeRHI

final class SubmissionPlannerTests: XCTestCase {
    private func renderPass(target: Texture) -> RenderPassRecord {
        RenderPassRecord(
            descriptor: RenderPassDescriptor(colorTargets: [
                RenderColorTarget(texture: target),
            ]),
            body: []
        )
    }

    private func barrierBlocks(in submit: PlannedSubmit) -> [[BarrierCommand]] {
        submit.commands.compactMap { command in
            guard case .barriers(let barriers) = command else { return nil }
            return barriers
        }
    }

    // MARK: Single-queue automatic barrier

    func testRenderPassSynthesizesBarrierIntoRenderTarget() throws {
        let planner = SubmissionPlanner()
        let target = Texture(id: 1)
        let plan = try planner.buildPlan(
            queue: .graphics,
            commands: [.renderPass(renderPass(target: target))],
            external: SubmitDescriptor()
        )

        XCTAssertEqual(plan.submits.count, 1)
        let submit = plan.submits[0]
        XCTAssertEqual(submit.queue, .graphics)

        // A barrier block precedes the render pass.
        let blocks = barrierBlocks(in: submit)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].first?.destinationState, .renderTarget)
        XCTAssertEqual(blocks[0].first?.sourceState, [])
    }

    func testRepeatedPassesOfSameResourceEmitSingleBarrier() throws {
        let planner = SubmissionPlanner()
        let target = Texture(id: 1)
        let pass = renderPass(target: target)
        let plan = try planner.buildPlan(
            queue: .graphics,
            commands: [.renderPass(pass), .renderPass(pass)],
            external: SubmitDescriptor()
        )

        let submit = plan.submits[0]
        // [.barriers, .renderPass, .renderPass] — one barrier block, two passes.
        XCTAssertEqual(barrierBlocks(in: submit).count, 1)
        XCTAssertEqual(submit.commands.count, 3)
    }

    // MARK: Cross-queue release / acquire

    func testCrossQueueUseSplitsIntoReleaseAndAcquire() throws {
        let planner = SubmissionPlanner()
        let target = Texture(id: 1)

        // First own the texture on the graphics queue.
        let graphicsPlan = try planner.buildPlan(
            queue: .graphics,
            commands: [.renderPass(renderPass(target: target))],
            external: SubmitDescriptor()
        )
        XCTAssertEqual(graphicsPlan.submits.count, 1)

        // Now consume it on the compute queue through a binding set.
        let setID: UInt32 = 50
        planner.registerBindingSetEntries(
            setID,
            entries: [BindingSetEntry(slot: 0, resource: .texture(target))]
        )
        let computePass = ComputePassRecord(body: [
            .setBindingSet(slot: 0, set: BindingSet(id: setID)),
        ])
        let plan = try planner.buildPlan(
            queue: .compute,
            commands: [.computePass(computePass)],
            external: SubmitDescriptor()
        )

        // Two submits: a release on graphics (signals a timeline) and the
        // compute submit (waits on it).
        XCTAssertEqual(plan.submits.count, 2)
        let release = plan.submits[0]
        let consumer = plan.submits[1]

        XCTAssertEqual(release.queue, .graphics)
        XCTAssertEqual(release.waitSemaphores.count, 0)
        XCTAssertEqual(release.signalSemaphores.count, 1)
        let timelineID = release.signalSemaphores[0].id
        XCTAssertEqual(release.signalSemaphores[0].value, 1)

        XCTAssertEqual(consumer.queue, .compute)
        XCTAssertTrue(consumer.waitSemaphores.contains { $0.id == timelineID })

        // The acquire barrier on the consumer transitions renderTarget -> shaderResource.
        let blocks = barrierBlocks(in: consumer)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].first?.sourceState, .renderTarget)
        XCTAssertEqual(blocks[0].first?.destinationState, .shaderResource)
        XCTAssertEqual(blocks[0].first?.syncAction, .acquire)
    }

    func testExternalSemaphoresAreForwardedToMainSubmit() throws {
        let planner = SubmissionPlanner()
        let target = Texture(id: 1)
        let external = SubmitDescriptor(
            waitSemaphores: [TimelineSemaphore(id: 7, value: 3)],
            signalSemaphores: [TimelineSemaphore(id: 9, value: 4)]
        )
        let plan = try planner.buildPlan(
            queue: .graphics,
            commands: [.renderPass(renderPass(target: target))],
            external: external
        )
        let submit = plan.submits.last
        XCTAssertTrue(submit?.waitSemaphores.contains { $0.id == 7 && $0.value == 3 } ?? false)
        XCTAssertTrue(submit?.signalSemaphores.contains { $0.id == 9 && $0.value == 4 } ?? false)
    }

    // MARK: Same-state storage hazards (orthogonal access layer)

    private func computePassBinding(setID: UInt32) -> ComputePassRecord {
        ComputePassRecord(body: [
            .setBindingSet(slot: 0, set: BindingSet(id: setID)),
        ])
    }

    func testSameStateStorageWawEmitsOrderingBarrier() throws {
        let planner = SubmissionPlanner()
        let buffer = Buffer(id: 1)
        let setID: UInt32 = 30
        planner.registerBindingSetEntries(
            setID,
            entries: [BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: buffer))]
        )
        let pass = computePassBinding(setID: setID)
        let plan = try planner.buildPlan(
            queue: .compute,
            commands: [.computePass(pass), .computePass(pass)],
            external: SubmitDescriptor()
        )

        let submit = plan.submits[0]
        // [.barriers(transition), .computePass, .barriers(ordering), .computePass]
        let blocks = barrierBlocks(in: submit)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(submit.commands.count, 4)
        // The second barrier is an ordering barrier: before == after.
        XCTAssertEqual(blocks[1].first?.sourceState, [.shaderResource, .unorderedAccess])
        XCTAssertEqual(blocks[1].first?.destinationState, [.shaderResource, .unorderedAccess])
        XCTAssertEqual(blocks[1].first?.syncAction, .full)
    }

    func testSameStateReadOnlyRepeatsEmitNoOrderingBarrier() throws {
        let planner = SubmissionPlanner()
        let texture = Texture(id: 1)
        let setID: UInt32 = 31
        planner.registerBindingSetEntries(
            setID,
            entries: [BindingSetEntry(slot: 0, resource: .texture(texture))]
        )
        let pass = computePassBinding(setID: setID)
        let plan = try planner.buildPlan(
            queue: .compute,
            commands: [.computePass(pass), .computePass(pass)],
            external: SubmitDescriptor()
        )

        let submit = plan.submits[0]
        // Only the initial []→shaderResource transition; read-after-read adds none.
        XCTAssertEqual(barrierBlocks(in: submit).count, 1)
        XCTAssertEqual(submit.commands.count, 3)
    }

    func testCrossQueueSameStateStillTransfersOwnership() throws {
        let planner = SubmissionPlanner()
        let buffer = Buffer(id: 1)
        let setID: UInt32 = 32
        planner.registerBindingSetEntries(
            setID,
            entries: [BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: buffer))]
        )
        let pass = computePassBinding(setID: setID)

        _ = try planner.buildPlan(
            queue: .compute,
            commands: [.computePass(pass)],
            external: SubmitDescriptor()
        )
        let plan = try planner.buildPlan(
            queue: .graphics,
            commands: [.computePass(pass)],
            external: SubmitDescriptor()
        )

        // Release on compute + acquire on graphics even though state is unchanged.
        XCTAssertEqual(plan.submits.count, 2)
        let release = plan.submits[0]
        let consumer = plan.submits[1]
        XCTAssertEqual(release.queue, .compute)
        XCTAssertEqual(release.signalSemaphores.count, 1)
        XCTAssertEqual(consumer.queue, .graphics)
        XCTAssertTrue(consumer.waitSemaphores.contains {
            $0.id == release.signalSemaphores[0].id
        })

        let blocks = barrierBlocks(in: consumer)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].first?.sourceState, [.shaderResource, .unorderedAccess])
        XCTAssertEqual(blocks[0].first?.destinationState, [.shaderResource, .unorderedAccess])
        XCTAssertEqual(blocks[0].first?.syncAction, .acquire)
    }
}
