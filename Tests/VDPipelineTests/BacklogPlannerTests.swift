// 後追いの計画と実行（PLAN §8.9.9。T-41 §6.1）。判定は DeletionPolicy.canDeleteSource だけ。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

/// reply を順に覚える（何回呼ばれたかを見る）。
final class BacklogReplies<Value: Sendable & Equatable>: Sendable {
    private let recorded = Mutex<[Result<Value, BacklogFailure>]>([])

    var reply: @Sendable (Result<Value, BacklogFailure>) -> Void {
        { r in self.recorded.withLock { $0.append(r) } }
    }

    var results: [Result<Value, BacklogFailure>] { recorded.withLock { $0 } }
}

@Suite("BacklogPlanner")
struct BacklogPlannerTests {
    /// 結果待ちの request_id（要求は書かない）
    static let manualID = "20260912T030000Z-8483e42457304a9d-abcdef"
    static let tenOClock = "2026-09-12T10:00:00+09:00"
    static let elevenOClock = "2026-09-12T11:00:00+09:00"
    static let tenFile = "TX00_MIC001_20260912_100000_orig.wav"
    static let elevenFile = "TX00_MIC001_20260912_110000_orig.wav"

    struct Fixture {
        let scene: DeletionScene
        let ingest: ScriptedIngest

        var planner: BacklogPlanner { BacklogPlanner(deps: scene.deletionDependencies(ingest: ingest)) }
        var pk: String { scene.partkey }
    }

    /// 過去分の舞台（Raw ノート・transcript・デバイス上の原本がそろい、三重ロックが外れている）
    static func backlogStage() throws -> Fixture {
        let scene = try DeletionScene(status: .completed, sessionStatus: .completed)
        return Fixture(scene: scene, ingest: ScriptedIngest(snapshot: scene.snapshot()))
    }

    /// PENDING の Part（ファイルはデバイスに在る）
    static func pendingScene() throws -> DeletionScene {
        try DeletionScene(status: .sourceDeletePending, errorCode: .sourceIdentityMismatch, sessionStatus: .completed)
    }

    /// 手動で消した分の舞台（デバイスは在り、ファイルが無い）
    static func absentStage() throws -> Fixture {
        let scene = try pendingScene()
        return Fixture(scene: scene, ingest: ScriptedIngest(snapshot: scene.snapshot(relpaths: [])))
    }

    static func part(_ scene: DeletionScene, _ pk: String) throws -> RecordingRow {
        try #require(try scene.store.recording(pk))
    }

    static func events(_ scene: DeletionScene, _ pk: String) throws -> [EventRow] {
        try scene.store.events(entity: .recording, key: pk)
    }

    static func logged(_ scene: DeletionScene, _ body: String, level: String) -> Bool {
        scene.logLines.contains { $0.contains(" " + level + " ") && $0.hasSuffix(" " + body) }
    }

    // MARK: - 過去分の計画

    @Test("過去分: COMPLETED の Session の COMPLETED の Part で式が真なら対象（TEST-20: 対象 1 件以上で試す）")
    func planListsCompletedPartsThatPassTheFormula() async throws {
        let f = try Self.backlogStage()
        let plan = try await f.planner.planBacklog()
        #expect(plan.eligible == [f.pk])
        #expect(plan.skipped == [])
    }

    @Test("SOURCE_DELETE_PENDING の Part も対象")
    func planIncludesPendingParts() async throws {
        let scene = try Self.pendingScene()
        let f = Fixture(scene: scene, ingest: ScriptedIngest(snapshot: scene.snapshot()))
        let plan = try await f.planner.planBacklog()
        #expect(plan.eligible == [f.pk])
    }

    @Test("source_deleted_at が在れば already_deleted")
    func alreadyDeletedIsSkipped() async throws {
        let f = try Self.backlogStage()
        try f.scene.store.updateRecording(f.pk, [.sourceDeletedAt("2026-09-12T10:00:00+09:00")])
        let plan = try await f.planner.planBacklog()
        #expect(plan.eligible == [])
        #expect(plan.skipped == [BacklogSkip(partkey: f.pk, reason: "already_deleted")])
    }

    @Test(
        "式が偽なら not_deletable（パラメータ化: デバイスに無い・Raw の鍵が無い・ロック 1 が偽）",
        arguments: ["absentOnDevice", "rawKeyMissing", "lock1Off"])
    func formulaFalseIsNotDeletable(_ breakage: String) async throws {
        let f = try Self.backlogStage()
        switch breakage {
        case "absentOnDevice":
            await f.ingest.setSnapshot(f.scene.snapshot(relpaths: []))
        case "rawKeyMissing":
            try f.scene.replaceInRawNote(f.pk, with: f.scene.deviceID + "/other/other.wav", updateSHA: true)
        default:
            f.scene.updateConfig { $0.cleanup.deleteSourceAudio = false }
        }
        let plan = try await f.planner.planBacklog()
        #expect(plan.eligible == [])
        #expect(plan.skipped == [BacklogSkip(partkey: f.pk, reason: "not_deletable")])
    }

