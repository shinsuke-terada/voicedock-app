// NSRegularExpression で文字列全体に一致するかを調べる（PLAN §4.1）。
import Foundation

enum PatternMatch {
    /// pattern を毎回コンパイルし（NSRegularExpression は Sendable が保証されないので static に持たない）、
    /// 範囲 NSRange(location: 0, length: s.utf16.count) で firstMatch を取り、一致範囲が文字列全体と等しいときだけ
    /// 捕捉グループの文字列（範囲が NSNotFound のグループは nil）を返す。コンパイル失敗・不一致・部分一致は nil。
    static func wholeMatch(_ pattern: String, _ s: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let length = s.utf16.count
        guard let match = regex.firstMatch(in: s, range: NSRange(location: 0, length: length)) else { return nil }
        // `$` は末尾の改行の直前にも一致するので、一致範囲が全体と等しいことを確かめる。
        guard match.range.location == 0, match.range.length == length else { return nil }
        var groups: [String?] = []
        for index in 0...regex.numberOfCaptureGroups {
            let nsRange = match.range(at: index)
            if nsRange.location == NSNotFound {
                groups.append(nil)
            } else if let range = Range(nsRange, in: s) {
                groups.append(String(s[range]))
            } else {
                groups.append(nil)
            }
        }
        return groups
    }
}
