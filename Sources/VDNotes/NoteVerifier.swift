// 保存検証（PLAN §8.7 の RN-1〜RN-6 / DN-1〜DN-9。voicedock notes.py:294-454 の R-n / W-n と同じ判定と打ち切り）。
import Foundation
import VDCore

public enum NoteKind: Sendable {
    case raw, daily
}

public struct NoteRuleResult: Equatable, Sendable {
    /// "RN-1" … "RN-6" / "DN-1" … "DN-9"
    public let rule: String
    public let passed: Bool
}

public struct NoteVerification: Equatable, Sendable {
    /// 評価した規則（評価の順）
    public let results: [NoteRuleResult]

    /// passed でないものの rule（評価の順）
    public var failedRules: [String] { results.filter { !$0.passed }.map(\.rule) }

    /// results が空でなく、全部 passed
    public var passed: Bool { !results.isEmpty && results.allSatisfy(\.passed) }

    /// error_message に載せる 1 行
    public var failureMessage: String { "落ちた規則: " + failedRules.joined(separator: ", ") }
}

public enum NoteVerifier {
    static let rawPrefix = "RN"
    static let dailyPrefix = "DN"

    /// 書き込み直後と削除判定（§8.9.1 の verifyRawNote。T-36）が同じ関数を呼ぶ。期待値は呼び手が決める。
    /// 打ち切りの位置は voicedock と同じ（落ちた規則の列が error_message に出るため）。
    public static func verify(
        url: URL, kind: NoteKind, sessionKey: String, expectedSHA256: String,
        expectedKeys: Set<String>, summaryHeading: String
    ) -> NoteVerification {
        let prefix = kind == .raw ? rawPrefix : dailyPrefix
        var results: [NoteRuleResult] = []
        func add(_ n: Int, _ ok: Bool) {
            results.append(NoteRuleResult(rule: prefix + "-" + String(n), passed: ok))
        }
        func dailyBodyChecks(_ text: String) {
            add(8, hasContentUnder(text, summaryHeading))
            add(9, hasWikiLink(text))
        }

        // 規則 1: symlink を辿らずに通常ファイルであること
        var st = stat()
        if lstat(url.path(percentEncoded: false), &st) != 0 || (st.st_mode & S_IFMT) != S_IFREG {
            add(1, false)
            return NoteVerification(results: results)
        }
        add(1, true)

        // 規則 2
        let size = st.st_size
        add(2, size > 0)
        if size == 0 {
            return NoteVerification(results: results)
        }

        // 規則 3（読めなければ安全側で打ち切る）
        guard let data = try? Data(contentsOf: url) else {
            add(3, false)
            return NoteVerification(results: results)
        }
        guard let text = String(validating: data, as: UTF8.self) else {
            add(3, false)
            return NoteVerification(results: results)
        }
        add(3, true)

        // 規則 4（偽でも続ける）
        add(4, FileHasher.sha256(data) == expectedSHA256)

        if kind == .daily {
            add(5, Frontmatter.split(text) != nil)
        }

        let keyRule = kind == .raw ? 5 : 6
        guard let doc = Frontmatter.parse(text) else {
            add(keyRule, false)
            add(keyRule + 1, false)
            if kind == .daily {
                dailyBodyChecks(text)
            }
            return NoteVerification(results: results)
        }

        // RN-5 / DN-6: 鍵はスカラー列で比べる（00-api-map §0）
        add(keyRule, (doc[Frontmatter.keySessionKey] as? String).map { PyText.scalarsEqual($0, sessionKey) } ?? false)

        // 鍵の集合もスカラー列で比べる（Set<String> は正準等価で比べるため）
        let found = scalarSet(Frontmatter.stringList(doc, Frontmatter.keyRecordingKeys))
        let expected = scalarSet(expectedKeys)
        switch kind {
        case .raw:
            // RN-6 は包含
            add(6, expected.isSubset(of: found))
        case .daily:
            // NOTE-12: DN-7 は完全一致（RN-6 と混同しない）
            add(7, found == expected)
            dailyBodyChecks(text)
        }
        return NoteVerification(results: results)
    }

    /// 鍵の集合をスカラー列の集合にする（00-api-map §0。partkey の照合はバイト一致）
    static func scalarSet(_ keys: some Sequence<String>) -> Set<[Unicode.Scalar]> {
        Set(keys.map { Array($0.unicodeScalars) })
    }

    /// DN-8（NOTE-13）。`^<見出し>\s*$` の行の後、次の `^#{1,6} ` の行の手前までに本文があるか。
    static func hasContentUnder(_ text: String, _ heading: String) -> Bool {
        let lines = ScalarText.splitLF(text)
        let head = Array(heading.unicodeScalars)
        guard
            let index = lines.firstIndex(where: { line in
                let scalars = Array(line.unicodeScalars)
                guard scalars.count >= head.count, Array(scalars[0..<head.count]) == head else { return false }
                return scalars[head.count...].allSatisfy { PyText.isSpace($0) }
            })
        else { return false }
        var body: [String] = []
        for line in lines[(index + 1)...] {
            if isHeadingLine(line) {
                break
            }
            body.append(line)
        }
        return !PyText.strip(body.joined(separator: "\n")).unicodeScalars.isEmpty
    }

    /// `#` が 1〜6 個続いた直後が半角空白（U+0020）
    static func isHeadingLine(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        var hashes = 0
        while hashes < scalars.count && scalars[hashes] == "#" {
            hashes += 1
        }
        return hashes >= 1 && hashes <= 6 && hashes < scalars.count && scalars[hashes] == " "
    }

    /// DN-9（NOTE-01）。`\[\[[^\]]+\]\]` が在るか
    static func hasWikiLink(_ text: String) -> Bool {
        let s = Array(text.unicodeScalars)
        let open: Unicode.Scalar = "["
        let close: Unicode.Scalar = "]"
        var i = 0
        while i + 1 < s.count {
            if s[i] == open && s[i + 1] == open {
                if let j = s[(i + 2)...].firstIndex(of: close), j >= i + 3, j + 1 < s.count, s[j + 1] == close {
                    return true
                }
            }
            i += 1
        }
        return false
    }
}
