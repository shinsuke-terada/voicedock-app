// 後追いの実行はプレビューで見せた対象に限る（PLAN §8.9.9。F-72・issue #112 の G1 と B5）。舞台は BacklogPlannerTests と同じ。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice

@testable import VDPipeline
@testable import VDStore

@Suite("BacklogPlanner（F-72 同意の範囲）")
struct BacklogConsentTests {
    typealias Base = BacklogPlannerTests

    /// 過去分の舞台に、同じ Session の COMPLETED の兄弟を足す（デバイスにも置き、Raw ノートと snapshot に載せる）
    static func addEligibleSibling(_ f: Base.Fixture) async throws -> String {
        let sibling = try f.scene.addPart(fileName: Base.tenFile, startedAt: Base.tenOClock, status: .completed)
        try f.scene.writeRawNote()
        await f.ingest.setSnapshot(f.scene.snapshot())
        return sibling
    }

    static func execute(_ f: Base.Fixture, _ kind: BacklogKind, preview: [String]) async
        -> [Result<BacklogExecution, BacklogFailure>]
    {
        let replies = BacklogReplies<BacklogExecution>()
        await f.planner.handle(
            .execute(preview: BacklogPlan(eligible: preview, skipped: []), reply: replies.reply), kind: kind)
        return replies.results
    }

    /// SOURCE_DELETING→COMPLETED だけを DB で拒む（1 つ目の遷移は通り、2 つ目で例外になる）
    static func blockCompletion(_ scene: DeletionScene) throws {
        let from = PartStatus.sourceDeleting.rawValue
        let to = PartStatus.completed.rawValue
        let sql =
            "CREATE TRIGGER f72_block_completed BEFORE UPDATE OF status ON recordings WHEN OLD.status = '" + from
            + "' AND NEW.status = '" + to + "' BEGIN SELECT RAISE(ABORT, 'blocked'); END"
        try scene.store.pool.write { try $0.execute(sql: sql) }
    }

    static func scalars(_ keys: [String]) -> [[Unicode.Scalar]] {
        keys.map { Array($0.unicodeScalars) }
    }

    // MARK: - 過去分

    @Test("F-72 過去分: プレビューの後に増えた対象は書かない（プレビューで見せた対象だけを実行する）")
    func backlogDoesNotWriteTargetsAddedAfterThePreview() async throws {
        let f = try Base.backlogStage()
        let preview = try await f.planner.planBacklog()
        #expect(preview.eligible == [f.pk])
        let sibling = try await Self.addEligibleSibling(f)
        #expect(try await f.planner.planBacklog().eligible == [f.pk, sibling])
        let results = await Self.execute(f, .backlog, preview: preview.eligible)
        #expect(results == [.success(BacklogExecution(previewed: 1, added: 1, done: 1))])
        let shown = try Base.part(f.scene, f.pk)
        #expect(shown.status == .sourceDeleting)
        let id = try #require(shown.deleteRequestID)
        #expect(f.scene.requests().map(\.lastPathComponent) == [id + ".json"])
        let added = try Base.part(f.scene, sibling)
        #expect(added.status == .completed)
        #expect(added.deleteRequestID == nil)
        #expect(!f.scene.logLines.contains { $0.contains(" delete_requested ") && $0.contains(sibling) })
    }

    @Test("F-72 過去分: プレビューの対象が減っていれば残った対象だけを実行し、減った分を飛ばした数に入れる")
    func backlogExecutesOnlyTheRemainingPreviewedTargets() async throws {
        let f = try Base.backlogStage()
        let sibling = try await Self.addEligibleSibling(f)
        let preview = try await f.planner.planBacklog()
        #expect(preview.eligible == [f.pk, sibling])
        try f.scene.store.updateRecording(sibling, [.sourceDeletedAt("2026-09-12T10:30:00+09:00")])
        let results = await Self.execute(f, .backlog, preview: preview.eligible)
        #expect(results == [.success(BacklogExecution(previewed: 2, added: 0, done: 1))])
        #expect(try Base.part(f.scene, f.pk).status == .sourceDeleting)
        #expect(try Base.part(f.scene, sibling).status == .completed)
        #expect(f.scene.requests().count == 1)
    }

