import CapabilityRuntime
import Foundation

/// Layer 1 of the three-tier intent resolution pipeline.
///
/// Classifies natural-language intents against the registered capability set using
/// weighted token overlap and synonym expansion. Runs synchronously in <5 ms with
/// no network calls. Returns `nil` when confidence falls below `confidenceThreshold`,
/// signalling the coordinator to escalate to the AI backend (Layer 2).
///
/// # Scoring
/// Each capability gets a weighted token bag:
///   - verbID tokens   × 3  (most diagnostic: "scene", "spawn", "transform")
///   - summary tokens  × 2  (human-readable intent description)
///   - argument hints  × 0.5 (domain vocabulary)
///
/// The query is tokenized and synonym-expanded before matching. Score =
/// Σ(matched weights) / Σ(total capability weights), capped at 1.0.
///
/// # Argument filling
/// Layer 1 fills `targetObjectIDs` from the context's selected objects.
/// All other argument slots are left empty — the `IntentTransactionBuilder`
/// and `AmbiguityScorer` handle missing args through the confirmation path.
public struct LocalIntentClassifier: Sendable {

    // MARK: - Configuration

    /// Minimum score required to return a result instead of escalating to Layer 2.
    /// Range 0…1. Lower values increase recall but risk false positives.
    public var confidenceThreshold: Double

    public init(confidenceThreshold: Double = 0.32) {
        self.confidenceThreshold = confidenceThreshold
    }

    // MARK: - Public API

    /// Returns a resolved `IntentResolutionResult` if the classifier is confident enough,
    /// or `nil` to signal escalation to the next layer.
    public func classify(
        _ intent: NaturalLanguageIntent,
        context: NaturalLanguageIntentContext,
        capabilities: [CapabilitySymbolicView]
    ) -> IntentResolutionResult? {
        guard !capabilities.isEmpty else { return nil }

        let queryTokens = expandedTokens(from: intent.text)
        guard !queryTokens.isEmpty else { return nil }

        var bestCapability: CapabilitySymbolicView?
        var bestScore: Double = 0

        for capability in capabilities {
            let s = score(queryTokens: queryTokens, capability: capability)
            if s > bestScore {
                bestScore = s
                bestCapability = capability
            }
        }

        guard let capability = bestCapability, bestScore >= confidenceThreshold else {
            return nil
        }

        let confidence = min(bestScore, 1.0)
        let ir = IntentIR(
            verb: capability.verbID,
            summary: capability.summary,
            targetObjectIDs: context.selectedObjectIDs,
            arguments: [:],
            confidence: confidence,
            evidence: [IntentEvidence(kind: "local_classifier", summary: intent.text)],
            source: intent.source
        )

        return IntentResolutionResult(
            naturalLanguageIntent: intent,
            intent: ir,
            candidates: [IntentResolutionCandidate(verbID: capability.verbID,
                                                    confidence: confidence,
                                                    reason: "token_overlap")]
        )
    }

    /// Returns the top-N capabilities by score, sorted descending, above `minConfidence`.
    /// Used for live suggestions as the user types — callers should pass a low `minConfidence`
    /// (e.g. 0.1) so partially-typed queries surface results early.
    public func topMatches(
        _ intent: NaturalLanguageIntent,
        context: NaturalLanguageIntentContext,
        capabilities: [CapabilitySymbolicView],
        maxCount: Int = 3,
        minConfidence: Double = 0.1
    ) -> [(capability: CapabilitySymbolicView, confidence: Double)] {
        guard !capabilities.isEmpty else { return [] }
        let queryTokens = expandedTokens(from: intent.text)
        guard !queryTokens.isEmpty else { return [] }

        return capabilities
            .compactMap { cap -> (CapabilitySymbolicView, Double)? in
                let s = score(queryTokens: queryTokens, capability: cap)
                guard s >= minConfidence else { return nil }
                return (cap, min(s, 1.0))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(maxCount)
            .map { $0 }
    }

    // MARK: - Scoring

    private func score(queryTokens: Set<String>, capability: CapabilitySymbolicView) -> Double {
        var weightedTokens: [String: Double] = [:]

        for token in tokenize(capability.verbID) {
            weightedTokens[token, default: 0] += 3.0
        }
        for token in tokenize(capability.summary) {
            weightedTokens[token, default: 0] += 2.0
        }
        for arg in capability.arguments {
            for token in tokenize(arg.llmHint ?? arg.description ?? arg.name) {
                weightedTokens[token, default: 0] += 0.5
            }
        }

        let totalWeight = weightedTokens.values.reduce(0, +)
        guard totalWeight > 0 else { return 0 }

        // Build the synonym-expanded set from core tokens only (verbID + summary, weight ≥ 2).
        // Excluding arg-hint tokens prevents low-weight descriptor words (e.g. "new" in
        // "new entity name") from creating spurious cross-capability synonym matches.
        var capCoreSet = Set<String>()
        for (token, weight) in weightedTokens where weight >= 2.0 {
            capCoreSet.insert(token)
            if let synonyms = Synonyms.map[token] {
                capCoreSet.formUnion(synonyms)
            }
        }

        var matchWeight: Double = 0
        for queryToken in queryTokens {
            if let w = weightedTokens[queryToken] {
                matchWeight += w
            } else if let synonyms = Synonyms.map[queryToken],
                      !synonyms.isDisjoint(with: capCoreSet) {
                // Synonym hit gets a flat bonus rather than proportional weight to avoid
                // inflating scores on small capabilities.
                matchWeight += 1.0
            }
        }

        return matchWeight / totalWeight
    }

    // MARK: - Tokenisation

    private func expandedTokens(from text: String) -> Set<String> {
        var tokens = tokenize(text)
        for token in tokens {
            if let synonyms = Synonyms.map[token] {
                tokens.formUnion(synonyms)
            }
        }
        return tokens
    }

    private func tokenize(_ text: String) -> Set<String> {
        var tokens: Set<String> = []
        let lower = text.lowercased()
        var buffer = ""
        var cjkRun: [Character] = []

        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            // Emit individual characters and bigrams so both single-char
            // and two-char compound words (e.g. "创建") can match synonyms.
            for ch in cjkRun { tokens.insert(String(ch)) }
            for i in 0 ..< cjkRun.count - 1 {
                tokens.insert(String(cjkRun[i]) + String(cjkRun[i + 1]))
            }
            cjkRun.removeAll()
        }

        for char in lower {
            if char.isCJK {
                if !buffer.isEmpty {
                    tokens.formUnion(wordSplit(buffer))
                    buffer = ""
                }
                cjkRun.append(char)
            } else {
                flushCJK()
                buffer.append(char)
            }
        }
        flushCJK()
        if !buffer.isEmpty {
            tokens.formUnion(wordSplit(buffer))
        }
        return tokens
    }

