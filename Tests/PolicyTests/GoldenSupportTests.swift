// TestSupport の golden の道具（GoldenJSON・Golden・GoldenAssert・UnifiedDiff）そのものを確かめる（TEST-05、T-25）。
import Foundation
import Testing

@testable import TestSupport

@Suite("GoldenSupport")
struct GoldenSupportTests {
    static let fixedPartkey = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"

    @Test("一致すれば何も記録しない（バイト列）")
    func bytesMatchRecordsNothing() {
        // PLAN §8.6 SN: 変える文字が無い名前はそのまま
        GoldenAssert.matches("2026-08-29 raw", group: "sanitize", name: "plain")
    }

    @Test("違えば記録する（バイト列）")
    func bytesMismatchRecordsIssue() {
        withKnownIssue {
            GoldenAssert.matches("2026-08-29 raw ", group: "sanitize", name: "plain")
        }
    }

    @Test("一致すれば何も記録しない（値。PLAN §4.2 の固定値）")
    func jsonMatchRecordsNothing() {
        GoldenAssert.matchesJSON(
            ["key": .string(Self.fixedPartkey), "slug": "a5d046dce76cfedc"], group: "keys", name: "partkey_fixed")
    }

    @Test("違えば記録する（値）")
    func jsonMismatchRecordsIssue() {
        withKnownIssue {
            GoldenAssert.matchesJSON(
                ["key": .string(Self.fixedPartkey), "slug": "a5d046dce76cfedd"], group: "keys", name: "partkey_fixed")
        }
    }

    @Test("比べ方を取り違えたら記録する")
    func wrongComparisonKindRecordsIssue() {
        withKnownIssue {
            GoldenAssert.matches("{}", group: "keys", name: "partkey_fixed")
        }
    }

    @Test("GoldenJSON の文字列はスカラー列で比べる（NFC と NFD を区別する）")
    func goldenJSONComparesScalars() {
        #expect(GoldenJSON.string("\u{304C}") != GoldenJSON.string("\u{304B}\u{3099}"))
        #expect(GoldenJSON.string("a") == GoldenJSON.string("a"))
    }

    @Test("GoldenJSON の数は整数と小数を数として比べ、真偽値とは区別する")
    func goldenJSONNumbers() {
        #expect(GoldenJSON.integer(2) == GoldenJSON.number(2.0))
        #expect(GoldenJSON.integer(1) != GoldenJSON.bool(true))
        #expect(GoldenJSON(any: NSNumber(value: true)) == .bool(true))
        #expect(GoldenJSON(any: 3) == .integer(3))
        #expect(GoldenJSON(any: 1.5) == .number(1.5))
    }

