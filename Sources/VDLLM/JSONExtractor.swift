// LLM の応答から JSON オブジェクトを取り出す（voicedock llm.py:238-307 と同じ 4 段）。
import Foundation
import VDCore

/// すべて `unicodeScalars` の上で処理する（Python の文字 = コードポイント）。
/// 正規表現は使わない（Python の `\s` と ICU の `\s` の違いを持ち込まないため。PT-20）。
public enum JSONExtractor {
    private static let thinkOpen = Array("<think>".unicodeScalars)
    private static let thinkClose = Array("</think>".unicodeScalars)
    private static let fence = Array("```".unicodeScalars)
    private static let newlineFence = Array("\n```".unicodeScalars)
    private static let jsonTag = Array("json".unicodeScalars)

    /// voicedock `THINK_RE = <think>.*?</think>`（DOTALL）の `sub("")` → `partition("<think>")`。
    public static func stripThink(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        var pos = 0
        while let open = find(thinkOpen, in: scalars, from: pos),
            let close = find(thinkClose, in: scalars, from: open + thinkOpen.count)
        {
            scalars.removeSubrange(open..<(close + thinkClose.count))
            pos = open
        }
        if let open = find(thinkOpen, in: scalars, from: 0) {
            return string(scalars[0..<open])
        }
        return string(scalars[...])
    }

    /// 取り出せなければ nil。例外を投げない。戻り値のキーの並びは入力の順（重複キーは後勝ちで最初の位置）。
    public static func extractObject(_ text: String) -> [(String, PyJSONValue)]? {
        let cleaned = PyText.strip(stripThink(text))
        let scalars = Array(cleaned.unicodeScalars)
        let candidates = [cleaned] + fenced(scalars) + balanced(scalars)
        for candidate in candidates {
            if case .object(let entries) = PyJSON.decode(candidate) {
                return entries
            }
        }
        return nil
    }

    /// `re.findall(r"```(?:json)?\s*\n(.*?)\n?```", s, re.S)` と同じ結果。
    static func fenced(_ s: [Unicode.Scalar]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < s.count {
            guard hasPrefix(fence, in: s, at: i), let (group, end) = fenceMatch(s, at: i) else {
                i += 1
                continue
            }
            result.append(group)
            i = end
        }
        return result
    }

    /// `(?:json)?` は先に「在る」を試す。
    private static func fenceMatch(_ s: [Unicode.Scalar], at i: Int) -> (String, Int)? {
        for withTag in [true, false] {
            var j = i + fence.count
            if withTag {
                guard hasPrefix(jsonTag, in: s, at: j) else { continue }
                j += jsonTag.count
            }
            var r = j
            while r < s.count && PyText.isSpace(s[r]) {
                r += 1
            }
            guard let k = (j..<r).last(where: { s[$0] == "\n" }) else { continue }
            let c = k + 1
            // `\n?` が貪欲なので "\n```" を "```" より先に調べる。
            for e in c..<s.count {
                if hasPrefix(newlineFence, in: s, at: e) {
                    return (string(s[c..<e]), e + newlineFence.count)
                }
                if hasPrefix(fence, in: s, at: e) {
                    return (string(s[c..<e]), e + fence.count)
                }
            }
            // 前置き "" を試しても同じ結果なので終わる。
            return nil
        }
        return nil
    }

    /// 最初の "{" から、文字列の外で括弧が釣り合うところまで（1 個か 0 個）。一重引用符は文字列として扱わない。
    static func balanced(_ s: [Unicode.Scalar]) -> [String] {
        guard let start = s.firstIndex(of: "{") else {
            return []
        }
        var depth = 0
        var inString = false
        var escaped = false
        for idx in start..<s.count {
            let ch = s[idx]
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" && inString {
                escaped = true
                continue
            }
            if ch == "\"" {
                inString.toggle()
                continue
            }
            if inString {
                continue
            }
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return [string(s[start...idx])]
                }
            }
        }
        return []
    }

    private static func hasPrefix(_ needle: [Unicode.Scalar], in s: [Unicode.Scalar], at i: Int) -> Bool {
        i + needle.count <= s.count && s[i..<(i + needle.count)].elementsEqual(needle)
    }

    private static func find(_ needle: [Unicode.Scalar], in s: [Unicode.Scalar], from start: Int) -> Int? {
        var i = start
        while i + needle.count <= s.count {
            if hasPrefix(needle, in: s, at: i) {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func string(_ slice: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: slice)
        return String(view)
    }
}
