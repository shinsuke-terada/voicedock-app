// 結果の回収と pend（PLAN §8.9.6。同じ秒問題を generation で消す。T-38 §6.5）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

@Suite("ResultCollector")
struct ResultCollectorTests {
    static let pk = DeletionScene.partkey
    /// 要求を書かずに ID だけを持たせるときの request_id
    static let manualID = "20260912T030000Z-8483e42457304a9d-abcdef"

    struct Fixture {
        let scene: DeletionScene
        let ingest: ScriptedIngest
        let deps: DeletionDependencies
        let pended: PendedPartkeys
    }

    static func fixture(_ scene: DeletionScene) async -> Fixture {
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        let pended = PendedPartkeys()
        return Fixture(
            scene: scene, ingest: ingest, deps: scene.deletionDependencies(ingest: ingest, pended: pended),
            pended: pended)
    }

    /// 要求を 1 件書いた状態。request_id を返す
    static func requestOne(_ f: Fixture) async throws -> String {
        #expect(await DeletionRequester(deps: f.deps).requestDeletions(sessionKey: DeletionScene.sessionKey) == 1)
        return try #require(try part(f.scene).deleteRequestID)
    }

    /// 消えた後の走査にして collect(2)
    static func collectAfterScan(_ f: Fixture, snapshot: DeviceSnapshot? = nil) async {
        await f.ingest.setSnapshot(snapshot ?? f.scene.snapshot(generation: 2, relpaths: []))
        await ResultCollector(deps: f.deps).collectDeleteResults(reaperScanGeneration: 2)
    }

    static func deleted(_ f: Fixture, _ id: String) throws {
        try f.scene.writeResult(partkey: pk, requestID: id, status: .deleted, detail: DeletionScene.relpath)
    }

    static func part(_ scene: DeletionScene) throws -> RecordingRow {
        try #require(try scene.store.recording(pk))
    }

    static func events(_ scene: DeletionScene) throws -> [EventRow] {
        try scene.store.events(entity: .recording, key: pk)
    }

    static func logged(_ scene: DeletionScene, _ body: String) -> Bool {
        scene.logLines.contains { $0.hasSuffix(" " + body) }
    }

