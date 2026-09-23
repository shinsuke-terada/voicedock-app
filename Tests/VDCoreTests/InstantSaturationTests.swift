// Instant の算術の桁あふれと、transcript の秒の読み取り（F-71・#120。PLAN §5.7・§8.4）。落ちないことと、端に寄せた値を固定値で見る。
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("Instant の桁あふれと秒の読み取り（F-71）")
struct InstantSaturationTests {
    // MARK: - Instant

    @Test("F-71 adding(milliseconds:) の桁あふれは Int64 の端に寄せる")
    func addingMillisecondsSaturates() {
        #expect(Instant(epochMillis: 9_223_372_036_854_775_800).adding(milliseconds: 100).epochMillis == Int64.max)
        #expect(Instant(epochMillis: -9_223_372_036_854_775_800).adding(milliseconds: -100).epochMillis == Int64.min)
        #expect(Instant(epochMillis: 1000).adding(milliseconds: -1500).epochMillis == -500)
    }

    @Test("F-71 adding(seconds:) の × 1000 の桁あふれは Int64 の端に寄せる")
    func addingSecondsSaturates() {
        #expect(Instant(epochMillis: 0).adding(seconds: Int.max).epochMillis == Int64.max)
        #expect(Instant(epochMillis: 0).adding(seconds: Int.min).epochMillis == Int64.min)
        // × 1000 はあふれず、足し算であふれる
        #expect(Instant(epochMillis: 9_223_372_036_854_000_000).adding(seconds: 1_000_000).epochMillis == Int64.max)
        #expect(Instant(epochMillis: 1_790_000_000_000).adding(seconds: -1800).epochMillis == 1_789_998_200_000)
    }

    @Test("F-71 引き算の桁あふれは Int64 の端に寄せる")
    func differenceSaturates() {
        #expect(Instant(epochMillis: Int64.max) - Instant(epochMillis: -1) == Int64.max)
        #expect(Instant(epochMillis: Int64.min) - Instant(epochMillis: 1) == Int64.min)
        #expect(Instant(epochMillis: 5) - Instant(epochMillis: 8) == -3)
    }

    @Test("F-71 Date からの変換は NaN を 0、範囲外を端に寄せる")
    func dateConversionSaturates() {
        #expect(Instant(date: Date(timeIntervalSince1970: .nan)).epochMillis == 0)
        #expect(Instant(date: Date(timeIntervalSince1970: 1e300)).epochMillis == Int64.max)
        #expect(Instant(date: Date(timeIntervalSince1970: -1e300)).epochMillis == Int64.min)
        #expect(Instant(date: Date(timeIntervalSince1970: .infinity)).epochMillis == Int64.max)
        #expect(Instant(date: Date(timeIntervalSince1970: 1.5)).epochMillis == 1500)
    }

    // MARK: - SecondsToMillis

    @Test("F-71 fromWhisperSeconds は読めない秒でも落ちない（NaN は 0、範囲外は ±10 億秒）")
    func fromWhisperSecondsNeverTraps() {
        #expect(SecondsToMillis.fromWhisperSeconds(.nan) == 0)
        #expect(SecondsToMillis.fromWhisperSeconds(.infinity) == 1_000_000_000_000)
        #expect(SecondsToMillis.fromWhisperSeconds(-.infinity) == -1_000_000_000_000)
        #expect(SecondsToMillis.fromWhisperSeconds(1e300) == 1_000_000_000_000)
        #expect(SecondsToMillis.fromWhisperSeconds(-1e19) == -1_000_000_000_000)
        #expect(SecondsToMillis.fromWhisperSeconds(1.5) == 1500)
        #expect(SecondsToMillis.fromWhisperSeconds(0) == 0)
    }

    @Test(
        "F-71 isReadable は有限で絶対値が 10 億秒以下だけ",
        arguments: [
            (0.0, true), (1_000_000_000.0, true), (-1_000_000_000.0, true), (12.345, true),
            (1_000_000_000.001, false), (-1_000_000_001.0, false), (Double.nan, false), (Double.infinity, false),
            (-Double.infinity, false),
        ])
    func isReadable(seconds: Double, readable: Bool) {
        #expect(SecondsToMillis.isReadable(seconds) == readable)
    }

    // MARK: - PartTranscriptCodec.decode

    static func transcript(start: String = "0.0", end: String = "1.0", duration: String = "1.0") -> Data {
        Data(
            """
            {"partkey": "DJIMIC3/A/B.wav", "language": "ja", "duration_seconds": \(duration),
             "started_at": "2026-08-29T07:12:04+09:00", "text": "a",
             "segments": [{"start": \(start), "end": \(end), "text": "a"}]}
            """.utf8)
    }

    @Test(
        "F-71 start・end・duration_seconds が NaN・Infinity・10 億秒超なら transcript は読めない",
        arguments: ["NaN", "Infinity", "-Infinity", "1000000000.5", "-1000000001", "1e300"])
    func unreadableNumbersMakeTranscriptUnreadable(value: String) {
        #expect(PartTranscriptCodec.decode(Self.transcript(start: value)) == nil)
        #expect(PartTranscriptCodec.decode(Self.transcript(end: value)) == nil)
        #expect(PartTranscriptCodec.decode(Self.transcript(duration: value)) == nil)
    }

    @Test("F-71 10 億秒ちょうどの transcript は読める")
    func boundarySecondsAreReadable() throws {
        let t = try #require(
            PartTranscriptCodec.decode(
                Self.transcript(start: "-1000000000", end: "1000000000", duration: "1000000000")))
        #expect(t.segments == [TranscriptSegment(start: -1_000_000_000, end: 1_000_000_000, text: "a")])
        #expect(t.durationSeconds == 1_000_000_000)
    }

    @Test("F-71 segments が空の transcript は読める")
    func emptySegmentsAreReadable() throws {
        let data = Data(
            """
            {"partkey": "DJIMIC3/A/B.wav", "language": "ja", "duration_seconds": null,
             "started_at": "2026-08-29T07:12:04+09:00", "text": "", "segments": []}
            """.utf8)
        let t = try #require(PartTranscriptCodec.decode(data))
        #expect(t.segments == [])
        #expect(t.durationSeconds == nil)
    }
}
