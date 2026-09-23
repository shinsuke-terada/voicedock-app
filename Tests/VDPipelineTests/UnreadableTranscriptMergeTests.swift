// 統合で有効な Part の transcript が読めないとき（PLAN §5.6。F-74・issue #114）。
// 「本当に空」と区別せずに session_empty で COMPLETED にしない。MERGED 以降では毎 tick 黙って止まらない。
// どちらも既存の SESSION_MERGE_FAILED の経路で知らせる（辺もイベントも増やさない）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("UnreadableTranscriptMerge")
struct UnreadableTranscriptMergeTests {
    static let key = PipelineFixtures.sessionKey
    /// addSessionPart(hour: 9) の partkey
    static let nineOClock = "DJIMIC3/TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"
    static let failedLog =
        "session_merge_failed session_key=DJIMIC3:20260912 error_code=SESSION_MERGE_FAILED"

    static func process(_ w: PipelineWorld) async throws -> SessionStepResult {
        await SessionSteps(ctx: try await w.context()).process(sessionKey: Self.key)
    }

    /// 9 時の Part の transcript を読めなくする（無い・壊れている）
    static func breakTranscript(_ w: PipelineWorld, _ how: String) throws {
        let url = w.layout.transcript(slug: KeySlug.of(Self.nineOClock))
        if how == "無い" {
            try FileManager.default.removeItem(at: url)
        } else {
            try Data("{".utf8).write(to: url)
        }
    }

    @Test(
        "F-74 有効な Part の transcript が読めず segment が 0 件なら session_empty にせず MERGING→FAILED（SESSION_MERGE_FAILED）（パラメータ化: 無い・壊れている）",
        arguments: ["無い", "壊れている"])
    func unreadableTranscriptFailsTheMerge(_ how: String) async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        try w.addSessionPart(hour: 9, status: .rawSaved)
        try w.addSessionPart(hour: 10, status: .skipped, text: nil)
        try Self.breakTranscript(w, how)
        #expect(try await Self.process(w) == .stopped)
        let session = try w.session()
        #expect(session.status == .failed)
        #expect(session.errorCode == .sessionMergeFailed)
        #expect(session.errorMessage == "文字起こしを読めない Part があります: " + Self.nineOClock)
        let events = try w.sessionEvents().suffix(2)
        #expect(events.map(\.fromStatus) == ["READY", "MERGING"])
        #expect(events.map(\.toStatus) == ["MERGING", "FAILED"])
        #expect(w.lines("session_merge_failed").contains { $0.hasSuffix(Self.failedLog) })
        #expect(w.lines("session_empty") == [])
    }

    @Test("F-74 有効な Part の transcript が読めて text が空白だけなら、従来どおり本当に空として session_empty で COMPLETED")
    func readableButBlankTranscriptIsStillEmpty() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        try w.addSessionPart(hour: 9, status: .rawSaved, text: " \u{3000} ")
        #expect(try await Self.process(w) == .empty)
        #expect(try w.session().status == .completed)
        #expect(
            w.lines("session_empty").contains { $0.hasSuffix("session_empty session_key=DJIMIC3:20260912 parts=1") })
        #expect(w.lines("session_merge_failed") == [])
    }

    @Test(
        "F-74 MERGED 以降で transcript が読めなくなった Session は黙って止まらず、→ANALYZING→FAILED（SESSION_MERGE_FAILED）にする（パラメータ化: MERGED・ANALYZING・ANALYZED・WRITING）",
        arguments: [SessionStatus.merged, .analyzing, .analyzed, .writing])
    func unreadableAfterMergeFailsTheSession(_ status: SessionStatus) async throws {
        let w = try await PipelineWorld.make()
        // LLM は使える（解析へ進めば llama-server を起動する）。失敗は LLM を起動せずに決める
        try await w.installLLM()
        try w.addSession(status: status)
        try w.addSessionPart(hour: 9, status: .rawSaved)
        try Self.breakTranscript(w, "無い")
        #expect(try await Self.process(w) == .stopped)
        let session = try w.session()
        #expect(session.status == .failed)
        #expect(session.errorCode == .sessionMergeFailed)
        #expect(session.errorMessage == "文字起こしを読めない Part があります: " + Self.nineOClock)
        let expected: [(String?, String, String?)]
        switch status {
        case .merged:
            expected = [("MERGED", "ANALYZING", nil), ("ANALYZING", "FAILED", nil)]
        case .analyzing:
            expected = [("ANALYZING", "FAILED", nil)]
        default:
            expected = [(status.rawValue, "ANALYZING", "stale_analysis"), ("ANALYZING", "FAILED", nil)]
        }
        let events = Array(try w.sessionEvents().suffix(expected.count))
        #expect(events.map(\.fromStatus) == expected.map(\.0))
        #expect(events.map(\.toStatus) == expected.map(\.1))
        #expect(events.map(\.detail) == expected.map(\.2))
        #expect(w.lines("session_merge_failed").contains { $0.hasSuffix(Self.failedLog) })
        #expect(await w.llm.ensureCalls.isEmpty)
        #expect(await w.chat.calls.isEmpty)
        // 次の tick でも同じ失敗を繰り返さない（FAILED は requeue の担当）
        #expect(try await Self.process(w) == .stopped)
        #expect(w.lines("session_merge_failed").count == 1)
    }

    @Test("F-74 一部の Part だけ transcript が読めないなら、従来どおり読めない Part を飛ばして MERGED にする（失敗にしない）")
    func partiallyUnreadableStillMerges() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .ready)
        try w.addSessionPart(hour: 9, status: .rawSaved)
        try w.addSessionPart(hour: 10, status: .rawSaved, text: nil)
        // LLM を入れていないので解析のガードで止まる（MERGED のまま）
        #expect(try await Self.process(w) == .stopped)
        #expect(try w.session().status == .merged)
        #expect(
            w.lines("session_merged").contains {
                $0.hasSuffix("session_merged session_key=DJIMIC3:20260912 parts=2 excluded=0 chars=10")
            })
        #expect(w.lines("session_merge_failed") == [])
    }

    @Test("F-74 TEST-28 Part が 0 件なら読めない Part も 0 件で、MERGED の Session を失敗にしない")
    func noPartsIsNotAFailure() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(status: .merged)
        let steps = SessionSteps(ctx: try await w.context())
        #expect(steps.unreadableTranscriptPartkeys([]) == [])
        #expect(!steps.failUnreadableAfterMerge(Self.key))
        #expect(try w.session().status == .merged)
        #expect(w.lines("session_merge_failed") == [])
    }
}
