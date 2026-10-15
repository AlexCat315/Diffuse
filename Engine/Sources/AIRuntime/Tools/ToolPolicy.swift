import Foundation

/// One model-facing tool invocation observed before it executes.
public struct ToolCall: Sendable, Equatable {
    public var name: String
    /// Canonical JSON arguments; empty when the tool takes none.
    public var arguments: Data
    public var origin: ToolCallOrigin

    public init(name: String, arguments: Data, origin: ToolCallOrigin) {
        self.name = name
        self.arguments = arguments
        self.origin = origin
    }
}

/// Where a tool call came from. Policies may scope checks by origin; it grants
/// no authority.
public enum ToolCallOrigin: Sendable, Equatable {
    case agentSession
    case mcp
}

/// One policy handler's verdict.
public enum ToolPolicyDecision: Sendable {
    /// Continue with the (possibly rewritten) call.
    case allow(ToolCall)
    /// Stop the policy chain; the call does not execute.
    case deny(ToolPolicyDenial)
}

/// Why a policy refused a tool call.
public struct ToolPolicyDenial: Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Equatable {
        case mode
        case untrustedProject
        case rateLimit
        case policy
    }

    public var code: Code
    public var reason: String

    public init(code: Code, reason: String) {
        self.code = code
        self.reason = reason
    }

    public var description: String { reason }
}

/// Thrown when a tool policy handler returns `.deny`.
public enum ToolPolicyError: Error, Sendable, Equatable {
    case denied(ToolPolicyDenial)
    case invalidRewrite
}

extension ToolPolicyError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .denied(denial): return denial.reason
        case .invalidRewrite: return "tool policies may rewrite arguments, but cannot change the tool name or origin"
        }
    }
}

extension ToolPolicyError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Ordered, short-circuiting policy chain evaluated before a tool call
/// executes.
///
/// Handlers run in registration order and may rewrite the call or stop it with
/// a denial. An empty policy is a pass-through, so hosts that register nothing
/// keep their exact previous behavior. Denials are surfaced to the caller as
/// `ToolPolicyError.denied`; the AI session turns them into a tool-result
/// observation the model can react to, and MCP turns them into a failed tool
/// result.
public struct ToolPolicy: Sendable {
    public typealias Handler = @Sendable (ToolCall) throws -> ToolPolicyDecision

    private let handlers: [Handler]

    public init(handlers: [Handler] = []) {
        self.handlers = handlers
    }

    public func appending(_ handler: @escaping Handler) -> ToolPolicy {
        ToolPolicy(handlers: handlers + [handler])
    }

    /// Returns the call to execute (possibly rewritten). The first denial stops
    /// the chain; errors thrown by handlers propagate unchanged.
    public func evaluate(_ call: ToolCall) throws -> ToolCall {
        var current = call
        for handler in handlers {
            switch try handler(current) {
            case let .allow(next):
                guard next.name == call.name, next.origin == call.origin else {
                    throw ToolPolicyError.invalidRewrite
                }
                current = next
            case let .deny(denial): throw ToolPolicyError.denied(denial)
            }
        }
        return current
    }
}
