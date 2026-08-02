import Foundation
import GuavaUIRuntime

// MARK: - Storage value & store

/// Primitive value forms an `@AppStorage` key can hold. Mirrors SwiftUI's
/// supported set (Bool / Int / Double / String, plus RawRepresentable of
/// those via `AppStorageConvertible`).
public enum AppStorageValue: Equatable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        self = .string(try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }
}

/// Key-value backend for `@AppStorage`. Implementations persist however they
/// like (file, registry, in-memory for tests). Main-thread only, like the
/// rest of the UI layer.
public protocol AppStorageStore: AnyObject {
    func value(forKey key: String) -> AppStorageValue?
    func set(_ value: AppStorageValue?, forKey key: String)
}

/// Process-wide default store, used when an `@AppStorage` does not name one
/// explicitly. Hosts (e.g. the editor) inject their own at startup.
public enum AppStorageDefaults {
    nonisolated(unsafe) public static var store: AppStorageStore = FileAppStorageStore(
        url: FileAppStorageStore.defaultURL()
    )
}

/// JSON-file-backed store: one flat `[key: primitive]` dictionary, written
/// atomically on every mutation (preference-scale traffic).
public final class FileAppStorageStore: AppStorageStore {
    public let url: URL
    private var values: [String: AppStorageValue]
    private var persistenceEnabled = true

    /// Non-nil when an unreadable file was moved aside during initialization.
    /// Hosts may surface this as a recoverable preferences warning.
    public private(set) var loadWarning: String?

    /// The most recent persistence failure. Values still update in memory so a
    /// read-only or temporarily unavailable preferences directory does not make
    /// controls appear broken.
    public private(set) var lastSaveError: String?

    /// Location of the unreadable file retained for diagnostics/recovery.
    public private(set) var quarantinedURL: URL?

    public init(url: URL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            values = [:]
            return
        }

        do {
            let data = try Data(contentsOf: url)
            values = try JSONDecoder().decode([String: AppStorageValue].self, from: data)
        } catch {
            values = [:]
            let originalError = error
            let quarantineURL = Self.quarantineURL(for: url)
            do {
                try FileManager.default.moveItem(at: url, to: quarantineURL)
                quarantinedURL = quarantineURL
                loadWarning = "Unreadable app storage was moved to \(quarantineURL.lastPathComponent): \(originalError)"
            } catch {
                persistenceEnabled = false
                loadWarning = "Unreadable app storage could not be quarantined; disk writes are disabled to preserve it: \(error); original error: \(originalError)"
            }
            if let loadWarning {
                FileHandle.standardError.write(Data("[FileAppStorageStore] \(loadWarning)\n".utf8))
            }
        }
    }

    public static func defaultURL(appName: String = "GuavaUI") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("app-storage.json")
    }

    public func value(forKey key: String) -> AppStorageValue? {
        values[key]
    }

    public func set(_ value: AppStorageValue?, forKey key: String) {
        values[key] = value
        guard persistenceEnabled else { return }
        do {
            let data = try JSONEncoder().encode(values)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = String(describing: error)
            FileHandle.standardError.write(Data("[FileAppStorageStore] failed to persist \(url.path): \(error)\n".utf8))
        }
    }

    private static func quarantineURL(for url: URL) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem).corrupt-\(UUID().uuidString)\(suffix)")
    }
}

/// Non-persisting store for tests and previews.
public final class MemoryAppStorageStore: AppStorageStore {
    public private(set) var values: [String: AppStorageValue] = [:]
    public init() {}
    public func value(forKey key: String) -> AppStorageValue? { values[key] }
    public func set(_ value: AppStorageValue?, forKey key: String) { values[key] = value }
}

// MARK: - Convertible values

/// Types `@AppStorage` can wrap. `Equatable` so writes of an unchanged value
/// do not schedule a recompose (see the @State no-dedupe gotcha).
public protocol AppStorageConvertible: Equatable {
    init?(storageValue: AppStorageValue)
    var storageValue: AppStorageValue { get }
}

extension Bool: AppStorageConvertible {
    public init?(storageValue: AppStorageValue) {
        guard case .bool(let v) = storageValue else { return nil }
        self = v
    }
    public var storageValue: AppStorageValue { .bool(self) }
}

extension Int: AppStorageConvertible {
    public init?(storageValue: AppStorageValue) {
        guard case .int(let v) = storageValue else { return nil }
        self = v
    }
    public var storageValue: AppStorageValue { .int(self) }
}

extension Double: AppStorageConvertible {
    public init?(storageValue: AppStorageValue) {
        switch storageValue {
        case .double(let v): self = v
        case .int(let v): self = Double(v)
        default: return nil
        }
    }
    public var storageValue: AppStorageValue { .double(self) }
}

