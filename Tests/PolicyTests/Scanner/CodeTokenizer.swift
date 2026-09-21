// SourceScanner のコードを語（トークン）に分ける（PLAN §9.4。T-04）。

/// コードの語 1 つ。
struct CodeToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// 識別子とキーワード（`[A-Za-z_][A-Za-z0-9_]*`。`` `x` `` は x）。
        case identifier
        /// 数値（`[0-9][0-9A-Za-z_.]*`）。
        case number
        /// それ以外の 1 文字（`.` `(` `@` `#` `!` など）。
        case punctuation
    }
    let kind: Kind
    let text: String
    /// 1 始まりの行番号。
    let line: Int
    /// 直前のトークンとの間に空白・改行があったか（ファイルの先頭は true）。
    let spaceBefore: Bool
}

/// トークンへの分割。
enum CodeTokenizer {
    static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
        (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || c == "_"
    }

    static func isIdentifierContinue(_ c: Unicode.Scalar) -> Bool {
        isIdentifierStart(c) || (c >= "0" && c <= "9")
    }

    static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }

    static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" }

    static func tokens(_ code: [Unicode.Scalar]) -> [CodeToken] {
        var result: [CodeToken] = []
        var i = 0
        var line = 1
        var sawSpace = true
        func text(_ from: Int, _ to: Int) -> String {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: code[from..<to])
            return String(v)
        }
        while i < code.count {
            let c = code[i]
            if isSpace(c) {
                if c == "\n" { line += 1 }
                sawSpace = true
                i += 1
                continue
            }
            if c == "`", i + 1 < code.count, isIdentifierStart(code[i + 1]) {
                var j = i + 1
                while j < code.count && isIdentifierContinue(code[j]) { j += 1 }
                if j < code.count && code[j] == "`" {
                    result.append(CodeToken(kind: .identifier, text: text(i + 1, j), line: line, spaceBefore: sawSpace))
                    sawSpace = false
                    i = j + 1
                    continue
                }
            }
            if isIdentifierStart(c) {
                var j = i
                while j < code.count && isIdentifierContinue(code[j]) { j += 1 }
                result.append(CodeToken(kind: .identifier, text: text(i, j), line: line, spaceBefore: sawSpace))
                sawSpace = false
                i = j
                continue
            }
            if isDigit(c) {
                var j = i
                while j < code.count && (isIdentifierContinue(code[j]) || code[j] == ".") { j += 1 }
                result.append(CodeToken(kind: .number, text: text(i, j), line: line, spaceBefore: sawSpace))
                sawSpace = false
                i = j
                continue
            }
            result.append(CodeToken(kind: .punctuation, text: text(i, i + 1), line: line, spaceBefore: sawSpace))
            sawSpace = false
            i += 1
        }
        return result
    }
}
