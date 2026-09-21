// PyText が Python 3.12 の str と同じに振る舞うこと（PLAN §5.7、T-45）。
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("PyText")
struct PyTextTests {
    /// golden `pytext/enumerations.json`（Python 3.12 / unicodedata 15.0.0 で全コードポイントを調べたもの）。
    static func enumerations() throws -> [String: GoldenJSON] {
        guard let object = try Golden.expectedJSON("pytext", "enumerations").objectValue else {
            throw GoldenError.malformedInput("pytext/enumerations")
        }
        return object
    }

    static func scalarSet(_ json: GoldenJSON?) -> Set<UInt32> {
        Set((json?.arrayValue ?? []).compactMap(\.intValue).map(UInt32.init))
    }

    static var allScalars: [Unicode.Scalar] {
        (UInt32(0)...0x10FFFF).compactMap(Unicode.Scalar.init)
    }

    @Test("golden は unicodedata 15.0.0 で作られている")
    func goldenUnicodeVersion() throws {
        #expect(try Self.enumerations()["unicodeVersion"]?.stringValue == "15.0.0")
        #expect(PyCaseFoldTable.unicodeVersion == "15.0.0")
    }

    @Test("isSpace は Python の str.isspace と全スカラーで一致する")
    func isSpaceMatchesPython() throws {
        let expected = Self.scalarSet(try Self.enumerations()["isspace"])
        #expect(expected.count == 29)
        for scalar in Self.allScalars {
            #expect(PyText.isSpace(scalar) == expected.contains(scalar.value), "U+\(String(scalar.value, radix: 16))")
        }
    }

    @Test("splitLines の区切りは Python の str.splitlines と全スカラーで一致する")
    func lineBreaksMatchPython() throws {
        let expected = Self.scalarSet(try Self.enumerations()["splitlinesSeparators"])
        #expect(expected.count == 10)
        for scalar in Self.allScalars {
            var text = String.UnicodeScalarView()
            text.append(contentsOf: ["a", scalar, "b"])
            let isBreak = PyText.splitLines(String(text)).count == 2
            #expect(isBreak == expected.contains(scalar.value), "U+\(String(scalar.value, radix: 16))")
        }
    }

    @Test("casefold の表は Python の str.casefold と完全に一致する")
    func casefoldTableMatchesPython() throws {
        guard let expected = try Self.enumerations()["casefold"]?.objectValue else {
            Issue.record("casefold がありません")
            return
        }
        #expect(expected.count == PyCaseFoldTable.map.count)
        for (key, value) in expected {
            let source = UInt32(key) ?? 0
            let mapped = (value.arrayValue ?? []).compactMap(\.intValue).map(UInt32.init)
            #expect(PyCaseFoldTable.map[source] == mapped, "U+\(String(source, radix: 16))")
        }
    }

    @Test("isCombining は Unicode 15.0 で割り当て済みの全スカラーで Python と一致する")
    func combiningMatchesPython() throws {
        let enumerations = try Self.enumerations()
        let expected = Self.scalarSet(enumerations["combining"])
        var checked = 0
        for range in enumerations["assignedRanges"]?.arrayValue ?? [] {
            let bounds = (range.arrayValue ?? []).compactMap(\.intValue)
            guard bounds.count == 2 else {
                Issue.record("assignedRanges の形が不正です")
                continue
            }
            for value in UInt32(bounds[0])...UInt32(bounds[1]) {
                guard let scalar = Unicode.Scalar(value) else { continue }
                checked += 1
                #expect(PyText.isCombining(scalar) == expected.contains(value), "U+\(String(value, radix: 16))")
            }
        }
        #expect(checked > 280_000)
    }

    @Test("golden の各ケース（strip・stripChars・splitlines・collapse・casefold・nfc・nfkc）")
    func goldenCases() throws {
        let cases = try Golden.cases("pytext").filter { $0.name != "enumerations" }
        #expect(!cases.isEmpty)
        for item in cases {
            let inputs = try item.strings("inputs")
            let kind = try item.string("kind")
            let outputs: [GoldenJSON]
            switch kind {
            case "strip": outputs = inputs.map { .string(PyText.strip($0)) }
            case "stripChars":
                let chars = Set(try item.string("chars").unicodeScalars)
                outputs = inputs.map { .string(PyText.strip($0, chars: chars)) }
            case "splitlines": outputs = inputs.map { .array(PyText.splitLines($0).map(GoldenJSON.string)) }
            case "collapse": outputs = inputs.map { .string(PyText.collapseWhitespace($0)) }
            case "casefold": outputs = inputs.map { .string(PyText.casefold($0)) }
            case "nfc": outputs = inputs.map { .string(PyText.nfc($0)) }
            case "nfkc": outputs = inputs.map { .string(PyText.nfkc($0)) }
            default:
                Issue.record("未知の kind: \(kind)")
                continue
            }
            GoldenAssert.matchesJSON(.array(outputs), group: "pytext", name: item.name)
        }
    }

    @Test(
        "PLAN §5.7 の固定例",
        arguments: [
            ("Stra\u{DF}e", "strasse"), ("\u{3A3}\u{391}\u{3A3}", "\u{3C3}\u{3B1}\u{3C3}"), ("\u{130}", "i\u{307}"),
            ("\u{FB01}", "fi"),
        ])
    func casefoldFixedExamples(input: String, expected: String) {
        #expect(PyText.scalarsEqual(PyText.casefold(input), expected))
    }

    @Test("PLAN §5.7 の文分割の例を部品で組む（関数そのものは T-27 の DailyNote）")
    func sentenceSplitExample() {
        let pieces = PyText.splitLines("A。B。 C".replacingOccurrences(of: "。", with: "。\n")).map(PyText.strip)
        #expect(pieces.filter { !$0.isEmpty } == ["A。", "B。", "C"])
    }

    @Test("strip は U+001C〜U+001F も空白として除く（CharacterSet と違う）")
    func stripRemovesInformationSeparators() {
        #expect(PyText.strip("\u{1C}X\u{1F}") == "X")
        #expect(PyText.strip("\u{200B}a\u{200B}") == "\u{200B}a\u{200B}")
        #expect(PyText.strip("") == "")
    }

    @Test("collapseWhitespace は NBSP を空白として畳み、ZWSP は残す")
    func collapseKeepsZeroWidthSpace() {
        #expect(PyText.scalarsEqual(PyText.collapseWhitespace("a\u{A0}b\u{200B}c"), "a b\u{200B}c"))
        #expect(PyText.collapseWhitespace(" a ") == " a ")
    }

    @Test("splitLines の端の扱い")
    func splitLinesEdges() {
        #expect(PyText.splitLines("") == [])
        #expect(PyText.splitLines("\n") == [""])
        #expect(PyText.splitLines("a\n") == ["a"])
        #expect(PyText.splitLines("\r\n\r") == ["", ""])
        #expect(PyText.splitLines("a\r\r\nb") == ["a", "", "b"])
    }

    @Test("scalarsEqual は正準等価でも違うスカラー列を区別する（Swift の == は区別しない）")
    func scalarsEqualDistinguishesNormalization() {
        #expect("\u{304C}" == "\u{304B}\u{3099}")
        #expect(!PyText.scalarsEqual("\u{304C}", "\u{304B}\u{3099}"))
        #expect(PyText.scalarsEqual(PyText.nfc("\u{304B}\u{3099}"), "\u{304C}"))
    }
}