extension Float: AppStorageConvertible {
    public init?(storageValue: AppStorageValue) {
        guard let d = Double(storageValue: storageValue) else { return nil }
        self = Float(d)
    }
    public var storageValue: AppStorageValue { .double(Double(self)) }
}

extension String: AppStorageConvertible {
    public init?(storageValue: AppStorageValue) {
        guard case .string(let v) = storageValue else { return nil }
        self = v
    }
    public var storageValue: AppStorageValue { .string(self) }
}

/// `enum ThemeMode: String, AppStorageConvertible {}` is all an app enum needs.
public extension AppStorageConvertible where Self: RawRepresentable, RawValue: AppStorageConvertible {
    init?(storageValue: AppStorageValue) {
        guard let raw = RawValue(storageValue: storageValue) else { return nil }
        self.init(rawValue: raw)
    }
    var storageValue: AppStorageValue { rawValue.storageValue }
}

// MARK: - Shared per-key box

/// One live value per (store, key, type), shared by every `@AppStorage`
/// instance referencing that key. Observers are scope-invalidation closures
/// wired by `ViewScope` and keyed by a token that survives `replaceView`
/// (the new wrapper instance adopts the old token in `_copyValue`), so a
/// rebuilt view replaces its observer entry instead of accumulating one per
/// rebuild. Dead tokens are pruned lazily.
final class _AppStorageToken {}

private final class _AppStorageTokenHolder {
    var token = _AppStorageToken()
}

final class _AppStorageBox<Value: AppStorageConvertible> {
    let key: String
    let store: AppStorageStore
    private(set) var value: Value
    private var observers: [(token: () -> _AppStorageToken?, fire: () -> Void)] = []

    init(key: String, store: AppStorageStore, defaultValue: Value) {
        self.key = key
        self.store = store
        self.value = store.value(forKey: key).flatMap(Value.init(storageValue:)) ?? defaultValue
    }

    func setValue(_ newValue: Value) {
        guard newValue != value else { return }
        value = newValue
        store.set(newValue.storageValue, forKey: key)
        // Snapshot before firing: invalidations can recompose synchronously
        // and re-wire observers.
        for observer in observers where observer.token() != nil {
            observer.fire()
        }
    }

    func setObserver(_ fire: @escaping () -> Void, for token: _AppStorageToken) {
        observers.removeAll { $0.token() == nil || $0.token() === token }
        observers.append(({ [weak token] in token }, fire))
    }
}

enum _AppStorageBoxRegistry {
    nonisolated(unsafe) private static var boxes: [String: AnyObject] = [:]

    static func box<Value: AppStorageConvertible>(key: String,
                                                  store: AppStorageStore,
                                                  defaultValue: Value) -> _AppStorageBox<Value> {
        let registryKey = "\(ObjectIdentifier(store))#\(Value.self)#\(key)"
        if let existing = boxes[registryKey] as? _AppStorageBox<Value> {
            return existing
        }
        let box = _AppStorageBox(key: key, store: store, defaultValue: defaultValue)
        boxes[registryKey] = box
        return box
    }
}

// MARK: - @AppStorage

/// `@State`-shaped property wrapper whose value persists across launches and
/// stays in sync between every view that names the same key.
///
/// ```swift
/// @AppStorage("inspector.showGrid") var showGrid = true
/// ```
///
/// Reads come from the shared per-key box (seeded from the store on first
/// use); writes persist to the store and recompose every subscribed view.
/// The store defaults to `AppStorageDefaults.store` — hosts inject their own
/// file location at startup.
@propertyWrapper
public struct AppStorage<Value: AppStorageConvertible>: DynamicProperty {
    private let box: _AppStorageBox<Value>
    private let tokenHolder: _AppStorageTokenHolder

    public init(wrappedValue defaultValue: Value,
                _ key: String,
                store: AppStorageStore? = nil) {
        self.box = _AppStorageBoxRegistry.box(key: key,
                                              store: store ?? AppStorageDefaults.store,
                                              defaultValue: defaultValue)
        self.tokenHolder = _AppStorageTokenHolder()
    }

    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.setValue(newValue) }
    }

    public var projectedValue: Binding<Value> {
        Binding(get: { box.value },
                set: { box.setValue($0) })
    }
}

// Same contract as `State`: the box is only touched on the main thread (the
// recomposer/dispatch loop), so the wrapper can cross Sendable boundaries.
extension AppStorage: @unchecked Sendable where Value: Sendable {}

extension AppStorage: _StateErased {
    public func _wire(invalidate: @escaping () -> Void) {
        box.setObserver(invalidate, for: tokenHolder.token)
    }

    public func _copyValue(from other: _StateErased) {
        // The shared box is the source of truth — no value to copy. Adopt the
        // outgoing instance's token so re-wiring replaces its observer entry
        // instead of stacking a new one per parent rebuild.
        guard let typed = other as? AppStorage<Value> else { return }
        tokenHolder.token = typed.tokenHolder.token
    }
}
