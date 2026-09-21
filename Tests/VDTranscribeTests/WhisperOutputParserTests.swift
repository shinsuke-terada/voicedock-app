// WhisperOutputParser のテスト（T-17 §6.2。PLAN §8.4 手順 7）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDTranscribe

@Suite("WhisperOutputParser")
struct WhisperOutputParserTests {
    static func parse(_ text: String) -> (language: String, text: String, segments: [TranscriptSegment])? {
        WhisperOutputParser.parse(Data(text.utf8), fallbackLanguage: "ja")
    }

    @Test("既定の生 JSON を読む")
    func parsesDefaultDocument() throws {
        let parsed = try #require(Self.parse(FakeWhisper.rawDocument()))
        #expect(parsed.language == "ja")
        #expect(
            parsed.segments == [
                TranscriptSegment(start: 0.0, end: 3.2, text: "おはようございます。"),
                TranscriptSegment(start: 5.5, end: 9.0, text: "今日の予定を確認します。"),
            ])
        #expect(parsed.text == "おはようございます。今日の予定を確認します。")
    }

    @Test("ASR-05 offsets はミリ秒")
    func offsetsAreMilliseconds() throws {
        let parsed = try #require(Self.parse(FakeWhisper.rawDocument([FakeWhisperUtterance(12.5, 20.25, " 正午すぎ")])))
        #expect(parsed.segments == [TranscriptSegment(start: 12.5, end: 20.25, text: "正午すぎ")])
    }

    @Test("小数のミリ秒は Python と同じ丸め")
    func fractionalMillisecondsAreRoundedLikePython() throws {
        let parsed = try #require(Self.parse(#"{"transcription":[{"offsets":{"from":1.5,"to":2},"text":"a"}]}"#))
        #expect(parsed.segments == [TranscriptSegment(start: 0.002, end: 0.002, text: "a")])
    }

    @Test("bool の offsets は飛ばす")
    func boolOffsetsAreSkipped() throws {
        let json = #"""
            {"transcription":[{"offsets":{"from": true, "to": 1},"text":"真"},{"offsets":{"from":0,"to":1000},"text":"よい"}]}
            """#
        let parsed = try #require(Self.parse(json))
        #expect(parsed.segments == [TranscriptSegment(start: 0.0, end: 1.0, text: "よい")])
    }

    @Test("壊れた要素だけ飛ばす")
    func onlyBadEntryIsSkipped() throws {
        let json = #"""
            {"transcription":[{"offsets":{"from":0,"to":1000},"text":"よい"},\#
            {"offsets":{"from":null,"to":null},"text":"壊れている"},\#
            {"offsets":{"from":2000,"to":3000},"text":"もよい"}]}
            """#
        let parsed = try #require(Self.parse(json))
        #expect(
            parsed.segments == [
                TranscriptSegment(start: 0.0, end: 1.0, text: "よい"),
                TranscriptSegment(start: 2.0, end: 3.0, text: "もよい"),
            ])
        #expect(parsed.text == "よいもよい")
    }

    @Test("result.language を使う")
    func usesReportedLanguage() throws {
        let parsed = try #require(Self.parse(FakeWhisper.rawDocument(language: "en")))
        #expect(parsed.language == "en")
    }

    @Test("JSON でなければ nil", arguments: [#"{"transcription": ["#, "null", ""])
    func unparseableIsNil(text: String) {
        #expect(Self.parse(text) == nil)
    }

    @Test(
        "形が崩れても結果を返す",
        arguments: [
            "{}", #"{"transcription":"not a list"}"#, #"{"transcription":[1,2,3]}"#,
            #"{"transcription":[{"offsets":{"from":"x","to":1},"text":"a"}]}"#,
            #"{"transcription":[{"text":"offsets が無い"}]}"#, #""string""#,
        ])
    func neverCrashes(text: String) throws {
        let parsed = try #require(Self.parse(text))
        #expect(parsed.language == "ja")
        #expect(parsed.segments.isEmpty)
        #expect(parsed.text == "")
    }

    @Test("text は strip し、空の区間は捨てる")
    func textIsStrippedAndEmptyDropped() throws {
        let json = #"""
            {"transcription":[{"offsets":{"from":0,"to":1000},"text":"  "},\#
            {"offsets":{"from":1000,"to":2000},"text":"　x　"}]}
            """#
        let parsed = try #require(Self.parse(json))
        #expect(parsed.segments == [TranscriptSegment(start: 1.0, end: 2.0, text: "x")])
    }
}
