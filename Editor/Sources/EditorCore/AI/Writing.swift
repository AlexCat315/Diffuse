import AIRuntime
import Foundation

/// Self-contained text transformations offered in the writing editor. Each
/// runs as one tool-less completion and returns text for the author to review;
/// nothing is applied to the document until they accept it.
public enum EditorWritingAction: String, CaseIterable, Sendable, Identifiable {
    case improve, proofread, shorten, expand, simplify, professional, casual,
         translateEnglish, translateChinese, summarize, continueWriting, outline

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .improve: "Improve Writing"
        case .proofread: "Fix Spelling and Grammar"
        case .shorten: "Make Shorter"
        case .expand: "Make Longer"
        case .simplify: "Simplify Language"
        case .professional: "Professional Tone"
        case .casual: "Casual Tone"
        case .translateEnglish: "Translate to English"
        case .translateChinese: "Translate to Chinese"
        case .summarize: "Summarize"
        case .continueWriting: "Continue Writing"
        case .outline: "Generate Outline"
        }
    }

    /// Whether the result replaces the source text or is added after it.
    public var replacesSource: Bool {
        switch self {
        case .summarize, .continueWriting, .outline: false
        default: true
        }
    }

    var instruction: String {
        switch self {
        case .improve: "Rewrite the text to read more clearly and fluently while keeping its meaning, voice and language."
        case .proofread: "Correct spelling, grammar and punctuation only. Change nothing else."
        case .shorten: "Rewrite the text to be about half as long, keeping every key point."
        case .expand: "Rewrite the text with more detail, examples and explanation, about twice as long."
        case .simplify: "Rewrite the text in plain, simple language that a general reader understands."
        case .professional: "Rewrite the text in a clear, professional tone."
        case .casual: "Rewrite the text in a friendly, conversational tone."
        case .translateEnglish: "Translate the text into natural English."
        case .translateChinese: "Translate the text into natural Simplified Chinese."
        case .summarize: "Summarize the text in a few sentences, in the text's language."
        case .continueWriting: "Continue writing from where the text ends, matching its style, language and format. Return only the continuation."
        case .outline: "Produce a hierarchical Markdown outline (headings and bullets) of the text, in the text's language."
        }
    }
}

extension EditorApplication {
    /// Runs a writing action on `text`. `document` (the whole file) gives the
    /// model context when `text` is only a selection.
    @MainActor
    public func performWritingAction(_ action: EditorWritingAction, text: String, document: String? = nil,
                                     path: String? = nil, customInstruction: String? = nil) async throws -> String {
        let instruction = customInstruction.map { "Apply this instruction to the text: \($0)" } ?? action.instruction
        var prompt = ""
        if let document, document != text, !document.isEmpty {
            prompt += "Surrounding document\(path.map { " (\($0))" } ?? ""), for context only:\n<document>\n\(String(document.prefix(24_000)))\n</document>\n\n"
        }
        prompt += "<text>\n\(String(text.prefix(48_000)))\n</text>"
        return try await completeText(instructions: """
            You are a writing assistant inside a text editor. \(instruction)
            Preserve Markdown formatting, code blocks, links and line structure where they exist.
            Reply with the resulting text only: no preamble, no explanation, no surrounding quotes or code fences.
            """, prompt: prompt)
    }

    /// Drafts a commit message from the changes about to be committed: the
    /// staged changes, or every change when nothing is staged.
    @MainActor
    public func draftCommitMessage() async throws -> String {
        let versionControl = workstation.versionControl
        let snapshot = versionControl.snapshot
        let changes = snapshot.staged.isEmpty ? snapshot.unstaged : snapshot.staged
        guard !changes.isEmpty else { throw EditorProjectToolError("There are no changes to describe.") }
        var budget = 40_000
        var sections: [String] = []
        for change in changes.prefix(40) {
            let summary = "\(change.state.rawValue): \(change.path)"
            guard budget > 0 else { sections.append(summary); continue }
            let diff = String(await versionControl.diff(change).prefix(min(budget, 8_000)))
            budget -= diff.count
            sections.append(summary + (diff.isEmpty ? "" : "\n" + diff))
        }
        let recent = snapshot.history.prefix(8).map(\.summary).joined(separator: "\n")
        let message = try await completeText(instructions: """
            Write a commit message for the changes below. Use a concise imperative subject line \
            of at most 72 characters, then a blank line and a short body only when the change needs \
            explanation. Follow the style of the recent messages when they share a convention. \
            Reply with the commit message only.
            """, prompt: "Recent commit messages:\n\(recent.isEmpty ? "(none)" : recent)\n\nChanges:\n\(sections.joined(separator: "\n\n"))",
            maxTokens: 400)
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
    }

    @MainActor
    func completeText(instructions: String, prompt: String, maxTokens: Int? = nil) async throws -> String {
        await pendingAISetupTask?.value
        guard let session else {
            throw EditorProjectToolError(store.state.assistant.aiSettings.provider == .none
                ? "No AI provider configured. Choose one in Settings."
                : "The configured AI provider has no usable credential.")
        }
        return try await session.complete(instructions: instructions, prompt: prompt, maxTokens: maxTokens)
    }
}
