// NativeRHI — submission planner.
//
// Swift port of the submission-tracking core from rhi.zig, adapted to the typed
// command model (no byte-stream decode). The planner walks a recorded command
// list and, for each resource usage:
//   * tracks the current resource state (StateTracker) and synthesizes a barrier
//     when a different state is required;
//   * tracks which queue owns each resource, and when a resource is used on a
//     different queue it splits the ownership transfer into a release submit on
//     the source queue (signaling a timeline semaphore) and an acquire on the
//     consumer (waiting on it);
//   * merges repeated transitions of the same resource.
//
// The result is a self-contained `SubmitPlan` the Device executes in order.

import Foundation

final class SubmissionPlanner {
    private struct PendingTransfer {
        let srcQueue: QueueClass
        let dstQueue: QueueClass
        let releasedState: ResourceState
        var semaphore: TimelineSemaphore
    }

    private struct SplitReleaseRequest {
        let resource: ResourceRef
        var srcState: ResourceState
        let srcQueue: QueueClass
        let dstQueue: QueueClass
    }

    private struct QueueTimeline {
        var id: UInt32 = 0
        var nextValue: UInt64 = 0
    }

    private struct Tracking {
        var stateTracker = StateTracker()
        var accessTracker = AccessTracker()
        var resourceQueues: [ResourceRef: QueueClass] = [:]
        var pendingTransfers: [ResourceRef: PendingTransfer] = [:]
        var queueTimelines: [QueueClass: QueueTimeline] = [:]
        var nextTimelineSemaphoreID: UInt32 = 1
    }
    private var tracking = Tracking()
    private struct RegisteredBindings {
        let entries: [BindingSetEntry]
        let readOnlySlots: Set<UInt32>
    }
    private var bindingSetEntries: [UInt32: RegisteredBindings] = [:]

    /// Restore an unsubmitted plan as a value, including queue timeline values.
    func checkpoint() -> () -> Void {
        let previous = tracking
        return { [weak self] in self?.tracking = previous }
    }

    init() {}

    // MARK: Binding set bookkeeping

    func registerBindingSetEntries(_ handleID: UInt32, entries: [BindingSetEntry], readOnlySlots: Set<UInt32> = []) {
        bindingSetEntries[handleID] = RegisteredBindings(entries: entries, readOnlySlots: readOnlySlots)
    }

    func removeBindingSetEntries(_ handleID: UInt32) {
        bindingSetEntries[handleID] = nil
    }

    /// Removes all frontend/planner bookkeeping for a resource being destroyed.
    func forgetResource(_ resource: ResourceRef) {
        tracking.stateTracker.removeResource(resource)
        tracking.accessTracker.removeResource(resource)
        tracking.resourceQueues[resource] = nil
        tracking.pendingTransfers[resource] = nil
    }

    /// Immediate uploads finish on the graphics queue (or write coherent host
    /// storage before it is submitted). Their next GPU reader still needs a
    /// transfer-write dependency and, on another queue, a timeline handoff.
    func recordImmediateWrite(_ resource: ResourceRef) {
        tracking.stateTracker.setCurrentState(resource, .copyDestination)
        tracking.resourceQueues[resource] = .graphics
        tracking.pendingTransfers[resource] = nil
        _ = tracking.accessTracker.observe(ResourceAccess(resource: resource, kind: .write, stage: .transfer), on: .graphics)
    }

    // MARK: Plan entry point

