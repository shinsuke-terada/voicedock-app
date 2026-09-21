// PT-06 が探す状態名とエラーコード名（計画書の付録 A から読む。T-05 で docs/SPEC.md に切り替える）（T-04）。
import TestSupport

struct PolicyVocabulary: Sendable {
    let stateNames: [String]
    let errorCodeNames: [String]

    /// `docs/PLAN.md` の付録 A.1（「Part の状態」「Session の状態」の表）と A.3（エラーコードの表）から読む。
    static func load() throws -> PolicyVocabulary {
        let plan = try MarkdownDocument.load("docs/PLAN.md")
        let states = MarkdownDocument.tables(in: try plan.section("A.1"))
            .filter { table in table.header.contains { $0 == "Part の状態" || $0 == "Session の状態" } }
            .flatMap { $0.rows.compactMap { $0.count >= 2 ? unquote($0[1]) : nil } }
        let codes = MarkdownDocument.tables(in: try plan.section("A.3"))
            .filter { $0.header.contains("コード") }
            .flatMap { table in
                table.rows.compactMap { row -> String? in
                    guard row.count >= 2, Int(row[0]) != nil else { return nil }
                    return unquote(row[1])
                }
            }
        return PolicyVocabulary(stateNames: Array(Set(states)).sorted(), errorCodeNames: codes)
    }

    /// `` `NAME` `` から NAME を取り出す（形が違えば nil）。
    static func unquote(_ cell: String) -> String? {
        guard cell.count >= 3, cell.hasPrefix("`"), cell.hasSuffix("`") else { return nil }
        return String(cell.dropFirst().dropLast())
    }
}
