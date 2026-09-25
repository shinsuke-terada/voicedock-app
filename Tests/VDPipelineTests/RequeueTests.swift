// requeue（PLAN §5.4 の 4 つの契機）のテスト（T-18 §6.4）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("Requeue")
struct RequeueTests {
    static func relpath(_ hhmmss: String) -> String {
        "TX_MIC001_20260829_071201/TX01_MIC002_20260829_" + hhmmss + "_orig.wav"
    }

    @Test("requeue は戻り先へ戻し retry_count を 0 に")
    func requeueResetsRetryCount() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        for _ in 0..<3 { try w.movePart(pk, [.normalizing, .failed], code: .whisperFailed) }
        #expect(try w.part(pk).retryCount == 3)
        let n = try Requeue(ctx: try await w.context()).requeueFailed(.startup)
        #expect(n == 1)
        let row = try w.part(pk)
        #expect(row.status == .normalizing)
        #expect(row.retryCount == 0)
        #expect(try w.partEvents(pk).last?.detail == "requeue")
        #expect(w.lines("recovery_completed").contains { $0.hasSuffix("INFO  recovery_completed requeued=1") })
    }

    @Test("needs_recopy の Part は requeue しない")
    func requeueSkipsNeedsRecopy() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        try w.movePart(pk, [.normalizing, .failed], code: .normalizedMissing)
        try w.store.updateRecording(pk, [.needsRecopy(true)])
        let n = try Requeue(ctx: try await w.context()).requeueFailed(.connect)
        #expect(n == 0)
        #expect(try w.part(pk).status == .failed)
    }

    @Test("RetryPolicy を見ずに全部戻す")
    func requeueIgnoresRetryPolicy() async throws {
        let w = try await PipelineWorld.make()
        try w.moveSession("DJIMIC3:20260829", [.ready, .merging, .merged, .analyzing, .failed], code: .llmInvalidJSON)
        let pk = try w.insertPart()
        try w.movePart(pk, [.normalizing, .failed], code: .importFailed)
        let n = try Requeue(ctx: try await w.context()).requeueFailed(.manual)
        #expect(n == 2)
    }

    @Test("戻り先は直近の FAILED への遷移元")
    func requeueUsesTheLatestFailedOrigin() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        try w.movePart(pk, [.normalizing, .failed])
        try w.movePart(
            pk, [.normalizing, .normalized, .transcribing, .transcribed, .rawWriting, .failed],
            code: .obsidianRawWriteFailed)
        _ = try Requeue(ctx: try await w.context()).requeueFailed(.manual)
        #expect(try w.part(pk).status == .rawWriting)
    }

    @Test("契機 4: needs_recopy が 0 に戻った SOURCE_HASH_MISMATCH / NORMALIZED_MISSING だけ")
    func requeueRecopiedOnlyAfterRecopy() async throws {
        let w = try await PipelineWorld.make()
        let hash = try w.insertPart(relpath: Self.relpath("071201"))
        let missing = try w.insertPart(relpath: Self.relpath("071202"))
        let whisper = try w.insertPart(relpath: Self.relpath("071203"))
        try w.movePart(hash, [.normalizing, .failed], code: .sourceHashMismatch)
        try w.movePart(missing, [.normalizing, .failed], code: .normalizedMissing)
        try w.store.updateRecording(missing, [.needsRecopy(true)])
        try w.movePart(whisper, [.normalizing, .failed], code: .whisperFailed)

        let n = try Requeue(ctx: try await w.context()).requeueRecopied()

        #expect(n == 1)
        let row = try w.part(hash)
        #expect(row.status == .normalizing)
        #expect(row.retryCount == 0)
        #expect(try w.partEvents(hash).last?.detail == "recopied")
        #expect(try w.part(missing).status == .failed)
        #expect(try w.part(whisper).status == .failed)
    }

    @Test("Part → Session の順")
    func requeuePartsBeforeSessions() async throws {
        let w = try await PipelineWorld.make()
        let key = "DJIMIC3:20260829"
        try w.moveSession(key, [.ready, .merging, .failed])
        let pk = try w.insertPart()
        try w.movePart(pk, [.normalizing, .failed])
        _ = try Requeue(ctx: try await w.context()).requeueFailed(.manual)
        let partEvent = try #require(try w.partEvents(pk).last)
        let sessionEvent = try #require(try w.store.events(entity: .session, key: key).last)
        #expect(partEvent.detail == "requeue" && sessionEvent.detail == "requeue")
        #expect(partEvent.id < sessionEvent.id)
    }

    @Test("FAILED が無ければ 0・ログ無し")
    func nothingFailed() async throws {
        let w = try await PipelineWorld.make()
        let ctx = try await w.context()
        #expect(try Requeue(ctx: ctx).requeueFailed(.startup) == 0)
        #expect(try Requeue(ctx: ctx).requeueRecopied() == 0)
        #expect(w.sink.lines == [])
    }
}
