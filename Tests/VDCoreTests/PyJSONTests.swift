// PyJSON が Python の json.dumps / json.loads と同じに振る舞うこと（PLAN §5.7、T-45）。
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("PyJSON")
struct PyJSONTests {
    /// golden の型付きの値（`["s", 文字列]` など。T-25）を PyJSONValue にする。
    static func value(fromTagged json: GoldenJSON) throws -> PyJSONValue {
        guard let items = json.arrayValue, let kind = items.first?.stringValue else {
            throw GoldenError.malformedInput("型付きの値ではありません: \(json)")
        }
        let payload = items.count > 1 ? items[1] : GoldenJSON.null
        switch kind {
        case "n": return .null
        case "b": return .bool(payload.boolValue ?? false)
        case "i":
            guard case .integer(let integer) = payload else { throw GoldenError.malformedInput("i: \(payload)") }
            return .int(integer)
        case "f":
            guard let text = payload.stringValue, let number = Double(text) else {
                throw GoldenError.malformedInput("f: \(payload)")
            }
            return .double(number)
        case "s": return .string(payload.stringValue ?? "")
        case "a": return .array(try (payload.arrayValue ?? []).map(value(fromTagged:)))
        case "o":
            return .object(
                try (payload.arrayValue ?? []).map { pair in
                    guard let parts = pair.arrayValue, parts.count == 2, let key = parts[0].stringValue else {
                        throw GoldenError.malformedInput("o: \(pair)")
                    }
                    return (key, try value(fromTagged: parts[1]))
                })
        default: throw GoldenError.malformedInput("未知の型: \(kind)")
        }
    }

    /// PyJSONValue を golden の型付きの値にする（浮動小数は Python の repr: 非有限は nan / inf / -inf）。
    static func tagged(_ value: PyJSONValue) -> GoldenJSON {
        switch value {
        case .null: return ["n"]
        case .bool(let flag): return ["b", .bool(flag)]
        case .int(let integer): return ["i", .integer(integer)]
        case .double(let number):
            let text =
                number.isNaN ? "nan" : number.isInfinite ? (number < 0 ? "-inf" : "inf") : PyJSON.formatDouble(number)
            return ["f", .string(text)]
        case .string(let text): return ["s", .string(text)]
        case .array(let items): return ["a", .array(items.map(tagged))]
        case .object(let pairs): return ["o", .array(pairs.map { [.string($0.0), tagged($0.1)] })]
        }
    }

    @Test("golden pyjson: dumps の書式が Python と一致する")
    func goldenDumps() throws {
        let cases = try Golden.cases("pyjson")
        #expect(!cases.isEmpty)
        for item in cases {
            let value = try Self.value(fromTagged: try item.value("value"))
            let mode = try item.string("mode")
            switch mode {
            case "compact": GoldenAssert.matches(PyJSON.dumpsCompact(value), group: "pyjson", name: item.name)
            case "compact_sorted":
                GoldenAssert.matches(PyJSON.dumpsCompact(value, sortKeys: true), group: "pyjson", name: item.name)
            case "indent2": GoldenAssert.matches(PyJSON.dumpsIndent2(value), group: "pyjson", name: item.name)
            case "file": GoldenAssert.matches(bytes: PyJSON.fileData(value), group: "pyjson", name: item.name)
            default: Issue.record("未知の mode: \(mode)")
            }
        }
    }

    @Test("golden pyjson_decode: decode が Python の json.loads と同じ値を返す（読めないものは nil）")
    func goldenDecode() throws {
        let cases = try Golden.cases("pyjson_decode")
        #expect(!cases.isEmpty)
        for item in cases {
            let result = PyJSON.decode(try item.string("text"))
            let actual: GoldenJSON = ["ok": .bool(result != nil), "value": result.map(Self.tagged) ?? .null]
            GoldenAssert.matchesJSON(actual, group: "pyjson_decode", name: item.name)
        }
    }

    @Test("escape は \" \\ と U+0000〜U+001F だけをエスケープし、両端の \" を付けない")
    func escapeRules() {
        #expect(PyJSON.escape("a\"b\\c") == #"a\"b\\c"#)
        #expect(PyJSON.escape("\n\r\t\u{8}\u{C}") == #"\n\r\t\b\f"#)
        #expect(PyJSON.escape("\u{1}\u{1F}") == "\\" + "u0001" + "\\" + "u001f")
        #expect(PyJSON.escape("/\u{7F}\u{2028}\u{E9}") == "/\u{7F}\u{2028}\u{E9}")
    }

