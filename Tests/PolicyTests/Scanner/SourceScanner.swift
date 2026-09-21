// Swift のソースを「コード」と「文字列リテラル」に分ける簡易字句解析器（PLAN §9.4。T-04）。
// コメントと文字列リテラルの中身を空白に置き換えたコードを作り、文字列リテラルの中身は別に集める。
// 行番号を保つため、改行は置き換えない。文字列補間 `\( … )` の中身はコードとして残す。

/// 文字列リテラル 1 つ。
struct StringLiteral: Equatable, Sendable {
    /// 開きの区切り（`#` を含む）の先頭の位置（Unicode スカラーの添字）。
    let offset: Int
    /// 開きの区切りがある行（1 始まり）。
    let line: Int
    /// 区切りの間のソースそのもの（エスケープは解かない。補間 `\(…)` もそのまま含む）。
    let raw: String
    /// `"""` の複数行リテラルか。
    let isMultiline: Bool
    /// raw 文字列の `#` の数（通常の文字列は 0）。
    let hashCount: Int
}

/// 字句解析の結果。
struct ScannedSource: Sendable {
    /// コメントと文字列リテラルを空白にしたソース（スカラーの数と改行の位置は元と同じ）。
    let code: [Unicode.Scalar]
    /// 文字列リテラルの一覧（出現順。補間の中の文字列も含む）。
    let literals: [StringLiteral]
    /// `code` を String にしたもの。
    var codeText: String {
        var s = String.UnicodeScalarView()
        s.append(contentsOf: code)
        return String(s)
    }
}

/// 簡易字句解析器。
enum SourceScanner {
    private enum Context {
        /// コード。`interpolationDepth` が nil なら最上位、そうでなければ補間の中（括弧の深さ）。
        case code(interpolationDepth: Int?)
        /// 文字列リテラルの中。
        case string(start: Int, offset: Int, line: Int, multiline: Bool, hashes: Int)
    }

    private static let newline: Unicode.Scalar = "\n"
    private static let space: Unicode.Scalar = " "
    private static let quote: Unicode.Scalar = "\""
    private static let hash: Unicode.Scalar = "#"
    private static let backslash: Unicode.Scalar = "\\"
    private static let slash: Unicode.Scalar = "/"
    private static let star: Unicode.Scalar = "*"
    private static let openParen: Unicode.Scalar = "("
    private static let closeParen: Unicode.Scalar = ")"

    /// `text` を字句解析する。
    static func scan(_ text: String) -> ScannedSource {
        let s = Array(text.unicodeScalars)
        let n = s.count
        var out = [Unicode.Scalar](repeating: space, count: n)
        var literals: [StringLiteral] = []
        var stack: [Context] = [.code(interpolationDepth: nil)]
        var line = 1
        var i = 0

        func starts(_ pattern: [Unicode.Scalar], at index: Int) -> Bool {
            guard index + pattern.count <= n else { return false }
            for k in 0..<pattern.count where s[index + k] != pattern[k] { return false }
            return true
        }
        /// index の文字を空白にする（改行は残し、行を数える）。
        func blank(_ index: Int) {
            if s[index] == newline {
                out[index] = newline
                line += 1
            }
        }
        /// index の文字をそのままコードに出す。
        func emit(_ index: Int) {
            out[index] = s[index]
            if s[index] == newline { line += 1 }
        }
        func raw(_ from: Int, _ to: Int) -> String {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: s[from..<to])
            return String(v)
        }

        while i < n {
            guard let top = stack.last else { break }
            switch top {
            case .code(let depth):
                if starts([slash, slash], at: i) {
                    while i < n && s[i] != newline { i += 1 }
                    continue
                }
                if starts([slash, star], at: i) {
                    var level = 0
                    while i < n {
                        if starts([slash, star], at: i) {
                            level += 1
                            i += 2
                        } else if starts([star, slash], at: i) {
                            level -= 1
                            i += 2
                            if level == 0 { break }
                        } else {
                            blank(i)
                            i += 1
                        }
                    }
                    continue
                }
                if s[i] == hash || s[i] == quote {
                    var hashes = 0
                    while i + hashes < n && s[i + hashes] == hash { hashes += 1 }
                    let q = i + hashes
                    if q < n && s[q] == quote {
                        let multiline = starts([quote, quote, quote], at: q)
                        let length = hashes + (multiline ? 3 : 1)
                        let startLine = line
                        for k in i..<(i + length) { blank(k) }
                        stack.append(
                            .string(start: i + length, offset: i, line: startLine, multiline: multiline, hashes: hashes)
                        )
                        i += length
                        continue
                    }
                }
                if let d = depth {
                    if s[i] == openParen {
                        stack[stack.count - 1] = .code(interpolationDepth: d + 1)
                        emit(i)
                        i += 1
                        continue
                    }
                    if s[i] == closeParen {
                        if d == 0 {
                            stack.removeLast()
                            i += 1
                            continue
                        }
                        stack[stack.count - 1] = .code(interpolationDepth: d - 1)
                        emit(i)
                        i += 1
                        continue
                    }
                }
                emit(i)
                i += 1
            case .string(let start, let offset, let startLine, let multiline, let hashes):
                let closing = (multiline ? [quote, quote, quote] : [quote]) + Array(repeating: hash, count: hashes)
                if starts(closing, at: i) {
                    literals.append(
                        StringLiteral(
                            offset: offset, line: startLine, raw: raw(start, i), isMultiline: multiline,
                            hashCount: hashes))
                    stack.removeLast()
                    for k in i..<(i + closing.count) { blank(k) }
                    i += closing.count
                    continue
                }
                let escape = [backslash] + Array(repeating: hash, count: hashes)
                if starts(escape, at: i) {
                    let j = i + escape.count
                    if j < n && s[j] == openParen {
                        for k in i...j { blank(k) }
                        stack.append(.code(interpolationDepth: 0))
                        i = j + 1
                        continue
                    }
                    for k in i..<min(j + 1, n) { blank(k) }
                    i = j + 1
                    continue
                }
                if !multiline && s[i] == newline {
                    literals.append(
                        StringLiteral(
                            offset: offset, line: startLine, raw: raw(start, i), isMultiline: false, hashCount: hashes))
                    stack.removeLast()
                    blank(i)
                    i += 1
                    continue
                }
                blank(i)
                i += 1
            }
        }
        for context in stack.reversed() {
            if case .string(let start, let offset, let startLine, let multiline, let hashes) = context {
                literals.append(
                    StringLiteral(
                        offset: offset, line: startLine, raw: raw(start, n), isMultiline: multiline, hashCount: hashes))
            }
        }
        literals.sort { $0.offset < $1.offset }
        return ScannedSource(code: out, literals: literals)
    }
}
