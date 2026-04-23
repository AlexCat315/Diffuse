import Foundation

public enum PreconditionKind: String, Sendable, Equatable, Codable {
    case targetState = "target_state"
    case documentRevision = "document_revision"
    case role
    case releasePhase = "release_phase"
    case budget
    case cacheValidity = "cache_validity"
    case bindingResolved = "binding_resolved"
    case custom
}

public enum PreconditionSeverity: String, Sendable, Equatable, Codable {
    case block
    case warn
}

public enum PredicateComparisonOperator: String, Sendable, Equatable, Codable {
    case equal = "=="
    case notEqual = "!="
    case lessThan = "<"
    case lessThanOrEqual = "<="
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
}

public enum RegexSafelistPattern: String, Sendable, Equatable, Codable {
    case identifier
    case dottedIdentifier = "dotted_identifier"
    case phrase

    var pattern: String {
        switch self {
        case .identifier:
            return "^[A-Za-z_][A-Za-z0-9_]*$"
        case .dottedIdentifier:
            return "^[A-Za-z_][A-Za-z0-9_.]*$"
        case .phrase:
            return "^[A-Za-z0-9 _.-]+$"
        }
    }
}

public enum PredicateValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case null
}

public indirect enum PredicateAst: Sendable, Equatable, Codable {
    case literal(PredicateValue)
    case fieldRef(String)
    case compare(PredicateComparisonOperator, lhs: PredicateAst, rhs: PredicateAst)
    case not(PredicateAst)
    case and([PredicateAst])
    case or([PredicateAst])
    case inSet(value: PredicateAst, options: [PredicateValue])
    case matchesRegexSafelist(value: PredicateAst, pattern: RegexSafelistPattern)
    case exists(String)
    case revisionEq(field: String, expected: String)
    case roleAtLeast(CapabilityRole)

    enum CodingKeys: String, CodingKey {
        case op
        case value
        case lhs
        case rhs
        case nodes
        case options
        case pattern
        case field
        case expected
        case role
    }

    enum Op: String, Codable {
        case literal
        case fieldRef = "field_ref"
        case compare
        case not
        case and
        case or
        case inSet = "in_set"
        case matchesRegexSafelist = "matches_regex_safelist"
        case exists
        case revisionEq = "revision_eq"
        case roleAtLeast = "role_at_least"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let op = try container.decode(Op.self, forKey: .op)
        switch op {
        case .literal:
            self = .literal(try container.decode(PredicateValue.self, forKey: .value))
        case .fieldRef:
            self = .fieldRef(try container.decode(String.self, forKey: .field))
        case .compare:
            self = .compare(try container.decode(PredicateComparisonOperator.self, forKey: .value),
                            lhs: try container.decode(PredicateAst.self, forKey: .lhs),
                            rhs: try container.decode(PredicateAst.self, forKey: .rhs))
        case .not:
            self = .not(try container.decode(PredicateAst.self, forKey: .value))
        case .and:
            self = .and(try container.decode([PredicateAst].self, forKey: .nodes))
        case .or:
            self = .or(try container.decode([PredicateAst].self, forKey: .nodes))
        case .inSet:
            self = .inSet(value: try container.decode(PredicateAst.self, forKey: .value),
                          options: try container.decode([PredicateValue].self, forKey: .options))
        case .matchesRegexSafelist:
            self = .matchesRegexSafelist(value: try container.decode(PredicateAst.self, forKey: .value),
                                         pattern: try container.decode(RegexSafelistPattern.self, forKey: .pattern))
        case .exists:
            self = .exists(try container.decode(String.self, forKey: .field))
        case .revisionEq:
            self = .revisionEq(field: try container.decode(String.self, forKey: .field),
                               expected: try container.decode(String.self, forKey: .expected))
        case .roleAtLeast:
            self = .roleAtLeast(try container.decode(CapabilityRole.self, forKey: .role))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .literal(value):
            try container.encode(Op.literal, forKey: .op)
            try container.encode(value, forKey: .value)
        case let .fieldRef(path):
            try container.encode(Op.fieldRef, forKey: .op)
            try container.encode(path, forKey: .field)
        case let .compare(op, lhs, rhs):
            try container.encode(Op.compare, forKey: .op)
            try container.encode(op, forKey: .value)
            try container.encode(lhs, forKey: .lhs)
            try container.encode(rhs, forKey: .rhs)
        case let .not(inner):
            try container.encode(Op.not, forKey: .op)
            try container.encode(inner, forKey: .value)
        case let .and(nodes):
            try container.encode(Op.and, forKey: .op)
            try container.encode(nodes, forKey: .nodes)
        case let .or(nodes):
            try container.encode(Op.or, forKey: .op)
            try container.encode(nodes, forKey: .nodes)
        case let .inSet(value, options):
            try container.encode(Op.inSet, forKey: .op)
            try container.encode(value, forKey: .value)
            try container.encode(options, forKey: .options)
        case let .matchesRegexSafelist(value, pattern):
            try container.encode(Op.matchesRegexSafelist, forKey: .op)
            try container.encode(value, forKey: .value)
            try container.encode(pattern, forKey: .pattern)
        case let .exists(field):
            try container.encode(Op.exists, forKey: .op)
            try container.encode(field, forKey: .field)
        case let .revisionEq(field, expected):
            try container.encode(Op.revisionEq, forKey: .op)
            try container.encode(field, forKey: .field)
            try container.encode(expected, forKey: .expected)
        case let .roleAtLeast(role):
            try container.encode(Op.roleAtLeast, forKey: .op)
            try container.encode(role, forKey: .role)
        }
    }
}

