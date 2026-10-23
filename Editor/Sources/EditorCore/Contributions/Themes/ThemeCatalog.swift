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
    private var packages: [String: PackageThemes] = [:]
    private var revision: UInt64 = 0

    init() {}

    private struct PackageThemes {
        let generation: UUID
        let entries: [Entry]
    }

    private var entries: [Entry] { packages.keys.sorted().flatMap { packages[$0]?.entries ?? [] } }

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

    func register(_ package: ValidatedPluginPackage) throws -> Registration {
        let next = try Self.decode(package), id = package.manifest.id, generation = UUID()
        try lock.withLock {
            let claimed = Set(entries.map(\.descriptor.id))
            guard packages[id] == nil, !next.contains(where: { claimed.contains($0.descriptor.id) }) else {
                throw ThemeResourceError.invalidToken(id)
            }
            packages[id] = PackageThemes(generation: generation, entries: next)
            revision &+= 1
        }
        return Registration { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                guard self.packages[id]?.generation == generation else { return }
                self.packages.removeValue(forKey: id)
                self.revision &+= 1
            }
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