    @Test("浮動小数は Python の repr と同じ表記。非有限は NaN / Infinity / -Infinity")
    func formatDoubleRules() {
        #expect(PyJSON.formatDouble(1800) == "1800.0")
        #expect(PyJSON.formatDouble(1e-5) == "1e-05")
        #expect(PyJSON.formatDouble(1e16) == "1e+16")
        #expect(PyJSON.formatDouble(9_007_199_254_740_994) == "9007199254740994.0")
        #expect(PyJSON.formatDouble(-9.5e15) == "-9500000000000000.0")
        #expect(PyJSON.formatDouble(9.999e-5) == "9.999e-05")
        #expect(PyJSON.formatDouble(-0.0) == "-0.0")
        #expect(PyJSON.formatDouble(.nan) == "NaN")
        #expect(PyJSON.formatDouble(-.infinity) == "-Infinity")
    }

    @Test("sortKeys はスカラー値の順（Swift の < ではない）")
    func sortKeysByScalarValue() {
        let value = PyJSONValue.object([("e", .int(1)), ("a\u{301}", .int(2)), ("\u{E9}", .int(3))])
        #expect(PyJSON.dumpsCompact(value, sortKeys: true) == "{\"a\u{301}\":2,\"e\":1,\"\u{E9}\":3}")
    }

    @Test("indent 2 の空の入れ物と、fileData の末尾改行")
    func indentEmptyContainers() {
        #expect(PyJSON.dumpsIndent2(.array([.array([]), .object([])])) == "[\n  [],\n  {}\n]")
        #expect(PyJSON.fileData(.object([])) == Data("{}\n".utf8))
    }

    @Test("parse は文字列の先頭の U+FEFF を保ち、真偽値を区別する")
    func parseKeepsBOMAndBooleans() throws {
        let data = Data("{\"a\": true, \"b\": 1, \"c\": [NaN], \"d\": \"\u{FEFF}x\"}".utf8)
        let object = try #require(PyJSON.parse(data) as? [String: Any])
        #expect(PyJSON.isBool(try #require(object["a"])))
        #expect(!PyJSON.isBool(try #require(object["b"])))
        #expect((object["d"] as? String)?.unicodeScalars.first?.value == 0xFEFF)
    }

    @Test("parse は先頭の BOM・不正な UTF-8・余分な文字を受けない")
    func parseRejects() {
        #expect(PyJSON.parse(Data([0xEF, 0xBB, 0xBF, 0x7B, 0x7D])) == nil)
        #expect(PyJSON.parse(Data([0x22, 0xFF, 0x22])) == nil)
        #expect(PyJSON.parse(Data("{} x".utf8)) == nil)
        #expect(PyJSON.decode(Data([0x22, 0xFF, 0x22])) == nil)
        #expect(PyJSON.decode(Data("{\"k\": 1}".utf8)) == .object([("k", .int(1))]))
    }

    @Test("decode の入れ物の入れ子は 64 段まで（65 段で nil。とても深くてもスタックは溢れない）")
    func decodeDepthLimit() {
        let ok = String(repeating: "{\"a\":", count: 63) + "[1]" + String(repeating: "}", count: 63)
        let tooDeep = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        #expect(PyJSON.decode(ok) != nil)
        #expect(PyJSON.decode(tooDeep) == nil)
        #expect(PyJSON.decode(String(repeating: "[", count: 100_000)) == nil)
    }

    @Test("decode の同じキーは値が後勝ち、位置は最初")
    func decodeDuplicateKeys() {
        #expect(PyJSON.decode(#"{"b":1,"a":2,"b":3}"#) == .object([("b", .int(3)), ("a", .int(2))]))
    }

    @Test("PyJSONValue の == は文字列をスカラー列で、浮動小数をビット列で比べる")
    func equalityRules() {
        #expect(PyJSONValue.string("\u{304C}") != .string("\u{304B}\u{3099}"))
        #expect(PyJSONValue.double(0.0) != .double(-0.0))
        #expect(PyJSONValue.object([("a", .null)]) == .object([("a", .null)]))
    }
}
