// 一覧に無い、ID の無い SOURCE_DELETE_PENDING の自動の完了（PLAN §8.9.5 の手順 4a。F-78・issue #124）。
// 手で原本を消した後などで元ファイルが一覧に無くなった PENDING を、RAW_SAVED の F-64 と同じ観測の条件で、
// 「手動で消した分を完了にする」と同じ 2 遷移（resolve_absent → already_absent）で完了させ、Session も完了させる。
// source_deleted_at は入れない（アプリが消したのではない）。舞台は DeletionScene（/Volumes には触れない）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

@Suite("AbsentPendingCompletion")
struct AbsentPendingCompletionTests {
    static let pk = DeletionScene.partkey
    static let key = DeletionScene.sessionKey
    /// 要求を書かずに ID だけを持たせるときの request_id
    static let manualID = "20260912T030000Z-8483e42457304a9d-abcdef"
    /// 取り残しの結果の request_id（ID の無い Part には対応する試行が無い）
    static let strayID = "20260912T020000Z-8483e42457304a9d-fedcba"
    /// 既定の Part とは別の録音（一覧には在る。デバイスは接続中で列挙できている姿）
    static let otherRelpath = "TX_MIC001_20260912_100000/TX00_MIC001_20260912_100000_orig.wav"
    static let otherPK = "DJIMIC3/TX_MIC001_20260912_100000/TX00_MIC001_20260912_100000_orig.wav"
    static let otherID = "20260912T020000Z-0123456789abcdef-012345"

    /// reaper の拒否（size_mismatch）で ID の無い SOURCE_DELETE_PENDING になった Part と、SOURCE_DELETING の Session。
    /// Part を PENDING にした時刻（updated_at）は DeletionScene.now
    static func pendingScene() throws -> DeletionScene {
        try DeletionScene(
            status: .sourceDeletePending, errorCode: .sourceIdentityMismatch, sessionStatus: .sourceDeleting)
    }

    /// PENDING にした後の、既定の Part が一覧に無い走査（時計を 60 秒進める）
    static func absentSnapshot(_ scene: DeletionScene, relpaths: Set<String>? = nil) -> DeviceSnapshot {
        scene.clock.advance(seconds: 60)
        return scene.snapshot(relpaths: relpaths ?? [Self.otherRelpath])
    }

    static func deps(_ scene: DeletionScene, snapshot: DeviceSnapshot) -> DeletionDependencies {
        scene.deletionDependencies(ingest: ScriptedIngest(snapshot: snapshot))
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

    static func absentLog(_ scene: DeletionScene) -> Bool {
        scene.logLines.contains {
            $0.hasSuffix(" source_delete_skipped recording_key=" + Self.pk + " reason=already_absent")
        }
    }

    static func settledParts(_ scene: DeletionScene) throws -> [RecordingRow] {
        let ro = try #require(ReadOnlyStore.open(url: scene.layout.database))
        return try ro.completedParts(lastDetail: DeletionReason.notDeletable)
    }

    /// 一覧に無いと観測できて完了した姿（F-78。「手動で消した分を完了にする」と同じ 2 遷移。Session も完了する）
    static func expectCompletedAsAbsent(_ scene: DeletionScene) throws {
        #expect(scene.requests() == [])
        let part = try Self.part(scene)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt == nil)
        #expect(part.deleteRequestID == nil)
        #expect(part.errorCode == nil)
        let last2 = Array(try Self.events(scene).suffix(2))
        #expect(last2.map(\.fromStatus) == ["SOURCE_DELETE_PENDING", "SOURCE_DELETING"])
        #expect(last2.map(\.toStatus) == ["SOURCE_DELETING", "COMPLETED"])
        #expect(last2.map(\.detail) == ["resolve_absent", "already_absent"])
        #expect(Self.absentLog(scene))
        let session = try Self.session(scene)
        #expect(session.status == .completed)
        #expect(session.sourceDeletedAt == nil)
        #expect(session.deleteAttempts == 0)
    }

