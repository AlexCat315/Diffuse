import CovePluginKit

/// `swift package describe --type json`, as the editor shows a project:
/// what can run, and the products, targets and dependencies.
enum PackageDescription {
    static func read(_ output: String) -> JSON? {
        // SwiftPM may print warnings before the document.
        var bytes = Array(output.utf8)[...]
        while let first = bytes.first, first != UInt8(ascii: "{") { bytes = bytes.dropFirst() }
        guard let package = JSON.parse(text(bytes)), let name = package["name"]?.string else { return nil }
        var runnables: [JSON] = [], products: [JSON] = [], targets: [JSON] = [], dependencies: [JSON] = []
        for product in package["products"]?.array ?? [] {
            guard let productName = product["name"]?.string else { continue }
            let kind = product["type"]?.object?.members.first?.key ?? "product"
            if kind == "executable" { runnables.append(.string(productName)) }
            products.append(item(productName, kind))
        }
        for target in package["targets"]?.array ?? [] {
            guard let targetName = target["name"]?.string else { continue }
            targets.append(item(targetName, target["type"]?.string ?? ""))
        }
        for dependency in package["dependencies"]?.array ?? [] {
            guard let identity = dependency["identity"]?.string else { continue }
            dependencies.append(item(identity, dependency["url"]?.string ?? dependency["path"]?.string ?? ""))
        }
        var sections: [JSON] = [section("Products", products), section("Targets", targets)]
        if !dependencies.isEmpty { sections.append(section("Dependencies", dependencies)) }
        return ["name": .string(name), "runnables": .array(runnables), "sections": .array(sections)]
    }

    private static func item(_ name: String, _ detail: String) -> JSON {
        ["name": .string(name), "detail": .string(detail)]
    }

    private static func section(_ title: String, _ items: [JSON]) -> JSON {
        ["title": .string(title), "items": .array(items)]
    }
}
