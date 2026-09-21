// テストの表示名から規範の ID（ND・RV・CV・DR・E2E）を集める（PLAN §10.1・§10.3。T-05）。
import Foundation
import TestSupport

/// 表示名の先頭の ID と層（`ND-18 [R2] …` の R2）。
struct TestNameEntry: Equatable, Sendable {
    let id: String
    let layer: String?
    /// `Tests/` からの相対パス。
    let path: String
}

enum TestNameIndex {
    /// 表示名の先頭の形。ID の後は空白か終わり、層は ID の直後の `[A]` / `[R1]` / `[R2]` / `[R3]`。
    static let pattern = "^((?:ND|RV|CV|DR|E2E)-[0-9]+)(?: \\[(A|R1|R2|R3)\\])?(?: |$)"

    /// 文字列リテラルの直前のコードが `@Test(` か（空白は無視する）。
    static func isTestDisplayName(_ literal: StringLiteral, in code: [Unicode.Scalar]) -> Bool {
        var index = literal.offset - 1
        func skipSpaces() {
            while index >= 0 && CodeTokenizer.isSpace(code[index]) { index -= 1 }
        }
        skipSpaces()
        guard index >= 0, code[index] == "(" else { return false }
        index -= 1
        skipSpaces()
        let word: [Unicode.Scalar] = ["T", "e", "s", "t"]
        guard index - 3 >= 0, Array(code[(index - 3)...index]) == word else { return false }
        index -= 4
        guard index >= 0, code[index] == "@" else { return false }
        return true
    }

    /// 1 つのソースから集める。
    static func entries(in text: String, path: String) -> [TestNameEntry] {
        let scanned = SourceScanner.scan(text)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return scanned.literals.compactMap { literal in
            guard isTestDisplayName(literal, in: scanned.code) else { return nil }
            let raw = literal.raw
            let range = NSRange(location: 0, length: raw.utf16.count)
            guard let match = regex.firstMatch(in: raw, range: range), let id = Range(match.range(at: 1), in: raw)
            else { return nil }
            let layer = Range(match.range(at: 2), in: raw).map { String(raw[$0]) }
            return TestNameEntry(id: String(raw[id]), layer: layer, path: path)
        }
    }

    /// `Tests/` 配下の全 `.swift` から集める。
    static func load() throws -> [TestNameEntry] {
        let root = PackageRoot.file("Tests")
        guard let enumerator = FileManager.default.enumerator(atPath: root.path(percentEncoded: false)) else {
            return []
        }
        var result: [TestNameEntry] = []
        for case let path as String in enumerator where path.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            result += entries(in: text, path: path)
        }
        return result.sorted { ($0.path, $0.id) < ($1.path, $1.id) }
    }
}
