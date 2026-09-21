// Python の json.loads と同じ規則で JSON を読み、キーの順序を保った PyJSONValue にする（PLAN §5.7、§8.5）。
import Foundation

extension PyJSON {
    /// 入れ物（配列・オブジェクト）の入れ子の上限。65 段目で nil。
    /// 再帰下降のスタックが 512 KiB のスレッド（Swift Concurrency の協調スレッド）でも溢れない深さ（Debug ビルドで
    /// 1 段あたり約 2.5 KiB）。Python は約 1000 段まで読むが、LLM の出力と設定ファイルは 4 段を超えない。
    static let maxDecodeDepth = 64

    /// Python の `json.loads(text)` と同じものを受け、同じ値を返す。読めなければ nil（例外を投げない）。
    ///
    /// - 前後と要素の間の空白は U+0020・U+0009・U+000A・U+000D だけ。値の後に空白以外が残れば nil。先頭の U+FEFF は nil
    /// - `true` / `false` / `null` と、`NaN` / `Infinity` / `-Infinity`（`.double`）を受ける
    /// - 数は `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?`。小数部も指数部も無く `Int64` に収まれば `.int`、
    ///   それ以外は `.double(Double(文字列))`
    /// - 文字列のエスケープは `\" \\ \/ \b \f \n \r \t \uXXXX`（16 進は大小どちらも）。サロゲートの組は 1 つのスカラーにし、
    ///   対にならないサロゲートは U+FFFD にする。U+0000–U+001F の生の文字は nil
    /// - 同じキーが 2 回出たら、値は後勝ち・位置は最初の出現のまま（Python の dict）
    public static func decode(_ text: String) -> PyJSONValue? {
        var parser = PyJSONParser(scalars: Array(text.unicodeScalars))
        guard let value = parser.parseValue(depth: 0) else {
            return nil
        }
        parser.skipWhitespace()
        return parser.index == parser.scalars.count ? value : nil
    }

    /// UTF-8 のバイト列を `decode(_:)` で読む。不正な UTF-8 は nil（`parse` と同じ検査。00-api-map の `decode(_ data: Data)`）。
    public static func decode(_ data: Data) -> PyJSONValue? {
        guard let text = String(validating: data, as: UTF8.self) else {
            return nil
        }
        return decode(text)
    }
}