    @Test("GoldenJSON のオブジェクトはキーの順を問わない")
    func goldenJSONObjectOrder() throws {
        let a = try JSONDecoder().decode(GoldenJSON.self, from: Data(#"{"b": 1, "a": [true, null]}"#.utf8))
        let b = try JSONDecoder().decode(GoldenJSON.self, from: Data(#"{"a": [true, null], "b": 1}"#.utf8))
        #expect(a == b)
    }

    @Test("GoldenJSON は文字列の先頭の U+FEFF を保つ（JSONSerialization は落とす）")
    func goldenJSONKeepsLeadingBOM() throws {
        // JSON の本文は ["\u{FEFF}x"] を JSON のエスケープ（バックスラッシュ・u・feff）で書いたもの
        let json = "[\"" + "\\" + "ufeffx\"]"
        let value = try JSONDecoder().decode(GoldenJSON.self, from: Data(json.utf8))
        #expect(value.arrayValue?.first?.stringValue?.unicodeScalars.first?.value == 0xFEFF)
        // 入力の読み込みも同じ（pyjson_decode/bom_rejected の text は U+FEFF で始まる）
        let text = try Golden.testCase("pyjson_decode", "bom_rejected").string("text")
        #expect(text.unicodeScalars.first?.value == 0xFEFF)
    }

    @Test("GoldenCase の型付きの取り出しと誤り")
    func goldenCaseAccessors() throws {
        let item = try Golden.testCase("keys", "session_overflow2")
        #expect(try item.string("deviceID") == "DJIMIC3")
        #expect(try item.int("overflow") == 2)
        #expect(throws: GoldenError.missingKey(group: "keys", name: "session_overflow2", key: "nope")) {
            _ = try item.string("nope")
        }
        let mismatch = GoldenError.typeMismatch(
            group: "keys", name: "session_overflow2", key: "overflow", expected: "文字列")
        #expect(throws: mismatch) {
            _ = try item.string("overflow")
        }
        #expect(throws: GoldenError.noSuchCase(group: "keys", name: "nope")) {
            _ = try Golden.testCase("keys", "nope")
        }
    }

    @Test("入力の設定の上書きはすべて許されたキー（generate.py と同じ一覧）")
    func overridesAreAllowed() throws {
        var count = 0
        for group in try Golden.groupNames() {
            for item in try Golden.cases(group) {
                count += try item.overrides().count
            }
        }
        #expect(count > 0)
        #expect(!Golden.isAllowedOverride("llm.analysis.sections.mood.enabled"))
        #expect(!Golden.isAllowedOverride("cleanup.deleteSourceAudio"))
        #expect(Golden.isAllowedOverride("llm.analysis.sections.key_points.maxItems"))
        #expect(Golden.isAllowedOverride("llm.analysis.sections.summary.heading"))
        // F-54: maxItems を持つのは 5 節だけ。
        #expect(!Golden.isAllowedOverride("llm.analysis.sections.summary.maxItems"))
        #expect(!Golden.isAllowedOverride("llm.analysis.sections.timeline.maxItems"))
    }

    @Test("許された上書きの一覧が generate.py の ALLOWED_OVERRIDES・SECTION_OVERRIDE と同じ")
    func overrideListMatchesGenerator() throws {
        let source = try String(contentsOf: PackageRoot.file("tools/golden/generate.py"), encoding: .utf8)
        guard let start = source.range(of: "ALLOWED_OVERRIDES = {"),
            let end = source.range(of: "}", range: start.upperBound..<source.endIndex),
            let open = source.range(of: #"sections\.("#),
            let middle = source.range(of: #")\.("#, range: open.upperBound..<source.endIndex),
            let close = source.range(of: ")$", range: middle.upperBound..<source.endIndex)
        else {
            Issue.record("generate.py に ALLOWED_OVERRIDES か SECTION_OVERRIDE がありません")
            return
        }
        let quoted = source[start.upperBound..<end.lowerBound].split(separator: "\"", omittingEmptySubsequences: false)
        let keys = quoted.enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        #expect(keys.count == Golden.allowedOverrideKeys.count)
        #expect(Set(keys) == Golden.allowedOverrideKeys)
        let sections = source[open.upperBound..<middle.lowerBound].split(separator: "|").map(String.init)
        let fields = source[middle.upperBound..<close.lowerBound].split(separator: "|").map(String.init)
        #expect(Set(sections) == Golden.overridableSections)
        #expect(Set(fields) == Golden.overridableSectionFields)
        // F-54: maxItems を持たない節の一覧も 2 か所で同じ。
        guard let without = source.range(of: "SECTIONS_WITHOUT_MAX_ITEMS = {"),
            let withoutEnd = source.range(of: "}", range: without.upperBound..<source.endIndex)
        else {
            Issue.record("generate.py に SECTIONS_WITHOUT_MAX_ITEMS がありません")
            return
        }
        let excluded = source[without.upperBound..<withoutEnd.lowerBound]
            .split(separator: "\"", omittingEmptySubsequences: false)
            .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        #expect(Set(excluded) == Golden.overridableSections.subtracting(Golden.sectionsWithMaxItems))
    }

    @Test("unified diff: 同じなら空")
    func diffOfSameTextIsEmpty() {
        #expect(UnifiedDiff.render(expected: "a\nb\n", actual: "a\nb\n", expectedLabel: "e", actualLabel: "a").isEmpty)
    }

    @Test("unified diff: 1 行の変更")
    func diffOfOneLine() {
        let text = UnifiedDiff.render(expected: "a\nb\nc\n", actual: "a\nB\nc\n", expectedLabel: "e", actualLabel: "a")
        #expect(text == "--- e\n+++ a\n@@ -1,4 +1,4 @@\n a\n-b\n+B\n c\n \n")
    }

    @Test("unified diff: 末尾の改行の有無と見えない文字")
    func diffShowsTrailingNewlineAndInvisibles() {
        let text = UnifiedDiff.render(
            expected: "x\t\u{3000}\n", actual: "x\t\u{3000}", expectedLabel: "e", actualLabel: "a")
        #expect(text == "--- e\n+++ a\n@@ -1,2 +1,1 @@\n x\\t\\u{3000}\n-\n")
    }

    @Test("unified diff: 離れた変更は別のハンク")
    func diffSeparatesDistantHunks() {
        var lines = (1...20).map(String.init)
        let old = lines.joined(separator: "\n")
        lines[1] = "two"
        lines[18] = "nineteen"
        let text = UnifiedDiff.render(
            expected: old, actual: lines.joined(separator: "\n"), expectedLabel: "e", actualLabel: "a")
        #expect(text.components(separatedBy: "\n@@ ").count == 3)
        #expect(text.hasPrefix("--- e\n+++ a\n@@ -1,5 +1,5 @@\n 1\n-2\n+two\n 3\n 4\n 5\n@@ -16,5 +16,5 @@\n"))
    }
}
