// Unicode スカラー単位の文字列補助（PLAN §5.7）。Character 単位の比較を VDNotes で使わないための 1 か所。
enum ScalarText {
    /// s のスカラー列が prefix のスカラー列で始まるか
    static func hasPrefix(_ s: String, _ prefix: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        let head = Array(prefix.unicodeScalars)
        guard scalars.count >= head.count else { return false }
        return Array(scalars[0..<head.count]) == head
    }

    /// s のスカラー列が suffix のスカラー列で終わるか
    static func hasSuffix(_ s: String, _ suffix: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        let tail = Array(suffix.unicodeScalars)
        guard scalars.count >= tail.count else { return false }
        return Array(scalars[(scalars.count - tail.count)...]) == tail
    }

    /// "\n"（U+000A）だけで分割する。空の部分列を省かない（"a\n" → ["a", ""]）
    static func splitLF(_ s: String) -> [String] {
        var lines: [String] = []
        var current: [Unicode.Scalar] = []
        for scalar in Array(s.unicodeScalars) {
            if scalar == "\n" {
                lines.append(string(current))
                current = []
            } else {
                current.append(scalar)
            }
        }
        lines.append(string(current))
        return lines
    }

    /// 末尾の "\n"（U+000A）を全部取り除く（Python の s.rstrip("\n")）
    static func trimTrailingLF(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while scalars.last == "\n" {
            scalars.removeLast()
        }
        return string(scalars)
    }

    /// スカラー集合に含まれるスカラーを取り除く
    static func removing(_ s: String, _ set: Set<Unicode.Scalar>) -> String {
        string(Array(s.unicodeScalars).filter { !set.contains($0) })
    }

    /// スカラーを置き換える（map に在るものを置換、他はそのまま）
    static func replacing(_ s: String, _ map: [Unicode.Scalar: Unicode.Scalar]) -> String {
        string(Array(s.unicodeScalars).map { map[$0] ?? $0 })
    }

    /// スカラー列から文字列を作る（`String(String.UnicodeScalarView(scalars))`）。
    static func string(_ scalars: [Unicode.Scalar]) -> String {
        String(String.UnicodeScalarView(scalars))
    }
}
