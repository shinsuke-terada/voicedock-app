// whisper の生 JSON の秒の読み取り（F-71・#120。PLAN §8.4 手順 7）。読めない秒の区間はその要素だけ飛ばす。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDTranscribe

@Suite("WhisperOutputParser の秒（F-71）")
struct WhisperOutputParserSecondsTests {
    static func parse(_ text: String) -> (language: String, text: String, segments: [TranscriptSegment])? {
        WhisperOutputParser.parse(Data(text.utf8), fallbackLanguage: "ja")
    }

    @Test("F-71 offsets が NaN・Infinity・10 億秒超の区間は飛ばす")
    func unreadableOffsetsAreSkipped() throws {
        let parsed = try #require(
            Self.parse(
                #"""
                {"transcription":[
                  {"offsets":{"from":NaN,"to":1000},"text":"a"},
                  {"offsets":{"from":0,"to":Infinity},"text":"b"},
                  {"offsets":{"from":-Infinity,"to":1000},"text":"c"},
                  {"offsets":{"from":0,"to":1000000000001},"text":"e"},
                  {"offsets":{"from":-1000000000001,"to":0},"text":"f"},
                  {"offsets":{"from":0,"to":1e300},"text":"g"},
                  {"offsets":{"from":2000,"to":3000},"text":"d"}
                ]}
                """#))
        #expect(parsed.segments == [TranscriptSegment(start: 2.0, end: 3.0, text: "d")])
        #expect(parsed.text == "d")
    }

    @Test("F-71 10 億秒ちょうどの区間は読む")
    func boundaryOffsetsAreRead() throws {
        let parsed = try #require(
            Self.parse(#"{"transcription":[{"offsets":{"from":-1000000000000,"to":1000000000000},"text":"a"}]}"#))
        #expect(parsed.segments == [TranscriptSegment(start: -1_000_000_000, end: 1_000_000_000, text: "a")])
    }

    @Test("F-71 transcription が空なら区間も text も空")
    func emptyTranscription() throws {
        let parsed = try #require(Self.parse(#"{"transcription":[]}"#))
        #expect(parsed.segments == [])
        #expect(parsed.text == "")
        #expect(parsed.language == "ja")
    }
}
