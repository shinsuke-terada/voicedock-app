// whisper の生 JSON の寛容な読み方（PLAN §8.4 手順 7・付録 D の X-39。F-82・issue #119 の E9。利用者の決定 2026-09-23）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDTranscribe

@Suite("WhisperOutputParser（F-82 寛容に読む）")
struct WhisperOutputParserLenientTests {
    /// 1 区間の生 JSON（text の中身は UTF-8 のバイト列で渡す）
    static func document(textBytes: [UInt8]) -> Data {
        var data = Data(
            #"{"result": {"language": "ja"}, "transcription": [{"offsets": {"from": 0, "to": 1500}, "text": ""#.utf8)
        data.append(contentsOf: textBytes)
        data.append(contentsOf: Array(#""}]}"#.utf8))
        return data
    }

    static func parse(_ data: Data) -> (language: String, text: String, segments: [TranscriptSegment])? {
        WhisperOutputParser.parse(data, fallbackLanguage: "en")
    }

    @Test(
        "F-82 正常な生 JSON は手前処理で 1 バイトも変わらない",
        arguments: [
            FakeWhisper.rawDocument(),
            FakeWhisper.rawDocument([FakeWhisperUtterance(0, 1, "改行は\\nで、引用は\\\"と逆斜線\\\\、é は \\u00e9")]),
            #"{"transcription": [{"offsets": {"from": 0, "to": 1}, "text": "\t タブ\r\n"}]}"#,
            " \n{\"a\": [1, 2.5, true, null, \"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u0001\"]}\n",
        ])
    func validDocumentIsUnchanged(_ text: String) {
        let data = Data(text.utf8)
        #expect(Array(WhisperOutputParser.lenientText(data).utf8) == Array(data))
    }

    @Test("F-82 文字列の中の生の制御文字（U+0000〜U+001F）を \\u00XX にして読む（Part 全体を失敗にしない）")
    func rawControlCharactersInStringsAreEscaped() throws {
        // 「あ」<U+0001>「い」<TAB>「う」<LF>「え」<U+001F>
        let bytes: [UInt8] = [
            0xE3, 0x81, 0x82, 0x01, 0xE3, 0x81, 0x84, 0x09, 0xE3, 0x81, 0x86, 0x0A, 0xE3, 0x81, 0x88, 0x1F,
        ]
        let data = Self.document(textBytes: bytes)
        #expect(PyJSON.decode(data) == nil)

        let lenient = WhisperOutputParser.lenientText(data)
        #expect(lenient.contains(#""text": "あ\u0001い\u0009う\u000aえ\u001f""#))
        let parsed = try #require(Self.parse(data))
        #expect(parsed.language == "ja")
        #expect(parsed.segments == [TranscriptSegment(start: 0.0, end: 1.5, text: "あ\u{01}い\tう\nえ")])
    }

    @Test("F-82 区間の境目で割れた多バイト文字（不正な UTF-8）は U+FFFD にして読む")
    func brokenUTF8IsReplaced() throws {
        // 「あ」の先頭 2 バイトだけ（割れた多バイト文字）の後に「い」
        let data = Self.document(textBytes: [0xE3, 0x81, 0xE3, 0x81, 0x84])
        #expect(PyJSON.decode(data) == nil)

        let parsed = try #require(Self.parse(data))
        #expect(parsed.segments == [TranscriptSegment(start: 0.0, end: 1.5, text: "\u{FFFD}い")])
        #expect(parsed.text == "\u{FFFD}い")
    }

    @Test("F-82 文字列の外と、逆斜線の直後の 1 文字（エスケープの続き）は触らない（壊れた JSON は従来どおり読めない）")
    func outsideStringsAndEscapesAreUntouched() {
        // 文字列の外の U+0001 は JSON の誤り。手前処理は触らないので読めない
        let outside = Data([0x7B, 0x01, 0x7D])
        #expect(Array(WhisperOutputParser.lenientText(outside).utf8) == [0x7B, 0x01, 0x7D])
        #expect(Self.parse(outside) == nil)
        // 逆斜線の直後の生の制御文字はエスケープの続きとして残す（whisper は逆斜線を \\ にするので出ない）
        let afterBackslash = Data([0x22, 0x5C, 0x01, 0x22])
        #expect(Array(WhisperOutputParser.lenientText(afterBackslash).utf8) == [0x22, 0x5C, 0x01, 0x22])
        // \\ の後は文字列の続き（2 つ目の逆斜線はエスケープを閉じる）
        let escapedBackslash = Data([0x22, 0x5C, 0x5C, 0x01, 0x22])
        #expect(Array(WhisperOutputParser.lenientText(escapedBackslash).utf8) == Array(#""\\\u0001""#.utf8))
        // \" は文字列を閉じない
        let escapedQuote = Data([0x22, 0x5C, 0x22, 0x01, 0x22])
        #expect(Array(WhisperOutputParser.lenientText(escapedQuote).utf8) == Array(#""\"\u0001""#.utf8))
    }

    @Test("F-82 TEST-28 空の生 JSON は空のまま、読めない（nil）")
    func emptyDataIsUnreadable() {
        #expect(WhisperOutputParser.lenientText(Data()).isEmpty)
        #expect(Self.parse(Data()) == nil)
    }
}
