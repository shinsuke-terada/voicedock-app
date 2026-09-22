// Part の分組のテスト（T-22 §6.1。PLAN §5.6。voicedock test_session_group / test_session_reopen の上限）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDLLM
import VDStore

@testable import VDPipeline

@Suite("SessionGroup")
struct SessionGroupTests {
    /// 2026-09-12T23:00:00+09:00
    static let groupTime: Int64 = 1_789_221_600_000
    /// 2026-09-13T09:00:00+09:00（上限のテスト）
    static let limitTime: Int64 = 1_789_257_600_000
    static let key = "DJIMIC3:20260912"

    static func world(_ configure: @escaping (inout AppConfig) -> Void = { _ in }, at epochMillis: Int64 = groupTime)
        async throws -> PipelineWorld
    {
        let w = try await PipelineWorld.make(configure: configure)
        w.clock.set(Instant(epochMillis: epochMillis))
        return w
    }

    static func group(_ w: PipelineWorld) async throws {
        try SessionSteps(ctx: try await w.context()).groupNewParts()
    }

    /// すべての Session（session_key 順）。
    static func allSessions(_ w: PipelineWorld) throws -> [SessionRow] {
        var rows: [SessionRow] = []
        for status in SessionStatus.allCases { rows += try w.store.sessions(status: status) }
        return rows.sorted { $0.sessionKey < $1.sessionKey }
    }

    /// 上限のテストの Part（2026-09-12 の 09:00 から 1 分ずつ、60 秒。voicedock test_session_reopen add_part）。
    @discardableResult
    static func addLimitPart(_ w: PipelineWorld, minute: Int, duration: Double? = 60) throws -> String {
        let mm = String(format: "%02d", minute)
        return try w.registerRow(
            folder: "TX_MIC001_20260912_09\(mm)00", name: "TX00_MIC001_20260912_09\(mm)00_orig.wav",
            started: "2026-09-12T09:\(mm):00+09:00", duration: duration)
    }

    static func keys(_ w: PipelineWorld, _ pks: [String]) throws -> [String?] {
        try pks.map { try w.part($0).sessionKey }
    }

    @Test("送信機・フォルダが違っても同じ日は 1 Session")
    func sameDayIsOneSession() async throws {
        let w = try await Self.world()
        try w.registerRow()
        try w.registerRow(
            folder: "TX_MIC009_20260912_160000", name: "TX03_MIC009_20260912_160000_orig.wav",
            started: "2026-09-12T16:00:00+09:00")
        try await Self.group(w)
        let sessions = try Self.allSessions(w)
        #expect(sessions.map(\.sessionKey) == [Self.key])
        #expect(sessions.first?.partCount == 2)
        #expect(sessions.first?.status == .open)
    }

    @Test("TIME-02 23:50 開始の Part は開始日")
    func partSpanningMidnightBelongsToStartDay() async throws {
        let w = try await Self.world()
        let pk = try w.registerRow(
            folder: "TX_MIC001_20260912_235000", name: "TX00_MIC001_20260912_235000_orig.wav",
            started: "2026-09-12T23:50:00+09:00", duration: 1800)
        try await Self.group(w)
        #expect(try w.part(pk).sessionKey == Self.key)
    }

    @Test("CE timeZone 日付は設定のタイムゾーンで取る", arguments: [("Asia/Tokyo", "DJIMIC3:20260913"), ("UTC", Self.key)])
    func ceTimeZone(zone: String, expected: String) async throws {
        let w = try await Self.world { $0.timeZone = zone }
        let pk = try w.registerRow(started: "2026-09-12T15:30:00+00:00")
        try await Self.group(w)
        #expect(try w.part(pk).sessionKey == expected)
    }

