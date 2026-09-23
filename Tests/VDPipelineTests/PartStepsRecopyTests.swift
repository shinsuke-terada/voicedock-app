// needs_recopy の書き順と上げ下げ（PLAN §8.3・§8.4 手順 2・§5.4 の契機 4。F-82・issue #119 の D4・D5 と、
// F-77 の入力のヘッダの NORMALIZE_VERIFY_FAILED の取り直し（利用者の決定 2026-09-23））。本物の AVFoundation と BWF。
import Foundation
import GRDB
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDPipeline
@testable import VDStore

@Suite("PartSteps（F-82 needs_recopy）", .serialized)
struct PartStepsRecopyTests {
    static func installTrigger(_ w: PipelineWorld, _ sql: String) throws {
        try w.store.pool.write { db in try db.execute(sql: sql) }
    }

    static func dropTrigger(_ w: PipelineWorld) throws {
        try w.store.pool.write { db in try db.execute(sql: "DROP TRIGGER f82_abort") }
    }

    /// FAILED→NORMALIZING の events のうち detail が d のものの数
    static func requeues(_ w: PipelineWorld, _ pk: String, detail d: String) throws -> Int {
        try w.partEvents(pk).filter { $0.fromStatus == "FAILED" && $0.toStatus == "NORMALIZING" && $0.detail == d }
            .count
    }

    // MARK: - D4

    @Test("F-82 16 kHz も inbox も無いとき、needs_recopy を今の状態のまま先に書く（書けなければ →NORMALIZING に進まない）")
    func renormalizeWritesNeedsRecopyBeforeTransition() async throws {
        let (w, pk) = try await PartStepsTranscribeTests.prepared()
        try FileManager.default.removeItem(at: PartStepsTranscribeTests.audio(w, pk))
        // needs_recopy の書き込みで落ちたことにする（旧い順序では →NORMALIZING が先に確定して needs_recopy = 0 で残った）
        try Self.installTrigger(
            w,
            "CREATE TRIGGER f82_abort BEFORE UPDATE OF needs_recopy ON recordings WHEN NEW.needs_recopy = 1 "
                + "BEGIN SELECT RAISE(ABORT, 'f82'); END")

        #expect(try await PartStepsTranscribeTests.transcribe(w, pk) == false)

        let crashed = try w.part(pk)
        #expect(crashed.status == .normalized)
        #expect(crashed.needsRecopy == false)
        #expect(try w.partEvents(pk).last?.toStatus == "NORMALIZED")
    }

