// OPEN を閉じるテスト（T-22 §6.2。PLAN §5.6。voicedock session.py:276-313。F-66 で stale_day を廃止）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("SessionClose")
struct SessionCloseTests {
    static let key = "DJIMIC3:20260912"

    /// 2026-09-12T23:00+09:00 に 1 件を分組した世界。
    static func groupedWorld(_ configure: @escaping (inout AppConfig) -> Void = { _ in }) async throws
        -> PipelineWorld
    {
        let w = try await PipelineWorld.make(configure: configure)
        w.clock.set(Instant(epochMillis: SessionGroupTests.groupTime))
        try w.registerRow()
        try SessionSteps(ctx: try await w.context()).groupNewParts()
        return w
    }

    static func close(_ w: PipelineWorld) async throws {
        try SessionSteps(ctx: try await w.context()).closeIdleSessions()
    }

    @Test("日付が変わっただけでは閉じない（F-66。idle 前の過去の日の OPEN）")
    func dayChangeAloneDoesNotClose() async throws {
        let w = try await Self.groupedWorld { $0.session.idleCloseSeconds = 7200 }
        // 2026-09-12T23:00 → 2026-09-13T00:00:01（日付は過去、無通信は 3601 秒）
        w.clock.advance(seconds: 3601)
        try await Self.close(w)
        #expect(try w.session(Self.key).status == .open)
        #expect(!(try w.sessionEvents(Self.key).contains { $0.toStatus == "READY" }))
    }

    @Test("過去の日の OPEN も無通信 idleCloseSeconds で閉じる（detail idle）")
    func pastDayClosesByIdle() async throws {
        let w = try await Self.groupedWorld { $0.session.idleCloseSeconds = 7200 }
        w.clock.advance(seconds: 7200)
        try await Self.close(w)
        #expect(try w.session(Self.key).status == .ready)
        #expect(try w.sessionEvents(Self.key).last?.detail == "idle")
    }

    @Test("起動時（start）に、無通信を過ぎた過去の OPEN は idle で閉じる")
    func startClosesIdlePastDay() async throws {
        let w = try await Self.groupedWorld()
        // アプリが夜の間止まっていて、翌朝に起動した
        w.clock.advance(seconds: 36_000)
        await w.worker().start()
        #expect(try w.session(Self.key).status == .ready)
        #expect(try w.sessionEvents(Self.key).last?.detail == "idle")
    }

    @Test("当日でも idle 経過で閉じる")
    func idleSameDayBecomesReady() async throws {
        let w = try await Self.groupedWorld()
        w.clock.advance(seconds: 1801)
        try await Self.close(w)
        #expect(try w.session(Self.key).status == .ready)
        #expect(try w.sessionEvents(Self.key).last?.detail == "idle")
    }

    @Test("ちょうど idleCloseSeconds で閉じる")
    func exactlyIdleCloses() async throws {
        let w = try await Self.groupedWorld()
        w.clock.advance(seconds: 1800)
        try await Self.close(w)
        #expect(try w.session(Self.key).status == .ready)
    }

    @Test("idle 未満は OPEN")
    func recentStaysOpen() async throws {
        let w = try await Self.groupedWorld()
        w.clock.advance(seconds: 1799)
        try await Self.close(w)
        #expect(try w.session(Self.key).status == .open)
    }

    @Test("CE session.idleCloseSeconds 60 なら 61 秒で閉じる")
    func ceSessionIdleCloseSeconds() async throws {
        let w = try await Self.groupedWorld { $0.session.idleCloseSeconds = 60 }
        w.clock.advance(seconds: 61)
        try await Self.close(w)
        #expect(try w.session(Self.key).status == .ready)
        // 既定の 1800 なら OPEN のまま
        let d = try await Self.groupedWorld()
        d.clock.advance(seconds: 61)
        try await Self.close(d)
        #expect(try d.session(Self.key).status == .open)
    }

    @Test("2 回目は何もしない")
    func closingIsIdempotent() async throws {
        let w = try await Self.groupedWorld()
        w.clock.advance(seconds: 1801)
        try await Self.close(w)
        let before = try w.sessionEvents(Self.key).count
        try await Self.close(w)
        #expect(try w.sessionEvents(Self.key).count == before)
    }

    @Test("OPEN が無ければ何もしない")
    func noOpenSessions() async throws {
        let w = try await PipelineWorld.make()
        try await Self.close(w)
        #expect(try w.store.sessions(status: .ready).isEmpty)
    }
}
