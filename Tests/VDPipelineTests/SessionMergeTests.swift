// 統合のテスト（T-22 §6.4。PLAN §5.6「Block・統合」。voicedock session.py:329-423 / pipeline.py:1103-1138）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("SessionMerge")
struct SessionMergeTests {
    static let key = PipelineFixtures.sessionKey
    /// 2026-09-12T09:00:00+09:00
    static let nine: Int64 = 1_789_171_200_000

    static func seg(_ start: Double, _ end: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    static func build(_ w: PipelineWorld) async throws -> SessionTranscript {
        try #require(try SessionSteps(ctx: try await w.context()).buildSessionTranscript(Self.key))
    }

    /// 9 時の READY の Session と、09:00〜09:01 の Part（「朝」）と、time に始まる 60 秒の Part の blocks。
    static func blocks(
        second time: String, stamp: String, _ configure: @escaping (inout AppConfig) -> Void = { _ in }
    ) async throws -> [TimeBlock] {
        let w = try await PipelineWorld.make(configure: configure)
        try w.addSession(status: .ready)
        try w.addTimedPart(time: "09:00:00", stamp: "090000", segments: [Self.seg(0, 1, "朝")])
        try w.addTimedPart(time: time, stamp: stamp, segments: [Self.seg(0, 1, "昼")])
        return try await Self.build(w).blocks
    }

    @Test("FAILED / SKIPPED を除外する")
    func excludesFailedAndSkipped() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        try w.addSessionPart(hour: 9, status: .rawSaved, text: "朝")
        let failed = try w.addSessionPart(hour: 10, status: .failed, text: "昼")
        let skipped = try w.addSessionPart(hour: 11, status: .skipped, text: "夜")
        let t = try await Self.build(w)
        #expect(t.segments.map(\.text) == ["朝"])
        #expect(t.excludedPartkeys == [failed, skipped])
    }

    @Test("TIME-01 絶対時刻 = started_at + offset")
    func absoluteTimes() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        // 前の segment に足し込む壊れ方でも値が変わるよう、先に別の segment を置く
        try w.addTimedPart(
            time: "09:00:00", stamp: "090000", segments: [Self.seg(1.0, 1.2, "前"), Self.seg(1.5, 3.2, "後")])
        let t = try await Self.build(w)
        let s = try #require(t.segments.first { $0.text == "後" })
        // 2026-09-12T09:00:01+09:00 の Instant + 500 ms
        #expect(s.at.epochMillis == 1_789_171_201_000 + 500)
        #expect(s.endAt.epochMillis == Self.nine + 3200)
    }

    @Test("text を Python 互換 strip し空を捨てる")
    func textIsStrippedAndEmptyDropped() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        try w.addTimedPart(
            time: "09:00:00", stamp: "090000",
            segments: [Self.seg(0, 1, " a "), Self.seg(1, 2, "\u{3000}"), Self.seg(2, 3, "\u{1c}b\u{1f}")])
        #expect(try await Self.build(w).segments.map(\.text) == ["a", "b"])
    }

    @Test("(at, end_at) で安定ソート")
    func sortedByAtThenEndAt() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        try w.addTimedPart(time: "09:00:00", stamp: "090000", segments: [Self.seg(10, 20, "x")])
        try w.addTimedPart(time: "09:00:05", stamp: "090005", segments: [Self.seg(0, 30, "y"), Self.seg(5, 8, "z")])
        #expect(try await Self.build(w).segments.map(\.text) == ["y", "z", "x"])
    }

    @Test("読めない transcript は飛ばすが Block には数える")
    func unreadableTranscriptIsSkipped() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        try w.addTimedPart(time: "09:00:00", stamp: "090000", segments: [Self.seg(0, 1, "朝")])
        try w.addTimedPart(time: "09:30:00", stamp: "093000", segments: nil)
        let t = try await Self.build(w)
        #expect(t.segments.count == 1)
        #expect(t.blocks.count == 1)
        // 09:31:00
        #expect(t.blocks.first?.end.epochMillis == Self.nine + 31 * 60_000)
    }

    @Test("ちょうど閾値は区切らない")
    func blockGapExactlyDoesNotSplit() async throws {
        #expect(try await Self.blocks(second: "10:01:00", stamp: "100100").count == 1)
    }

    @Test("1 秒超えで区切る")
    func blockGapPlusOneSplits() async throws {
        #expect(try await Self.blocks(second: "10:01:01", stamp: "100101").count == 2)
    }

    @Test("CE session.blockGapSeconds 60 なら 2 分の空きで区切る")
    func ceSessionBlockGapSeconds() async throws {
        #expect(
            try await Self.blocks(second: "09:02:01", stamp: "090201") { $0.session.blockGapSeconds = 60 }.count == 2)
        // 既定なら 1
        #expect(try await Self.blocks(second: "09:02:01", stamp: "090201").count == 1)
    }

    @Test("ended_at が無い Part の後は必ず区切る")
    func unknownEndAlwaysSplits() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        try w.addTimedPart(time: "09:00:00", stamp: "090000", ended: false, segments: [Self.seg(0, 1, "朝")])
        try w.addTimedPart(time: "09:00:30", stamp: "090030", segments: [Self.seg(0, 1, "昼")])
        let blocks = try await Self.build(w).blocks
        #expect(blocks.count == 2)
        #expect(blocks.first?.start.epochMillis == Self.nine)
        #expect(blocks.first?.end.epochMillis == Self.nine)
    }

    @Test("有効な segment が 0 なら COMPLETED（session_empty）")
    func emptyMergeCompletes() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        try w.addSessionPart(hour: 9, status: .skipped)
        try w.addSessionPart(hour: 10, status: .skipped)
        let result = await SessionSteps(ctx: try await w.context()).process(sessionKey: Self.key)
        #expect(result == .empty)
        #expect(try w.session().status == .completed)
        let events = try w.sessionEvents().suffix(2)
        #expect(events.map(\.fromStatus) == ["READY", "MERGING"])
        #expect(events.map(\.toStatus) == ["MERGING", "COMPLETED"])
        #expect(
            w.lines("session_empty").contains { $0.hasSuffix("session_empty session_key=DJIMIC3:20260912 parts=2") })
        #expect(!PipelineFixtures.exists(w.layout.analysisJSON(sessionSlug: KeySlug.of(Self.key))))
    }

    @Test("Part 0 件の Session を直接処理しても COMPLETED")
    func noPartsCompletes() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        #expect(await SessionSteps(ctx: try await w.context()).process(sessionKey: Self.key) == .empty)
    }

    @Test("session_merged の数")
    func mergedIsLogged() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        try w.addSessionPart(hour: 9, status: .rawSaved)
        try w.addSessionPart(hour: 10, status: .failed)
        _ = await SessionSteps(ctx: try await w.context()).process(sessionKey: Self.key)
        #expect(try w.session().failedPartCount == 1)
        #expect(
            w.lines("session_merged").contains {
                $0.hasSuffix("session_merged session_key=DJIMIC3:20260912 parts=1 excluded=1 chars=10")
            })
    }

    @Test("MERGING から入っても READY→MERGING を書かない")
    func mergingEntryRecordsNoPhantom() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .merging)
        try w.addSessionPart(hour: 9)
        _ = await SessionSteps(ctx: try await w.context()).process(sessionKey: Self.key)
        #expect(try w.session().status == .merged)
        #expect(!(try w.sessionEvents().contains { $0.fromStatus == "READY" && $0.toStatus == "MERGING" }))
    }
}
