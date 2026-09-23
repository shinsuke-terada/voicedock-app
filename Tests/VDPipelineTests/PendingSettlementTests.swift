// 消せないまま待つのをやめる、の続き（PLAN §8.9.5 の 5a。F-74・issue #114）。
// reaper の拒否などで ID の無い SOURCE_DELETE_PENDING になり canDeleteSource が偽のまま変わらない Part も、
// F-69 と同じ条件で既存の 2 遷移（PENDING→SOURCE_DELETING→COMPLETED）で消さずに決着させ、Session を完了させる。
// あわせて、調べ直して原因が見つからなければ決着させないこと（R2）と、連続回数の記録の配線（R6）。舞台は DeletionScene。
import Foundation
import GRDB
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice

@testable import VDPipeline
@testable import VDStore

@Suite("PendingSettlement")
struct PendingSettlementTests {
    static let pk = DeletionScene.partkey
    static let key = DeletionScene.sessionKey
    /// 要求を書かずに ID だけを持たせるときの request_id
    static let manualID = "20260912T030000Z-8483e42457304a9d-abcdef"
    /// 決着の 2 つ目の遷移を DB で失敗させるトリガの名前
    static let blockTrigger = "f74_block_second_step"
    /// 既定の backoff（60, 300, 900, 3600）の段の数と合計
    static let backoffCount = 4
    static let backoffTotal = 4860
    static let otherRelpath = "TX_MIC001_20260912_100000/TX00_MIC001_20260912_100000_orig.wav"

    /// reaper の拒否（size_mismatch）で ID の無い SOURCE_DELETE_PENDING になった Part と、SOURCE_DELETING の Session
    static func pendingScene() throws -> DeletionScene {
        try DeletionScene(
            status: .sourceDeletePending, errorCode: .sourceIdentityMismatch, sessionStatus: .sourceDeleting)
    }

    static func stage(
        _ scene: DeletionScene, snapshot: DeviceSnapshot? = nil, streaks: UndeletableStreaks
    ) -> SessionDeletionStage {
        SessionDeletionStage(
            deps: scene.deletionDependencies(
                ingest: ScriptedIngest(snapshot: snapshot ?? scene.snapshot()), streaks: streaks))
    }

    /// 同じ連続回数の記録で times 回評価する
    static func evaluate(
        _ scene: DeletionScene, snapshot: DeviceSnapshot? = nil, streaks: UndeletableStreaks, times: Int = 2
    ) async {
        for _ in 0..<times {
            await Self.stage(scene, snapshot: snapshot, streaks: streaks).deleteSourcesIfSafe(sessionKey: Self.key)
        }
    }

    static func part(_ scene: DeletionScene) throws -> RecordingRow {
        try #require(try scene.store.recording(Self.pk))
    }

    static func session(_ scene: DeletionScene) throws -> SessionRow {
        try #require(try scene.store.session(Self.key))
    }

    static func events(_ scene: DeletionScene) throws -> [EventRow] {
        try scene.store.events(entity: .recording, key: Self.pk)
    }

    static func settledLog(_ scene: DeletionScene) -> Bool {
        scene.logLines.contains {
            $0.contains(" source_delete_skipped recording_key=" + Self.pk + " reason=not_deletable")
        }
    }

    static func settledParts(_ scene: DeletionScene) throws -> [RecordingRow] {
        let ro = try #require(ReadOnlyStore.open(url: scene.layout.database))
        return try ro.completedParts(lastDetail: DeletionReason.notDeletable)
    }

    /// canDeleteSource を偽にする（元ファイルはデバイスに在るまま。待っても変わらない原因）
    static func breakDeletability(_ scene: DeletionScene, _ cause: String) throws {
        switch cause {
        case "Raw ノートの手の編集":
            try scene.appendToRawNote("\n手で書き足した行\n")
        case "原本のサイズの食い違い":
            try scene.store.updateRecording(Self.pk, [.sourceSize(8192)])
        case "transcript の欠け":
            try FileManager.default.removeItem(at: scene.transcriptURL(Self.pk))
        default:
            try StorePaths.setSourcePath(scene.store, partkey: Self.pk, nil)
        }
    }

    /// 原因（表示名の語）→ 決着のときに記録される原因の語
    static let causeWords: [String: String] = [
        "Raw ノートの手の編集": "raw_note", "原本のサイズの食い違い": "pre_identity", "transcript の欠け": "transcript",
        "source_path が無い": "source_info",
    ]