    @Test("F-72 空のプレビュー（対象 0 件）では、立て直した計画に対象が在っても何も書かない（TEST-28）")
    func emptyPreviewWritesNothing() async throws {
        let f = try Base.backlogStage()
        #expect(try await f.planner.planBacklog().eligible == [f.pk])
        let results = await Self.execute(f, .backlog, preview: [])
        #expect(results == [.success(BacklogExecution(previewed: 0, added: 1, done: 0))])
        let part = try Base.part(f.scene, f.pk)
        #expect(part.status == .completed)
        #expect(part.deleteRequestID == nil)
        #expect(f.scene.requests() == [])
    }

    // MARK: - 手動で消した分

    @Test("F-72 手動で消した分: プレビューの後に増えた対象は完了にしない")
    func resolveAbsentDoesNotCompleteTargetsAddedAfterThePreview() async throws {
        let f = try Base.absentStage()
        let preview = try await f.planner.planResolveAbsent()
        #expect(preview.eligible == [f.pk])
        let sibling = try f.scene.addPart(
            fileName: Base.tenFile, startedAt: Base.tenOClock, status: .sourceDeletePending,
            errorCode: .sourceIdentityMismatch, onDevice: false)
        #expect(try await f.planner.planResolveAbsent().eligible == [f.pk, sibling])
        let results = await Self.execute(f, .resolveAbsent, preview: preview.eligible)
        #expect(results == [.success(BacklogExecution(previewed: 1, added: 1, done: 1))])
        #expect(try Base.part(f.scene, f.pk).status == .completed)
        #expect(try Base.part(f.scene, sibling).status == .sourceDeletePending)
    }

    @Test("F-72 手動で消した分: 完了への遷移に失敗したら ID と要求を残す（遷移 → 取り下げ → ID を外す の順）")
    func resolveAbsentKeepsTheIDWhenTheTransitionFails() async throws {
        let f = try Base.absentStage()
        let id = Base.manualID
        try f.scene.store.updateRecording(f.pk, [.deleteRequestID(id)])
        try DeleteQueue.write(
            DeleteRequest(
                requestID: id, createdAt: "2026-09-12T12:00:00+09:00", deviceID: f.scene.deviceID, partkey: f.pk,
                sessionKey: f.scene.sessionKey,
                target: DeleteTarget(relpath: DeletionScene.relpath, size: 4096, mtime: DeletionScene.sourceMtime)),
            layout: f.scene.layout)
        try Self.blockCompletion(f.scene)
        let results = await Self.execute(f, .resolveAbsent, preview: [f.pk])
        #expect(results == [.success(BacklogExecution(previewed: 1, added: 0, done: 0))])
        let part = try Base.part(f.scene, f.pk)
        #expect(part.status == .sourceDeleting)
        #expect(part.deleteRequestID == id)
        #expect(f.scene.requests().map(\.lastPathComponent) == [id + ".json"])
    }

    // MARK: - 照合

    @Test("F-72 照合はスカラー列の一致: 正準等価でも綴りの違う partkey はプレビューに無い対象として扱う")
    func consentComparesScalars() {
        let nfc = "DJIMIC3/TX_MIC001_20260912_090000/caf\u{E9}.wav"
        let nfd = "DJIMIC3/TX_MIC001_20260912_090000/cafe\u{301}.wav"
        let scope = BacklogPlanner.consented(preview: [nfc], rebuilt: [nfd, nfc])
        #expect(Self.scalars(scope.targets) == Self.scalars([nfc]))
        #expect(Self.scalars(scope.added) == Self.scalars([nfd]))
    }

    @Test("F-72 実行の対象は立て直した計画の順で、プレビューにだけ在るものは入らない")
    func consentFollowsTheRebuiltOrder() {
        let scope = BacklogPlanner.consented(preview: ["c", "a", "x"], rebuilt: ["a", "b", "c"])
        #expect(scope.targets == ["a", "c"])
        #expect(scope.added == ["b"])
    }
}