/// `PyJSON.decode` の再帰下降パーサ。
struct PyJSONParser {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    mutating func skipWhitespace() {
        while index < scalars.count {
            switch scalars[index].value {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    func peek() -> UInt32? {
        index < scalars.count ? scalars[index].value : nil
    }

    mutating func consume(_ literal: String) -> Bool {
        let expected = Array(literal.unicodeScalars)
        guard index + expected.count <= scalars.count,
            Array(scalars[index..<(index + expected.count)]) == expected
        else {
            return false
        }
        index += expected.count
        return true
    }

    /// `depth` は外側にある入れ物（配列・オブジェクト）の数。入れ物は `maxDecodeDepth` 段まで。
    mutating func parseValue(depth: Int) -> PyJSONValue? {
        skipWhitespace()
        guard let first = peek() else {
            return nil
        }
        switch first {
        case 0x7B:  // {
            return depth < PyJSON.maxDecodeDepth ? parseObject(depth: depth) : nil
        case 0x5B:  // [
            return depth < PyJSON.maxDecodeDepth ? parseArray(depth: depth) : nil
        case 0x22:  // "
            return parseString().map { .string($0) }
        case 0x74:  // t
            return consume("true") ? .bool(true) : nil
        case 0x66:  // f
            return consume("false") ? .bool(false) : nil
        case 0x6E:  // n
            return consume("null") ? .null : nil
        case 0x4E:  // N
            return consume("NaN") ? .double(.nan) : nil
        case 0x49:  // I
            return consume("Infinity") ? .double(.infinity) : nil
        case 0x2D:  // -
            if consume("-Infinity") {
                return .double(-.infinity)
            }
            return parseNumber()
        case 0x30...0x39:
            return parseNumber()
        default:
            return nil
        }
    }

    mutating func parseObject(depth: Int) -> PyJSONValue? {
        index += 1  // {
        var pairs: [(String, PyJSONValue)] = []
        var positions: [String: Int] = [:]
        skipWhitespace()
        if peek() == 0x7D {
            index += 1
            return .object([])
        }
        while true {
            skipWhitespace()
            guard peek() == 0x22, let key = parseString() else {
                return nil
            }
            skipWhitespace()
            guard peek() == 0x3A else {
                return nil
            }
            index += 1
            guard let value = parseValue(depth: depth + 1) else {
                return nil
            }
            // Swift の String のハッシュは正準等価なので、スカラー列を鍵にする
            let identity = key.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
            if let position = positions[identity] {
                pairs[position].1 = value
            } else {
                positions[identity] = pairs.count
                pairs.append((key, value))
            }
            skipWhitespace()
            switch peek() {
            case 0x2C:
                index += 1
            case 0x7D:
                index += 1
                return .object(pairs)
            default:
                return nil
            }
        }
    }

    mutating func parseArray(depth: Int) -> PyJSONValue? {
        index += 1  // [
        var items: [PyJSONValue] = []
        skipWhitespace()
        if peek() == 0x5D {
            index += 1
            return .array([])
        }
        while true {
            guard let value = parseValue(depth: depth + 1) else {
                return nil
            }
            items.append(value)
            skipWhitespace()
            switch peek() {
            case 0x2C:
                index += 1
            case 0x5D:
                index += 1
                return .array(items)
            default:
                return nil
            }
        }
    }

    mutating func parseString() -> String? {
        index += 1  // "
        var out = String.UnicodeScalarView()
        while let value = peek() {
            index += 1
            switch value {
            case 0x22:
                return String(out)
            case 0x5C:
                guard let escape = peek() else {
                    return nil
                }
                index += 1
                switch escape {
                case 0x22: out.append("\"")
                case 0x5C: out.append("\\")
                case 0x2F: out.append("/")
                case 0x62: out.append(Unicode.Scalar(0x08))
                case 0x66: out.append(Unicode.Scalar(0x0C))
                case 0x6E: out.append("\n")
                case 0x72: out.append("\r")
                case 0x74: out.append("\t")
                case 0x75:
                    guard let unit = parseHex4() else {
                        return nil
                    }
                    out.append(decodeUnit(unit))
                default:
                    return nil
                }
            case 0x00...0x1F:
                return nil
            default:
                out.append(scalars[index - 1])
            }
        }
        return nil
    }

    /// `\u` の後の 4 桁。
    mutating func parseHex4() -> UInt32? {
        guard index + 4 <= scalars.count else {
            return nil
        }
        var result: UInt32 = 0
        for offset in 0..<4 {
            let value = scalars[index + offset].value
            let digit: UInt32
            switch value {
            case 0x30...0x39: digit = value - 0x30
            case 0x41...0x46: digit = value - 0x41 + 10
            case 0x61...0x66: digit = value - 0x61 + 10
            default: return nil
            }
            result = result * 16 + digit
        }
        index += 4
        return result
    }

    /// 1 つの UTF-16 単位を Unicode スカラーにする。上位サロゲートの直後に `\u` の下位サロゲートがあれば組にする。
    mutating func decodeUnit(_ unit: UInt32) -> Unicode.Scalar {
        let replacement: Unicode.Scalar = "\u{FFFD}"
        if (0xD800...0xDBFF).contains(unit) {
            let saved = index
            if consume("\\u"), let low = parseHex4(), (0xDC00...0xDFFF).contains(low) {
                let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                return Unicode.Scalar(combined) ?? replacement
            }
            index = saved
            return replacement
        }
        return Unicode.Scalar(unit) ?? replacement
    }

    mutating func parseNumber() -> PyJSONValue? {
        let start = index
        var isInteger = true
        if peek() == 0x2D {
            index += 1
        }
        guard let lead = peek(), (0x30...0x39).contains(lead) else {
            return nil
        }
        index += 1
        if lead != 0x30 {
            while let digit = peek(), (0x30...0x39).contains(digit) {
                index += 1
            }
        }
        if peek() == 0x2E {
            let dot = index
            index += 1
            guard let digit = peek(), (0x30...0x39).contains(digit) else {
                index = dot
                return finishNumber(start: start, isInteger: isInteger)
            }
            isInteger = false
            while let next = peek(), (0x30...0x39).contains(next) {
                index += 1
            }
        }
        if let marker = peek(), marker == 0x65 || marker == 0x45 {
            let exponentStart = index
            index += 1
            if let sign = peek(), sign == 0x2B || sign == 0x2D {
                index += 1
            }
            guard let digit = peek(), (0x30...0x39).contains(digit) else {
                index = exponentStart
                return finishNumber(start: start, isInteger: isInteger)
            }
            isInteger = false
            while let next = peek(), (0x30...0x39).contains(next) {
                index += 1
            }
        }
        return finishNumber(start: start, isInteger: isInteger)
    }

    func finishNumber(start: Int, isInteger: Bool) -> PyJSONValue? {
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars[start..<index])
        let literal = String(text)
        if isInteger, let integer = Int64(literal) {
            return .int(integer)
        }
        return Double(literal).map { .double($0) }
    }
}