    @Test("結果待ち（ID が在る）は二重に要求しない")
    func awaitingResultIsNotDeletable() async throws {
        let f = try Self.backlogStage()
        try f.scene.store.updateRecording(f.pk, [.deleteRequestID(Self.manualID)])
        let plan = try await f.planner.planBacklog()
        #expect(plan.eligible == [])
        #expect(plan.skipped == [BacklogSkip(partkey: f.pk, reason: "not_deletable")])
    }

    @Test("snapshot が古ければ not_deletable")
    func staleSnapshotMakesEverythingNotDeletable() async throws {
        let f = try Self.backlogStage()
        await f.ingest.setSnapshot(f.scene.snapshot(completedAt: DeletionScene.now.adding(seconds: -901)))
        let plan = try await f.planner.planBacklog()
        #expect(plan.eligible == [])
        #expect(plan.skipped == [BacklogSkip(partkey: f.pk, reason: "not_deletable")])
    }

    @Test(
        "COMPLETED でない Session の Part は見ない（パラメータ化: SAVED・SOURCE_DELETING）",
        arguments: [SessionStatus.saved, .sourceDeleting])
    func onlyCompletedSessionsAreConsidered(_ sessionStatus: SessionStatus) async throws {
        let scene = try DeletionScene(status: .completed, sessionStatus: sessionStatus)
        let f = Fixture(scene: scene, ingest: ScriptedIngest(snapshot: scene.snapshot()))
        let plan = try await f.planner.planBacklog()
        #expect(plan.eligible == [])
        #expect(plan.skipped == [])
    }

    @Test("対象の状態は COMPLETED と SOURCE_DELETE_PENDING だけ")
    func onlyCompletedOrPendingPartsAreConsidered() async throws {
        let f = try Self.backlogStage()
        try f.scene.addPart(
            fileName: Self.tenFile, startedAt: Self.tenOClock, status: .skipped, errorCode: .noSpeechDetected)
        try f.scene.addPart(
            fileName: Self.elevenFile, startedAt: Self.elevenOClock, status: .failed, errorCode: .whisperFailed)
        let plan = try await f.planner.planBacklog()
        #expect(plan.eligible == [f.pk])
        #expect(plan.skipped == [])
    }

    @Test("COMPLETED の Session が無ければ空（TEST-28）")
    func emptyDatabasePlansNothing() async throws {
        let scene = try DeletionScene()
        let f = Fixture(scene: scene, ingest: ScriptedIngest(snapshot: scene.snapshot()))
        let plan = try await f.planner.planBacklog()
        #expect(plan.eligible == [])
        #expect(plan.skipped == [])
    }

    // MARK: - 過去分の実行

    @Test("TEST-20 プレビューは何も書かない（対象 1 件以上で）")
    func previewWritesNothing() async throws {
        let f = try Self.backlogStage()
        let eventsBefore = try Self.events(f.scene, f.pk).count
        let linesBefore = f.scene.logLines.count
        let replies = BacklogReplies<BacklogPlan>()
        await f.planner.handle(.preview(reply: replies.reply), kind: .backlog)
        #expect(replies.results == [.success(BacklogPlan(eligible: [f.pk], skipped: []))])
        #expect(f.scene.requests() == [])
        #expect(try Self.part(f.scene, f.pk).status == .completed)
        #expect(try Self.events(f.scene, f.pk).count == eventsBefore)
        #expect(f.scene.logLines.count == linesBefore)
    }

    @Test("実行は ID → 要求 → COMPLETED→SOURCE_DELETING")
    func executeRequestsAndTransitions() async throws {
        let f = try Self.backlogStage()
        let replies = BacklogReplies<BacklogExecution>()
        await f.planner.handle(.execute(reply: replies.reply), kind: .backlog)
        #expect(
            replies.results == [
                .success(BacklogExecution(plan: BacklogPlan(eligible: [f.pk], skipped: []), done: 1))
            ])
        let part = try Self.part(f.scene, f.pk)
        let id = try #require(part.deleteRequestID)
        let requests = f.scene.requests()
        #expect(requests.map(\.lastPathComponent) == [id + ".json"])
        let request = try ContractJSON.decodeRequest(try Data(contentsOf: try #require(requests.first))).get()
        #expect(request.partkey == f.pk)
        #expect(request.requestID == id)
        #expect(part.status == .sourceDeleting)
        let last = try #require(try Self.events(f.scene, f.pk).last)
        #expect(last.fromStatus == "COMPLETED")
        #expect(last.toStatus == "SOURCE_DELETING")
        #expect(
            Self.logged(
                f.scene,
                "delete_requested request_id=" + id + " recording_key=" + f.pk + " session_key=" + f.scene.sessionKey,
                level: "INFO"))
    }