    private func wordSplit(_ text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: "[a-z0-9]+") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(
            regex.matches(in: text, range: range).compactMap { match in
                guard let r = Range(match.range, in: text) else { return nil }
                let token = String(text[r])
                return token.count >= 2 ? token : nil
            }
        )
    }
}

// MARK: - Synonym table

private enum Synonyms {
    static let map: [String: Set<String>] = {
        var result: [String: Set<String>] = [:]
        for group in groups {
            let set = Set(group)
            for term in group { result[term] = set }
        }
        return result
    }()

    // Each inner array is one equivalence group.
    // English and Chinese terms share the same group so cross-language matching works.
    static let groups: [[String]] = [
        // Create / spawn
        ["spawn", "create", "add", "new", "instantiate",
         "生成", "创建", "添加", "新建", "新增", "实例化"],
        // Delete / remove
        ["delete", "remove", "destroy", "erase",
         "删除", "移除", "删掉", "销毁"],
        // Rename / name
        ["rename", "name", "label", "title",
         "重命名", "改名", "命名", "名字"],
        // Duplicate / copy
        ["duplicate", "copy", "clone",
         "复制", "克隆", "拷贝"],
        // Move / translate / transform
        ["move", "translate", "position", "transform", "relocate",
         "移动", "平移", "位置", "移到", "变换"],
        // Rotate
        ["rotate", "spin", "turn",
         "旋转", "转动"],
        // Scale / resize
        ["scale", "resize", "size",
         "缩放", "调整大小", "尺寸"],
        // Parent / attach / reparent
        ["parent", "attach", "reparent", "group",
         "父节点", "挂载", "附加", "编组"],
        // Component
        ["component", "module",
         "组件", "模块"],
        // Import
        ["import", "load",
         "导入", "载入"],
        // Export
        ["export", "save",
         "导出", "保存"],
        // Bake / cache
        ["bake", "cache", "precompute",
         "烘焙", "缓存"],
        // Render
        ["render", "draw",
         "渲染", "绘制"],
        // Camera
        ["camera", "cam", "view",
         "摄像机", "相机", "视角"],
        // Light / lighting
        ["light", "lighting", "illumination",
         "灯光", "光源", "照明"],
        // Animation
        ["animation", "anim", "animate", "keyframe",
         "动画", "关键帧"],
        // Sequence / shot / timeline
        ["sequence", "shot", "timeline", "clip",
         "序列", "镜头", "时间线", "片段"],
        // Set / assign / apply
        ["set", "assign", "apply", "update", "change",
         "设置", "赋值", "应用", "更新", "修改"],
        // Material / texture
        ["material", "texture", "shader", "surface",
         "材质", "纹理", "着色器", "表面"],
        // Scene
        ["scene", "level", "world",
         "场景", "关卡", "世界"],
    ]
}

// MARK: - Character helper

private extension Character {
    var isCJK: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v)    // CJK Unified Ideographs
            || (0x3400...0x4DBF).contains(v)    // CJK Extension A
            || (0xF900...0xFAFF).contains(v)    // CJK Compatibility Ideographs
    }
}