    func buildPlan(
        queue: QueueClass,
        commands: [RecordedCommand],
        external: SubmitDescriptor
    ) throws -> SubmitPlan {
        var mainCommands: [PlannedCommand] = []
        var splitReleases: [SplitReleaseRequest] = []
        var mainWaits: [TimelineSemaphore] = []
        var mainSignals: [TimelineSemaphore] = []

        for command in commands {
            switch command {
            case .accelerationStructureBuild(let build):
                var barriers: [BarrierCommand] = []
                for input in build.inputs {
                    let state: ResourceState = input.kind == .buffer ? .shaderResource : .accelerationStructureRead
                    collect(resource: input, desired: state,
                            access: Self.makeAccess(resource: input, state: state, stage: .compute),
                            scope: .outsidePass, on: queue, barriers: &barriers,
                            splitReleases: &splitReleases, waits: &mainWaits)
                }
                let output = ResourceRef(kind: .accelerationStructure, id: build.structure.id)
                collect(resource: output, desired: .accelerationStructureWrite,
                        access: ResourceAccess(resource: output, kind: .write, stage: .compute),
                        scope: .outsidePass, on: queue, barriers: &barriers,
                        splitReleases: &splitReleases, waits: &mainWaits)
                if !barriers.isEmpty { mainCommands.append(.barriers(barriers)) }
                mainCommands.append(.accelerationStructureBuild(build))

            case .barrier(let barrier):
                if let resolved = try resolveExplicit(
                    barrier,
                    submitting: queue,
                    splitReleases: &splitReleases,
                    waits: &mainWaits,
                    signals: &mainSignals
                ) {
                    mainCommands.append(.barriers([resolved]))
                    try applyExplicit(resolved)
                }

            case .renderPass(let record):
                var preBarriers: [BarrierCommand] = []
                collectRenderPassBarriers(
                    record,
                    on: queue,
                    barriers: &preBarriers,
                    splitReleases: &splitReleases,
                    waits: &mainWaits
                )
                if !preBarriers.isEmpty { mainCommands.append(.barriers(preBarriers)) }
                mainCommands.append(.renderPass(record))

            case .computePass(let record):
                var preBarriers: [BarrierCommand] = []
                collectComputePassBarriers(
                    record,
                    on: queue,
                    barriers: &preBarriers,
                    splitReleases: &splitReleases,
                    waits: &mainWaits
                )
                if !preBarriers.isEmpty { mainCommands.append(.barriers(preBarriers)) }
                mainCommands.append(.computePass(record))

            case .copyPass(let record):
                var preBarriers: [BarrierCommand] = []
                collectCopyPassBarriers(
                    record,
                    on: queue,
                    barriers: &preBarriers,
                    splitReleases: &splitReleases,
                    waits: &mainWaits
                )
                if !preBarriers.isEmpty { mainCommands.append(.barriers(preBarriers)) }
                mainCommands.append(.copyPass(record))
            }
        }

        return try finalizePlan(
            queue: queue,
            mainCommands: &mainCommands,
            splitReleases: splitReleases,
            external: external,
            mainWaits: &mainWaits,
            mainSignals: &mainSignals
        )
    }

    // MARK: Per-pass resource collection