    /// delete_attempts を attempts にし、Part を PENDING にした時刻（DeletionScene.now）から seconds 秒進める
    static func elapse(_ scene: DeletionScene, attempts: Int, seconds: Int) throws {
        try scene.store.updateSession(Self.key, [.deleteAttempts(attempts)])
        scene.clock.advance(seconds: seconds)
    }

    /// 決着せずに待った姿（Part は PENDING のまま、Session は SOURCE_DELETING のまま delete_attempts が evaluations 回増える）
    static func expectWaited(_ scene: DeletionScene, attempts: Int, evaluations: Int = 2) throws {
        let session = try Self.session(scene)
        #expect(session.status == .sourceDeleting)
        #expect(session.deleteAttempts == attempts + evaluations)
        let part = try Self.part(scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.errorCode == .sourceIdentityMismatch)
        #expect(part.sourceDeletedAt == nil)
        #expect(!Self.settledLog(scene))
        #expect(scene.requests() == [])
    }

    // MARK: - R1: ID の無い SOURCE_DELETE_PENDING の決着

    @Test(
        "F-74 ID の無い SOURCE_DELETE_PENDING も期限を過ぎ観測できた失敗が 2 回続いたら、消さずに PENDING→SOURCE_DELETING→COMPLETED（detail not_deletable・原因を記録）で Session も完了する（パラメータ化: 原因 4 つ）",
        arguments: ["Raw ノートの手の編集", "原本のサイズの食い違い", "transcript の欠け", "source_path が無い"])
    func pendingPartSettlesWithoutDeleting(_ cause: String) async throws {
        let scene = try Self.pendingScene()
        try Self.breakDeletability(scene, cause)
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        let streaks = UndeletableStreaks()
        // 1 回目は観測できた失敗が 1 回なので待つ
        await Self.evaluate(scene, streaks: streaks, times: 1)
        try Self.expectWaited(scene, attempts: Self.backoffCount, evaluations: 1)
        // 2 回目で決着
        await Self.evaluate(scene, streaks: streaks, times: 1)
        let word = try #require(Self.causeWords[cause])
        let part = try Self.part(scene)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt == nil)
        #expect(part.deleteRequestID == nil)
        #expect(part.errorCode == nil)
        #expect(part.errorMessage == word)
        let last2 = Array(try Self.events(scene).suffix(2))
        #expect(last2.map(\.fromStatus) == ["SOURCE_DELETE_PENDING", "SOURCE_DELETING"])
        #expect(last2.map(\.toStatus) == ["SOURCE_DELETING", "COMPLETED"])
        #expect(last2.map(\.detail) == ["not_deletable", "not_deletable"])
        #expect(
            scene.logLines.contains {
                $0.hasSuffix(" source_delete_skipped recording_key=" + Self.pk + " reason=not_deletable detail=" + word)
            })
        #expect(scene.requests() == [])
        // 元ファイルはデバイスに残る
        #expect(
            FileManager.default.fileExists(
                atPath: scene.deviceRoot.appendingPathComponent(DeletionScene.relpath).path(percentEncoded: false)))
        let session = try Self.session(scene)
        #expect(session.status == .completed)
        #expect(session.sourceDeletedAt == nil)
    }

    @Test("F-74 期限の前（PENDING にしてから backoff の合計に 1 秒足りない）は SOURCE_DELETE_PENDING のまま待つ")
    func pendingPartBeforeTheDeadlineWaits() async throws {
        let scene = try Self.pendingScene()
        try Self.breakDeletability(scene, "原本のサイズの食い違い")
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal - 1)
        await Self.evaluate(scene, streaks: UndeletableStreaks())
        try Self.expectWaited(scene, attempts: Self.backoffCount)
    }

    @Test("F-74 一覧に無い SOURCE_DELETE_PENDING は not_deletable で決着させない（F-78 で手順 4a が already_absent で完了させる）")
    func absentPendingIsNotSettled() async throws {
        let scene = try Self.pendingScene()
        try Self.breakDeletability(scene, "Raw ノートの手の編集")
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.evaluate(
            scene, snapshot: scene.snapshot(relpaths: [Self.otherRelpath]), streaks: UndeletableStreaks())
        #expect(!Self.settledLog(scene))
        #expect(try Self.settledParts(scene) == [])
        let part = try Self.part(scene)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt == nil)
        #expect(try Self.events(scene).last?.detail == "already_absent")
        #expect(scene.requests() == [])
    }

    @Test("F-74 SOURCE_DELETE_PENDING から決着した Part も要対応・状態の詳細に数え、「過去分を削除対象にする」で再評価され、原因が直れば対象になる")
    func settledPendingIsCountedAndRetargeted() async throws {
        let scene = try Self.pendingScene()
        try Self.breakDeletability(scene, "原本のサイズの食い違い")
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.evaluate(scene, streaks: UndeletableStreaks())
        // 数え方（要対応は一覧にまだ在るものだけ・状態の詳細は全部）
        let settled = try Self.settledParts(scene)
        #expect(settled.map(\.partkey) == [Self.pk])
        #expect(
            AttentionEvaluator.undeletableStillListed(settled, snapshot: scene.snapshot()).map(\.partkey) == [Self.pk])
        let report = StatusReporter.build(
            layout: scene.layout, config: scene.config, snapshot: scene.snapshot(), now: scene.clock.now(),
            zone: scene.zone)
        #expect(report.undeletableTotal == 1)
        let lines = report.lines
        let index = try #require(lines.firstIndex(of: "消せなかった録音（1 件。消さずに完了にしたもの）"))
        #expect(lines[index + 1] == "  " + Self.pk)
        #expect(lines[index + 2] == "    事前確認で原本が合わない（サイズ・時刻・場所）、デバイスに在る")
        // 後追い（COMPLETED の Session の COMPLETED の Part）で再評価される
        #expect(try Self.session(scene).status == .completed)
        let planner = BacklogPlanner(
            deps: scene.deletionDependencies(ingest: ScriptedIngest(snapshot: scene.snapshot())))
        let before = try await planner.planBacklog()
        #expect(before.eligible == [])
        #expect(before.skipped == [BacklogSkip(partkey: Self.pk, reason: DeletionReason.notDeletable)])
        // 原因を直す（DB の size を原本に戻す）
        try scene.store.updateRecording(Self.pk, [.sourceSize(4096)])
        let after = try await planner.planBacklog()
        #expect(after.eligible == [Self.pk])
    }

    @Test("F-74 PENDING の決着の 1 つ目の遷移が衝突したら status_changed を出して飛ばす（not_deletable のログも遷移も書かない）")
    func pendingSettleConflictLogsStatusChanged() async throws {
        let scene = try Self.pendingScene()
        let stale = try Self.part(scene)
        // 読んだ後に状態が変わった（別の経路で要求が書かれた）
        try scene.store.recordPartTransition(partkey: Self.pk, from: .sourceDeletePending, to: .sourceDeleting)
        let deps = scene.deletionDependencies(ingest: ScriptedIngest(snapshot: scene.snapshot()))
        DeletionRequester(deps: deps).settleAsNotDeletable(stale, cause: DeletionReason.causePreIdentity)
        #expect(
            scene.logLines.contains {
                $0.hasSuffix(" source_delete_skipped recording_key=" + Self.pk + " reason=status_changed")
            })
        #expect(!Self.settledLog(scene))
        #expect(!scene.logLines.contains { $0.contains(" config_warning ") })
        #expect(try Self.part(scene).status == .sourceDeleting)
        #expect(!(try Self.events(scene).contains { $0.detail == "not_deletable" }))
    }

    @Test("F-74 結果待ち（delete_request_id を持つ）SOURCE_DELETE_PENDING は、原因があり期限を過ぎていても決着させない（結果か期限切れを待つ）")
    func pendingAwaitingAResultIsNotSettled() async throws {
        let scene = try Self.pendingScene()
        try scene.store.updateRecording(Self.pk, [.deleteRequestID(Self.manualID)])
        try Self.breakDeletability(scene, "原本のサイズの食い違い")
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.evaluate(scene, streaks: UndeletableStreaks())
        let part = try Self.part(scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.deleteRequestID == Self.manualID)
        #expect(!Self.settledLog(scene))
        #expect(try Self.settledParts(scene) == [])
        #expect(try Self.session(scene).status == .sourceDeleting)
    }

    @Test("F-74 PENDING の決着の 2 遷移の間で落ちたら ID の無い SOURCE_DELETING が残るが、起動時の復旧が PENDING に戻し、次の評価で決着し直す")
    func interruptedSettleIsRecoveredAndSettledAgain() async throws {
        let scene = try Self.pendingScene()
        try Self.breakDeletability(scene, "原本のサイズの食い違い")
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        // 2 つ目の遷移（SOURCE_DELETING→COMPLETED）だけを DB で失敗させる（落ちた姿の代わり）
        try await scene.store.pool.write { db in
            try db.execute(
                sql: "CREATE TRIGGER " + Self.blockTrigger
                    + " BEFORE UPDATE OF status ON recordings WHEN OLD.status = '"
                    + PartStatus.sourceDeleting.rawValue + "' AND NEW.status = '" + PartStatus.completed.rawValue
                    + "' BEGIN SELECT RAISE(ABORT, 'f74'); END")
        }
        await Self.evaluate(scene, streaks: UndeletableStreaks())
        var part = try Self.part(scene)
        #expect(part.status == .sourceDeleting)
        #expect(part.deleteRequestID == nil)
        #expect(!Self.settledLog(scene))
        #expect(scene.logLines.contains { $0.contains(" config_warning rule=store ") })
        try await scene.store.pool.write { db in try db.execute(sql: "DROP TRIGGER " + Self.blockTrigger) }
        // 起動時の復旧（付録 A.1 の SOURCE_DELETING→SOURCE_DELETE_PENDING。Part と Session の 2 行）
        let recovery = Recovery(
            store: scene.store, layout: scene.layout, log: scene.log, config: scene.config, zone: scene.zone)
        #expect(try recovery.run() == 2)
        #expect(try Self.part(scene).status == .sourceDeletePending)
        #expect(try Self.session(scene).status == .sourceDeletePending)
        // 復旧で updated_at が進んだので期限をもう一度過ぎてから。連続回数はメモリなので 0 から数え直す
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.evaluate(scene, streaks: UndeletableStreaks())
        part = try Self.part(scene)
        #expect(part.status == .completed)
        #expect(part.errorMessage == "pre_identity")
        #expect(part.sourceDeletedAt == nil)
        #expect(try Self.events(scene).last?.detail == "not_deletable")
        #expect(try Self.settledParts(scene).map(\.partkey) == [Self.pk])
        #expect(try Self.session(scene).status == .completed)
    }

    // MARK: - R2: 調べ直して原因が見つからなければ決着させない

    @Test("F-74 決着の直前に調べ直して原因が見つからなければ決着させず（pre_identity にしない）、連続を切る")
    func noCauseFoundDoesNotSettleAndRestartsTheStreak() async throws {
        let scene = try DeletionScene()
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        let snapshot = scene.snapshot()
        let ctx = await scene.context(snapshot: snapshot)
        let deps = scene.deletionDependencies(ingest: ScriptedIngest(snapshot: snapshot))
        let requester = DeletionRequester(deps: deps)
        let session = try Self.session(scene)
        // 消せる Part（全部の検査が通る）。原因の語は無い
        let healthy = try Self.part(scene)
        let parts = try scene.store.recordings(inSession: Self.key)
        #expect(DeletionRequester.undeletableCause(healthy, session: session, parts: parts, ctx: ctx) == nil)
        // 期限を過ぎ、観測できた失敗として 2 回数えても、原因が無いので決着しない
        for _ in 0..<2 {
            requester.considerSettling(healthy, session: session, parts: parts, snapshot: snapshot, ctx: ctx)
        }
        #expect(try Self.part(scene).status == .rawSaved)
        #expect(!Self.settledLog(scene))
        // 連続は切れている: 原因ができても 1 回目では決着せず、2 回目で決着する
        try Self.breakDeletability(scene, "Raw ノートの手の編集")
        let broken = try Self.part(scene)
        requester.considerSettling(broken, session: session, parts: parts, snapshot: snapshot, ctx: ctx)
        #expect(try Self.part(scene).status == .rawSaved)
        #expect(!Self.settledLog(scene))
        requester.considerSettling(broken, session: session, parts: parts, snapshot: snapshot, ctx: ctx)
        let settled = try Self.part(scene)
        #expect(settled.status == .completed)
        #expect(settled.errorMessage == "raw_note")
    }

    // MARK: - R6: 連続回数の記録の配線

    @Test("F-74 Worker は tick をまたいで同じ連続回数の記録を TickContext と削除の段の依存に渡す")
    func workerSharesOneStreakRecordAcrossTicks() async throws {
        let w = try await PipelineWorld.make()
        let worker = w.worker()
        let config = try #require(await w.configStore.current())
        let first = await worker.makeContext(config, Worker.zone(for: config), snapshot: nil)
        let second = await worker.makeContext(config, Worker.zone(for: config), snapshot: nil)
        #expect(DeletionDependencies(ctx: first).streaks.record(Self.pk, connectEpoch: 1) == 1)
        #expect(DeletionDependencies(ctx: second).streaks.record(Self.pk, connectEpoch: 1) == 2)
        #expect(second.undeletableStreaks.record(Self.pk, connectEpoch: 1) == 3)
    }
}
