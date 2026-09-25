// RTTMParser のテスト（T-48 §5。PLAN §8.4.1。docs/POC.md 16 章）。
import Foundation
import Testing

@testable import VDTranscribe

@Suite("RTTMParser")
struct RTTMParserTests {
    /// P0-13 の実測（docs/POC.md 16.3）。
    static let p013 = """
        SPEAKER conv16k 1 0.000 2.224 <NA> <NA> A <NA> <NA>
        SPEAKER conv16k 1 2.326 11.205 <NA> <NA> A <NA> <NA>
        """

    static let line = "SPEAKER conv16k 1 0.000 2.224 <NA> <NA> A <NA> <NA>"

    @Test("RTTM の行を読む")
    func readsLines() {
        #expect(
            RTTMParser.parse(Self.p013) == [
                SpeakerTurn(start: 0.0, end: 2.224, speaker: "A"),
                SpeakerTurn(start: 2.326, end: 13.531, speaker: "A"),
            ])
    }

    @Test("空の RTTM は 0 件（TEST-28）", arguments: ["", "\n\n"])
    func emptyTextIsNoTurns(text: String) {
        #expect(RTTMParser.parse(text) == [])
    }

    @Test("CRLF と空行を許す")
    func crlfAndBlankLines() {
        #expect(
            RTTMParser.parse(Self.line + "\r\n\r\n") == [SpeakerTurn(start: 0.0, end: 2.224, speaker: "A")])
    }

    @Test("1 列目が SPEAKER でなければ全体が読めない")
    func wrongTypeIsUnreadable() {
        let text = Self.line + "\nLEXEME conv16k 1 2.326 11.205 <NA> <NA> A <NA> <NA>\n"
        #expect(RTTMParser.parse(text) == nil)
    }

    @Test("8 列未満は読めない")
    func tooFewColumns() {
        #expect(RTTMParser.parse("SPEAKER conv16k 1 0.000 2.224 <NA> <NA>") == nil)
    }

    @Test(
        "負・nan・inf は読めない",
        arguments: [
            "SPEAKER conv16k 1 -1 2.224 <NA> <NA> A <NA> <NA>",
            "SPEAKER conv16k 1 0.000 nan <NA> <NA> A <NA> <NA>",
            "SPEAKER conv16k 1 0.000 inf <NA> <NA> A <NA> <NA>",
        ])
    func negativeOrNonFinite(line: String) {
        #expect(RTTMParser.parse(line) == nil)
    }

    @Test("16 進の数は読めない（10 進だけ）")
    func hexIsUnreadable() {
        #expect(RTTMParser.parse("SPEAKER conv16k 1 0x1p3 2.224 <NA> <NA> A <NA> <NA>") == nil)
    }

    @Test("タブ区切りも読める")
    func tabsSeparate() {
        let text = ["SPEAKER", "conv16k", "1", "1.500", "0.500", "<NA>", "<NA>", "B", "<NA>", "<NA>"]
            .joined(separator: "\t")
        #expect(RTTMParser.parse(text) == [SpeakerTurn(start: 1.5, end: 2.0, speaker: "B")])
    }
}