    private func collectRenderPassBarriers(
        _ record: RenderPassRecord,
        on queue: QueueClass,
        barriers: inout [BarrierCommand],
        splitReleases: inout [SplitReleaseRequest],
        waits: inout [TimelineSemaphore]
    ) {
        for target in record.descriptor.colorTargets {
            for texture in [target.texture] + (target.resolveTexture.map { [$0] } ?? []) {
                let ref = ResourceRef(kind: .texture, id: texture.id)
                collect(
                    resource: ref,
                    desired: .renderTarget,
                    access: Self.makeAccess(resource: ref, state: .renderTarget,
                                            stage: .fragment, isAttachment: true),
                    scope: .beforePass,
                    on: queue, barriers: &barriers,
                    splitReleases: &splitReleases, waits: &waits
                )
            }
        }
        if let depth = record.descriptor.depthTarget {
            let ref = ResourceRef(kind: .texture, id: depth.texture.id)
            collect(
                resource: ref,
                desired: .depthWrite,
                access: Self.makeAccess(resource: ref, state: .depthWrite,
                                        stage: .fragment, isAttachment: true),
                scope: .beforePass,
                on: queue, barriers: &barriers,
                splitReleases: &splitReleases, waits: &waits
            )
        }
        // Sets are immutable and their resources are collected before the
        // entire pass. Rebinding a set for another draw adds no new access.
        var collectedSets: Set<UInt32> = []
        var collectedReads: [ResourceRef: ResourceState] = [:]
        for renderCommand in record.body {
            switch renderCommand {
            case .setBindingSet(slot: _, set: let set):
                guard collectedSets.insert(set.id).inserted else { continue }
                collectBindingSetResources(
                    set, on: queue, stage: [.vertex, .fragment, .task, .mesh], scope: .beforePass,
                    collectedReads: &collectedReads,
                    barriers: &barriers, splitReleases: &splitReleases, waits: &waits
                )
            case .setVertexBuffer(slot: _, buffer: let buffer, offset: _):
                let ref = ResourceRef(kind: .buffer, id: buffer.id)
                collectedReads[ref] = nil
                collect(
                    resource: ref,
                    desired: .vertexBuffer,
                    access: Self.makeAccess(resource: ref, state: .vertexBuffer, stage: .vertex),
                    scope: .beforePass,
                    on: queue, barriers: &barriers,
                    splitReleases: &splitReleases, waits: &waits
                )
            case .setIndexBuffer(buffer: let buffer, offset: _, type: _):
                let ref = ResourceRef(kind: .buffer, id: buffer.id)
                collectedReads[ref] = nil
                collect(
                    resource: ref,
                    desired: .indexBuffer,
                    access: Self.makeAccess(resource: ref, state: .indexBuffer, stage: .vertex),
                    scope: .beforePass,
                    on: queue, barriers: &barriers,
                    splitReleases: &splitReleases, waits: &waits
                )
            case .drawIndirect(buffer: let buffer, offset: _, drawCount: _):
                let ref = ResourceRef(kind: .buffer, id: buffer.id)
                collectedReads[ref] = nil
                collect(
                    resource: ref,
                    desired: .indirectArgument,
                    access: Self.makeAccess(resource: ref, state: .indirectArgument, stage: .vertex),
                    scope: .beforePass,
                    on: queue, barriers: &barriers,
                    splitReleases: &splitReleases, waits: &waits
                )
            default:
                break
            }
        }
    }

    private func collectComputePassBarriers(
        _ record: ComputePassRecord,
        on queue: QueueClass,
        barriers: inout [BarrierCommand],
        splitReleases: inout [SplitReleaseRequest],
        waits: inout [TimelineSemaphore]
    ) {
        var collectedReads: [ResourceRef: ResourceState] = [:]
        for computeCommand in record.body {
            switch computeCommand {
            case .setBindingSet(slot: _, set: let set):
                collectBindingSetResources(
                    set, on: queue, stage: .compute, scope: .beforePass,
                    collectedReads: &collectedReads,
                    barriers: &barriers, splitReleases: &splitReleases, waits: &waits
                )
            case .dispatchIndirect(buffer: let buffer, offset: _):
                let ref = ResourceRef(kind: .buffer, id: buffer.id)
                collectedReads[ref] = nil
                collect(
                    resource: ref,
                    desired: .indirectArgument,
                    access: Self.makeAccess(resource: ref, state: .indirectArgument, stage: .compute),
                    scope: .beforePass,
                    on: queue, barriers: &barriers,
                    splitReleases: &splitReleases, waits: &waits
                )
            default:
                break
            }
        }
    }