public struct Precondition: Sendable, Equatable, Codable {
    public var id: String
    public var kind: PreconditionKind
    public var expr: PredicateAst
    public var message: String
    public var severity: PreconditionSeverity

    public init(id: String,
                kind: PreconditionKind,
                expr: PredicateAst,
                message: String,
                severity: PreconditionSeverity) {
        self.id = id
        self.kind = kind
        self.expr = expr
        self.message = message
        self.severity = severity
    }
}

public struct CapabilityFacts: Sendable, Equatable {
    public var values: [String: PredicateValue]

    public init(values: [String: PredicateValue] = [:]) {
        self.values = values
    }

    public subscript(path: String) -> PredicateValue? {
        values[path]
    }
}

public struct PreconditionFailure: Sendable, Equatable {
    public var preconditionID: String
    public var message: String
    public var severity: PreconditionSeverity

    public init(preconditionID: String,
                message: String,
                severity: PreconditionSeverity) {
        self.preconditionID = preconditionID
        self.message = message
        self.severity = severity
    }
}

public struct PreconditionReport: Sendable, Equatable {
    public var failures: [PreconditionFailure]

    public init(failures: [PreconditionFailure] = []) {
        self.failures = failures
    }

    public var blockingFailures: [PreconditionFailure] {
        failures.filter { $0.severity == .block }
    }

    public var warnings: [PreconditionFailure] {
        failures.filter { $0.severity == .warn }
    }

    public var isAllowed: Bool {
        blockingFailures.isEmpty
    }
}

public struct PreconditionChecker {
    public init() {}

    public func evaluate(_ preconditions: [Precondition],
                         facts: CapabilityFacts,
                         currentRole: CapabilityRole) -> PreconditionReport {
        let failures = preconditions.compactMap { precondition -> PreconditionFailure? in
            let passed = evaluate(precondition.expr, facts: facts, currentRole: currentRole)
            guard !passed else { return nil }
            return PreconditionFailure(preconditionID: precondition.id,
                                       message: precondition.message,
                                       severity: precondition.severity)
        }
        return PreconditionReport(failures: failures)
    }

