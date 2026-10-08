import Foundation
import GuavaUIRuntime

public struct FormIssue: Equatable, Sendable, Identifiable {
    public let fieldID: String
    public let label: String
    public let message: String
    public var id: String { fieldID }
    public init(fieldID: String, label: String, message: String) {
        self.fieldID = fieldID; self.label = label; self.message = message
    }
}

/// Rules read application-owned values when validation runs, avoiding a parallel field-value model.
public struct FormRule {
    public let fieldID: String
    public let label: String
    public let validate: () -> String?
    public init(_ fieldID: String, label: String, validate: @escaping () -> String?) {
        self.fieldID = fieldID; self.label = label; self.validate = validate
    }
    public static func required(_ fieldID: String, label: String, value: @escaping () -> String) -> Self {
        Self(fieldID, label: label) { value().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "This field is required." : nil }
    }
}

public enum FormSubmissionState: Equatable, Sendable {
    case editing, submitting, succeeded, failed(String)
}

private struct FormSession {
    var issues: [FormIssue] = []
    var submission: FormSubmissionState = .editing
    var submitCount = 0
}

/// Transient validation/submission state. Authored values and persistence stay in the application.
public final class FormController {
    private var session = FormSession()
    private let registrar = ObservableStateRegistrar()
    public init() {}
    public var issues: [FormIssue] { registrar.access("form"); return session.issues }
    public var submission: FormSubmissionState { registrar.access("form"); return session.submission }
    public var submitCount: Int { registrar.access("form"); return session.submitCount }
    public var isSubmitting: Bool { submission == .submitting }
    public func error(for fieldID: String) -> String? { issues.first { $0.fieldID == fieldID }?.message }

    @discardableResult
    public func validate(_ rules: [FormRule]) -> Bool {
        precondition(Set(rules.map(\.fieldID)).count == rules.count, "Form field IDs must be unique")
        session.issues = rules.compactMap { rule in
            guard let message = rule.validate(), !message.isEmpty else { return nil }
            return FormIssue(fieldID: rule.fieldID, label: rule.label, message: message)
        }
        registrar.invalidate("form")
        return session.issues.isEmpty
    }
    @discardableResult
    public func beginSubmit(_ rules: [FormRule]) -> Bool {
        guard !isSubmitting else { return false }
        session.submitCount += 1
        guard validate(rules) else { session.submission = .editing; registrar.invalidate("form"); return false }
        session.submission = .submitting
        registrar.invalidate("form")
        return true
    }
    public func finishSubmit(error: String? = nil) {
        guard isSubmitting else { return }
        session.submission = error.map(FormSubmissionState.failed) ?? .succeeded
        registrar.invalidate("form")
    }
    public func reset() { session = FormSession(); registrar.invalidate("form") }
}
