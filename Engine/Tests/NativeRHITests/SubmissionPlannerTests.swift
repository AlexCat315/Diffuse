// NativeRHITests — SubmissionPlanner: barrier synthesis, duplicate-transition
// merging, and cross-queue release/acquire splitting.

import XCTest
@testable import NativeRHI

final class SubmissionPlannerTests: XCTestCase {
    func testCachedReadDependenciesKeepUploadQueueWriteAndForgetBoundaries() throws {
        let planner = SubmissionPlanner(), set = BindingSet(id: 50), writer = BindingSet(id: 51)
        let resources = [ResourceRef(kind: .texture, id: 2), ResourceRef(kind: .buffer, id: 3), ResourceRef(kind: .buffer, id: 4)]
        planner.registerBindingSetEntries(set.id, entries: [
            BindingSetEntry(slot: 0, resource: .texture(Texture(id: 2))),
            BindingSetEntry(slot: 1, resource: .uniformBuffer(buffer: Buffer(id: 3))),
            BindingSetEntry(slot: 2, resource: .storageBuffer(buffer: Buffer(id: 4))),
            BindingSetEntry(slot: 3, resource: .sampler(Sampler(id: 5)))], readOnlySlots: [2])
        planner.registerBindingSetEntries(writer.id, entries: [BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: Buffer(id: 4)))])
        let render = RecordedCommand.renderPass(RenderPassRecord(descriptor: RenderPassDescriptor(colorTargets: []),
            body: [.setBindingSet(slot: 0, set: set)]))
        let compute = RecordedCommand.computePass(ComputePassRecord(body: [.setBindingSet(slot: 0, set: set)]))
        for resource in resources { planner.recordImmediateWrite(resource) }
        let first = try planner.buildPlan(queue: .graphics, commands: [render], external: SubmitDescriptor())
        XCTAssertEqual(Set(barrierBlocks(in: first.submits[0]).flatMap { $0 }.map(\.resource)), Set(resources))
        let steady = try planner.buildPlan(queue: .graphics, commands: [render], external: SubmitDescriptor())
        XCTAssertTrue(barrierBlocks(in: steady.submits[0]).isEmpty)
        planner.recordImmediateWrite(resources[2])
        let uploaded = try planner.buildPlan(queue: .graphics, commands: [render], external: SubmitDescriptor())
        XCTAssertEqual(barrierBlocks(in: uploaded.submits[0]).flatMap { $0 }.map(\.resource), [resources[2]])
        let handoff = try planner.buildPlan(queue: .compute, commands: [compute], external: SubmitDescriptor())
        XCTAssertEqual(handoff.submits.count, 2)
        XCTAssertEqual(handoff.submits[0].signalSemaphores, handoff.submits[1].waitSemaphores)
        let acquired = barrierBlocks(in: handoff.submits[1]).flatMap { $0 }
        XCTAssertEqual(Set(acquired.map(\.resource)), Set(resources))
        XCTAssertTrue(acquired.allSatisfy { $0.syncAction == .acquire })
        let written = try planner.buildPlan(queue: .compute, commands: [.computePass(ComputePassRecord(body: [
            .setBindingSet(slot: 0, set: writer)]))], external: SubmitDescriptor())
        XCTAssertEqual(barrierBlocks(in: written.submits[0]).flatMap { $0 }.map(\.destinationState), [.unorderedAccess])
        let reread = try planner.buildPlan(queue: .compute, commands: [compute], external: SubmitDescriptor())
        XCTAssertEqual(barrierBlocks(in: reread.submits[0]).flatMap { $0 }.map(\.destinationState), [.shaderResource])
        planner.forgetResource(resources[0])
        let forgotten = try planner.buildPlan(queue: .compute, commands: [compute], external: SubmitDescriptor())
        XCTAssertEqual(barrierBlocks(in: forgotten.submits[0]).flatMap { $0 }.map(\.resource), [resources[0]])
    }

    func testPresentationRestoresTheExternalStateBeforeImageReuse() throws {
        let planner = SubmissionPlanner(), target = Texture(id: 1)
        _ = try planner.buildPlan(queue: .graphics, commands: [.renderPass(renderPass(target: target))], external: SubmitDescriptor())
        planner.recordPresentation(ResourceRef(kind: .texture, id: target.id))
        let reused = try planner.buildPlan(queue: .graphics, commands: [.renderPass(renderPass(target: target))], external: SubmitDescriptor())
        let barrier = try XCTUnwrap(barrierBlocks(in: reused.submits[0]).first?.first)
        XCTAssertEqual(barrier.sourceState, .present)
        XCTAssertEqual(barrier.destinationState, .renderTarget)
    }

    func testRepeatedRenderBindingsPreservePassAndQueueDependencies() throws {
        let planner = SubmissionPlanner()
        let set = BindingSet(id: 50)
        let storage = Buffer(id: 4)
        planner.registerBindingSetEntries(set.id, entries: [
            BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: Buffer(id: 3))),
            BindingSetEntry(slot: 1, resource: .texture(Texture(id: 2))),
            BindingSetEntry(slot: 2, resource: .storageBuffer(buffer: storage))
        ])
        let pass = RenderPassRecord(descriptor: RenderPassDescriptor(colorTargets: [RenderColorTarget(texture: Texture(id: 1))]),
            body: (0..<100).map { _ in .setBindingSet(slot: 0, set: set) })
        let result = try planner.buildPlan(queue: .graphics, commands: [.renderPass(pass), .renderPass(pass)], external: SubmitDescriptor())
        let blocks = barrierBlocks(in: result.submits[0])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(Set(blocks[0].map(\.resource.id)), [1, 2, 3, 4])
        XCTAssertEqual(blocks[0].filter { $0.resource.id == storage.id }.count, 1)
        XCTAssertEqual(blocks[1].filter { $0.resource.id == storage.id }.count, 1)
        let ordered = try XCTUnwrap(blocks[1].first { $0.resource.id == storage.id })
        XCTAssertEqual(ordered.sourceState, .unorderedAccess)
        XCTAssertEqual(ordered.destinationState, .unorderedAccess)
        let compute = try planner.buildPlan(queue: .compute,
            commands: [.computePass(ComputePassRecord(body: [.setBindingSet(slot: 0, set: set)]))], external: SubmitDescriptor())
        XCTAssertEqual(compute.submits.count, 2)
        XCTAssertEqual(compute.submits[1].waitSemaphores, compute.submits[0].signalSemaphores)
        let acquire = barrierBlocks(in: compute.submits[1]).flatMap { $0 }.filter { $0.syncAction == .acquire }
        XCTAssertEqual(Set(acquire.map(\.resource.id)), [2, 3, 4])
    }

    func testDistinctSetsSharingReadsKeepUploadAndQueueHandoffs() throws {
        let planner = SubmissionPlanner(), buffer = Buffer(id: 1)
        let resource = ResourceRef(kind: .buffer, id: buffer.id)
        planner.recordImmediateWrite(resource)
        let sets = (0..<96).map { BindingSet(id: UInt32(50 + $0)) }
        for (index, set) in sets.enumerated() {
            planner.registerBindingSetEntries(set.id, entries: [
                BindingSetEntry(slot: 0, resource: .uniformBuffer(buffer: buffer)),
                BindingSetEntry(slot: 1, resource: .texture(Texture(id: UInt32(1000 + index))))
            ])
        }
        let pass = RenderPassRecord(descriptor: RenderPassDescriptor(colorTargets: []),
            body: sets.map { .setBindingSet(slot: 0, set: $0) })
        let graphics = try planner.buildPlan(queue: .graphics, commands: [.renderPass(pass)], external: SubmitDescriptor())
        let barriers = barrierBlocks(in: graphics.submits[0]).flatMap { $0 }
        XCTAssertEqual(barriers.count, 97)
        let upload = try XCTUnwrap(barriers.first { $0.resource == resource })
        XCTAssertEqual(upload.sourceState, .copyDestination)
        XCTAssertEqual(upload.destinationState, .constantBuffer)
        let computePass = ComputePassRecord(body: sets.map { .setBindingSet(slot: 0, set: $0) })
        let compute = try planner.buildPlan(queue: .compute, commands: [.computePass(computePass)], external: SubmitDescriptor())
        XCTAssertEqual(compute.submits.count, 2)
        XCTAssertEqual(compute.submits[0].signalSemaphores, compute.submits[1].waitSemaphores)
        let acquired = barrierBlocks(in: compute.submits[1]).flatMap { $0 }
        XCTAssertEqual(acquired.count, 97)
        XCTAssertTrue(acquired.allSatisfy { $0.syncAction == .acquire })
        let writer = BindingSet(id: 200)
        planner.registerBindingSetEntries(writer.id, entries: [BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: buffer))])
        let write = try planner.buildPlan(queue: .compute,
            commands: [.computePass(ComputePassRecord(body: [.setBindingSet(slot: 0, set: writer)]))], external: SubmitDescriptor())
        XCTAssertEqual(barrierBlocks(in: write.submits[0]).first?.first?.destinationState, .unorderedAccess)
    }

    func testSharedReadCollectionResetsAfterWritesAndOtherBufferUses() throws {
        for render in [true, false] {
            let planner = SubmissionPlanner(), buffer = Buffer(id: 1)
            let sets = (0..<5).map { BindingSet(id: UInt32(50 + $0)) }
            for (index, set) in sets.enumerated() {
                planner.registerBindingSetEntries(set.id, entries: [BindingSetEntry(slot: 0,
                    resource: index == 2 ? .storageBuffer(buffer: buffer) : .uniformBuffer(buffer: buffer))])
            }
            let commands: [RecordedCommand]
            if render {
                commands = [.renderPass(RenderPassRecord(descriptor: RenderPassDescriptor(colorTargets: []), body: [
                    .setBindingSet(slot: 0, set: sets[0]), .setVertexBuffer(slot: 0, buffer: buffer, offset: 0),
                    .setBindingSet(slot: 0, set: sets[1]), .setBindingSet(slot: 0, set: sets[2]),
                    .setBindingSet(slot: 0, set: sets[3]), .setBindingSet(slot: 0, set: sets[4])]))]
            } else {
                commands = [.computePass(ComputePassRecord(body: [
                    .setBindingSet(slot: 0, set: sets[0]), .dispatchIndirect(buffer: buffer, offset: 0),
                    .setBindingSet(slot: 0, set: sets[1]), .setBindingSet(slot: 0, set: sets[2]),
                    .setBindingSet(slot: 0, set: sets[3]), .setBindingSet(slot: 0, set: sets[4])]))]
            }
            let plan = try planner.buildPlan(queue: .graphics, commands: commands, external: SubmitDescriptor())
            let barriers = barrierBlocks(in: plan.submits[0]).flatMap { $0 }
            XCTAssertEqual(barriers.map(\.destinationState), [.constantBuffer, render ? .vertexBuffer : .indirectArgument,
                .constantBuffer, .unorderedAccess, .constantBuffer])
        }
    }

    func testResolvedAttachmentGetsWriteBarrierAndCrossQueueDependency() throws {
        let planner = SubmissionPlanner()
        var color = RenderColorTarget(texture: Texture(id: 1), store: false)
        color.resolveTexture = Texture(id: 2)
        let pass = RenderPassRecord(descriptor: RenderPassDescriptor(colorTargets: [color]), body: [])
        let producer = try planner.buildPlan(queue: .graphics, commands: [.renderPass(pass)], external: SubmitDescriptor())
        XCTAssertEqual(Set(barrierBlocks(in: producer.submits[0]).flatMap { $0 }.map(\.resource.id)), [1, 2])
        planner.registerBindingSetEntries(50, entries: [BindingSetEntry(slot: 0, resource: .texture(Texture(id: 2)))])
        let consumer = try planner.buildPlan(queue: .compute, commands: [.computePass(ComputePassRecord(body: [
            .setBindingSet(slot: 0, set: BindingSet(id: 50))]))], external: SubmitDescriptor())
        XCTAssertEqual(consumer.submits.count, 2)
        XCTAssertEqual(consumer.submits[0].queue, .graphics)
        XCTAssertEqual(consumer.submits[1].waitSemaphores, consumer.submits[0].signalSemaphores)
        let acquire = try XCTUnwrap(barrierBlocks(in: consumer.submits[1]).flatMap { $0 }.first { $0.resource.id == 2 })
        XCTAssertEqual(acquire.sourceState, .renderTarget)
        XCTAssertEqual(acquire.destinationState, .shaderResource)
        XCTAssertEqual(acquire.syncAction, .acquire)
    }

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
        XCTAssertEqual(blocks[1].first?.sourceState, .unorderedAccess)
        XCTAssertEqual(blocks[1].first?.destinationState, .unorderedAccess)
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
        XCTAssertEqual(blocks[0].first?.sourceState, .unorderedAccess)
        XCTAssertEqual(blocks[0].first?.destinationState, .unorderedAccess)
        XCTAssertEqual(blocks[0].first?.syncAction, .acquire)
    }
    func testCheckpointRestoresOwnershipAndTimelineValues() throws {
        let planner = SubmissionPlanner()
        let first = CopyPassRecord(body: [.copyBuffer(src: Buffer(id: 1), srcOffset: 0, dst: Buffer(id: 2), dstOffset: 0, size: 16)])
        _ = try planner.buildPlan(queue: .graphics, commands: [.copyPass(first)], external: SubmitDescriptor())
        let rollback = planner.checkpoint()
        let next = CopyPassRecord(body: [.copyBuffer(src: Buffer(id: 2), srcOffset: 0, dst: Buffer(id: 3), dstOffset: 0, size: 16)])
        let abandoned = try planner.buildPlan(queue: .compute, commands: [.copyPass(next)], external: SubmitDescriptor())
        rollback()
        let retried = try planner.buildPlan(queue: .compute, commands: [.copyPass(next)], external: SubmitDescriptor())
        XCTAssertEqual(retried.submits.count, 2)
        XCTAssertEqual(retried.submits.map(\.waitSemaphores), abandoned.submits.map(\.waitSemaphores))
        XCTAssertEqual(retried.submits.map(\.signalSemaphores), abandoned.submits.map(\.signalSemaphores))
        XCTAssertEqual(barrierBlocks(in: retried.submits[0]).first?.first?.sourceState, .copyDestination)
    }
    func testReadOnlyStorageBindingsDoNotIntroduceWriteDependencies() throws {
        let planner = SubmissionPlanner()
        planner.registerBindingSetEntries(20, entries: [BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: Buffer(id: 1)))], readOnlySlots: [0])
        let pass = ComputePassRecord(body: [.setBindingSet(slot: 0, set: BindingSet(id: 20))])
        let first = try planner.buildPlan(queue: .compute, commands: [.computePass(pass)], external: SubmitDescriptor())
        XCTAssertEqual(barrierBlocks(in: first.submits[0]).first?.first?.destinationState, .shaderResource)
        let next = try planner.buildPlan(queue: .compute, commands: [.computePass(pass)], external: SubmitDescriptor())
        XCTAssertEqual(next.submits[0].commands.count, 1)
        XCTAssertTrue(barrierBlocks(in: next.submits[0]).isEmpty)
    }

    func testImmediateUploadToComputeIntroducesTransferWriteHandoff() throws {
        let planner = SubmissionPlanner()
        planner.recordImmediateWrite(ResourceRef(kind: .buffer, id: 1))
        planner.registerBindingSetEntries(20, entries: [BindingSetEntry(slot: 0, resource: .storageBuffer(buffer: Buffer(id: 1)))], readOnlySlots: [0])
        let pass = ComputePassRecord(body: [.setBindingSet(slot: 0, set: BindingSet(id: 20))])
        let plan = try planner.buildPlan(queue: .compute, commands: [.computePass(pass)], external: SubmitDescriptor())
        XCTAssertEqual(plan.submits.count, 2)
        XCTAssertEqual(plan.submits[0].queue, .graphics)
        XCTAssertEqual(barrierBlocks(in: plan.submits[0]).first?.first?.sourceState, .copyDestination)
        XCTAssertEqual(plan.submits[0].signalSemaphores, plan.submits[1].waitSemaphores)
    }

}