    private func evaluate(_ expr: PredicateAst,
                          facts: CapabilityFacts,
                          currentRole: CapabilityRole) -> Bool {
        switch expr {
        case let .literal(value):
            if case let .bool(boolean) = value {
                return boolean
            }
            return resolvedValue(for: expr, facts: facts, currentRole: currentRole) != .null

        case .fieldRef:
            return resolvedValue(for: expr, facts: facts, currentRole: currentRole) != .null

        case let .compare(op, lhs, rhs):
            return compare(resolvedValue(for: lhs, facts: facts, currentRole: currentRole),
                           resolvedValue(for: rhs, facts: facts, currentRole: currentRole),
                           using: op)

        case let .not(inner):
            return !evaluate(inner, facts: facts, currentRole: currentRole)

        case let .and(nodes):
            return nodes.allSatisfy { evaluate($0, facts: facts, currentRole: currentRole) }

        case let .or(nodes):
            return nodes.contains { evaluate($0, facts: facts, currentRole: currentRole) }

        case let .inSet(value, options):
            let resolved = resolvedValue(for: value, facts: facts, currentRole: currentRole)
            return options.contains(resolved)

        case let .matchesRegexSafelist(value, pattern):
            guard case let .string(stringValue) = resolvedValue(for: value, facts: facts, currentRole: currentRole) else {
                return false
            }
            return stringValue.range(of: pattern.pattern, options: .regularExpression) != nil

        case let .exists(field):
            return facts[field] != nil

        case let .revisionEq(field, expected):
            guard case let .string(actual) = facts[field] else { return false }
            return actual == expected

        case let .roleAtLeast(role):
            return currentRole >= role
        }
    }

    private func resolvedValue(for expr: PredicateAst,
                               facts: CapabilityFacts,
                               currentRole: CapabilityRole) -> PredicateValue {
        switch expr {
        case let .literal(value):
            return value
        case let .fieldRef(path):
            return facts[path] ?? .null
        case let .roleAtLeast(role):
            return .bool(currentRole >= role)
        case let .exists(field):
            return .bool(facts[field] != nil)
        case let .revisionEq(field, expected):
            if case let .string(actual) = facts[field] {
                return .bool(actual == expected)
            }
            return .bool(false)
        default:
            return .bool(evaluate(expr, facts: facts, currentRole: currentRole))
        }
    }

    private func compare(_ lhs: PredicateValue,
                         _ rhs: PredicateValue,
                         using op: PredicateComparisonOperator) -> Bool {
        switch (lhs, rhs) {
        case let (.integer(left), .integer(right)):
            return compareNumbers(Double(left), Double(right), using: op)
        case let (.number(left), .number(right)):
            return compareNumbers(left, right, using: op)
        case let (.integer(left), .number(right)):
            return compareNumbers(Double(left), right, using: op)
        case let (.number(left), .integer(right)):
            return compareNumbers(left, Double(right), using: op)
        case let (.string(left), .string(right)):
            switch op {
            case .equal:
                return left == right
            case .notEqual:
                return left != right
            case .lessThan:
                return left < right
            case .lessThanOrEqual:
                return left <= right
            case .greaterThan:
                return left > right
            case .greaterThanOrEqual:
                return left >= right
            }
        case let (.bool(left), .bool(right)):
            switch op {
            case .equal:
                return left == right
            case .notEqual:
                return left != right
            default:
                return false
            }
        case (.null, .null):
            return op == .equal
        default:
            return false
        }
    }

    private func compareNumbers(_ lhs: Double,
                                _ rhs: Double,
                                using op: PredicateComparisonOperator) -> Bool {
        switch op {
        case .equal:
            return lhs == rhs
        case .notEqual:
            return lhs != rhs
        case .lessThan:
            return lhs < rhs
        case .lessThanOrEqual:
            return lhs <= rhs
        case .greaterThan:
            return lhs > rhs
        case .greaterThanOrEqual:
            return lhs >= rhs
        }
    }
}