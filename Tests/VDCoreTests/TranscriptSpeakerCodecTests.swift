// 正規化 transcript の区間の speaker の読み書きの検査（PLAN §8.4.1。F-89。T-47）。
import Foundation
import Testing

@testable import VDCore

@Suite("TranscriptSpeakerCodec")
struct TranscriptSpeakerCodecTests {
    static func transcript(_ segments: [TranscriptSegment]) -> PartTranscript {
        PartTranscript(
            partkey: "k", language: "ja", durationSeconds: 12.5, startedAt: "2026-08-29T07:12:04+09:00",
            text: "おはよう。はい。", segments: segments)
    }

    /// 区間の中が `"speaker": <値>` の文書（speaker 以外は正しい）。
    static func document(speakerJSON: String) -> Data {
        Data(
            ("{\"partkey\": \"k\", \"language\": \"ja\", \"duration_seconds\": 1.5, "
                + "\"started_at\": \"2026-08-29T07:12:04+09:00\", \"text\": \"t\", "
                + "\"segments\": [{\"start\": 0.0, \"end\": 1.0, \"text\": \"t\", \"speaker\": \(speakerJSON)}]}")
                .utf8)
    }

    @Test("話者なしの transcript は F-89 の前とバイト単位で同じ")
    func withoutSpeakerIsByteIdentical() {
        let t = Self.transcript([
            TranscriptSegment(start: 0.0, end: 3.2, text: "おはよう。"),
            TranscriptSegment(start: 9.001, end: 12.5, text: "はい。"),
        ])
        let expected = """
            {
              "partkey": "k",
              "language": "ja",
              "duration_seconds": 12.5,
              "started_at": "2026-08-29T07:12:04+09:00",
              "text": "おはよう。はい。",
              "segments": [
                {
                  "start": 0.0,
                  "end": 3.2,
                  "text": "おはよう。"
                },
                {
                  "start": 9.001,
                  "end": 12.5,
                  "text": "はい。"
                }
              ]
            }

            """
        #expect(PartTranscriptCodec.encode(t) == Data(expected.utf8))
    }

    @Test("speaker は text の後に書く")
    func speakerIsWrittenAfterText() {
        let t = Self.transcript([TranscriptSegment(start: 0.0, end: 3.2, text: "おはよう。", speaker: "A")])
        let expectedSegment = """
                {
                  "start": 0.0,
                  "end": 3.2,
                  "text": "おはよう。",
                  "speaker": "A"
                }
            """
        #expect(String(decoding: PartTranscriptCodec.encode(t), as: UTF8.self).contains(expectedSegment))
    }

    @Test("話者のある区間とない区間が混ざる")
    func mixedSpeakers() {
        let t = Self.transcript([
            TranscriptSegment(start: 0.0, end: 3.2, text: "おはよう。", speaker: "A"),
            TranscriptSegment(start: 9.001, end: 12.5, text: "はい。"),
        ])
        let expected = """
            {
              "partkey": "k",
              "language": "ja",
              "duration_seconds": 12.5,
              "started_at": "2026-08-29T07:12:04+09:00",
              "text": "おはよう。はい。",
              "segments": [
                {
                  "start": 0.0,
                  "end": 3.2,
                  "text": "おはよう。",
                  "speaker": "A"
                },
                {
                  "start": 9.001,
                  "end": 12.5,
                  "text": "はい。"
                }
              ]
            }

            """
        #expect(PartTranscriptCodec.encode(t) == Data(expected.utf8))
    }

    @Test("書いて読むと同じ")
    func roundTrip() {
        let t = Self.transcript([
            TranscriptSegment(start: 0.0, end: 3.2, text: "おはよう。", speaker: "A"),
            TranscriptSegment(start: 9.001, end: 12.5, text: "はい。", speaker: "S27"),
            TranscriptSegment(start: 12.5, end: 13.0, text: "…"),
        ])
        #expect(PartTranscriptCodec.decode(PartTranscriptCodec.encode(t)) == t)
    }

    @Test("speaker が文字列でなければ読めない", arguments: ["1", "null"])
    func nonStringSpeakerIsUnreadable(speakerJSON: String) {
        #expect(PartTranscriptCodec.decode(Self.document(speakerJSON: speakerJSON)) == nil)
    }

    @Test("区間 0 の transcript（TEST-28）")
    func emptySegments() {
        let t = Self.transcript([])
        let expected = """
            {
              "partkey": "k",
              "language": "ja",
              "duration_seconds": 12.5,
              "started_at": "2026-08-29T07:12:04+09:00",
              "text": "おはよう。はい。",
              "segments": []
            }

            """
        #expect(PartTranscriptCodec.encode(t) == Data(expected.utf8))
        #expect(PartTranscriptCodec.decode(PartTranscriptCodec.encode(t)) == t)
    }
}
