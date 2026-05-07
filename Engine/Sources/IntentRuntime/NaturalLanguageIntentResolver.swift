import Foundation

public struct NaturalLanguageIntent: Sendable, Equatable, Codable {
    public var id: String
    public var text: String
    public var localeIdentifier: String?
    public var source: IntentSource
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                text: String,
                localeIdentifier: String? = nil,
                source: IntentSource = .human,
                createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.source = source
        self.createdAt = createdAt
    }
}

public struct NaturalLanguageIntentContext: Sendable, Equatable, Codable {
    public var selectedObjectIDs: [String]
    /// Human-readable names of selected entities, for LLM context ("Cube 01", "Camera").
    public var selectedEntityLabels: [String]
    /// Total number of entities currently in the scene.
    public var entityCount: Int
    /// Current workspace mode: "level", "modeling", or "animation".
    public var workspaceMode: String?
    /// VerbIDs of the last 3 successfully applied intents, for multi-step context.
    public var recentVerbs: [String]
    public var localeIdentifier: String?

    public init(selectedObjectIDs: [String] = [],
                selectedEntityLabels: [String] = [],
                entityCount: Int = 0,
                workspaceMode: String? = nil,
                recentVerbs: [String] = [],
                localeIdentifier: String? = nil) {
        self.selectedObjectIDs = selectedObjectIDs
        self.selectedEntityLabels = selectedEntityLabels
        self.entityCount = entityCount
        self.workspaceMode = workspaceMode
        self.recentVerbs = recentVerbs
        self.localeIdentifier = localeIdentifier
    }
}

public struct IntentResolutionCandidate: Sendable, Equatable, Codable {
    public var verbID: String
    public var confidence: Double
    public var reason: String

    public init(verbID: String,
                confidence: Double,
                reason: String) {
        self.verbID = verbID
        self.confidence = confidence
        self.reason = reason
    }
}

public enum UnresolvableIntentReason: String, Sendable, Equatable, Codable {
    case emptyInput = "empty_input"
    case unsupportedVerb = "unsupported_verb"
    case missingTarget = "missing_target"
    case missingArgument = "missing_argument"
}

public enum UnresolvableIntentStatus: String, Sendable, Equatable, Codable {
    case open
    case resolved
    case dismissed
}

public struct UnresolvableIntent: Identifiable, Sendable, Equatable, Codable {
    public var id: String
    public var naturalLanguageIntent: NaturalLanguageIntent
    public var reason: UnresolvableIntentReason
    public var message: String
    public var candidateVerbIDs: [String]
    public var missingArguments: [String]
    public var targetObjectIDs: [String]
    public var status: UnresolvableIntentStatus
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                naturalLanguageIntent: NaturalLanguageIntent,
                reason: UnresolvableIntentReason,
                message: String,
                candidateVerbIDs: [String] = [],
                missingArguments: [String] = [],
                targetObjectIDs: [String] = [],
                status: UnresolvableIntentStatus = .open,
                createdAt: Date = Date()) {
        self.id = id
        self.naturalLanguageIntent = naturalLanguageIntent
        self.reason = reason
        self.message = message
        self.candidateVerbIDs = candidateVerbIDs
        self.missingArguments = missingArguments
        self.targetObjectIDs = targetObjectIDs
        self.status = status
        self.createdAt = createdAt
    }
}

public struct IntentResolutionResult: Sendable, Equatable, Codable {
    public var naturalLanguageIntent: NaturalLanguageIntent
    public var intent: IntentIR?
    public var unresolved: UnresolvableIntent?
    public var candidates: [IntentResolutionCandidate]

    public init(naturalLanguageIntent: NaturalLanguageIntent,
                intent: IntentIR? = nil,
                unresolved: UnresolvableIntent? = nil,
                candidates: [IntentResolutionCandidate] = []) {
        self.naturalLanguageIntent = naturalLanguageIntent
        self.intent = intent
        self.unresolved = unresolved
        self.candidates = candidates
    }

    public var isResolved: Bool {
        intent != nil
    }
}

