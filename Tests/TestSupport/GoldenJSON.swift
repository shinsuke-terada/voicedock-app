// golden の JSON の値（入力と .json の期待値）。JSONDecoder で読み、Unicode スカラー列で比べる（PLAN §10.4、T-25）。
import Foundation

/// golden の JSON の値。
///
/// - 読み取りは `JSONDecoder`（`JSONSerialization` は文字列の先頭の U+FEFF を落とすので使わない。Xcode 27.0 で確認）
/// - 文字列の比較は Unicode スカラー列（Swift の `==` は正準等価で比べ、NFC の有無を見逃すため）
/// - 数は整数の字面なら `.integer`、それ以外は `.number`。`.integer` と `.number` は数として等しければ等しい
public indirect enum GoldenJSON: Sendable, Equatable, Decodable, CustomStringConvertible {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([GoldenJSON])
    case object([String: GoldenJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([GoldenJSON].self) {
            self = .array(items)
        } else {
            self = .object(try container.decode([String: GoldenJSON].self))
        }
    }

    /// Swift / Foundation の値から作る（`String`・`Bool`・整数・`Double`・`NSNumber`・配列・辞書・`nil`・`NSNull`）。
    /// 表せない値は nil。
    public init?(any value: Any?) {
        guard let value else {
            self = .null
            return
        }
        switch value {
        case is NSNull:
            self = .null
        case let json as GoldenJSON:
            self = json
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number as CFNumber) {
                self = .number(number.doubleValue)
            } else {
                self = .integer(number.int64Value)
            }
        case let flag as Bool:
            self = .bool(flag)
        case let integer as Int:
            self = .integer(Int64(integer))
        case let integer as Int64:
            self = .integer(integer)
        case let number as Double:
            self = .number(number)
        case let items as [Any?]:
            var converted: [GoldenJSON] = []
            for item in items {
                guard let json = GoldenJSON(any: item) else {
                    return nil
                }
                converted.append(json)
            }
            self = .array(converted)
        case let pairs as [String: Any?]:
            var converted: [String: GoldenJSON] = [:]
            for (key, item) in pairs {
                guard let json = GoldenJSON(any: item) else {
                    return nil
                }
                converted[key] = json
            }
            self = .object(converted)
        default:
            return nil
        }
    }

    public static func == (lhs: GoldenJSON, rhs: GoldenJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.integer(let a), .integer(let b)):
            return a == b
        case (.number(let a), .number(let b)):
            return a == b
        case (.integer(let a), .number(let b)), (.number(let b), .integer(let a)):
            return Double(a) == b
        case (.string(let a), .string(let b)):
            return a.unicodeScalars.elementsEqual(b.unicodeScalars)
        case (.array(let a), .array(let b)):
            return a == b
        case (.object(let a), .object(let b)):
            let left = GoldenJSON.sortedPairs(a)
            let right = GoldenJSON.sortedPairs(b)
            return left.count == right.count
                && zip(left, right).allSatisfy { pair in
                    pair.0.0.unicodeScalars.elementsEqual(pair.1.0.unicodeScalars) && pair.0.1 == pair.1.1
                }
        default:
            return false
        }
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    /// 整数の字面か、整数に等しい小数なら Int。
    public var intValue: Int? {
        switch self {
        case .integer(let integer): return Int(exactly: integer)
        case .number(let number): return Int(exactly: number)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let integer): return Double(integer)
        case .number(let number): return number
        default: return nil
        }
    }

    public var arrayValue: [GoldenJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectValue: [String: GoldenJSON]? {
        if case .object(let pairs) = self { return pairs }
        return nil
    }

    /// Foundation の値（`NSNull`・`NSNumber`・`String`・`[Any]`・`[String: Any]`）。AppConfig への上書きなどに使う。
    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let flag): return NSNumber(value: flag)
        case .integer(let integer): return NSNumber(value: integer)
        case .number(let number): return NSNumber(value: number)
        case .string(let text): return text
        case .array(let items): return items.map(\.foundationObject)
        case .object(let pairs): return pairs.mapValues(\.foundationObject)
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// 差分の表示用の JSON（キーはスカラー値の順、2 空白の字下げ、末尾改行なし）。
    public var description: String {
        var out = ""
        render(level: 0, into: &out)
        return out
    }

    static func sortedPairs(_ pairs: [String: GoldenJSON]) -> [(String, GoldenJSON)] {
        pairs.map { ($0.key, $0.value) }.sorted { lhs, rhs in
            lhs.0.unicodeScalars.map(\.value).lexicographicallyPrecedes(rhs.0.unicodeScalars.map(\.value))
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029, 0xFEFF:
                out += "\\u{" + String(scalar.value, radix: 16) + "}"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    func render(level: Int, into out: inout String) {
        let pad = String(repeating: " ", count: 2 * (level + 1))
        let close = String(repeating: " ", count: 2 * level)
        switch self {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .integer(let integer): out += String(integer)
        case .number(let number): out += number.description
        case .string(let text): out += GoldenJSON.quoted(text)
        case .array(let items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad
                item.render(level: level + 1, into: &out)
                out += index + 1 < items.count ? ",\n" : "\n"
            }
            out += close + "]"
        case .object(let pairs):
            if pairs.isEmpty {
                out += "{}"
                return
            }
            let sorted = GoldenJSON.sortedPairs(pairs)
            out += "{\n"
            for (index, pair) in sorted.enumerated() {
                out += pad + GoldenJSON.quoted(pair.0) + ": "
                pair.1.render(level: level + 1, into: &out)
                out += index + 1 < sorted.count ? ",\n" : "\n"
            }
            out += close + "}"
        }
    }
}

extension GoldenJSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: GoldenJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, GoldenJSON)...) {
        var pairs: [String: GoldenJSON] = [:]
        for (key, value) in elements {
            pairs[key] = value
        }
        self = .object(pairs)
    }
}