    private func collectCopyPassBarriers(
        _ record: CopyPassRecord,
        on queue: QueueClass,
        barriers: inout [BarrierCommand],
        splitReleases: inout [SplitReleaseRequest],
        waits: inout [TimelineSemaphore]
    ) {
        for copyCommand in record.body {
            switch copyCommand {
            case .copyTexture(let src, let dst, _, _):
                let source = ResourceRef(kind: .texture, id: src.id)
                let destination = ResourceRef(kind: .texture, id: dst.id)
                collect(resource: source, desired: .copySource,
                    access: Self.makeAccess(resource: source, state: .copySource, stage: .transfer),
                    scope: .outsidePass, on: queue, barriers: &barriers, splitReleases: &splitReleases, waits: &waits)
                collect(resource: destination, desired: .copyDestination,
                    access: Self.makeAccess(resource: destination, state: .copyDestination, stage: .transfer),
                    scope: .outsidePass, on: queue, barriers: &barriers, splitReleases: &splitReleases, waits: &waits)
            case .copyBuffer(src: let src, srcOffset: _, dst: let dst, dstOffset: _, size: _):
                let srcRef = ResourceRef(kind: .buffer, id: src.id)
                collect(
                    resource: srcRef,
                    desired: .copySource,
                    access: Self.makeAccess(resource: srcRef, state: .copySource, stage: .transfer),
                    scope: .outsidePass,
                    on: queue, barriers: &barriers,
                    splitReleases: &splitReleases, waits: &waits
                )
                let dstRef = ResourceRef(kind: .buffer, id: dst.id)
                collect(
                    resource: dstRef,
                    desired: .copyDestination,
                    access: Self.makeAccess(resource: dstRef, state: .copyDestination, stage: .transfer),
                    scope: .outsidePass,
                    on: queue, barriers: &barriers,
                    splitReleases: &splitReleases, waits: &waits
                )
            case .copyBufferToTexture(let upload):
                let srcRef = ResourceRef(kind: .buffer, id: upload.buffer.id)
                collect(
                    resource: srcRef,
                    desired: .copySource,
                    access: Self.makeAccess(resource: srcRef, state: .copySource, stage: .transfer),
                    scope: .outsidePass,
                    on: queue, barriers: &barriers,
                    splitReleases: &splitReleases, waits: &waits
                )
                let dstRef = ResourceRef(kind: .texture, id: upload.texture.id)
                collect(
                    resource: dstRef,
                    desired: .copyDestination,
                    access: Self.makeAccess(resource: dstRef, state: .copyDestination, stage: .transfer),
                    scope: .outsidePass,
                    on: queue, barriers: &barriers,
                    splitReleases: &splitReleases, waits: &waits
                )
            case .copyTextureToBuffer(texture: let src, width: _, height: _, buffer: let dst, offset: _, bytesPerRow: _):
                let srcRef = ResourceRef(kind: .texture, id: src.id)
                collect(
                    resource: srcRef,
                    desired: .copySource,
                    access: Self.makeAccess(resource: srcRef, state: .copySource, stage: .transfer),
                    scope: .outsidePass,
                    on: queue, barriers: &barriers,
                    splitReleases: &splitReleases, waits: &waits
                )
                let dstRef = ResourceRef(kind: .buffer, id: dst.id)
                collect(
                    resource: dstRef,
                    desired: .copyDestination,
                    access: Self.makeAccess(resource: dstRef, state: .copyDestination, stage: .transfer),
                    scope: .outsidePass,
                    on: queue, barriers: &barriers,
                    splitReleases: &splitReleases, waits: &waits
                )
            }
       }
    }

    private func collectBindingSetResources(
        _ set: BindingSet,
        on queue: QueueClass,
        stage: AccessStage,
        scope: BarrierPassScope,
        collectedReads: inout [ResourceRef: ResourceState],
        barriers: inout [BarrierCommand],
        splitReleases: inout [SplitReleaseRequest],
        waits: inout [TimelineSemaphore]
    ) {
        guard let entries = bindingSetEntries[set.id] else { return }
        for entry in entries.entries {
            guard let tracked = trackedResource(for: entry.resource, readOnly: entries.readOnlySlots.contains(entry.slot)) else { continue }
            let access = ResourceAccess(
                resource: tracked.resource,
                kind: Self.accessKind(tracked.state),
                stage: stage
            )
            // All binding reads in this pass use the same stage mask and
            // whole-resource range. Different immutable sets can share one
            // read dependency; writes and other buffer uses reset this entry.
            if access.kind == .read {
                guard collectedReads[tracked.resource] != tracked.state else { continue }
                collectedReads[tracked.resource] = tracked.state
            } else {
                collectedReads[tracked.resource] = nil
            }
            collect(
                resource: tracked.resource,
                desired: tracked.state,
                access: access,
                scope: scope,
                on: queue, barriers: &barriers,
                splitReleases: &splitReleases, waits: &waits
            )
        }
    }

