// frontmatter の書き出し（自前）と読み取り（Yams）。PLAN §8.6 / NOTE-06。voicedock notes.py:108-220 と同じ出力。
import Foundation
import VDCore
import Yams

public enum FrontmatterValue: Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case null
    case array([String])
}

public enum Frontmatter {
    static let delimiter = "---"
    // フィールド名（00-api-map §9。書き手（T-26・T-27）と検証側（T-28・T-36）が同じ定数を使う）
    public static let keySessionKey = "voicedock_session_key"
    public static let keyRecordingKeys = "voicedock_recording_keys"
    public static let keyFailedParts = "voicedock_failed_parts"
    public static let keySkippedParts = "voicedock_skipped_parts"
    public static let keyType = "type"

    /// NOTE-06: 汎用シリアライザを使わず、渡された順に 1 行ずつ書く。末尾に区切りと改行を含む。
    public static func render(_ fields: [(String, FrontmatterValue)]) -> String {
        var lines = [delimiter]
        for (key, value) in fields {
            switch value {
            case .string(let s):
                lines.append(key + ": " + quote(s))
            case .bool(let b):
                lines.append(key + ": " + (b ? "true" : "false"))
            case .int(let n):
                lines.append(key + ": " + String(n))
            case .null:
                lines.append(key + ": null")
            case .array(let a):
                if a.isEmpty {
                    // 空配列は `[]`。`key:` だけだと YAML が null と読み、「0 件」と「欄が無い」が区別できない
                    lines.append(key + ": []")
                } else {
                    lines.append(key + ":")
                    lines += a.map { "  - " + quote($0) }
                }
            }
        }
        lines.append(delimiter)
        return lines.joined(separator: "\n") + "\n"
    }

    /// `\` → `\\`、`"` → `\"` の後、U+0000〜U+001F と U+007F を取り除き、二重引用符で囲む（C1・U+2028・U+2029 は残す）。
    /// 置換は `.literal`（スカラー単位）。既定の比較は結合文字が続く `\` / `"` を見逃す（PLAN §5.7）。
    public static func quote(_ s: String) -> String {
        var escaped = s.replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"", options: .literal)
        escaped = ScalarText.removing(escaped, Sanitize.controlScalars)
        return "\"" + escaped + "\""
    }

    /// 本文の行頭（先頭と各 `\n` の直後）の `---` を `\---` にする（`re.sub(r"^---", r"\---", s, flags=re.M)`）。
    public static func escapeBody(_ s: String) -> String {
        ScalarText.splitLF(s)
            .map { ScalarText.hasPrefix($0, delimiter) ? "\\" + $0 : $0 }
            .joined(separator: "\n")
    }

    /// `(front, body)`。先頭が `---\n` で、閉じ行（行頭の `---` の後に空白だけ）が在るときだけ。
    /// Python の `re.search(r"^---\s*$", rest, re.M)` と同じ結果を正規表現を使わずに出す。
    public static func split(_ text: String) -> (front: String, body: String)? {
        guard ScalarText.hasPrefix(text, delimiter + "\n") else { return nil }
        let r = Array(Array(text.unicodeScalars).dropFirst(4))
        let n = r.count
        let dash: Unicode.Scalar = "-"
        for p in 0..<n where p == 0 || r[p - 1] == "\n" {
            guard p + 3 <= n, r[p] == dash, r[p + 1] == dash, r[p + 2] == dash else { continue }
            var spaces = 0
            while p + 3 + spaces < n && PyText.isSpace(r[p + 3 + spaces]) {
                spaces += 1
            }
            let candidates = (0...spaces).filter { k in p + 3 + k == n || r[p + 3 + k] == "\n" }
            guard let kMax = candidates.max() else { continue }
            return (ScalarText.string(Array(r[0..<p])), ScalarText.string(Array(r[(p + 3 + kMax)..<n])))
        }
        return nil
    }

    /// frontmatter を辞書で返す。読めなければ nil。例外を投げない（Yams の例外・重複キーも nil）。
    public static func parse(_ text: String) -> [String: Any]? {
        guard let (front, _) = split(text) else { return nil }
        let value: Any?
        do {
            value = try Yams.load(yaml: front)
        } catch {
            return nil
        }
        if let mapping = value as? [AnyHashable: Any] {
            var result: [String: Any] = [:]
            for (key, element) in mapping {
                if let name = key.base as? String {
                    result[name] = element
                }
            }
            return result
        }
        if let mapping = value as? [String: Any] {
            return mapping
        }
        return nil
    }

    /// §8.9.1 の `frontmatterKeys`。ノートの `voicedock_recording_keys`。読めなければ空（安全側）。
    public static func recordingKeys(ofFile url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let text = String(validating: data, as: UTF8.self) else { return [] }
        guard let doc = parse(text) else { return [] }
        return stringList(doc, keyRecordingKeys)
    }

    /// doc[key] が配列なら各要素を PyStr.describe したもの。配列でなければ（無い・文字列など）空配列
    public static func stringList(_ doc: [String: Any], _ key: String) -> [String] {
        guard let items = doc[key] as? [Any] else { return [] }
        return items.map { PyStr.describe($0) }
    }
}
