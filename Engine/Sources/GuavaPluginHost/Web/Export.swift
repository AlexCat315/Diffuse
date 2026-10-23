import CapabilityRuntime
import Foundation
import PluginRuntime

// The browser consumes the same parsed WIT types and authority inspected by
// the native host. It does not maintain a second WIT parser or permission list.
private struct WebPackageDescriptor: Encodable {
    let formatVersion = 1
    let inspection: PluginInspection
    let witContract: WITContract
    let hostContracts: [CapabilityContract]
}

enum WebPackageExportError: Error {
    case usage
}

func exportWebPackage(at url: URL, loader: PluginPackageLoader,
                      runtime: any WASIComponentRuntime, limits: PluginResourceLimits, registry: CapabilityRegistry) throws {
    let package = try loader.load(at: url)
    try runtime.validateComponent(package, limits: limits)
    let inspection = PluginInspection(package: package,
                                      contracts: PluginWITContractDeriver.contracts(for: package))
    let descriptor = WebPackageDescriptor(inspection: inspection, witContract: try package.requireRuntime().witContract,
        hostContracts: package.manifest.composableHostCapabilities.compactMap { registry.descriptor(for: $0)?.contract })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(descriptor))
}
