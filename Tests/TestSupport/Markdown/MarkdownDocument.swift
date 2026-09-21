// Markdown の文書から節・表・コードフェンスを取り出す（PLAN §10.3 の SPEC 同期の読み方。T-04 で作り、T-05 が使う）。
import Foundation

/// 文書が読めないときの誤り。テストは skip せず fail にする（PLAN §10.3）。
public enum MarkdownError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case sectionNotFound(String)

    public var description: String {
        switch self {
        case .missing(let path): "\(path) が見つかりません"
        case .sectionNotFound(let key): "見出し \(key) が見つかりません"
        }
    }
}

/// Markdown の表 1 つ。
public struct MarkdownTable: Equatable, Sendable {
    /// 見出し行のセル。
    public let header: [String]
    /// 本文の行のセル（区切り行 `|---|` を除く）。
    public let rows: [[String]]
    /// 表の直前の空でない行（無ければ nil）。
    public let precedingLine: String?
}

/// Markdown の文書。
public struct MarkdownDocument: Sendable {
    public let lines: [String]

    public init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// リポジトリのルートからの相対パスで読む。無ければ `MarkdownError.missing`。
    public static func load(_ relativePath: String) throws -> MarkdownDocument {
        let url = PackageRoot.file(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw MarkdownError.missing(relativePath)
        }
        return MarkdownDocument(text: text)
    }

    /// コードフェンスの開きか閉じの行か（行頭の空白の後に ``` ）。
    public static func isFence(_ line: String) -> Bool {
        line.drop { $0 == " " || $0 == "\t" }.hasPrefix("```")
    }

    /// 見出し行なら `#` の後の本文を返す（`#` が 1〜6 個と空白 1 つ）。
    public static func headingText(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return String(rest.dropFirst())
    }

    /// 次の節の始まりとみなす見出しか（本文が数字・英大文字・「付録」で始まる）。
    public static func isSectionBoundary(_ line: String) -> Bool {
        guard let text = headingText(line), let first = text.unicodeScalars.first else { return false }
        return (first >= "0" && first <= "9") || (first >= "A" && first <= "Z") || text.hasPrefix("付録")
    }

    /// 見出しの本文が `key` で始まる最初の節の行（見出しの次の行から、次の節の見出しの手前まで）。
    /// コードフェンスの中の行は見出しとして扱わない（`# 2026-…` で節が切れた事故。voicedock #13）。
    public func section(_ key: String) throws -> [String] {
        var inFence = false
        var start: Int?
        for (index, line) in lines.enumerated() {
            if Self.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let begin = start {
                if Self.isSectionBoundary(line) { return Array(lines[begin..<index]) }
            } else if let text = Self.headingText(line), text.hasPrefix(key) {
                start = index + 1
            }
        }
        guard let begin = start else { throw MarkdownError.sectionNotFound(key) }
        return Array(lines[begin...])
    }

    /// 表の行をセルに分ける（バッククォートの中の `|` と `\|` では分けない。前後の空白は除く）。
    public static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        let body = line.trimmingCharacters(in: .whitespaces)
        for ch in body.dropFirst() {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(ch)
        }
        return cells
    }

    /// `lines` の中の表をすべて返す（フェンスの中は見ない）。
    public static func tables(in lines: [String]) -> [MarkdownTable] {
        var tables: [MarkdownTable] = []
        var inFence = false
        var index = 0
        var lastNonEmpty: String?
        while index < lines.count {
            let line = lines[index]
            if isFence(line) {
                inFence.toggle()
                index += 1
                continue
            }
            if !inFence && line.hasPrefix("|") {
                let header = cells(line)
                var rows: [[String]] = []
                var j = index + 1
                while j < lines.count && lines[j].hasPrefix("|") {
                    let rowCells = cells(lines[j])
                    let isSeparator = rowCells.allSatisfy { cell in
                        !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
                    }
                    if !isSeparator { rows.append(rowCells) }
                    j += 1
                }
                tables.append(MarkdownTable(header: header, rows: rows, precedingLine: lastNonEmpty))
                lastNonEmpty = lines[j - 1]
                index = j
                continue
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lastNonEmpty = line }
            index += 1
        }
        return tables
    }

    /// `lines` の中のコードフェンスの中身（`language` が nil なら言語を問わない）。直前の空でない行も返す。
    public static func fences(in lines: [String], language: String?) -> [(precedingLine: String?, body: [String])] {
        var result: [(precedingLine: String?, body: [String])] = []
        var index = 0
        var lastNonEmpty: String?
        while index < lines.count {
            let line = lines[index]
            if isFence(line) {
                let info = line.drop { $0 == " " || $0 == "\t" }.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                var j = index + 1
                while j < lines.count && !isFence(lines[j]) {
                    body.append(lines[j])
                    j += 1
                }
                if language == nil || info == language { result.append((lastNonEmpty, body)) }
                index = j + 1
                lastNonEmpty = nil
                continue
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lastNonEmpty = line }
            index += 1
        }
        return result
    }
}
