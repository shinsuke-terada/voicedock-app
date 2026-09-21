// GoldenCase.orderedObject がキーの順を保つことを golden の入力で確かめる（T-45 4.11）。
import Foundation
import TestSupport
import Testing
import VDCore

@Suite("GoldenCase.orderedObject") struct GoldenCasePyJSONTests {
    @Test("入力の payload をキーの順のまま読む")
    func keepsKeyOrder() throws {
        let item = try Golden.testCase("llm_validate", "multi_order")
        let pairs = try item.orderedObject("payload")
        #expect(pairs.map(\.0) == ["mood", "summary", "tags", "zzz"])
    }

    @Test("辞書の GoldenJSON と同じ中身（順だけが違う）")
    func sameContentAsFields() throws {
        let item = try Golden.testCase("llm_validate", "ok_full")
        let pairs = try item.orderedObject("payload")
        let fields = try item.object("payload")
        #expect(Set(pairs.map(\.0)) == Set(fields.keys))
        #expect(pairs.count == fields.count)
    }

    @Test("全 23 ケースで投げない")
    func allValidateCasesDecode() throws {
        for item in try Golden.cases("llm_validate") {
            #expect(throws: Never.self) { try item.orderedObject("payload") }
        }
    }

    @Test("無いキーは missingKey、オブジェクトでなければ typeMismatch")
    func reportsErrors() throws {
        let item = try Golden.testCase("llm_validate", "ok_minimal")
        #expect(throws: GoldenError.missingKey(group: "llm_validate", name: "ok_minimal", key: "nope")) {
            try item.orderedObject("nope")
        }
        #expect(
            throws: GoldenError.typeMismatch(group: "llm_validate", name: "ok_minimal", key: "name", expected: "オブジェクト")
        ) {
            try item.orderedObject("name")
        }
    }
}
