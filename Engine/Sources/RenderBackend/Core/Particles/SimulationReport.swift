struct GPUParticleSimulationEncodeReport {
    var batchCount: Int
    var particleCount: Int
    var dispatchWorkgroups: Int
    var sortPassCount: Int
    var sortItemCount: Int
    var sortPaddedItemCount: Int
    var sortDispatchWorkgroups: Int
    var instanceDispatchWorkgroups: Int
    var renderInstanceCount: Int
    var eventCapacity: Int
    var eventBufferBytes: Int

    init(batchCount: Int = 0,
         particleCount: Int = 0,
         dispatchWorkgroups: Int = 0,
         sortPassCount: Int = 0,
         sortItemCount: Int = 0,
         sortPaddedItemCount: Int = 0,
         sortDispatchWorkgroups: Int = 0,
         instanceDispatchWorkgroups: Int = 0,
         renderInstanceCount: Int = 0,
         eventCapacity: Int = 0,
         eventBufferBytes: Int = 0) {
        self.batchCount = max(0, batchCount)
        self.particleCount = max(0, particleCount)
        self.dispatchWorkgroups = max(0, dispatchWorkgroups)
        self.sortPassCount = max(0, sortPassCount)
        self.sortItemCount = max(0, sortItemCount)
        self.sortPaddedItemCount = max(0, sortPaddedItemCount)
        self.sortDispatchWorkgroups = max(0, sortDispatchWorkgroups)
        self.instanceDispatchWorkgroups = max(0, instanceDispatchWorkgroups)
        self.renderInstanceCount = max(0, renderInstanceCount)
        self.eventCapacity = max(0, eventCapacity)
        self.eventBufferBytes = max(0, eventBufferBytes)
    }

    mutating func include(batchParticleCount: Int,
                          dispatchWorkgroups: Int,
                          sortPassCount: Int = 0,
                          sortItemCount: Int = 0,
                          sortPaddedItemCount: Int = 0,
                          sortDispatchWorkgroups: Int = 0,
                          instanceDispatchWorkgroups: Int = 0,
                          renderInstanceCount: Int = 0,
                          eventCapacity: Int = 0,
                          eventBufferBytes: Int = 0) {
        batchCount += 1
        particleCount += max(0, batchParticleCount)
        self.dispatchWorkgroups += max(0, dispatchWorkgroups)
        self.sortPassCount += max(0, sortPassCount)
        self.sortItemCount += max(0, sortItemCount)
        self.sortPaddedItemCount += max(0, sortPaddedItemCount)
        self.sortDispatchWorkgroups += max(0, sortDispatchWorkgroups)
        self.instanceDispatchWorkgroups += max(0, instanceDispatchWorkgroups)
        self.renderInstanceCount += max(0, renderInstanceCount)
        self.eventCapacity += max(0, eventCapacity)
        self.eventBufferBytes += max(0, eventBufferBytes)
    }
}
