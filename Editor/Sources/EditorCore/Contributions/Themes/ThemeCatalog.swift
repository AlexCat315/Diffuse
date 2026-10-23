import Foundation
import PluginRuntime
public import GuavaUICompose

public struct EditorThemeDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let appearance: String
}

public struct ThemeCatalogSnapshot: Sendable {
    public let revision: UInt64
    public let themes: [EditorThemeDescriptor]
}

public final class EditorThemeCatalog: @unchecked Sendable {
    public static let defaultThemeID = "studio.theme.default"
    private let lock = NSLock()
    private var entries: [Entry] = bundled
    private var revision: UInt64 = 0

    init() {}

    private struct Entry: Sendable {
        let descriptor: EditorThemeDescriptor
        let resource: ThemeResource
    }

    private static let bundled: [Entry] = BundledPlugins.catalog.flatMap { plugin in
        guard let package = try? PluginPackageLoader().load(at: plugin.package) else { return [Entry]() }
        return (try? decode(package)) ?? []
    }

    static func validate(_ package: ValidatedPluginPackage) throws {
        _ = try decode(package)
    }

    func update(packages: [ValidatedPluginPackage]) throws {
        var next: [Entry] = []
        var ids = Set<String>()
        for package in packages.sorted(by: { $0.manifest.id < $1.manifest.id }) {
            for entry in try Self.decode(package) {
                guard ids.insert(entry.descriptor.id).inserted else {
                    throw ThemeResourceError.invalidToken(entry.descriptor.id)
                }
                next.append(entry)
            }
        }
        lock.withLock {
            entries = next
            revision &+= 1
        }
    }

    var snapshot: ThemeCatalogSnapshot {
        lock.withLock { ThemeCatalogSnapshot(revision: revision, themes: entries.map(\.descriptor)) }
    }

    func theme(id: String = EditorThemeCatalog.defaultThemeID, dark: Bool) -> Theme {
        let entry = lock.withLock { entries.first { $0.descriptor.id == id } }
        let variant = dark ? entry?.resource.dark : entry?.resource.light
        return (try? variant?.make(dark: dark)) ?? (dark ? Theme.defaultDark : Theme.defaultLight)
    }

    public static func bundledTheme(id: String = defaultThemeID, dark: Bool) -> Theme {
        let entry = bundled.first { $0.descriptor.id == id }
        let variant = dark ? entry?.resource.dark : entry?.resource.light
        return (try? variant?.make(dark: dark)) ?? (dark ? Theme.defaultDark : Theme.defaultLight)
    }

    private static func decode(_ package: ValidatedPluginPackage) throws -> [Entry] {
        try package.manifest.contributes.decode(ThemeContributionPoint.self).map { contribution in
            let resource = try JSONDecoder().decode(ThemeResource.self, from: package.resource(at: contribution.path))
            try resource.validate(appearance: contribution.appearance)
            return Entry(descriptor: EditorThemeDescriptor(id: contribution.id, title: contribution.title,
                                                          appearance: contribution.appearance), resource: resource)
        }
    }
}
