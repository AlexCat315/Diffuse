internal import Foundation

enum ScriptAssistanceReplies {
    static func signatures(_ data: Data?) -> ScriptSignatureHelp? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["signatures"] as? [[String: Any]] else { return nil }
        let signatures = candidates.compactMap { candidate -> ScriptSignatureInformation? in
            guard let label = candidate["label"] as? String else { return nil }
            let parameters = (candidate["parameters"] as? [[String: Any]] ?? []).compactMap { parameter -> ScriptSignatureParameter? in
                let parameterLabel: String
                if let text = parameter["label"] as? String { parameterLabel = text }
                else if let offsets = parameter["label"] as? [Int], offsets.count == 2,
                        offsets[0] >= 0, offsets[0] <= offsets[1], offsets[1] <= label.utf16.count,
                        let start = String.Index(utf16Offset: offsets[0], in: label).samePosition(in: label),
                        let end = String.Index(utf16Offset: offsets[1], in: label).samePosition(in: label) {
                    parameterLabel = String(label[start..<end])
                } else { return nil }
                return ScriptSignatureParameter(label: parameterLabel, documentation: ScriptLanguageReplies.parseMarkup(parameter["documentation"])?.text)
            }
            return ScriptSignatureInformation(label: label, documentation: ScriptLanguageReplies.parseMarkup(candidate["documentation"])?.text,
                                              parameters: parameters)
        }
        guard !signatures.isEmpty else { return nil }
        let active = min(max(0, object["activeSignature"] as? Int ?? 0), signatures.count - 1)
        let parameter = candidates.indices.contains(active) ? candidates[active]["activeParameter"] as? Int : nil
        return ScriptSignatureHelp(signatures: signatures, activeSignature: active,
                                    activeParameter: parameter ?? object["activeParameter"] as? Int)
    }

    static func symbols(_ data: Data?) -> [ScriptDocumentSymbol] {
        guard let data, let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return values.compactMap(symbol)
    }

    private static func symbol(_ object: [String: Any]) -> ScriptDocumentSymbol? {
        guard let name = object["name"] as? String, let kind = object["kind"] as? Int,
              let range = ScriptLanguageReplies.parseSpan(object["range"] ?? (object["location"] as? [String: Any])?["range"]) else { return nil }
        return ScriptDocumentSymbol(name: name, detail: object["detail"] as? String, kind: kind, range: range,
                                    selectionRange: ScriptLanguageReplies.parseSpan(object["selectionRange"]) ?? range,
                                    children: (object["children"] as? [[String: Any]] ?? []).compactMap(symbol))
    }
}