public struct NaturalLanguageIntentResolver: Sendable {
    public init() {}

    public func resolve(_ naturalLanguageIntent: NaturalLanguageIntent,
                        context: NaturalLanguageIntentContext = NaturalLanguageIntentContext()) -> IntentResolutionResult {
        let trimmed = naturalLanguageIntent.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return unresolved(naturalLanguageIntent,
                              reason: .emptyInput,
                              message: "Enter an intent before submitting it.")
        }

        let normalized = trimmed.lowercased()
        let selectedTargets = context.selectedObjectIDs
        let candidate = classify(normalized)
        guard let candidate else {
            return unresolved(naturalLanguageIntent,
                              reason: .unsupportedVerb,
                              message: "No registered capability matched this intent.",
                              candidates: [])
        }

        switch candidate.verbID {
        case "scene.spawn_entity":
            let label = quotedText(in: trimmed)
                ?? valueAfterKeyword(in: trimmed, keywords: ["named", "called", "name", "名为", "叫", "命名为"])
                ?? "AI Entity"
            let position = parseVec3(in: trimmed) ?? IntentVector3(x: 0, y: 0, z: 0)
            return resolved(naturalLanguageIntent,
                            verb: "scene.spawn_entity",
                            summary: "Spawn scene entity",
                            targetObjectIDs: [],
                            arguments: [
                                "label": .string(label),
                                "position": .vec3(position),
                            ],
                            confidence: candidate.confidence,
                            candidates: [candidate])

        case "scene.set_name":
            guard !selectedTargets.isEmpty else {
                return unresolved(naturalLanguageIntent,
                                  reason: .missingTarget,
                                  message: "Select an entity before renaming it.",
                                  candidates: [candidate],
                                  missingArguments: ["entity_id"])
            }
            guard let name = quotedText(in: trimmed)
                    ?? valueAfterKeyword(in: trimmed, keywords: [" to ", " as ", "为", "叫", "命名为", "改成", "改为"]),
                  !name.isEmpty
            else {
                return unresolved(naturalLanguageIntent,
                                  reason: .missingArgument,
                                  message: "Provide a new name for the selected entity.",
                                  candidates: [candidate],
                                  missingArguments: ["name"],
                                  targetObjectIDs: selectedTargets)
            }
            return resolved(naturalLanguageIntent,
                            verb: "scene.set_name",
                            summary: "Rename selected entity",
                            targetObjectIDs: selectedTargets,
                            arguments: ["name": .string(name)],
                            confidence: candidate.confidence,
                            candidates: [candidate])

        case "scene.duplicate_entity":
            guard !selectedTargets.isEmpty else {
                return unresolved(naturalLanguageIntent,
                                  reason: .missingTarget,
                                  message: "Select an entity before duplicating it.",
                                  candidates: [candidate],
                                  missingArguments: ["entity_id"])
            }
            return resolved(naturalLanguageIntent,
                            verb: "scene.duplicate_entity",
                            summary: "Duplicate selected entity",
                            targetObjectIDs: selectedTargets,
                            arguments: [:],
                            confidence: candidate.confidence,
                            candidates: [candidate])

        case "scene.delete_entity":
            guard !selectedTargets.isEmpty else {
                return unresolved(naturalLanguageIntent,
                                  reason: .missingTarget,
                                  message: "Select an entity before deleting it.",
                                  candidates: [candidate],
                                  missingArguments: ["entity_id"])
            }
            return resolved(naturalLanguageIntent,
                            verb: "scene.delete_entity",
                            summary: "Delete selected entity",
                            targetObjectIDs: selectedTargets,
                            arguments: [:],
                            confidence: candidate.confidence,
                            candidates: [candidate])

        case "scene.set_transform":
            guard !selectedTargets.isEmpty else {
                return unresolved(naturalLanguageIntent,
                                  reason: .missingTarget,
                                  message: "Select an entity before setting its transform.",
                                  candidates: [candidate],
                                  missingArguments: ["entity_id"])
            }
            guard let position = parseVec3(in: trimmed) else {
                return unresolved(naturalLanguageIntent,
                                  reason: .missingArgument,
                                  message: "Provide a target position as three numbers.",
                                  candidates: [candidate],
                                  missingArguments: ["translation"],
                                  targetObjectIDs: selectedTargets)
            }
            return resolved(naturalLanguageIntent,
                            verb: "scene.set_transform",
                            summary: "Set selected transform",
                            targetObjectIDs: selectedTargets,
                            arguments: ["translation": .vec3(position)],
                            confidence: candidate.confidence,
                            candidates: [candidate])

        case "scene.set_visibility":
            guard !selectedTargets.isEmpty else {
                return unresolved(naturalLanguageIntent,
                                  reason: .missingTarget,
                                  message: "Select an entity before toggling its visibility.",
                                  candidates: [candidate],
                                  missingArguments: ["entity_id"])
            }
            let isHiding = containsAny(normalized, ["hide", "invisible", "隐藏", "不可见"])
            return resolved(naturalLanguageIntent,
                            verb: "scene.set_visibility",
                            summary: isHiding ? "Hide selected entity" : "Show selected entity",
                            targetObjectIDs: selectedTargets,
                            arguments: ["visible": .bool(!isHiding)],
                            confidence: candidate.confidence,
                            candidates: [candidate])

        case "scene.reset_transform":
            guard !selectedTargets.isEmpty else {
                return unresolved(naturalLanguageIntent,
                                  reason: .missingTarget,
                                  message: "Select an entity before resetting its transform.",
                                  candidates: [candidate],
                                  missingArguments: ["entity_id"])
            }
            return resolved(naturalLanguageIntent,
                            verb: "scene.reset_transform",
                            summary: "Reset selected entity transform",
                            targetObjectIDs: selectedTargets,
                            arguments: [:],
                            confidence: candidate.confidence,
                            candidates: [candidate])

        case "scene.snap_to_ground":
            guard !selectedTargets.isEmpty else {
                return unresolved(naturalLanguageIntent,
                                  reason: .missingTarget,
                                  message: "Select an entity before snapping it to ground.",
                                  candidates: [candidate],
                                  missingArguments: ["entity_id"])
            }
            return resolved(naturalLanguageIntent,
                            verb: "scene.snap_to_ground",
                            summary: "Snap selected entity to ground",
                            targetObjectIDs: selectedTargets,
                            arguments: [:],
                            confidence: candidate.confidence,
                            candidates: [candidate])

        default:
            return unresolved(naturalLanguageIntent,
                              reason: .unsupportedVerb,
                              message: "The matched capability is not yet supported by the deterministic resolver.",
                              candidates: [candidate])
        }
    }

    private func classify(_ text: String) -> IntentResolutionCandidate? {
        if containsAny(text, ["spawn", "create", "add", "new entity", "生成", "创建", "添加", "新建"]) {
            return IntentResolutionCandidate(verbID: "scene.spawn_entity", confidence: 0.76, reason: "spawn keyword")
        }
        if containsAny(text, ["rename", "set name", "change name", "重命名", "改名", "命名"]) {
            return IntentResolutionCandidate(verbID: "scene.set_name", confidence: 0.78, reason: "rename keyword")
        }
        if containsAny(text, ["duplicate", "copy", "clone", "复制", "克隆"]) {
            return IntentResolutionCandidate(verbID: "scene.duplicate_entity", confidence: 0.74, reason: "duplicate keyword")
        }
        if containsAny(text, ["delete", "remove", "删除", "移除"]) {
            return IntentResolutionCandidate(verbID: "scene.delete_entity", confidence: 0.74, reason: "delete keyword")
        }
        if containsAny(text, ["move", "translate", "set transform", "set position", "移动", "平移", "设置位置"]) {
            return IntentResolutionCandidate(verbID: "scene.set_transform", confidence: 0.7, reason: "transform keyword")
        }
        if containsAny(text, ["hide", "show", "visible", "invisible", "visibility", "隐藏", "显示", "可见", "不可见"]) {
            return IntentResolutionCandidate(verbID: "scene.set_visibility", confidence: 0.76, reason: "visibility keyword")
        }
        if containsAny(text, ["reset transform", "reset position", "reset rotation", "reset scale",
                               "center transform", "归零", "重置变换", "重置位置", "重置旋转"]) {
            return IntentResolutionCandidate(verbID: "scene.reset_transform", confidence: 0.74, reason: "reset keyword")
        }
        if containsAny(text, ["snap to ground", "snap ground", "贴地", "落地", "吸附到地面"]) {
            return IntentResolutionCandidate(verbID: "scene.snap_to_ground", confidence: 0.74, reason: "snap keyword")
        }
        return nil
    }

    private func resolved(_ naturalLanguageIntent: NaturalLanguageIntent,
                          verb: String,
                          summary: String,
                          targetObjectIDs: [String],
                          arguments: [String: IntentArgumentValue],
                          confidence: Double,
                          candidates: [IntentResolutionCandidate]) -> IntentResolutionResult {
        let intent = IntentIR(verb: verb,
                              summary: summary,
                              targetObjectIDs: targetObjectIDs,
                              arguments: arguments,
                              confidence: confidence,
                              evidence: [
                                IntentEvidence(kind: "natural_language",
                                               summary: naturalLanguageIntent.text)
                              ],
                              source: naturalLanguageIntent.source)
        return IntentResolutionResult(naturalLanguageIntent: naturalLanguageIntent,
                                      intent: intent,
                                      candidates: candidates)
    }

    private func unresolved(_ naturalLanguageIntent: NaturalLanguageIntent,
                            reason: UnresolvableIntentReason,
                            message: String,
                            candidates: [IntentResolutionCandidate] = [],
                            missingArguments: [String] = [],
                            targetObjectIDs: [String] = []) -> IntentResolutionResult {
        let unresolved = UnresolvableIntent(naturalLanguageIntent: naturalLanguageIntent,
                                            reason: reason,
                                            message: message,
                                            candidateVerbIDs: candidates.map(\.verbID),
                                            missingArguments: missingArguments,
                                            targetObjectIDs: targetObjectIDs)
        return IntentResolutionResult(naturalLanguageIntent: naturalLanguageIntent,
                                      unresolved: unresolved,
                                      candidates: candidates)
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func quotedText(in text: String) -> String? {
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("《", "》")]
        for (open, close) in pairs {
            guard let start = text.firstIndex(of: open) else { continue }
            let bodyStart = text.index(after: start)
            guard bodyStart < text.endIndex,
                  let end = text[bodyStart...].firstIndex(of: close)
            else { continue }
            let value = String(text[bodyStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func valueAfterKeyword(in text: String, keywords: [String]) -> String? {
        for keyword in keywords {
            guard let range = text.range(of: keyword, options: [.caseInsensitive]) else { continue }
            let value = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func parseVec3(in text: String) -> IntentVector3? {
        let pattern = #"[-+]?\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        let values = matches.compactMap { match -> Float? in
            guard let range = Range(match.range, in: text) else { return nil }
            return Float(text[range])
        }
        guard values.count >= 3 else { return nil }
        return IntentVector3(x: values[0], y: values[1], z: values[2])
    }
}

public final class UnresolvableIntentQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UnresolvableIntent]

    public init(items: [UnresolvableIntent] = []) {
        self.items = items
    }

    @discardableResult
    public func append(_ item: UnresolvableIntent) -> UnresolvableIntent {
        lock.lock()
        items.append(item)
        lock.unlock()
        return item
    }

    public func snapshot(includeClosed: Bool = false) -> [UnresolvableIntent] {
        lock.lock()
        let result = includeClosed ? items : items.filter { $0.status == .open }
        lock.unlock()
        return result
    }

    public func markResolved(id: String) {
        update(id: id, status: .resolved)
    }

    public func dismiss(id: String) {
        update(id: id, status: .dismissed)
    }

    private func update(id: String, status: UnresolvableIntentStatus) {
        lock.lock()
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].status = status
        }
        lock.unlock()
    }
}
