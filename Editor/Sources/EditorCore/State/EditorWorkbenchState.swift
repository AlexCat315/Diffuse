import Foundation
import RenderBackend

public enum EditorViewportMode: String, Codable, Sendable {
    case scene, game
}

public enum EditorOutputTab: String, Sendable, Hashable {
    case logs, problems, build
}

public enum EditorGamePreviewResolution: String, Codable, CaseIterable, Hashable, Sendable {
    case fit, hd720, fullHD, portrait, square
    public var title: String {
        switch self {
        case .fit: "Fit Window"
        case .hd720: "1280 × 720 · 16:9"
        case .fullHD: "1920 × 1080 · 16:9"
        case .portrait: "720 × 1280 · 9:16"
        case .square: "1024 × 1024 · 1:1"
        }
    }
    public var size: RenderDrawableSize? {
        switch self {
        case .fit: nil
        case .hd720: .init(width: 1280, height: 720)
        case .fullHD: .init(width: 1920, height: 1080)
        case .portrait: .init(width: 720, height: 1280)
        case .square: .init(width: 1024, height: 1024)
        }
    }
    public var aspectRatio: Float? { size.map { Float($0.width) / Float($0.height) } }
}

public enum EditorIssueTarget: Codable, Sendable, Equatable, Hashable {
    case script(id: String, line: Int, column: Int)
    case asset(id: String)
    case entity(id: UInt64)
    case file(path: String)

    static func unresolvedBindingTarget(_ descriptions: [String], in manifest: EditorSceneManifest) -> EditorIssueTarget? {
        let descriptions = Set(descriptions)
        func find(_ nodes: [EditorSceneManifestNode]) -> EditorIssueTarget? {
            for node in nodes {
                if (node.script?.bindings ?? []).contains(where: { binding in
                    let reference = binding.identifier ?? "handle #\(binding.script)"
                    return binding.isEnabled && descriptions.contains("\(node.name): \(reference)")
                }) { return .entity(id: node.id) }
                if let target = find(node.children) { return target }
            }
            return nil
        }
        return find(manifest.roots)
    }

    static func compilerDiagnostic(scriptID: String, sourceURL: URL, output: String) -> EditorIssueTarget {
        let name = NSRegularExpression.escapedPattern(for: sourceURL.lastPathComponent)
        let pattern = "(?:^|\\n)[^\\n]*" + name + ":([0-9]+):([0-9]+):\\s*error:"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let lineRange = Range(match.range(at: 1), in: output),
           let columnRange = Range(match.range(at: 2), in: output),
           let line = Int(output[lineRange]), let column = Int(output[columnRange]) {
            return .script(id: scriptID, line: max(0, line - 1), column: max(0, column - 1))
        }
        return .script(id: scriptID, line: 0, column: 0)
    }
}

public enum EditorOperationKind: String, Codable, Sendable {
    case importing, exporting
}

public enum EditorOperationStatus: String, Codable, Sendable {
    case running, succeeded, failed
}

public struct EditorOperation: Identifiable, Sendable, Equatable {
    public let id: String
    public var kind: EditorOperationKind
    public var status: EditorOperationStatus
    public var message: String
    public var completed: Int
    public var total: Int
    public var nextStep: String?
    public var target: EditorIssueTarget?

    public init(id: String = UUID().uuidString, kind: EditorOperationKind,
                status: EditorOperationStatus = .running, message: String,
                completed: Int = 0, total: Int = 0, nextStep: String? = nil,
                target: EditorIssueTarget? = nil) {
        self.id = id; self.kind = kind; self.status = status; self.message = message
        self.completed = completed; self.total = total; self.nextStep = nextStep; self.target = target
    }
}

public struct EditorScriptNavigationRequest: Equatable, Sendable {
    public let id: UUID
    public let scriptID: String
    public let line: Int
    public let column: Int

    public init(scriptID: String, line: Int = 0, column: Int = 0) {
        id = UUID(); self.scriptID = scriptID
        self.line = max(0, line); self.column = max(0, column)
    }
}