    private func trackedResource(for resource: BindingResource, readOnly: Bool) -> (resource: ResourceRef, state: ResourceState)? {
        switch resource {
        case .sampler:
            return nil
        case .texture(let texture):
            return (ResourceRef(kind: .texture, id: texture.id), .shaderResource)
        case .storageTexture(let texture):
            return (ResourceRef(kind: .texture, id: texture.id), .unorderedAccess)
        case .uniformBuffer(let buffer, _, _):
            return (ResourceRef(kind: .buffer, id: buffer.id), .constantBuffer)
        case .storageBuffer(let buffer, _):
            return (ResourceRef(kind: .buffer, id: buffer.id), readOnly ? .shaderResource : .unorderedAccess)
        case .accelerationStructure(let accel):
            return (ResourceRef(kind: .accelerationStructure, id: accel.id), .accelerationStructureRead)
        }
    }

    // MARK: Automatic transition + cross-queue split

    private func collect(
        resource: ResourceRef,
        desired: ResourceState,
        access: ResourceAccess,
        scope: BarrierPassScope,
        on queue: QueueClass,
        barriers: inout [BarrierCommand],
        splitReleases: inout [SplitReleaseRequest],
        waits: inout [TimelineSemaphore]
    ) {
        let ownerQueue = tracking.resourceQueues[resource] ?? queue
        let crossQueue = ownerQueue != queue

        // Capture the real prior state before any layer mutates it.
        let beforeState = tracking.stateTracker.currentState(resource)

        // Layer 1: state/layout transition (may be empty when state is unchanged).
        tracking.stateTracker.requireState(resource, desired)
        let stateBarriers = tracking.stateTracker.commitBarriers()

        // Layer 2: access ordering (RAW/WAR/WAW), tracked regardless of state.
        let hazards = tracking.accessTracker.observe(access, on: queue)
        let sameQueueHazards = hazards.filter { $0.sourceQueue == $0.destinationQueue }

        if crossQueue {
            // Ownership transfer: release on the owner (from the real prior
            // state) + acquire here (to the desired state). This subsumes both
            // the state transition and the memory ordering, so it is required
            // even when the state is unchanged.
            if let pending = matchingPendingTransfer(
                resource, srcQueue: ownerQueue, dstQueue: queue, state: beforeState
            ) {
                appendUnique(&waits, pending.semaphore)
            } else {
                appendSplitRelease(
                    SplitReleaseRequest(
                        resource: resource, srcState: beforeState,
                        srcQueue: ownerQueue, dstQueue: queue
                    ),
                    &splitReleases
                )
            }
            barriers.append(BarrierCommand(
                resource: resource,
                sourceState: beforeState,
                destinationState: desired,
                syncAction: .acquire,
                passScope: scope,
                sourceQueue: ownerQueue,
                destinationQueue: queue
            ))
            tracking.pendingTransfers[resource] = nil
        } else if let stateBarrier = stateBarriers.first {
            // State changed: the transition barrier also orders memory.
            barriers.append(BarrierCommand(
                resource: resource,
                sourceState: stateBarrier.before,
                destinationState: stateBarrier.after,
                syncAction: .full,
                passScope: scope,
                sourceQueue: ownerQueue,
                destinationQueue: queue
            ))
        } else if !access.isAttachment, !sameQueueHazards.isEmpty {
            // State unchanged, but a RAW/WAR/WAW hazard on a storage/unordered
            // access exists: emit an ordering barrier even though nothing
            // transitioned. Attachment writes are pass-ordered and excluded.
            barriers.append(BarrierCommand(
                resource: resource,
                sourceState: desired,
                destinationState: desired,
                syncAction: .full,
                passScope: scope,
                sourceQueue: ownerQueue,
                destinationQueue: queue
            ))
        }

        tracking.resourceQueues[resource] = queue
    }

    // MARK: Access construction

    /// States that perform a write (anything else is a read).
    private static let writeStates: ResourceState = [
        .unorderedAccess, .renderTarget, .depthWrite, .copyDestination,
        .resolveDestination, .accelerationStructureWrite,
    ]

    /// Derives the access kind (read/write) from a resource state.
    private static func accessKind(_ state: ResourceState) -> AccessKind {
        state.intersection(writeStates).isEmpty ? .read : .write
    }