    @Test("F-82 D4 途中で落ちて起動し直しても、SOURCE_MISSING の SKIPPED（終端）にならず NORMALIZED_MISSING で再コピーを待つ")
    func crashDuringRenormalizeStillWaitsForRecopy() async throws {
        let (w, pk) = try await PartStepsTranscribeTests.prepared()
        try FileManager.default.removeItem(at: PartStepsTranscribeTests.audio(w, pk))
        try Self.installTrigger(
            w,
            "CREATE TRIGGER f82_abort BEFORE UPDATE OF needs_recopy ON recordings WHEN NEW.needs_recopy = 1 "
                + "BEGIN SELECT RAISE(ABORT, 'f82'); END")
        _ = try await PartStepsTranscribeTests.transcribe(w, pk)
        try Self.dropTrigger(w)
        // 起動し直し: 復旧 → Part の工程
        let ctx = try await w.context()
        _ = try Recovery(store: w.store, layout: w.layout, log: w.log, config: ctx.config, zone: ctx.zone).run()
        _ = await PartSteps(ctx: ctx).process(partkey: pk)

        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .normalizedMissing)
        #expect(row.needsRecopy)
        #expect(try Requeue(ctx: ctx).requeueFailed(.connect) == 0)
    }

    @Test("F-82 D4 inbox が在れば needs_recopy を書かずに NORMALIZING へ戻すだけ")
    func renormalizeWithInboxDoesNotFlag() async throws {
        let (w, pk) = try await PartStepsTranscribeTests.prepared()
        try FileManager.default.removeItem(at: PartStepsTranscribeTests.audio(w, pk))
        try PartStepsTranscribeTests.putInbox(w)

        #expect(try await PartStepsTranscribeTests.transcribe(w, pk) == false)

        let row = try w.part(pk)
        #expect(row.status == .normalizing)
        #expect(row.needsRecopy == false)
        #expect(w.lines("normalize_failed").isEmpty)
    }

    // MARK: - D5

    @Test("F-82 D5 変換が成功したら needs_recopy を下ろす（後で FAILED になっても requeue から外れない）")
    func successClearsNeedsRecopy() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.registerPart()
        try w.store.updateRecording(pk, [.needsRecopy(true)])

        #expect(try await PartStepsNormalizeTests.normalize(w, pk))

        #expect(try w.part(pk).status == .normalized)
        #expect(try w.part(pk).needsRecopy == false)
        try w.movePart(pk, [.transcribing, .failed], code: .whisperFailed)
        #expect(try Requeue(ctx: try await w.context()).requeueFailed(.manual) == 1)
        #expect(try w.part(pk).status == .transcribing)
    }

    // MARK: - 入力のヘッダの NORMALIZE_VERIFY_FAILED の取り直し

    @Test("F-82 入力のヘッダが実データより短い NORMALIZE_VERIFY_FAILED は needs_recopy を立て、契機 1〜3 の requeue から外れる")
    func extentMismatchFlagsRecopy() async throws {
        let w = try await PipelineWorld.make { $0.audio.inboxRetain = "normalized" }
        let pk = try w.registerPart(seconds: 2.0)
        let (inbox, blob) = try PartStepsNormalizeExtentTests.writeStaleInbox(w, pk)

        #expect(try await PartStepsNormalizeTests.normalize(w, pk) == false)

        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .normalizeVerifyFailed)
        #expect(row.errorMessage == "入力のヘッダの長さと実データの量が合いません（ヘッダ 96000 フレーム、実データ 192000 フレーム）")
        #expect(row.needsRecopy)
        #expect(try Data(contentsOf: inbox) == blob)
        #expect(try Requeue(ctx: try await w.context()).requeueFailed(.connect) == 0)
        #expect(try w.part(pk).status == .failed)
    }

    @Test("F-82 取り直した後も契機 4（requeueRecopied）では戻さず、次の再評価の契機で 1 回だけ変換し直す（接続したままでは繰り返さない）")
    func recopyIsOncePerReevaluation() async throws {
        let w = try await PipelineWorld.make { $0.audio.inboxRetain = "normalized" }
        let pk = try w.registerPart(seconds: 2.0)
        _ = try PartStepsNormalizeExtentTests.writeStaleInbox(w, pk)
        _ = try await PartStepsNormalizeTests.normalize(w, pk)
        let ctx = try await w.context()
        let requeue = Requeue(ctx: ctx)
        // 取り込みが同じ（直っていない）原本を取り直したことにする（IngestService.registerCopied と同じ列）
        let copied = try w.part(pk)
        try w.store.updateRecording(
            pk, [.inboxPath(copied.inboxPath), .sha256Helper(copied.sha256Helper), .needsRecopy(false)])

        #expect(try requeue.requeueRecopied() == 0)
        #expect(try w.part(pk).status == .failed)

        #expect(try requeue.requeueFailed(.connect) == 1)
        #expect(try w.part(pk).status == .normalizing)
        #expect(try await PartStepsNormalizeTests.normalize(w, pk) == false)

        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .normalizeVerifyFailed)
        #expect(row.needsRecopy)
        #expect(try requeue.requeueFailed(.connect) == 0)
        #expect(try requeue.requeueRecopied() == 0)
        #expect(try Self.requeues(w, pk, detail: "recopied") == 0)
        #expect(try Self.requeues(w, pk, detail: "requeue") == 1)
    }

    @Test(
        "F-82 needs_recopy を立てる変換の失敗は SOURCE_HASH_MISMATCH と、入力のヘッダの NORMALIZE_VERIFY_FAILED だけ",
        arguments: [
            (ErrorCode.sourceHashMismatch, "再計算した SHA-256 がコピー時の値と一致しません", true),
            (.normalizeVerifyFailed, "入力のヘッダの長さと実データの量が合いません（ヘッダ 96000 フレーム、実データ 192000 フレーム）", true),
            (.normalizeVerifyFailed, "入力の WAV の構造を読めません（data チャンクがありません）", false),
            (.normalizeVerifyFailed, "長さが入力と 2.00 秒ずれています（許容 1.0 秒）", false),
            (.normalizeVerifyFailed, "sample_rate が 8000（期待 16000）", false),
            (.normalizeVerifyFailed, "", false),
            (.importFailed, "入力のヘッダの長さと実データの量が合いません", false),
        ])
    func needsRecopyClassification(code: ErrorCode, message: String, expected: Bool) {
        #expect(PartSteps.needsRecopy(StageFailure(code, message)) == expected)
    }
}