    @Test("日付違い・デバイス違いは別")
    func differentDayOrDevice() async throws {
        let w = try await Self.world()
        try w.registerRow()
        try w.registerRow(
            folder: "TX_MIC001_20260913_090000", name: "TX00_MIC001_20260913_090000_orig.wav",
            started: "2026-09-13T09:00:00+09:00")
        try w.registerRow(device: "NO NAME")
        try await Self.group(w)
        #expect(
            try Self.allSessions(w).map(\.sessionKey) == ["DJIMIC3:20260912", "DJIMIC3:20260913", "NO NAME:20260912"])
    }

    @Test("対象は session_key が NULL の Part だけ")
    func onlyUngroupedParts() async throws {
        let w = try await Self.world()
        let pk = try w.registerRow()
        try await Self.group(w)
        let before = try w.eventCount(parts: [pk], sessions: [Self.key])
        try await Self.group(w)
        #expect(try w.eventCount(parts: [pk], sessions: [Self.key]) == before)
    }

    @Test("集計列を数え直す")
    func columnsAreRecounted() async throws {
        let w = try await Self.world()
        try w.registerRow(duration: 600)
        try w.registerRow(
            folder: "TX_MIC001_20260912_160000", name: "TX00_MIC001_20260912_160000_orig.wav",
            started: "2026-09-12T16:00:00+09:00", duration: 1200, status: .skipped)
        try await Self.group(w)
        let s = try w.session(Self.key)
        #expect(s.partCount == 2)
        #expect(s.failedPartCount == 1)
        #expect(s.recordedSeconds == 1800.0)
        #expect(s.startedAt == "2026-09-12T12:09:50+09:00")
        #expect(s.endedAt == "2026-09-12T16:20:00+09:00")
        #expect(s.dayDate == "2026-09-12")
    }

    @Test("SM-02 OPEN への追加は OPEN→OPEN")
    func addingToOpenIsATransition() async throws {
        let w = try await Self.world()
        let pk1 = try w.registerRow()
        let pk2 = try w.registerRow(
            folder: "TX_MIC001_20260912_160000", name: "TX00_MIC001_20260912_160000_orig.wav",
            started: "2026-09-12T16:00:00+09:00")
        try await Self.group(w)
        let events = try w.sessionEvents(Self.key)
        #expect(events.map(\.fromStatus) == [nil, "OPEN", "OPEN"])
        #expect(events.map(\.toStatus) == ["OPEN", "OPEN", "OPEN"])
        #expect(events.map(\.detail) == [nil, pk1, pk2])
    }

    @Test("閉じた Session への追加は events を書かず再オープンしない")
    func addingToClosedWritesNoEvent() async throws {
        let w = try await Self.world()
        let pk1 = try w.registerRow()
        try await Self.group(w)
        try w.store.recordSessionTransition(sessionKey: Self.key, from: .open, to: .ready)
        let before = try w.sessionEvents(Self.key).count
        let pk2 = try w.registerRow(
            folder: "TX_MIC001_20260912_160000", name: "TX00_MIC001_20260912_160000_orig.wav",
            started: "2026-09-12T16:00:00+09:00")
        try await Self.group(w)
        #expect(try w.part(pk2).sessionKey == w.part(pk1).sessionKey)
        #expect(try w.sessionEvents(Self.key).count == before)
        let s = try w.session(Self.key)
        #expect(s.status == .ready)
        #expect(s.partCount == 2)
        // 再オープンできる状態（SAVED）でも、分組では再オープンしない（契機は RAW_SAVED / FAILED / SKIPPED）
        try w.forceSession(Self.key, status: .saved)
        let pk3 = try w.registerRow(
            folder: "TX_MIC001_20260912_170000", name: "TX00_MIC001_20260912_170000_orig.wav",
            started: "2026-09-12T17:00:00+09:00")
        try await Self.group(w)
        #expect(try w.part(pk3).sessionKey == Self.key)
        #expect(try w.sessionEvents(Self.key).count == before)
        let saved = try w.session(Self.key)
        #expect(saved.status == .saved)
        #expect(saved.regeneratedCount == 0)
    }

    @Test("未分組が無ければ何もしない")
    func emptyGroupsNothing() async throws {
        let w = try await Self.world()
        try await Self.group(w)
        #expect(try Self.allSessions(w).isEmpty)
    }

    // MARK: - 上限

    @Test("上限に達しなければ 1 つ")
    func belowLimitSharesOne() async throws {
        let w = try await Self.world({ $0.session.maxParts = 4 }, at: Self.limitTime)
        let pks = try (0..<4).map { try Self.addLimitPart(w, minute: $0) }
        try await Self.group(w)
        #expect(try Self.keys(w, pks) == [Self.key, Self.key, Self.key, Self.key])
    }

    @Test("CE session.maxParts 超えた分は #2・#3 へ")
    func ceSessionMaxParts() async throws {
        let w = try await Self.world({ $0.session.maxParts = 2 }, at: Self.limitTime)
        let pks = try (0..<5).map { try Self.addLimitPart(w, minute: $0) }
        try await Self.group(w)
        let k = Self.key
        #expect(try Self.keys(w, pks) == [k, k, k + "#2", k + "#2", k + "#3"])
    }

    @Test("CE session.maxDurationSeconds でも割れる")
    func ceSessionMaxDurationSeconds() async throws {
        let w = try await Self.world(
            {
                $0.session.maxDurationSeconds = 120
                $0.session.maxParts = 99
            }, at: Self.limitTime)
        let pks = try (0..<3).map { try Self.addLimitPart(w, minute: $0) }
        try await Self.group(w)
        let k = Self.key
        #expect(try Self.keys(w, pks) == [k, k, k + "#2"])
    }

    @Test("長さ不明は 0 として数える")
    func unknownDurationCountsAsZero() async throws {
        let w = try await Self.world(
            {
                $0.session.maxDurationSeconds = 120
                $0.session.maxParts = 99
            }, at: Self.limitTime)
        let pks = try (0..<3).map { try Self.addLimitPart(w, minute: $0, duration: nil) }
        try await Self.group(w)
        #expect(try Self.keys(w, pks) == [Self.key, Self.key, Self.key])
    }

    @Test("空きのある最も小さい n を選ぶ")
    func secondPassFillsTheFirstRoom() async throws {
        let w = try await Self.world({ $0.session.maxParts = 2 }, at: Self.limitTime)
        for m in 0..<3 { try Self.addLimitPart(w, minute: m) }
        try await Self.group(w)
        let fourth = try Self.addLimitPart(w, minute: 3)
        try await Self.group(w)
        #expect(try w.part(fourth).sessionKey == Self.key + "#2")
    }
}
