import Foundation
import TabulaFoundation

/// One condition of the visual filter builder.
public struct FilterRule: Identifiable, Hashable, Sendable {
    public enum Operator: String, CaseIterable, Identifiable, Sendable {
        case equals = "="
        case notEquals = "≠"
        case less = "<"
        case greater = ">"
        case lessOrEqual = "≤"
        case greaterOrEqual = "≥"
        case contains = "contains"
        case notContains = "not contains"
        case startsWith = "starts with"
        case endsWith = "ends with"
        case isNull = "is NULL"
        case isNotNull = "is not NULL"
        case inList = "in"

        public var id: String { rawValue }
        public var needsValue: Bool { self != .isNull && self != .isNotNull }
    }

    /// How a rule joins the rules before it. AND binds tighter than OR, as in SQL.
    public enum Conjunction: String, CaseIterable, Identifiable, Sendable {
        case and = "AND"
        case or = "OR"
        public var id: String { rawValue }
    }

    public var id = UUID()
    public var column: String
    public var op: Operator
    public var value: String
    /// Ignored on the first rule that is used.
    public var conjunction: Conjunction
    /// Unticked rules stay in the filter bar but are left out of the condition.
    public var isEnabled: Bool

    public init(
        column: String,
        op: Operator = .equals,
        value: String = "",
        conjunction: Conjunction = .and,
        isEnabled: Bool = true
    ) {
        self.column = column
        self.op = op
        self.value = value
        self.conjunction = conjunction
        self.isEnabled = isEnabled
    }

    /// The used rules in AND groups, the groups joined by OR (AND binds tighter, as in SQL). A rule left out still
    /// separates groups: in `a OR b AND c`, leaving out b gives `a OR c`, not `a AND c`.
    public static func groups(_ rules: [FilterRule]) -> [[FilterRule]] {
        var groups: [[FilterRule]] = []
        var startsGroup = false
        for rule in rules {
            if rule.conjunction == .or {
                startsGroup = true
            }
            guard rule.isUsed else {
                continue
            }
            if groups.isEmpty || startsGroup {
                groups.append([])
            }
            startsGroup = false
            groups[groups.count - 1].append(rule)
        }
        return groups
    }

    /// Whether the rule takes part in the condition: ticked, with a value when its operator needs one.
    public var isUsed: Bool {
        guard isEnabled else {
            return false
        }
        return !op.needsValue || !value.isEmpty
    }
}

extension SQLDialect {
    /// A function SQLiteDriver registers on its connections: the text with Unicode case folded.
    public static let caseFoldFunction = "tabula_casefold"

    /// SQL for one rule. Text matching ignores case: ILIKE on PostgreSQL (with a cast, so numeric columns work too),
    /// the column's collation on MySQL, and Unicode case folding on SQLite, whose LIKE folds only ASCII letters.
    public func condition(_ rule: FilterRule) -> String {
        let column = quoteIdentifier(rule.column)
        let asText =
            switch flavor {
            case .postgres: "CAST(\(column) AS TEXT)"
            case .sqlite: "\(Self.caseFoldFunction)(\(column))"
            case .mysql: column
            }
        let like = flavor == .postgres ? "ILIKE" : "LIKE"
        func pattern(_ prefix: String, _ suffix: String) -> String {
            // MySQL's LIKE has no default escape under NO_BACKSLASH_ESCAPES, and '\\' reads differently there, so
            // it escapes with "!".
            let escape = flavor == .mysql ? "!" : "\\"
            let escaped = rule.value.replacingOccurrences(of: escape, with: escape + escape)
                .replacingOccurrences(of: "%", with: escape + "%").replacingOccurrences(of: "_", with: escape + "_")
            let text = literal(prefix + escaped + suffix)
            switch flavor {
            case .postgres: return text + " ESCAPE '\\'"
            case .sqlite: return "\(Self.caseFoldFunction)(\(text)) ESCAPE '\\'"
            case .mysql: return text + " ESCAPE '!'"
            }
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

    /// Combines the used rules by their conjunctions (`FilterRule.groups`); unticked rules and rules missing a
    /// required value are skipped. `a AND b OR c` becomes `(a AND b) OR c`, spelling out SQL's precedence.
    public func condition(_ rules: [FilterRule]) -> String {
        let groups = FilterRule.groups(rules).map { group in group.map(condition) }
        guard groups.count > 1 else {
            return groups.first?.joined(separator: " AND ") ?? ""
        }
        return groups.map { $0.count == 1 ? $0[0] : "(\($0.joined(separator: " AND ")))" }.joined(separator: " OR ")
    }
}