    @Test("PENDING からは SOURCE_DELETE_PENDING→SOURCE_DELETING")
    func executeFromPending() async throws {
        let scene = try Self.pendingScene()
        let f = Fixture(scene: scene, ingest: ScriptedIngest(snapshot: scene.snapshot()))
        let replies = BacklogReplies<BacklogExecution>()
        await f.planner.handle(.execute(reply: replies.reply), kind: .backlog)
        #expect(
            replies.results == [
                .success(BacklogExecution(plan: BacklogPlan(eligible: [f.pk], skipped: []), done: 1))
            ])
        let last = try #require(try Self.events(f.scene, f.pk).last)
        #expect(last.fromStatus == "SOURCE_DELETE_PENDING")
        #expect(last.toStatus == "SOURCE_DELETING")
    }

    @Test("DEL-19 計画の後に状態が変わった Part は status_changed で飛ばし、残りを続ける")
    func statusChangeDuringExecutionContinues() async throws {
        let f = try Self.backlogStage()
        let sibling = try f.scene.addPart(fileName: Self.tenFile, startedAt: Self.tenOClock, status: .completed)
        try f.scene.writeRawNote()
        // デバイスに置いた兄弟も snapshot に載せる
        await f.ingest.setSnapshot(f.scene.snapshot())
        let plan = try await f.planner.planBacklog()
        #expect(plan.eligible == [f.pk, sibling])
        try f.scene.store.recordPartTransition(partkey: f.pk, from: .completed, to: .sourceDeleting)
        #expect(try await f.planner.executeBacklog(plan) == 1)
        let row = try Self.part(f.scene, sibling)
        #expect(row.status == .sourceDeleting)
        let id = try #require(row.deleteRequestID)
        #expect(f.scene.requests().map(\.lastPathComponent) == [id + ".json"])
        #expect(
            Self.logged(
                f.scene, "source_delete_skipped recording_key=" + f.pk + " reason=status_changed", level: "WARNING"))
    }

    @Test("後追いで SOURCE_DELETING にした Part も全件回収で完了する（voicedock の欠陥を直した）")
    func executedPartsAreCollected() async throws {
        let f = try Self.backlogStage()
        let deps = f.scene.deletionDependencies(ingest: f.ingest)
        let replies = BacklogReplies<BacklogExecution>()
        await BacklogPlanner(deps: deps).handle(.execute(reply: replies.reply), kind: .backlog)
        let id = try #require(try Self.part(f.scene, f.pk).deleteRequestID)
        try f.scene.writeResult(partkey: f.pk, requestID: id, status: .deleted, detail: DeletionScene.relpath)
        await f.ingest.setSnapshot(f.scene.snapshot(generation: 2, relpaths: []))
        await ResultCollector(deps: deps).collectDeleteResults(reaperScanGeneration: 2)
        let part = try Self.part(f.scene, f.pk)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt != nil)
        #expect(try f.scene.store.session(f.scene.sessionKey)?.status == .completed)
    }

    // MARK: - 手動で消した分

    @Test("手動で消した分: 新鮮な snapshot にデバイスが在り relpath が無い PENDING が対象")
    func resolveAbsentPlansGoneFiles() async throws {
        let f = try Self.absentStage()
        let plan = try await f.planner.planResolveAbsent()
        #expect(plan.eligible == [f.pk])
        #expect(plan.skipped == [])
    }

    @Test(
        "デバイスが無い・snapshot が古い・無いなら device_absent（パラメータ化。未接続を「無い」と判定しない）",
        arguments: ["noDevice", "stale", "nil"])
    func resolveAbsentNeedsTheDevice(_ observation: String) async throws {
        let f = try Self.absentStage()
        switch observation {
        case "noDevice": await f.ingest.setSnapshot(f.scene.snapshot(includeDevice: false))
        case "stale":
            await f.ingest.setSnapshot(
                f.scene.snapshot(relpaths: [], completedAt: DeletionScene.now.adding(seconds: -901)))
        default: await f.ingest.setSnapshot(nil)
        }
        let plan = try await f.planner.planResolveAbsent()
        #expect(plan.eligible == [])
        #expect(plan.skipped == [BacklogSkip(partkey: f.pk, reason: "device_absent")])
    }

    @Test("relpath が在れば still_present")
    func resolveAbsentLeavesPresentFiles() async throws {
        let f = try Self.absentStage()
        await f.ingest.setSnapshot(f.scene.snapshot())
        let plan = try await f.planner.planResolveAbsent()
        #expect(plan.eligible == [])
        #expect(plan.skipped == [BacklogSkip(partkey: f.pk, reason: "still_present")])
    }

    @Test("source_path が無ければ「無い」と確かめられない")
    func resolveAbsentWithoutSourcePathIsStillPresent() async throws {
        let f = try Self.absentStage()
        try StorePaths.setSourcePath(f.scene.store, partkey: f.pk, nil)
        let plan = try await f.planner.planResolveAbsent()
        #expect(plan.eligible == [])
        #expect(plan.skipped == [BacklogSkip(partkey: f.pk, reason: "still_present")])
    }

    @Test("実行: 2 遷移で COMPLETED、source_deleted_at を入れず、要求・結果を取り下げ ID を外す")
    func resolveAbsentCompletesWithoutDeletionTime() async throws {
        let f = try Self.absentStage()
        let id = Self.manualID
        try f.scene.store.updateRecording(f.pk, [.deleteRequestID(id)])
        try DeleteQueue.write(
            DeleteRequest(
                requestID: id, createdAt: "2026-09-12T12:00:00+09:00", deviceID: f.scene.deviceID, partkey: f.pk,
                sessionKey: f.scene.sessionKey,
                target: DeleteTarget(relpath: DeletionScene.relpath, size: 4096, mtime: DeletionScene.sourceMtime)),
            layout: f.scene.layout)
        try f.scene.writeResult(
            partkey: f.pk, requestID: id, status: .sourceIdentityMismatch, detail: DeletionScene.relpath)
        #expect(f.scene.requests().count == 1)
        #expect(f.scene.results().count == 1)
        let replies = BacklogReplies<BacklogExecution>()
        await f.planner.handle(.execute(reply: replies.reply), kind: .resolveAbsent)
        #expect(
            replies.results == [
                .success(BacklogExecution(plan: BacklogPlan(eligible: [f.pk], skipped: []), done: 1))
            ])
        let part = try Self.part(f.scene, f.pk)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt == nil)
        #expect(part.deleteRequestID == nil)
        let events = try Self.events(f.scene, f.pk)
        #expect(events.suffix(2).map(\.detail) == ["resolve_absent", "already_absent"])
        #expect(f.scene.requests() == [])
        #expect(f.scene.results() == [])
        #expect(
            Self.logged(
                f.scene, "source_delete_skipped recording_key=" + f.pk + " reason=already_absent", level: "INFO"))
    }

    @Test("DEL-19 手動で消した分も状態が変わった Part を飛ばして続ける")
    func resolveAbsentStatusChangeContinues() async throws {
        let f = try Self.absentStage()
        let sibling = try f.scene.addPart(
            fileName: Self.tenFile, startedAt: Self.tenOClock, status: .sourceDeletePending,
            errorCode: .sourceIdentityMismatch, onDevice: false)
        let plan = try await f.planner.planResolveAbsent()
        #expect(plan.eligible == [f.pk, sibling])
        try f.scene.store.recordPartTransition(partkey: f.pk, from: .sourceDeletePending, to: .sourceDeleting)
        #expect(try await f.planner.executeResolveAbsent(plan) == 1)
        #expect(try Self.part(f.scene, sibling).status == .completed)
        #expect(
            Self.logged(
                f.scene, "source_delete_skipped recording_key=" + f.pk + " reason=status_changed", level: "WARNING"))
    }

    @Test("実行の時点で在ることが分かれば完了にしない")
    func resolveAbsentRechecksAbsence() async throws {
        let f = try Self.absentStage()
        let plan = try await f.planner.planResolveAbsent()
        #expect(plan.eligible == [f.pk])
        await f.ingest.setSnapshot(f.scene.snapshot())
        #expect(try await f.planner.executeResolveAbsent(plan) == 0)
        #expect(try Self.part(f.scene, f.pk).status == .sourceDeletePending)
    }

    @Test("PENDING が無ければ空（TEST-28）")
    func emptyPendingPlansNothing() async throws {
        let f = try Self.backlogStage()
        let plan = try await f.planner.planResolveAbsent()
        #expect(plan.eligible == [])
        #expect(plan.skipped == [])
    }
}
