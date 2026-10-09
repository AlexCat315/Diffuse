/// Merge stage visibility while preserving the reflected resource ABI.
extension BindingLayoutDescriptor {
    public init(reflecting artifacts: [ShaderArtifact]) throws {
        var entries: [UInt32: BindingLayoutEntry] = [:]
        for artifact in artifacts {
            guard Set(artifact.interface.bindings.map(\.slot)).count == artifact.interface.bindings.count else {
                throw RHIError.layoutMismatch("duplicate reflected resource slot in one shader")
            }
            for binding in artifact.interface.bindings {
                guard binding.space == 0 else { throw RHIError.layoutMismatch("reflected layout expects space0") }
                if var existing = entries[binding.slot] {
                    guard existing.type == binding.type, existing.buffer == binding.buffer else {
                        throw RHIError.layoutMismatch("inconsistent reflected resource at \(binding.slot)")
                    }
                    existing.visibility.formUnion(ShaderVisibility(artifact.stage)); entries[binding.slot] = existing
                } else {
                    var entry = BindingLayoutEntry(slot: binding.slot, type: binding.type, visibility: ShaderVisibility(artifact.stage))
                    entry.buffer = binding.buffer; entries[binding.slot] = entry
                }
            }
        }
        self.init(entries: entries.values.sorted { $0.slot < $1.slot })
    }
}