    @Test(
        "F-78 一覧に無い、ID の無い SOURCE_DELETE_PENDING は要求を書かずに →SOURCE_DELETING（resolve_absent）→COMPLETED（already_absent）で完了し、Session も完了する（source_deleted_at は入れない）"
    )
    func absentPendingCompletesWithoutRequest() async throws {
        let scene = try Self.pendingScene()
        let snapshot = Self.absentSnapshot(scene)
        await SessionDeletionStage(deps: Self.deps(scene, snapshot: snapshot)).deleteSourcesIfSafe(
            sessionKey: Self.key)
        try Self.expectCompletedAsAbsent(scene)
        // 元ファイルには触れない（偽のボリュームには残っている。一覧に無いのは観測の上だけ）
        #expect(
            FileManager.default.fileExists(
                atPath: scene.deviceRoot.appendingPathComponent(DeletionScene.relpath).path(percentEncoded: false)))
        // 「消せなかった録音」（detail not_deletable）には数えない
        #expect(try Self.settledParts(scene) == [])
        #expect(!scene.logLines.contains { $0.contains(" reason=not_deletable") })
        // 「手動で消した分を完了にする」の対象にも残らない
        let plan = try await BacklogPlanner(deps: Self.deps(scene, snapshot: snapshot)).planResolveAbsent()
        #expect(plan.eligible == [])
        #expect(plan.skipped == [])
    }

    @Test("F-78 TEST-28 一覧が空（録音 0 件）でも、接続中で列挙できていれば ID の無い SOURCE_DELETE_PENDING は完了する")
    func emptyListingCompletesPending() async throws {
        let scene = try Self.pendingScene()
        let snapshot = Self.absentSnapshot(scene, relpaths: [])
        await SessionDeletionStage(deps: Self.deps(scene, snapshot: snapshot)).deleteSourcesIfSafe(
            sessionKey: Self.key)
        try Self.expectCompletedAsAbsent(scene)
    }

    @Test(
        "F-78 無いと観測できなければ ID の無い SOURCE_DELETE_PENDING を完了にしない（パラメータ化: 未接続・列挙できない・unavailable が観測より優先・snapshot が古い・source_path が無い）",
        arguments: ["未接続", "列挙できない", "unavailable が優先", "snapshot が古い", "source_path が無い"])
    func unobservedAbsenceKeepsPending(_ condition: String) async throws {
        let scene = try Self.pendingScene()
        let eventsBefore = try Self.events(scene).count
        // 以下の snapshot は（古いものも）PENDING にした後の走査
        let listed = Self.absentSnapshot(scene)
        let snapshot: DeviceSnapshot
        switch condition {
        case "未接続":
            snapshot = scene.snapshot(relpaths: [Self.otherRelpath], includeDevice: false)
        case "列挙できない":
            // IngestService の姿: 一覧が不完全なデバイスは devices に載せず unavailable に載せる
            snapshot = DeviceSnapshot(
                generation: 1, completedAt: scene.clock.now(), connectEpoch: 1, devices: [:],
                unavailable: [scene.deviceID: "not_listable"], notListableErrno: [:])
        case "unavailable が優先":
            snapshot = DeviceSnapshot(
                generation: 1, completedAt: scene.clock.now(), connectEpoch: 1, devices: listed.devices,
                unavailable: [scene.deviceID: "not_listable"], notListableErrno: [:])
        case "snapshot が古い":
            // PENDING の後の走査だが、評価の時点では 901 秒たっている
            snapshot = listed
            scene.clock.advance(seconds: 901)
        default:
            try StorePaths.setSourcePath(scene.store, partkey: Self.pk, nil)
            snapshot = listed
        }
        await SessionDeletionStage(deps: Self.deps(scene, snapshot: snapshot)).deleteSourcesIfSafe(
            sessionKey: Self.key)
        let part = try Self.part(scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.errorCode == .sourceIdentityMismatch)
        #expect(part.sourceDeletedAt == nil)
        #expect(try Self.events(scene).count == eventsBefore)
        #expect(!Self.absentLog(scene))
        #expect(scene.requests() == [])
        let session = try Self.session(scene)
        #expect(session.status == .sourceDeleting)
        #expect(session.deleteAttempts == 1)
    }

    @Test(
        "F-78 PENDING にする前・同じ秒の snapshot では完了にしない（updated_at は秒に切り捨て。境界: ちょうど 1 秒後なら完了）",
        arguments: [(Int64(-60_000), false), (0, false), (999, false), (1000, true)])
    func snapshotBeforePendingDoesNotComplete(_ offsetMillis: Int64, _ completes: Bool) async throws {
        let scene = try Self.pendingScene()
        scene.clock.advance(seconds: 60)
        let snapshot = scene.snapshot(
            relpaths: [Self.otherRelpath], completedAt: DeletionScene.now.adding(milliseconds: offsetMillis))
        #expect(
            await DeletionRequester(deps: Self.deps(scene, snapshot: snapshot)).requestDeletions(sessionKey: Self.key)
                == 0)
        #expect(try Self.part(scene).status == (completes ? .completed : .sourceDeletePending))
        #expect(Self.absentLog(scene) == completes)
        #expect(scene.requests() == [])
    }

    @Test("F-78 結果待ち（delete_request_id を持つ）SOURCE_DELETE_PENDING は一覧に無くても自動で完了にしない（結果か期限切れを待つ）")
    func absentPendingAwaitingAResultIsNotCompleted() async throws {
        let scene = try Self.pendingScene()
        try scene.store.updateRecording(Self.pk, [.deleteRequestID(Self.manualID)])
        let snapshot = Self.absentSnapshot(scene)
        #expect(
            await DeletionRequester(deps: Self.deps(scene, snapshot: snapshot)).requestDeletions(sessionKey: Self.key)
                == 0)
        let part = try Self.part(scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.deleteRequestID == Self.manualID)
        #expect(!Self.absentLog(scene))
    }

    @Test("F-78 完了のとき、同じ Part の取り残しの要求・結果を取り下げる（「手動で消した分を完了にする」と同じ。ほかの Part の結果は残す）")
    func strayRequestAndResultAreWithdrawn() async throws {
        let scene = try Self.pendingScene()
        // 取り残しの要求（書いた後に ID だけが外れた姿）と結果、ほかの Part の結果
        let writerDeps = Self.deps(scene, snapshot: scene.snapshot())
        let row = try Self.part(scene)
        #expect(try RequestWriter(deps: writerDeps).write(part: row, sessionKey: Self.key) != nil)
        try scene.store.updateRecording(Self.pk, [.deleteRequestID(nil)])
        try scene.writeResult(
            partkey: Self.pk, requestID: Self.strayID, status: .sourceIdentityMismatch, detail: "size_mismatch")
        let other = try scene.writeResult(
            partkey: Self.otherPK, requestID: Self.otherID, status: .sourceIdentityMismatch, detail: "size_mismatch")
        #expect(scene.requests().count == 1)
        #expect(scene.results().count == 2)
        let snapshot = Self.absentSnapshot(scene)
        #expect(
            await DeletionRequester(deps: Self.deps(scene, snapshot: snapshot)).requestDeletions(sessionKey: Self.key)
                == 0)
        #expect(try Self.part(scene).status == .completed)
        #expect(scene.requests() == [])
        #expect(scene.results().map(\.lastPathComponent) == [other.lastPathComponent])
        #expect(Self.absentLog(scene))
    }

    @Test("F-78 failureIsObserved は元ファイルが一覧に無ければ偽（(d)。評価の経路では手順 4a が先に完了させる防御。一覧に在れば真）")
    func failureIsNotObservedWhenTheSourceIsNotListed() async throws {
        let scene = try Self.pendingScene()
        let part = try Self.part(scene)
        let parts = try scene.store.recordings(inSession: Self.key)
        // 正の対照: 一覧に在る（ほかの条件 a〜c も満たす）
        let listed = scene.snapshot()
        let listedContext = await scene.context(snapshot: listed)
        #expect(DeletionRequester.failureIsObserved(part, parts: parts, snapshot: listed, ctx: listedContext))
        // 一覧に無い（接続中で列挙できている）
        let absent = scene.snapshot(relpaths: [Self.otherRelpath])
        let absentContext = await scene.context(snapshot: absent)
        #expect(!DeletionRequester.failureIsObserved(part, parts: parts, snapshot: absent, ctx: absentContext))
    }

    @Test("F-78 PENDING の完了の 1 つ目の遷移が衝突したら status_changed を出して飛ばす（already_absent のログも遷移も書かない）")
    func absentCompletionConflictLogsStatusChanged() async throws {
        let scene = try Self.pendingScene()
        let stale = try Self.part(scene)
        // 読んだ後に状態が変わった（別の経路で要求が書かれた）
        try scene.store.recordPartTransition(partkey: Self.pk, from: .sourceDeletePending, to: .sourceDeleting)
        let deps = Self.deps(scene, snapshot: Self.absentSnapshot(scene))
        try DeletionRequester(deps: deps).completeAsAbsent(stale)
        #expect(
            scene.logLines.contains {
                $0.hasSuffix(" source_delete_skipped recording_key=" + Self.pk + " reason=status_changed")
            })
        #expect(!Self.absentLog(scene))
        #expect(!scene.logLines.contains { $0.contains(" config_warning ") })
        #expect(try Self.part(scene).status == .sourceDeleting)
        #expect(!(try Self.events(scene).contains { $0.detail == "resolve_absent" || $0.detail == "already_absent" }))
    }
}
