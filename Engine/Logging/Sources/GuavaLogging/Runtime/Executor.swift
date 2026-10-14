#if canImport(Dispatch)
import Dispatch
#endif

final class LogExecutor: @unchecked Sendable {
    #if canImport(Dispatch)
    private let queue = DispatchQueue(label: "com.guava.logging", qos: .utility)
    private let key = DispatchSpecificKey<Bool>()
    init() { queue.setSpecific(key: key, value: true) }
    var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == true }
    func sync<T>(_ body: () throws -> T) rethrows -> T { if isCurrent { return try body() }; return try queue.sync(execute: body) }
    func async(_ body: @escaping @Sendable () -> Void) { queue.async(execute: body) }
    #else
    private var depth = 0
    var isCurrent: Bool { depth > 0 }
    func sync<T>(_ body: () throws -> T) rethrows -> T { depth += 1; defer { depth -= 1 }; return try body() }
    func async(_ body: @escaping @Sendable () -> Void) { sync(body) }
    #endif
}