    /// Builds a `ResourceAccess` for a collected resource.
    private static func makeAccess(
        resource: ResourceRef, state: ResourceState, stage: AccessStage,
        isAttachment: Bool = false
    ) -> ResourceAccess {
        ResourceAccess(resource: resource, kind: accessKind(state), stage: stage,
                       isAttachment: isAttachment)
    }

    // MARK: Explicit barrier resolution

    private func resolveExplicit(
        _ barrier: BarrierCommand,
        submitting queue: QueueClass,
        splitReleases: inout [SplitReleaseRequest],
        waits: inout [TimelineSemaphore],
        signals: inout [TimelineSemaphore]
    ) throws -> BarrierCommand? {
        let srcQueue = barrier.sourceQueue
        let dstQueue = barrier.destinationQueue
        let resource = barrier.resource

        if srcQueue == dstQueue {
            return barrier
        }

        switch barrier.syncAction {
        case .full:
            guard queue == dstQueue else { return nil }
            try arrangeRelease(
                resource: resource, srcQueue: srcQueue, dstQueue: dstQueue,
                state: barrier.sourceState,
                splitReleases: &splitReleases, waits: &waits
            )
            var acquire = barrier
            acquire.syncAction = .acquire
            return acquire

        case .acquire:
            guard queue == dstQueue else { return nil }
            try arrangeRelease(
                resource: resource, srcQueue: srcQueue, dstQueue: dstQueue,
                state: barrier.sourceState,
                splitReleases: &splitReleases, waits: &waits
            )
            return barrier

        case .release:
            guard queue == srcQueue else { return nil }
            if srcQueue != dstQueue {
                let semaphore = try ensureSignalSemaphore(queue: queue, signals: &signals)
                tracking.pendingTransfers[resource] = PendingTransfer(
                    srcQueue: srcQueue, dstQueue: dstQueue,
                    releasedState: barrier.sourceState, semaphore: semaphore
                )
            }
            var release = barrier
            release.destinationState = release.sourceState
            return release
        }
    }

    private func arrangeRelease(
        resource: ResourceRef,
        srcQueue: QueueClass,
        dstQueue: QueueClass,
        state: ResourceState,
        splitReleases: inout [SplitReleaseRequest],
        waits: inout [TimelineSemaphore]
    ) throws {
        if let pending = matchingPendingTransfer(resource, srcQueue: srcQueue, dstQueue: dstQueue, state: state) {
            appendUnique(&waits, pending.semaphore)
        } else {
            appendSplitRelease(
                SplitReleaseRequest(
                    resource: resource, srcState: state,
                    srcQueue: srcQueue, dstQueue: dstQueue
                ),
                &splitReleases
            )
        }
    }

    private func applyExplicit(_ barrier: BarrierCommand) throws {
        let resource = barrier.resource
        switch barrier.syncAction {
        case .full:
            tracking.stateTracker.setCurrentState(resource, barrier.destinationState)
            tracking.resourceQueues[resource] = barrier.destinationQueue
            tracking.pendingTransfers[resource] = nil

        case .acquire:
            if let pending = tracking.pendingTransfers[resource] {
                guard pending.srcQueue == barrier.sourceQueue,
                      pending.dstQueue == barrier.destinationQueue,
                      pending.releasedState == barrier.sourceState
                else {
                    throw RHIError.submitFailed("acquire barrier does not match a pending release")
                }
                tracking.pendingTransfers[resource] = nil
            }
            tracking.stateTracker.setCurrentState(resource, barrier.destinationState)
            tracking.resourceQueues[resource] = barrier.destinationQueue

        case .release:
            let releasedState = barrier.sourceState
            tracking.stateTracker.setCurrentState(resource, releasedState)
            tracking.resourceQueues[resource] = barrier.sourceQueue
            if barrier.sourceQueue == barrier.destinationQueue {
                tracking.pendingTransfers[resource] = nil
                return
            }
            let existingSemaphore = tracking.pendingTransfers[resource]?.semaphore
                ?? TimelineSemaphore(id: 0, value: 0)
            tracking.pendingTransfers[resource] = PendingTransfer(
                srcQueue: barrier.sourceQueue,
                dstQueue: barrier.destinationQueue,
                releasedState: releasedState,
                semaphore: existingSemaphore
            )
        }
    }

