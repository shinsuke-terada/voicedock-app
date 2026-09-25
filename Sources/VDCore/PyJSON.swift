// Python の json.dumps(ensure_ascii=False) と同じ書式の JSON を書く（PLAN §5.7、CR-24）。
import Foundation

/// 順序付きの JSON の値。オブジェクトのキーの順序は呼び手が決める（`sortKeys` のときだけ並べ替える）。
public indirect enum PyJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([PyJSONValue])
    case object([(String, PyJSONValue)])

    /// 文字列は Unicode スカラー列で、浮動小数はビット列で比べる（`-0.0` と `0.0` は書き出しが違うので区別する）。
    public static func == (lhs: PyJSONValue, rhs: PyJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.int(let a), .int(let b)):
            return a == b
        case (.double(let a), .double(let b)):
            return a.bitPattern == b.bitPattern
        case (.string(let a), .string(let b)):
            return a.unicodeScalars.elementsEqual(b.unicodeScalars)
        case (.array(let a), .array(let b)):
            return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count
                && zip(a, b).allSatisfy { pair in
                    pair.0.0.unicodeScalars.elementsEqual(pair.1.0.unicodeScalars) && pair.0.1 == pair.1.1
                }
        default:
            return false
        }
    }
}

extension PyJSONValue {
    /// Foundation の値にする（真偽値は `NSNumber(value: Bool)` なので `PyJSON.isBool` が真になる）。
    /// オブジェクトは `[String: Any]` になるので、キーの順序は失われる。
    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let flag): return NSNumber(value: flag)
        case .int(let number): return NSNumber(value: number)
        case .double(let number): return NSNumber(value: number)
        case .string(let text): return text
        case .array(let items): return items.map(\.foundationObject)
        case .object(let pairs):
            var result: [String: Any] = [:]
            for (key, value) in pairs {
                result[key] = value.foundationObject
            }
            return result
        }
    }
}

/// Python の `json.dumps(value, ensure_ascii=False, …)` と同じ文字列を作る。
///
/// - `dumpsIndent2`: `indent=2`（区切り `,` と `: `、要素ごとに改行と 2 空白の字下げ、空の配列は `[]`、空のオブジェクトは `{}`）
/// - `dumpsCompact`: `separators=(",", ":")`
/// - 文字列は `"` `\` と U+0000–001F だけをエスケープする（`\n \r \t \b \f` は短い形、他は `\u00xx` の小文字 16 進）。
///   `/`・U+007F・U+2028・非 ASCII はそのまま
/// - 浮動小数は `Double.description`（Python の `repr` と同じ表記）。非有限は `NaN` / `Infinity` / `-Infinity`
/// - `sortKeys` はキーを Unicode スカラー値の辞書式順で並べる（Python の `sort_keys=True`。Swift の `<` は使わない）
public enum PyJSON {
    public static func dumpsIndent2(_ value: PyJSONValue) -> String {
        var out = ""
        write(value, indent: 2, level: 0, sortKeys: false, into: &out)
        return out
    }

    public static func dumpsCompact(_ value: PyJSONValue, sortKeys: Bool = false) -> String {
        var out = ""
        write(value, indent: nil, level: 0, sortKeys: sortKeys, into: &out)
        return out
    }

    /// ファイルに書く形（`dumpsIndent2` ＋ 末尾の `\n`）の UTF-8。
    public static func fileData(_ value: PyJSONValue) -> Data {
        Data((dumpsIndent2(value) + "\n").utf8)
    }

    /// JSON の文字列リテラルの中身（両端の `"` は含まない）。Python の `py_encode_basestring` から両端の `"` を除いたもの。
    public static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x00...0x1F: out += "\\u" + hex4(scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Python の `json.dumps` の浮動小数の表記（有限なら `repr(float)` と同じ。非有限は `NaN` / `Infinity` / `-Infinity`）。
    ///
    /// 桁は `Double.description`（最短で元に戻る 10 進）と同じ。ただし Swift は絶対値が 2^53 を超えると指数表記にし、
    /// Python は 1e16 未満なら固定小数点で書くので、その間（`9007199254740994.0`〜`9999999999999998.0`）だけ書き直す。
    public static func formatDouble(_ value: Double) -> String {
        if value.isNaN {
            return "NaN"
        }
        if value.isInfinite {
            return value < 0 ? "-Infinity" : "Infinity"
        }
        let text = value.description
        guard value.magnitude > 0x1p53, value.magnitude < 1e16, let marker = text.firstIndex(of: "e"),
            let exponent = Int(text[text.index(after: marker)...])
        else {
            return text
        }
        let sign = value < 0 ? "-" : ""
        let digits = text[..<marker].filter { $0.isNumber }
        return sign + digits + String(repeating: "0", count: max(0, exponent + 1 - digits.count)) + ".0"
    }

    /// UTF-8 の JSON を Python の `json.loads` と同じ規則で読み（`decode`）、Foundation の値
    /// （`[String: Any]` / `[Any]` / `String` / `NSNumber` / `NSNull`）にして返す。読めなければ nil。
    ///
    /// `JSONSerialization` は使わない: 文字列の先頭の U+FEFF を黙って落とし（Xcode 27.0 で確認）、`NaN` を受けないため。
    /// 不正な UTF-8 は nil（Python の `read_text(encoding="utf-8")` の失敗と同じ扱い）。
    public static func parse(_ data: Data) -> Any? {
        guard let text = String(validating: data, as: UTF8.self), let value = decode(text) else {
            return nil
        }
        return value.foundationObject
    }

    /// `parse` が返した値が真偽値か（真偽値の `NSNumber` は `as? Int` を通ってしまうので型 ID で区別する）。
    public static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else {
            return false
        }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// キーを Unicode スカラー値の辞書式順で比べる（Python の文字列の比較と同じ）。
    static func keyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.map(\.value).lexicographicallyPrecedes(rhs.unicodeScalars.map(\.value))
    }

    static func hex4(_ value: UInt32) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    static func write(_ value: PyJSONValue, indent: Int?, level: Int, sortKeys: Bool, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .bool(let flag):
            out += flag ? "true" : "false"
        case .int(let number):
            out += String(number)
        case .double(let number):
            out += formatDouble(number)
        case .string(let text):
            out += "\"" + escape(text) + "\""
        case .array(let items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 {
                    out += ","
                }
                if let indent {
                    out += "\n" + String(repeating: " ", count: indent * (level + 1))
                }
                write(item, indent: indent, level: level + 1, sortKeys: sortKeys, into: &out)
            }
            if let indent {
                out += "\n" + String(repeating: " ", count: indent * level)
            }
            out += "]"
        case .object(let pairs):
            if pairs.isEmpty {
                out += "{}"
                return
            }
            let ordered = sortKeys ? pairs.sorted { keyPrecedes($0.0, $1.0) } : pairs
            out += "{"
            for (index, pair) in ordered.enumerated() {
                if index > 0 {
                    out += ","
                }
                if let indent {
                    out += "\n" + String(repeating: " ", count: indent * (level + 1))
                }
                out += "\"" + escape(pair.0) + "\""
                out += indent == nil ? ":" : ": "
                write(pair.1, indent: indent, level: level + 1, sortKeys: sortKeys, into: &out)
            }
            if let indent {
                out += "\n" + String(repeating: " ", count: indent * level)
            }
            out += "}"
        }
    }
}
