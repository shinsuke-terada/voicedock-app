// Session の指紋と Block の検査（PLAN §5.6・§8.5。T-10）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("SessionTranscript")
struct SessionTranscriptTests {
    /// 2026-08-29 00:00 JST を基準にした時刻（時・分）。
    static func at(_ hour: Int, _ minute: Int) -> Instant {
        Instant(epochMillis: 1_787_929_200_000).adding(seconds: hour * 3600 + minute * 60)
    }

    static func block(_ start: Instant, _ end: Instant) -> TimeBlock { TimeBlock(start: start, end: end) }

    func v4Transcript(excluded: [String]) throws -> (SessionTranscript, ZonedTime) {
        let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        let base = try #require(zone.parseISO("2026-08-29T07:12:04+09:00"))
        let transcript = SessionTranscript(
            dayDate: try #require(LocalDate(dashed: "2026-08-29")),
            segments: [
                AbsoluteSegment(at: base, endAt: base.adding(milliseconds: 3200), text: "おはようございます。"),
                AbsoluteSegment(
                    at: base.adding(milliseconds: 9001), endAt: base.adding(milliseconds: 12999), text: "今日は/\"x\""),
            ],
            blocks: [TimeBlock(start: base, end: base.adding(seconds: 1800))],
            excludedPartkeys: excluded)
        return (transcript, zone)
    }

    @Test("指紋は voicedock の実測と同じ（PLAN §8.5）")
    func fingerprintMatchesVoicedock() throws {
        let (transcript, zone) = try v4Transcript(excluded: [])
        #expect(
            TranscriptFingerprint.of(transcript, zone: zone)
                == "894a61422b5c95830fe8b36c33ae2c3af728851d00a5e02e9f691d61ad5fb86f")
    }

    @Test("除外 Part は指紋に入らない")
    func fingerprintIgnoresExcluded() throws {
        let (plain, zone) = try v4Transcript(excluded: [])
        let (excluded, _) = try v4Transcript(excluded: ["DJIMIC3/a.wav", "DJIMIC3/b.wav"])
        #expect(
            TranscriptFingerprint.of(excluded, zone: zone)
                == "894a61422b5c95830fe8b36c33ae2c3af728851d00a5e02e9f691d61ad5fb86f")
        #expect(TranscriptFingerprint.of(plain, zone: zone) == TranscriptFingerprint.of(excluded, zone: zone))
    }

    @Test("Part が無ければ Block も無い")
    func blocksEmpty() {
        #expect(BlockComputer.blocks([], gapSeconds: 3600) == [])
    }

    @Test("続けて録った Part は 1 つ")
    func blocksBackToBack() {
        let parts: [(startedAt: Instant, endedAt: Instant?)] = [
            (Self.at(9, 0), Self.at(9, 30)), (Self.at(9, 30), Self.at(10, 30)),
        ]
        #expect(BlockComputer.blocks(parts, gapSeconds: 3600) == [Self.block(Self.at(9, 0), Self.at(10, 30))])
    }

    @Test("ちょうど閾値の間隔は区切らない")
    func blocksExactThresholdDoesNotSplit() {
        let parts: [(startedAt: Instant, endedAt: Instant?)] = [
            (Self.at(9, 0), Self.at(9, 30)), (Self.at(10, 30), Self.at(11, 0)),
        ]
        #expect(BlockComputer.blocks(parts, gapSeconds: 3600) == [Self.block(Self.at(9, 0), Self.at(11, 0))])
    }

    @Test("1 秒超えると区切る")
    func blocksOneSecondOverSplits() {
        let second = Self.at(10, 30).adding(seconds: 1)
        let parts: [(startedAt: Instant, endedAt: Instant?)] = [
            (Self.at(9, 0), Self.at(9, 30)), (second, Self.at(11, 0)),
        ]
        #expect(
            BlockComputer.blocks(parts, gapSeconds: 3600) == [
                Self.block(Self.at(9, 0), Self.at(9, 30)), Self.block(second, Self.at(11, 0)),
            ])
    }

    @Test("入力の順は問わない")
    func blocksOrderDoesNotMatter() {
        let parts: [(startedAt: Instant, endedAt: Instant?)] = [
            (Self.at(9, 0), Self.at(9, 30)), (Self.at(9, 30), Self.at(10, 0)), (Self.at(13, 0), Self.at(13, 10)),
        ]
        let expected = [Self.block(Self.at(9, 0), Self.at(10, 0)), Self.block(Self.at(13, 0), Self.at(13, 10))]
        #expect(BlockComputer.blocks(parts, gapSeconds: 3600) == expected)
        #expect(BlockComputer.blocks(parts.reversed(), gapSeconds: 3600) == expected)
    }

    @Test("終了不明の Part の後は必ず区切り、その開始を塊の終わりにする")
    func blocksUnknownEndAlwaysSplits() {
        let parts: [(startedAt: Instant, endedAt: Instant?)] = [(Self.at(9, 0), nil), (Self.at(9, 1), Self.at(9, 30))]
        #expect(
            BlockComputer.blocks(parts, gapSeconds: 3600) == [
                Self.block(Self.at(9, 0), Self.at(9, 0)), Self.block(Self.at(9, 1), Self.at(9, 30)),
            ])
    }

    @Test("重なりは 1 つ、内包で短くしない")
    func blocksOverlapAndContain() {
        let overlap: [(startedAt: Instant, endedAt: Instant?)] = [
            (Self.at(9, 0), Self.at(9, 30)), (Self.at(9, 10), Self.at(9, 40)),
        ]
        #expect(BlockComputer.blocks(overlap, gapSeconds: 3600) == [Self.block(Self.at(9, 0), Self.at(9, 40))])
        let contain: [(startedAt: Instant, endedAt: Instant?)] = [
            (Self.at(9, 0), Self.at(10, 0)), (Self.at(9, 10), Self.at(9, 20)),
        ]
        #expect(BlockComputer.blocks(contain, gapSeconds: 3600) == [Self.block(Self.at(9, 0), Self.at(10, 0))])
    }

    @Test("閾値 0 でも続けて録った Part は 1 つ")
    func blocksZeroGap() {
        let parts: [(startedAt: Instant, endedAt: Instant?)] = [
            (Self.at(9, 0), Self.at(9, 30)), (Self.at(9, 30), Self.at(10, 0)),
            (Self.at(10, 0).adding(seconds: 1), Self.at(10, 5)),
        ]
        #expect(
            BlockComputer.blocks(parts, gapSeconds: 0) == [
                Self.block(Self.at(9, 0), Self.at(10, 0)),
                Self.block(Self.at(10, 0).adding(seconds: 1), Self.at(10, 5)),
            ])
    }
}
