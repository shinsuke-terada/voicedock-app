// Part の正規化 transcript の読み書きの検査（PLAN §8.4。T-10）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("TranscriptCodec")
struct TranscriptCodecTests {
    static let partkey = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"

    static let v4Example = PartTranscript(
        partkey: partkey, language: "ja", durationSeconds: 1800.0, startedAt: "2026-08-29T07:12:04+09:00",
        text: "おはようございます。今日は。float",
        segments: [
            TranscriptSegment(start: 0.0, end: 3.2, text: "おはようございます。"),
            TranscriptSegment(start: 9.001, end: 12.345, text: "今日は。"),
        ])

    /// 移植メモ V4 §2.5 の実測（逐語）。
    static let v4ExampleJSON = """
        {
          "partkey": "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
          "language": "ja",
          "duration_seconds": 1800.0,
          "started_at": "2026-08-29T07:12:04+09:00",
          "text": "おはようございます。今日は。float",
          "segments": [
            {
              "start": 0.0,
              "end": 3.2,
              "text": "おはようございます。"
            },
            {
              "start": 9.001,
              "end": 12.345,
              "text": "今日は。"
            }
          ]
        }

        """

    /// 6 つのキーを全部持つ正しい文書の辞書（キーを抜いたり差し替えたりして使う）。
    static func document(_ changes: [String: String] = [:], removing: String? = nil) -> Data {
        var pairs: [(String, String)] = [
            ("partkey", "\"k\""), ("language", "\"ja\""), ("duration_seconds", "1.5"),
            ("started_at", "\"2026-08-29T07:12:04+09:00\""), ("text", "\"t\""),
            ("segments", "[{\"start\": 0.0, \"end\": 1.0, \"text\": \"t\"}]"),
        ]
        pairs = pairs.filter { $0.0 != removing }.map { ($0.0, changes[$0.0] ?? $0.1) }
        return Data(("{" + pairs.map { "\"\($0.0)\": \($0.1)" }.joined(separator: ", ") + "}").utf8)
    }

    @Test("符号化は voicedock の実測と同じバイト列")
    func encodeMatchesVoicedock() {
        #expect(String(decoding: PartTranscriptCodec.encode(Self.v4Example), as: UTF8.self) == Self.v4ExampleJSON)
        // T-25 の golden（transcript_json/v4_example。float の区間を含む 3 segments）とも比べる
        let golden = PartTranscript(
            partkey: Self.partkey, language: "ja", durationSeconds: 1800.0, startedAt: "2026-08-29T07:12:04+09:00",
            text: "おはようございます。今日は。float",
            segments: Self.v4Example.segments + [TranscriptSegment(start: 0.002, end: 0.002, text: "float")])
        GoldenAssert.matches(bytes: PartTranscriptCodec.encode(golden), group: "transcript_json", name: "v4_example")
    }

    @Test("duration が無ければ null、segments が無ければ []")
    func encodeNullDuration() {
        let empty = PartTranscript(
            partkey: "k", language: "ja", durationSeconds: nil, startedAt: "2026-08-29T07:12:04+09:00", text: "",
            segments: [])
        let expected = """
            {
              "partkey": "k",
              "language": "ja",
              "duration_seconds": null,
              "started_at": "2026-08-29T07:12:04+09:00",
              "text": "",
              "segments": []
            }

            """
        #expect(String(decoding: PartTranscriptCodec.encode(empty), as: UTF8.self) == expected)
    }

    @Test("書いて読むと同じ")
    func decodeRoundTrip() {
        #expect(PartTranscriptCodec.decode(PartTranscriptCodec.encode(Self.v4Example)) == Self.v4Example)
        let empty = PartTranscript(
            partkey: "k", language: "en", durationSeconds: nil, startedAt: "2026-08-29T07:12:04+09:00", text: "",
            segments: [])
        #expect(PartTranscriptCodec.decode(PartTranscriptCodec.encode(empty)) == empty)
        #expect(PartTranscriptCodec.decode(Self.document()) != nil)
    }

    @Test("合格条件を 1 つでも満たさなければ nil")
    func decodeRejects() {
        for key in PartTranscriptCodec.requiredKeys {
            #expect(PartTranscriptCodec.decode(Self.document(removing: key)) == nil, "キー欠落 \(key)")
        }
        #expect(PartTranscriptCodec.decode(Self.document(["segments": "{}"])) == nil)
        #expect(PartTranscriptCodec.decode(Self.document(["segments": "[1]"])) == nil)
        #expect(
            PartTranscriptCodec.decode(Self.document(["segments": "[{\"start\": \"0\", \"end\": 1, \"text\": \"t\"}]"]))
                == nil)
        #expect(
            PartTranscriptCodec.decode(Self.document(["segments": "[{\"start\": true, \"end\": 1, \"text\": \"t\"}]"]))
                == nil)
        #expect(
            PartTranscriptCodec.decode(Self.document(["segments": "[{\"start\": 0, \"end\": 1, \"text\": 5}]"])) == nil)
        #expect(PartTranscriptCodec.decode(Self.document(["text": "5"])) == nil)
        #expect(PartTranscriptCodec.decode(Self.document(["duration_seconds": "true"])) == nil)
        #expect(PartTranscriptCodec.decode(Self.document(["partkey": "5"])) == nil)
        #expect(PartTranscriptCodec.decode(Data("not json".utf8)) == nil)
        #expect(PartTranscriptCodec.decode(Data()) == nil)
        #expect(PartTranscriptCodec.decode(Data("[]".utf8)) == nil)
    }

    @Test("ほかのキーがあってもよい")
    func decodeAllowsExtraKeys() {
        var text = String(decoding: Self.document(), as: UTF8.self)
        text.removeLast()
        text += ", \"x\": 1}"
        let decoded = PartTranscriptCodec.decode(Data(text.utf8))
        #expect(
            decoded
                == PartTranscript(
                    partkey: "k", language: "ja", durationSeconds: 1.5, startedAt: "2026-08-29T07:12:04+09:00",
                    text: "t", segments: [TranscriptSegment(start: 0.0, end: 1.0, text: "t")]))
    }
}
