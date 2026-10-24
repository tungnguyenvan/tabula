import Foundation

/// One condition of the visual filter builder.
public struct FilterRule: Identifiable, Hashable, Sendable {
    public enum Operator: String, CaseIterable, Identifiable, Sendable {
        case equals = "=", notEquals = "≠", less = "<", greater = ">", lessOrEqual = "≤", greaterOrEqual = "≥"
        case contains = "contains", notContains = "not contains", startsWith = "starts with", endsWith = "ends with"
        case isNull = "is NULL", isNotNull = "is not NULL", inList = "in"

        public var id: String { rawValue }
        public var needsValue: Bool { self != .isNull && self != .isNotNull }
    }

    /// How a rule joins the rules before it. AND binds tighter than OR, as in SQL.
    public enum Conjunction: String, CaseIterable, Identifiable, Sendable {
        case and = "AND", or = "OR"
        public var id: String { rawValue }
    }

    public var id = UUID()
    public var column: String
    public var op: Operator
    public var value: String
    /// Ignored on the first rule.
    public var conjunction: Conjunction

    public init(column: String, op: Operator = .equals, value: String = "", conjunction: Conjunction = .and) {
        self.column = column
        self.op = op
        self.value = value
        self.conjunction = conjunction
    }
}

extension SQLDialect {
    /// SQL for one rule. Text matching casts to text on Postgres so it also works on numeric columns.
    public func condition(_ rule: FilterRule) -> String {
        let column = quoteIdentifier(rule.column)
        let asText = kind == .postgres ? "CAST(\(column) AS TEXT)" : column
        let like = kind == .postgres ? "ILIKE" : "LIKE"
        func pattern(_ prefix: String, _ suffix: String) -> String {
            let escaped = rule.value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            return literal(prefix + escaped + suffix) + (kind == .mysql ? "" : " ESCAPE '\\'")
        }
        switch rule.op {
        case .equals: return "\(column) = \(literal(rule.value))"
        case .notEquals: return "\(column) <> \(literal(rule.value))"
        case .less: return "\(column) < \(literal(rule.value))"
        case .greater: return "\(column) > \(literal(rule.value))"
        case .lessOrEqual: return "\(column) <= \(literal(rule.value))"
        case .greaterOrEqual: return "\(column) >= \(literal(rule.value))"
        case .contains: return "\(asText) \(like) \(pattern("%", "%"))"
        case .notContains: return "\(asText) NOT \(like) \(pattern("%", "%"))"
        case .startsWith: return "\(asText) \(like) \(pattern("", "%"))"
        case .endsWith: return "\(asText) \(like) \(pattern("%", ""))"
        case .isNull: return "\(column) IS NULL"
        case .isNotNull: return "\(column) IS NOT NULL"
        case .inList:
            let items = rule.value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map(literal)
            return items.isEmpty ? "FALSE" : "\(column) IN (\(items.joined(separator: ", ")))"
        }
    }

    /// Combines rules by their conjunctions; rules missing a required value are skipped.
    /// `a AND b OR c` becomes `(a AND b) OR c`, spelling out SQL's precedence.
    public func condition(_ rules: [FilterRule]) -> String {
        var groups: [[String]] = []
        for rule in rules where !rule.op.needsValue || !rule.value.isEmpty {
            if groups.isEmpty || rule.conjunction == .or { groups.append([]) }
            groups[groups.count - 1].append(condition(rule))
        }
        guard groups.count > 1 else { return groups.first?.joined(separator: " AND ") ?? "" }
        return groups.map { $0.count == 1 ? $0[0] : "(\($0.joined(separator: " AND ")))" }.joined(separator: " OR ")
    }
}
