// 静的ポリシーの規則と照合の仕組み（PLAN §9.4。T-04）。
import Foundation

/// パスの集合。`/` で終わる要素はディレクトリの接頭辞、それ以外はファイルの完全一致。`*` は全部。
struct PathSet: Sendable {
    let entries: [String]

    static let all = PathSet(entries: ["*"])
    static let none = PathSet(entries: [])

    func contains(_ relativePath: String) -> Bool {
        entries.contains { entry in
            if entry == "*" { return true }
            if entry.hasSuffix("/") { return relativePath.hasPrefix(entry) }
            return relativePath == entry
        }
    }
}

/// 文字列リテラルの中身に対する照合。
struct LiteralMatcher: Sendable {
    let display: String
    let matches: @Sendable (String) -> Bool

    /// 部分文字列を含む。
    static func contains(_ needle: String) -> LiteralMatcher {
        LiteralMatcher(display: needle) { $0.contains(needle) }
    }

    /// 正規表現に一致する部分がある。
    static func regex(_ display: String, _ pattern: String, caseInsensitive: Bool = false) -> LiteralMatcher {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        let expression = try? NSRegularExpression(pattern: pattern, options: options)
        return LiteralMatcher(display: display) { raw in
            guard let expression else { return true }  // 正規表現が壊れていたら必ず違反にする（空振りしない）
            return expression.firstMatch(in: raw, range: NSRange(location: 0, length: raw.utf16.count)) != nil
        }
    }

    /// 語（`[A-Z0-9_]` を語の文字とする）としてどれかを含む。語の一覧が空なら必ず違反にする（空で緑にしない）。
    static func words(_ display: String, _ words: [String]) -> LiteralMatcher {
        guard !words.isEmpty else { return LiteralMatcher(display: display) { _ in true } }
        let alternation = words.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return regex(display, "(?<![A-Z0-9_])(?:\(alternation))(?![A-Z0-9_])")
    }
}

/// 規則の 1 条項（どのファイルを見て、何を探し、どこなら許すか）。
struct PolicyClause: Sendable {
    let scope: PathSet
    let allowed: PathSet
    let code: [TokenPattern]
    let literals: [LiteralMatcher]

    init(scope: PathSet = .all, allowed: PathSet, code: [TokenPattern] = [], literals: [LiteralMatcher] = []) {
        self.scope = scope
        self.allowed = allowed
        self.code = code
        self.literals = literals
    }
}

/// 規則（PT-nn）。
struct PolicyRule: Sendable {
    let id: String
    let clauses: [PolicyClause]
}

/// 違反 1 件。
struct Violation: Equatable, Sendable, CustomStringConvertible {
    let rule: String
    let path: String
    let line: Int
    let what: String

    var description: String { "\(rule) \(path):\(line) \(what)" }
}

/// 規則をファイルの集合に当てる。
enum PolicyEngine {
    static func check(_ rule: PolicyRule, files: [SourceFile]) -> [Violation] {
        var violations: [Violation] = []
        for clause in rule.clauses {
            for file in files
            where clause.scope.contains(file.relativePath) && !clause.allowed.contains(file.relativePath) {
                for pattern in clause.code {
                    for index in pattern.matches(in: file.tokens) {
                        violations.append(
                            Violation(
                                rule: rule.id, path: file.relativePath, line: file.tokens[index].line,
                                what: pattern.display))
                    }
                }
                for matcher in clause.literals {
                    for literal in file.scanned.literals where matcher.matches(literal.raw) {
                        violations.append(
                            Violation(rule: rule.id, path: file.relativePath, line: literal.line, what: matcher.display)
                        )
                    }
                }
            }
        }
        return violations
    }
}
