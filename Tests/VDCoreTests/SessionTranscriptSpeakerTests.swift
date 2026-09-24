// Session の指紋と区間の speaker の検査（PLAN §8.4.1・§8.5。F-89。T-47）。
import Foundation
import Testing
import VDContract

@testable import VDCore

@Suite("SessionTranscriptSpeaker")
struct SessionTranscriptSpeakerTests {
    static func zone() throws -> ZonedTime {
        ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
    }

    static func session(_ segments: [AbsoluteSegment], blocks: [TimeBlock] = []) throws -> SessionTranscript {
        SessionTranscript(
            dayDate: try #require(LocalDate(dashed: "2026-08-29")), segments: segments, blocks: blocks,
            excludedPartkeys: [])
    }

    @Test("話者なしの指紋は F-89 の前と同じ")
    func fingerprintWithoutSpeakerUnchanged() throws {
        // GoldenCoreTests の fingerprint/v4_example と同じ入力
        let zone = try Self.zone()
        let base = try #require(zone.parseISO("2026-08-29T07:12:04+09:00"))
        let transcript = try Self.session(
            [
                AbsoluteSegment(at: base, endAt: base.adding(milliseconds: 3200), text: "おはようございます。"),
                AbsoluteSegment(
                    at: base.adding(milliseconds: 9001), endAt: base.adding(milliseconds: 12_999), text: "今日は/\"x\""),
            ],
            blocks: [TimeBlock(start: base, end: base.adding(milliseconds: 1_800_000))])
        // Tests/Golden/expected/fingerprint/v4_example.out の 1 行目と 2 行目（逐語）
        let expectedPayload =
            #"{"blocks":[["2026-08-29T07:12:04+09:00","2026-08-29T07:42:04+09:00"]],"segments":[{"at":"2026-08-29T07:12:04+09:00","end_at":"2026-08-29T07:12:07+09:00","text":"おはようございます。"},{"at":"2026-08-29T07:12:13+09:00","end_at":"2026-08-29T07:12:16+09:00","text":"今日は/\"x\""}]}"#
        #expect(TranscriptFingerprint.payload(transcript, zone: zone) == expectedPayload)
        #expect(
            TranscriptFingerprint.of(transcript, zone: zone)
                == "894a61422b5c95830fe8b36c33ae2c3af728851d00a5e02e9f691d61ad5fb86f")
    }

    @Test("話者があると payload に speaker が入る")
    func fingerprintIncludesSpeaker() throws {
        let zone = try Self.zone()
        let base = try #require(zone.parseISO("2026-08-29T07:12:04+09:00"))
        let withSpeaker = try Self.session([
            AbsoluteSegment(at: base, endAt: base.adding(milliseconds: 3200), text: "はい。", speaker: "B")
        ])
        let withoutSpeaker = try Self.session([
            AbsoluteSegment(at: base, endAt: base.adding(milliseconds: 3200), text: "はい。")
        ])
        let payload = TranscriptFingerprint.payload(withSpeaker, zone: zone)
        #expect(payload.contains(#""speaker":"B""#))
        #expect(
            payload
                == #"{"blocks":[],"segments":[{"at":"2026-08-29T07:12:04+09:00","end_at":"2026-08-29T07:12:07+09:00","speaker":"B","text":"はい。"}]}"#
        )
        #expect(
            TranscriptFingerprint.of(withSpeaker, zone: zone) != TranscriptFingerprint.of(withoutSpeaker, zone: zone))
    }

    @Test("区間 0 の指紋（TEST-28）")
    func fingerprintEmpty() throws {
        let zone = try Self.zone()
        let transcript = try Self.session([])
        // Tests/Golden/expected/fingerprint/empty.out の 1 行目と 2 行目（逐語）
        #expect(TranscriptFingerprint.payload(transcript, zone: zone) == #"{"blocks":[],"segments":[]}"#)
        #expect(
            TranscriptFingerprint.of(transcript, zone: zone)
                == "a587326b615b44a1a7f8d7bacb8e1c583ad208ac263c76f384d9044cf2ed7bf8")
    }
}