    @Test("DELETED で、reaper の後の走査に無ければ COMPLETED")
    func deletedCompletesThePart() async throws {
        let f = await Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        try Self.deleted(f, id)
        await Self.collectAfterScan(f)
        let part = try Self.part(f.scene)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt == "2026-09-12T12:00:00+09:00")
        #expect(part.deleteRequestID == nil)
        #expect(f.scene.results() == [])
        #expect(Self.logged(f.scene, "source_deleted recording_key=" + Self.pk + " request_id=" + id))
    }

    @Test(
        "RAW_SAVED・SOURCE_DELETE_PENDING で待っていた Part は 2 遷移で完了（パラメータ化）",
        arguments: [PartStatus.rawSaved, .sourceDeletePending])
    func deletedFromRawSavedOrPendingTakesTwoSteps(_ status: PartStatus) async throws {
        let f = await Self.fixture(try DeletionScene())
        if status == .sourceDeletePending {
            try f.scene.movePart(Self.pk, to: .sourceDeletePending)
        }
        try f.scene.store.updateRecording(Self.pk, [.deleteRequestID(Self.manualID)])
        try Self.deleted(f, Self.manualID)
        await Self.collectAfterScan(f)
        #expect(try Self.part(f.scene).status == .completed)
        let last2 = Array(try Self.events(f.scene).suffix(2))
        #expect(last2.count == 2)
        #expect(last2.first?.fromStatus == status.rawValue && last2.first?.toStatus == "SOURCE_DELETING")
        #expect(last2.last?.fromStatus == "SOURCE_DELETING" && last2.last?.toStatus == "COMPLETED")
    }

    @Test("走査にまだ在れば SOURCE_DELETE_FAILED で PENDING")
    func stillInInventoryGoesPending() async throws {
        let f = await Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        try Self.deleted(f, id)
        await Self.collectAfterScan(f, snapshot: f.scene.snapshot(generation: 2))
        let part = try Self.part(f.scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.errorCode == .sourceDeleteFailed)
        #expect(part.deleteRequestID == nil)
        #expect(f.scene.results() == [])
        #expect(Self.logged(f.scene, "source_delete_pending recording_key=" + Self.pk + " reason=still_in_inventory"))
        #expect(f.pended.contains(Self.pk))
    }

    @Test("拒否は SOURCE_IDENTITY_MISMATCH で PENDING、理由語を残す")
    func identityMismatchGoesPending() async throws {
        let f = await Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        try f.scene.writeResult(
            partkey: Self.pk, requestID: id, status: .sourceIdentityMismatch, detail: "size_mismatch")
        await Self.collectAfterScan(f)
        let part = try Self.part(f.scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.errorCode == .sourceIdentityMismatch)
        #expect(try Self.events(f.scene).last?.detail == "size_mismatch")
        #expect(Self.logged(f.scene, "source_delete_pending recording_key=" + Self.pk + " reason=size_mismatch"))
    }

    @Test("DB に無い Part の結果は残す")
    func unknownPartkeyIsKept() async throws {
        let f = await Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        try f.scene.writeResult(
            partkey: "DJIMIC3/other/other_orig.wav", requestID: id, status: .deleted, detail: "other/other_orig.wav")
        await Self.collectAfterScan(f)
        #expect(f.scene.results().count == 1)
    }

    @Test("読めない結果は残す")
    func undecodableResultIsKept() async throws {
        let f = await Self.fixture(try DeletionScene())
        _ = try await Self.requestOne(f)
        let url = f.scene.layout.queueResult.appendingPathComponent("x.json", isDirectory: false)
        try Data("{".utf8).write(to: url)
        await Self.collectAfterScan(f)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test(". 始まりの結果は見ない")
    func hiddenResultIsIgnored() async throws {
        let f = await Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        let url = try f.scene.writeResult(
            partkey: Self.pk, requestID: id, status: .deleted, detail: DeletionScene.relpath)
        let hidden = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: hidden)
        await Self.collectAfterScan(f)
        #expect(try Self.part(f.scene).status == .sourceDeleting)
        #expect(FileManager.default.fileExists(atPath: hidden.path(percentEncoded: false)))
    }

    @Test("待っていない Part の結果は捨てる（#160。パラメータ化: ID nil・COMPLETED）", arguments: ["ID nil", "COMPLETED"])
    func resultForAPartNotWaitingIsDiscarded(_ kind: String) async throws {
        let f = await Self.fixture(try DeletionScene())
        let id: String
        if kind == "ID nil" {
            id = try await Self.requestOne(f)
            try f.scene.store.updateRecording(Self.pk, [.deleteRequestID(nil)])
        } else {
            id = Self.manualID
            try f.scene.movePart(Self.pk, to: .completed)
            try f.scene.store.updateRecording(Self.pk, [.deleteRequestID(id)])
        }
        let before = try Self.part(f.scene).status
        try Self.deleted(f, id)
        await Self.collectAfterScan(f)
        #expect(f.scene.results() == [])
        let part = try Self.part(f.scene)
        #expect(part.status == before)
        #expect(part.sourceDeletedAt == nil)
    }

    @Test("reaper が要求を消した後でも回収できる（BH-1）")
    func collectedAfterTheReaperRemovedTheRequest() async throws {
        let f = await Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        for url in f.scene.requests() { try FileManager.default.removeItem(at: url) }
        try Self.deleted(f, id)
        await Self.collectAfterScan(f)
        #expect(try Self.part(f.scene).status == .completed)
    }

    @Test("回収は Session で絞らない（COMPLETED の Session の Part も）")
    func collectionIsNotLimitedToEvaluatedSessions() async throws {
        let f = await Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        try f.scene.moveSession(to: .completed)
        try Self.deleted(f, id)
        await Self.collectAfterScan(f)
        #expect(try Self.part(f.scene).status == .completed)
    }

    @Test("根拠 B の DELETED は SKIPPED のまま source_deleted_at を書く")
    func skippedPartStaysSkippedWhenDeleted() async throws {
        let f = await Self.fixture(try DeletionScene(status: .skipped, errorCode: .noSpeechDetected))
        try f.scene.store.updateRecording(Self.pk, [.deleteRequestID(Self.manualID)])
        let eventsBefore = try Self.events(f.scene).count
        try Self.deleted(f, Self.manualID)
        await Self.collectAfterScan(f)
        let part = try Self.part(f.scene)
        #expect(part.status == .skipped)
        #expect(part.errorCode == .noSpeechDetected)
        #expect(part.sourceDeletedAt != nil)
        #expect(part.deleteRequestID == nil)
        #expect(try Self.events(f.scene).count == eventsBefore)
    }

    @Test("根拠 B の拒否は SKIPPED のまま ID だけ外す")
    func skippedPartRejectedKeepsItsReason() async throws {
        let f = await Self.fixture(try DeletionScene(status: .skipped, errorCode: .noSpeechDetected))
        try f.scene.store.updateRecording(Self.pk, [.deleteRequestID(Self.manualID)])
        try f.scene.writeResult(
            partkey: Self.pk, requestID: Self.manualID, status: .sourceIdentityMismatch, detail: "size_mismatch")
        await Self.collectAfterScan(f)
        let part = try Self.part(f.scene)
        #expect(part.status == .skipped)
        #expect(part.errorCode == .noSpeechDetected)
        #expect(part.deleteRequestID == nil)
        #expect(part.sourceDeletedAt == nil)
        #expect(Self.logged(f.scene, "source_delete_pending recording_key=" + Self.pk + " reason=size_mismatch"))
    }

    @Test("source_path が無ければ消えたと判定しない")
    func missingSourcePathIsNotGone() async throws {
        let f = await Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        try StorePaths.setSourcePath(f.scene.store, partkey: Self.pk, nil)
        try Self.deleted(f, id)
        await Self.collectAfterScan(f)
        #expect(try Self.part(f.scene).status == .sourceDeletePending)
        #expect(Self.logged(f.scene, "source_delete_pending recording_key=" + Self.pk + " reason=still_in_inventory"))
    }

    @Test("結果が無ければ何もしない（TEST-28）")
    func emptyQueueDoesNothing() async throws {
        let f = await Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        let linesBefore = f.scene.logLines
        let eventsBefore = try Self.events(f.scene).count
        await Self.collectAfterScan(f)
        let part = try Self.part(f.scene)
        #expect(part.status == .sourceDeleting)
        #expect(part.deleteRequestID == id)
        #expect(try Self.events(f.scene).count == eventsBefore)
        #expect(f.scene.logLines == linesBefore)
    }
}
