// frontmatter の書き出し（自前）と読み取り（Yams の compose。F-71）。PLAN §8.6 / NOTE-06。voicedock notes.py:108-220 と同じ出力。
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

    /// `\` → `\\`、`"` → `\"` の後、U+0000〜U+001F と U+007F を取り除き、二重引用符で囲む（U+0085・U+2028・U+2029 は残す）。
    /// F-83: YAML の読み手（libyaml・PyYAML）が拒む文字（`isUnreadableByYAML`）は `\uXXXX`（大文字 16 進 4 桁）にする。
    /// そのまま書くと frontmatter 全体が読めず、保存の検証が落ちて再試行ごとに ` (2)` … のノートが増えた（X-40）。
    /// 置換は `.literal`（スカラー単位）。既定の比較は結合文字が続く `\` / `"` を見逃す（PLAN §5.7）。
    public static func quote(_ s: String) -> String {
        var escaped = s.replacingOccurrences(of: "\\", with: "\\\\", options: .literal)
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"", options: .literal)
        escaped = ScalarText.removing(escaped, Sanitize.controlScalars)
        return "\"" + escapingUnreadable(escaped) + "\""
    }

    /// F-83: libyaml の読み取り（`CYaml/src/reader.c`、「control characters are not allowed」）と PyYAML（`Reader.NON_PRINTABLE`、
    /// 「special characters are not allowed」）が拒む文字のうち、`quote` が取り除く U+0000〜U+001F・U+007F を除いたもの:
    /// U+0080〜U+0084、U+0086〜U+009F、U+FFFE、U+FFFF（U+0085 と U+00A0 以降は受ける。サロゲートは Swift の文字列に無い）
    static func isUnreadableByYAML(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x80...0x84).contains(v) || (0x86...0x9F).contains(v) || v == 0xFFFE || v == 0xFFFF
    }

    /// `isUnreadableByYAML` のスカラーを二重引用符の中のエスケープ `\uXXXX`（大文字 16 進 4 桁）にする。値はそのまま読み戻せる
    static func escapingUnreadable(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            guard isUnreadableByYAML(scalar) else {
                out.append(scalar)
                continue
            }
            let hex = String(scalar.value, radix: 16, uppercase: true)
            out.append(contentsOf: ("\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex).unicodeScalars)
        }
        return String(out)
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
    /// F-71: `Yams.load` を使わない（既定の Constructor は 60 進の int `1:0:0:0:0:0:0:0:0:0:0` などの構築で桁あふれして落ちる）。
    /// `Yams.compose` の Node の最上位の mapping（タグが map）を読む。最上位の鍵が 1 つでも str の scalar でなければ
    /// （マージの鍵 `<<`・`yes` などの bool・数・null・複合鍵）全体を nil にする。鍵を黙って落とすと、
    /// 「載っている鍵 ⊆ 所有する鍵」（上書きの判定）が通りやすくなるため（3 つの呼び手すべてで nil が安全側）。
    /// 旧実装（`Yams.load`）は鍵をすべて文字列化し、複合鍵では落ちていた。値は:
    /// - scalar: `scalarValue`（`Yams.load` と同じ型。int は自前で読む）
    /// - sequence: 各要素を `[Any]` に。要素の scalar は `scalarValue`、入れ子の配列・辞書は中を読まず空の `[Any]` / `[AnyHashable: Any]`
    /// - mapping: 中を読まず空の `[AnyHashable: Any]`（呼び手は読まない。別名の展開を増やさない）
    public static func parse(_ text: String) -> [String: Any]? {
        guard let (front, _) = split(text) else { return nil }
        let root: Node?
        do {
            root = try Yams.compose(yaml: front)
        } catch {
            return nil
        }
        guard let root, case .mapping(let mapping) = root, Tag.Name(rawValue: root.tag.rawValue) == .map else {
            return nil
        }
        var result: [String: Any] = [:]
        for (key, value) in mapping {
            guard case .scalar(let name) = key, Tag.Name(rawValue: key.tag.rawValue) == .str else { return nil }
            result[name.string] = topLevelValue(value)
        }
        return result
    }

    /// 最上位の値（F-71）。配列は 1 段だけ読む。
    static func topLevelValue(_ node: Node) -> Any {
        switch node {
        case .scalar(let scalar):
            return scalarValue(scalar, tag: node.tag)
        case .sequence(let items):
            return items.map { item -> Any in
                switch item {
                case .scalar(let scalar): return scalarValue(scalar, tag: item.tag)
                case .sequence: return [Any]()
                case .mapping, .alias: return [AnyHashable: Any]()
                }
            }
        case .mapping, .alias:
            return [AnyHashable: Any]()
        }
    }

    /// scalar を解決したタグで `String` / `Bool` / `Int` / `Double` / `NSNull` にする（`Yams.load` と同じ型。F-71）。
    /// 作れなければ元の文字列（`Yams.load` の既定の戻りと同じ）。timestamp・binary・独自のタグは構築せず元の文字列
    static func scalarValue(_ scalar: Node.Scalar, tag: Tag) -> Any {
        switch Tag.Name(rawValue: tag.rawValue) {
        case .str: return scalar.string
        case .bool: return Bool.construct(from: scalar) ?? scalar.string
        case .int: return integer(scalar) ?? scalar.string
        case .float: return Double.construct(from: scalar) ?? scalar.string
        case .null: return NSNull.construct(from: scalar) ?? scalar.string
        default: return scalar.string
        }
    }

    /// YAML 1.1 の int を Yams の `Int.construct` と同じ手順で読む（`_` を除く → 符号 → `0x` `0b` `0o` `0` の基数 → 60 進 → 10 進）。
    /// F-71: 60 進は桁あふれを nil にする（Yams は基数を 1 桁余分に掛けて `60^11` で落ちる。ここでは値の桁だけを掛ける）
    static func integer(_ scalar: Node.Scalar) -> Int? {
        guard scalar.style == .any || scalar.style == .plain else { return nil }
        let text = scalar.string.replacingOccurrences(of: "_", with: "")
        if text == "0" { return 0 }
        let negative = text.hasPrefix("-")
        let body = text.dropFirst(negative || text.hasPrefix("+") ? 1 : 0)
        let sign = negative ? "-" : ""
        for (prefix, radix) in [("0x", 16), ("0b", 2), ("0o", 8), ("0", 8)] where body.hasPrefix(prefix) {
            return Int(sign + body.dropFirst(prefix.count), radix: radix)
        }
        guard body.contains(":") else { return Int(text) }
        var value = 0
        for component in body.split(separator: ":", omittingEmptySubsequences: false) {
            guard let digit = Int(component) else { return nil }
            let (shifted, shiftOverflows) = value.multipliedReportingOverflow(by: 60)
            let (sum, sumOverflows) = shifted.addingReportingOverflow(digit)
            if shiftOverflows || sumOverflows { return nil }
            value = sum
        }
        return negative ? -value : value
    }

    /// F-71: `recordingKeys(ofFile:)` が読むノートの大きさの上限（64 MiB。Raw ノートは 1 日分でも数 MB）。
    static let maxNoteBytes = 67_108_864

    /// §8.9.1 の `frontmatterKeys`。ノートの `voicedock_recording_keys`。読めなければ空（安全側）。
    /// F-71: 読む前に lstat で通常ファイルと大きさ（`maxNoteBytes` 以下）を確かめる（FIFO で止まらない・巨大なファイルを読まない）
    public static func recordingKeys(ofFile url: URL) -> [String] {
        guard let data = readNote(url) else { return [] }
        guard let text = String(validating: data, as: UTF8.self) else { return [] }
        guard let doc = parse(text) else { return [] }
        return stringList(doc, keyRecordingKeys)
    }

    /// lstat で通常ファイルかつ `maxNoteBytes` 以下を確かめてから、symlink を辿らず（O_NOFOLLOW）・待たず（O_NONBLOCK）に開き、
    /// fstat でもう一度確かめて全部読む（F-71）。どれかが満たせなければ nil
    static func readNote(_ url: URL) -> Data? {
        let path = url.path(percentEncoded: false)
        let limit = Int64(maxNoteBytes)
        var before = stat()
        guard lstat(path, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_size <= limit else {
            return nil
        }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var opened = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG, opened.st_size <= limit else {
            return nil
        }
        let read: Data?
        do {
            read = try handle.read(upToCount: maxNoteBytes + 1)
        } catch {
            return nil
        }
        // 空のファイルは nil（終わり）が返る
        let data = read ?? Data()
        return data.count <= maxNoteBytes ? data : nil
    }

    /// doc[key] が配列なら各要素を PyStr.describe したもの。配列でなければ（無い・文字列など）空配列
    public static func stringList(_ doc: [String: Any], _ key: String) -> [String] {
        guard let items = doc[key] as? [Any] else { return [] }
        return items.map { PyStr.describe($0) }
    }
}