    // MARK: Plan finalization

    private func finalizePlan(
        queue: QueueClass,
        mainCommands: inout [PlannedCommand],
        splitReleases: [SplitReleaseRequest],
        external: SubmitDescriptor,
        mainWaits: inout [TimelineSemaphore],
        mainSignals: inout [TimelineSemaphore]
    ) throws -> SubmitPlan {
        var submits: [PlannedSubmit] = []

        for releaseQueue in QueueClass.allCases {
            let requests = splitReleases.filter { $0.srcQueue == releaseQueue }
            guard !requests.isEmpty else { continue }

            let releaseBarriers = requests.map { request -> BarrierCommand in
                BarrierCommand(
                    resource: request.resource,
                    sourceState: request.srcState,
                    destinationState: request.srcState,
                    syncAction: .release,
                    passScope: .outsidePass,
                    sourceQueue: request.srcQueue,
                    destinationQueue: request.dstQueue
                )
            }

            let signal = nextQueueTimeline(releaseQueue)
            appendUnique(&mainWaits, signal)

            submits.append(PlannedSubmit(
                queue: releaseQueue,
                commands: [.barriers(releaseBarriers)],
                waitSemaphores: [],
                signalSemaphores: [signal]
            ))
        }

        for semaphore in external.waitSemaphores {
            appendUnique(&mainWaits, semaphore)
        }
        for semaphore in external.signalSemaphores {
            appendUnique(&mainSignals, semaphore)
        }

        submits.append(PlannedSubmit(
            queue: queue,
            commands: mainCommands,
            waitSemaphores: mainWaits,
            signalSemaphores: mainSignals
        ))

        return SubmitPlan(submits: submits)
    }

    // MARK: Timeline semaphores

    private func ensureSignalSemaphore(
        queue: QueueClass,
        signals: inout [TimelineSemaphore]
    ) throws -> TimelineSemaphore {
        if let existing = signals.first {
            return existing
        }
        let semaphore = nextQueueTimeline(queue)
        signals.append(semaphore)
        return semaphore
    }

    private func nextQueueTimeline(_ queue: QueueClass) -> TimelineSemaphore {
        var timeline = tracking.queueTimelines[queue] ?? QueueTimeline()
        if timeline.id == 0 {
            timeline.id = tracking.nextTimelineSemaphoreID
            tracking.nextTimelineSemaphoreID += 1
        }
        timeline.nextValue += 1
        tracking.queueTimelines[queue] = timeline
        return TimelineSemaphore(id: timeline.id, value: timeline.nextValue)
    }

    // MARK: Pending transfer lookup + list helpers

    private func matchingPendingTransfer(
        _ resource: ResourceRef,
        srcQueue: QueueClass,
        dstQueue: QueueClass,
        state: ResourceState
    ) -> PendingTransfer? {
        guard let pending = tracking.pendingTransfers[resource] else { return nil }
        guard pending.srcQueue == srcQueue,
              pending.dstQueue == dstQueue,
              pending.releasedState == state
        else { return nil }
        return pending
    }

    private func appendSplitRelease(
        _ request: SplitReleaseRequest,
        _ list: inout [SplitReleaseRequest]
    ) {
        if let index = list.firstIndex(where: {
            $0.resource == request.resource
                && $0.srcQueue == request.srcQueue
                && $0.dstQueue == request.dstQueue
        }) {
            list[index].srcState.formUnion(request.srcState)
        } else {
            list.append(request)
        }
    }

    @discardableResult
    private func appendUnique(_ list: inout [TimelineSemaphore], _ semaphore: TimelineSemaphore) -> Bool {
        guard semaphore.id != 0 else { return false }
        if list.contains(where: { $0.id == semaphore.id && $0.value == semaphore.value }) {
            return false
        }
        list.append(semaphore)
        return true
    }
}
