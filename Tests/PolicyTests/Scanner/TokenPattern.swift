// トークンの並びで禁止語を表す（PLAN §9.4 のトークン単位の照合。T-04）。

/// パターンの 1 要素。
enum PatternElement: Equatable, Sendable {
    /// 識別子が完全一致。
    case identifier(String)
    /// 識別子が接頭辞で一致（`URLSession` は `URLSessionConfiguration` にも当たる）。
    case identifierPrefix(String)
    /// 1 文字の記号。
    case punctuation(String)
}

/// 禁止するトークンの並び。
struct TokenPattern: Equatable, Sendable {
    /// 違反の表示に使う語（例 `remove(`）。
    let display: String
    let elements: [PatternElement]
    /// 要素の間に空白を許さない（`try!`・`as!`・`#/`）。
    let adjacent: Bool
    /// 自由関数の呼び出しとしてだけ数える（直前が `.` でない、または `Darwin.` / `Foundation.` / `Glibc.` / `Swift.` で修飾されている。直前が `func` なら宣言なので数えない）。
    let freeCall: Bool

    /// 自由関数の呼び出し `name(`。
    static func call(_ name: String) -> TokenPattern {
        TokenPattern(
            display: "\(name)(", elements: [.identifier(name), .punctuation("(")], adjacent: false, freeCall: true)
    }

    /// 識別子 1 つ（完全一致）。
    static func word(_ name: String) -> TokenPattern {
        TokenPattern(display: name, elements: [.identifier(name)], adjacent: false, freeCall: false)
    }

    /// 識別子 1 つ（接頭辞）。
    static func prefix(_ name: String) -> TokenPattern {
        TokenPattern(display: "\(name)…", elements: [.identifierPrefix(name)], adjacent: false, freeCall: false)
    }

    /// 並び。`spec` は空白区切り（識別子は識別子、それ以外の 1 文字は記号）。例 `"Date . now"`。
    static func sequence(_ display: String, _ spec: String, adjacent: Bool = false) -> TokenPattern {
        let elements: [PatternElement] = spec.split(separator: " ").map { part in
            let text = String(part)
            if let first = text.unicodeScalars.first, CodeTokenizer.isIdentifierStart(first) {
                return .identifier(text)
            }
            return .punctuation(text)
        }
        return TokenPattern(display: display, elements: elements, adjacent: adjacent, freeCall: false)
    }

    /// 自由関数の呼び出しを修飾してよい名前。
    static let callQualifiers: Set<String> = ["Darwin", "Foundation", "Glibc", "Swift"]

    /// `tokens` の中で一致した位置（先頭のトークンの添字）を返す。
    func matches(in tokens: [CodeToken]) -> [Int] {
        var found: [Int] = []
        guard !elements.isEmpty, tokens.count >= elements.count else { return found }
        for start in 0...(tokens.count - elements.count) where matchesAt(start, tokens) {
            found.append(start)
        }
        return found
    }

    private func matchesAt(_ start: Int, _ tokens: [CodeToken]) -> Bool {
        for (k, element) in elements.enumerated() {
            let token = tokens[start + k]
            if adjacent && k > 0 && token.spaceBefore { return false }
            switch element {
            case .identifier(let name):
                if token.kind != .identifier || token.text != name { return false }
            case .identifierPrefix(let name):
                if token.kind != .identifier || !token.text.hasPrefix(name) { return false }
            case .punctuation(let symbol):
                if token.kind != .punctuation || token.text != symbol { return false }
            }
        }
        if freeCall && start > 0 {
            let previous = tokens[start - 1]
            if previous.kind == .identifier && previous.text == "func" { return false }
            if previous.kind == .punctuation && previous.text == "." {
                guard start >= 2 else { return false }
                let qualifier = tokens[start - 2]
                return qualifier.kind == .identifier && Self.callQualifiers.contains(qualifier.text)
            }
        }
        return true
    }
}
