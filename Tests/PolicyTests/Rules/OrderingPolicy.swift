// PT-16: 「本体が先、記録が後」（DEV-16）。copyOne の本体で commitPartial( が registerCopied( より前にある（T-04）。

enum OrderingPolicy {
    static let id = "PT-16"
    static let path = "VDDevice/IngestService.swift"
    static let function = "copyOne"
    static let first = "commitPartial"
    static let second = "registerCopied"

    /// `func <name>(` の本体（最初の `{` から釣り合う `}` まで）のトークン。見つからなければ nil。
    static func body(of name: String, in tokens: [CodeToken]) -> ArraySlice<CodeToken>? {
        guard tokens.count >= 3 else { return nil }
        for start in 0..<(tokens.count - 2)
        where tokens[start].text == "func" && tokens[start + 1].text == name && tokens[start + 2].text == "(" {
            guard let open = tokens[(start + 3)...].firstIndex(where: { $0.kind == .punctuation && $0.text == "{" })
            else { return nil }
            var depth = 0
            for index in open..<tokens.count where tokens[index].kind == .punctuation {
                if tokens[index].text == "{" { depth += 1 }
                if tokens[index].text == "}" {
                    depth -= 1
                    if depth == 0 { return tokens[open...index] }
                }
            }
            return nil
        }
        return nil
    }

    /// 本体の中で `name(` が最初に現れるトークンの位置。
    static func firstCall(_ name: String, in body: ArraySlice<CodeToken>) -> Int? {
        for index in body.indices where index + 1 < body.endIndex {
            if body[index].kind == .identifier && body[index].text == name && body[index + 1].text == "(" {
                return index
            }
        }
        return nil
    }

    /// `required` が真なら、ファイルや関数が見つからないことも違反にする。
    static func check(files: [SourceFile], required: Bool) -> [Violation] {
        guard let file = files.first(where: { $0.relativePath == path }) else {
            return required ? [Violation(rule: id, path: path, line: 1, what: "ファイルがありません")] : []
        }
        guard let body = body(of: function, in: file.tokens) else {
            return required ? [Violation(rule: id, path: path, line: 1, what: "func \(function)( がありません")] : []
        }
        let commit = firstCall(first, in: body)
        let register = firstCall(second, in: body)
        guard let commit, let register else {
            return [Violation(rule: id, path: path, line: body.first?.line ?? 1, what: "\(first)( か \(second)( がありません")]
        }
        if commit < register { return [] }
        return [Violation(rule: id, path: path, line: body[register].line, what: "\(second)( が \(first)( より前")]
    }
}
