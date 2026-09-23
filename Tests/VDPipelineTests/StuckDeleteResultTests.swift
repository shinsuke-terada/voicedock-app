// 削除の結果で Part が永久に止まらないこと（PLAN §8.9.6・§8.9.7。F-74・issue #114）。
// partkey の合わない結果で期限切れを止めない（A2）、取り下げきれない要求が残れば ID を外さない（B1）、
// 後追いの ③ の前に止まった COMPLETED の結果を回収する（B2）、DELETED の後始末は遷移が先で ID を外すのは最後（B5）。
import Foundation
import GRDB
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice

@testable import VDPipeline
@testable import VDStore

@Suite("StuckDeleteResult")
struct StuckDeleteResultTests {
    static let pk = DeletionScene.partkey
    /// 要求を書かずに ID だけを持たせるときの request_id
    static let manualID = "20260912T030000Z-8483e42457304a9d-abcdef"
    /// 遷移を DB で失敗させるトリガの名前（B5）
    static let blockTrigger = "f74_block_completed"

    struct Fixture {
        let scene: DeletionScene
        let ingest: ScriptedIngest
        let deps: DeletionDependencies
    }

    static func fixture(_ scene: DeletionScene) -> Fixture {
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        return Fixture(scene: scene, ingest: ingest, deps: scene.deletionDependencies(ingest: ingest))
    }

    /// 要求を 1 件書いた状態（updated_at = now）。request_id を返す
    static func requestOne(_ f: Fixture) async throws -> String {
        #expect(await DeletionRequester(deps: f.deps).requestDeletions(sessionKey: DeletionScene.sessionKey) == 1)
        return try #require(try part(f.scene).deleteRequestID)
    }

    static func part(_ scene: DeletionScene) throws -> RecordingRow {
        try #require(try scene.store.recording(Self.pk))
    }

    static func events(_ scene: DeletionScene) throws -> [EventRow] {
        try scene.store.events(entity: .recording, key: Self.pk)
    }

    static func logged(_ scene: DeletionScene, _ body: String) -> Bool {
        scene.logLines.contains { $0.hasSuffix(" " + body) }
    }

    static func expire(_ f: Fixture) async {
        await RequestExpirer(deps: f.deps).expireDeleteRequests()
    }

    /// 消えた後の走査にして collect(2)
    static func collectAfterScan(_ f: Fixture, snapshot: DeviceSnapshot? = nil) async {
        await f.ingest.setSnapshot(snapshot ?? f.scene.snapshot(generation: 2, relpaths: []))
        await ResultCollector(deps: f.deps).collectDeleteResults(reaperScanGeneration: 2)
    }

    static func removeRequests(_ scene: DeletionScene) throws {
        for url in scene.requests() { try FileManager.default.removeItem(at: url) }
    }

    // MARK: - A2: 回収が拾えない結果で期限切れを止めない

    @Test("F-74 partkey が空の結果（reaper が読めない要求に書いたもの）は期限切れを妨げず、pend の後に捨てる")
    func emptyPartkeyResultDoesNotBlockExpiry() async throws {
        let f = Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        // reaper は要求を読めず、partkey "" の拒否を書いて要求を消した
        try Self.removeRequests(f.scene)
        try f.scene.writeResult(
            partkey: "", requestID: id, status: .sourceIdentityMismatch, detail: "malformed_request")
        // 回収は partkey で Part を引けないので残す
        await Self.collectAfterScan(f)
        #expect(f.scene.results().count == 1)
        #expect(try Self.part(f.scene).status == .sourceDeleting)
        f.scene.clock.advance(seconds: 3600)
        await Self.expire(f)
        let part = try Self.part(f.scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.errorCode == .deleteTimeout)
        #expect(part.deleteRequestID == nil)
        #expect(part.sourceDeletedAt == nil)
        #expect(f.scene.results() == [])
        #expect(Self.logged(f.scene, "source_delete_pending recording_key=" + Self.pk + " reason=no_result"))
    }

    @Test("F-74 読めない結果は期限切れを妨げない（結果のファイルは回収と同じく残す）")
    func undecodableResultDoesNotBlockExpiry() async throws {
        let f = Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        try Self.removeRequests(f.scene)
        let url = DeleteQueue.resultURL(id, layout: f.scene.layout)
        try Data("{".utf8).write(to: url)
        f.scene.clock.advance(seconds: 3600)
        await Self.expire(f)
        let part = try Self.part(f.scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.deleteRequestID == nil)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    // MARK: - B1: 取り下げきれない要求が残れば ID を外さない

    @Test("F-74 取り下げきれない要求（読めない <request_id>.json）が残れば pend せず ID を持ったまま次の tick でやり直す")
    func leftoverRequestKeepsTheID() async throws {
        let f = Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        // 要求が読めない（partkey で照合できず取り下げられない）
        try Data("{".utf8).write(to: DeleteQueue.requestURL(id, layout: f.scene.layout))
        f.scene.clock.advance(seconds: 3601)
        await Self.expire(f)
        var part = try Self.part(f.scene)
        #expect(part.status == .sourceDeleting)
        #expect(part.deleteRequestID == id)
        #expect(f.scene.requests().count == 1)
        #expect(!f.scene.logLines.contains { $0.contains(" source_delete_pending ") })
        // 要求が無くなった（reaper が処理した・取り下げられた）次の tick で期限切れにする
        try Self.removeRequests(f.scene)
        await Self.expire(f)
        part = try Self.part(f.scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.errorCode == .deleteTimeout)
        #expect(part.deleteRequestID == nil)
    }

    // MARK: - B2: ID を持つ COMPLETED の結果を回収する

    /// 後追いの ①② の後・③ の前に止まった姿（COMPLETED で ID を持つ）
    static func completedWithID(_ f: Fixture) throws {
        try f.scene.movePart(Self.pk, to: .completed)
        try f.scene.store.updateRecording(Self.pk, [.deleteRequestID(Self.manualID)])
    }

    @Test("F-74 後追いの ③ の前に止まった COMPLETED の Part（ID を持つ）の DELETED を回収し、遷移させずに source_deleted_at を書いて ID を外す")
    func deletedResultOfCompletedPartIsCollected() async throws {
        let f = Self.fixture(try DeletionScene())
        try Self.completedWithID(f)
        let eventsBefore = try Self.events(f.scene).count
        try f.scene.writeResult(
            partkey: Self.pk, requestID: Self.manualID, status: .deleted, detail: DeletionScene.relpath)
        await Self.collectAfterScan(f)
        let part = try Self.part(f.scene)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt == "2026-09-12T12:00:00+09:00")
        #expect(part.deleteRequestID == nil)
        #expect(try Self.events(f.scene).count == eventsBefore)
        #expect(f.scene.results() == [])
        #expect(Self.logged(f.scene, "source_deleted recording_key=" + Self.pk + " request_id=" + Self.manualID))
        #expect(!f.scene.logLines.contains { $0.contains(" config_warning ") })
    }

    @Test(
        "F-74 ID を持つ COMPLETED の拒否・一覧にまだ在るは ID を外すだけ（COMPLETED のまま、source_deleted_at は入れない）（パラメータ化）",
        arguments: ["拒否", "一覧にまだ在る"])
    func failedResultOfCompletedPartOnlyClearsTheID(_ kind: String) async throws {
        let f = Self.fixture(try DeletionScene())
        try Self.completedWithID(f)
        let eventsBefore = try Self.events(f.scene).count
        let reason: String
        if kind == "拒否" {
            try f.scene.writeResult(
                partkey: Self.pk, requestID: Self.manualID, status: .sourceIdentityMismatch, detail: "size_mismatch")
            await Self.collectAfterScan(f)
            reason = "size_mismatch"
        } else {
            try f.scene.writeResult(
                partkey: Self.pk, requestID: Self.manualID, status: .deleted, detail: DeletionScene.relpath)
            await Self.collectAfterScan(f, snapshot: f.scene.snapshot(generation: 2))
            reason = "still_in_inventory"
        }
        let part = try Self.part(f.scene)
        #expect(part.status == .completed)
        #expect(part.deleteRequestID == nil)
        #expect(part.sourceDeletedAt == nil)
        #expect(try Self.events(f.scene).count == eventsBefore)
        #expect(f.scene.results() == [])
        #expect(Self.logged(f.scene, "source_delete_pending recording_key=" + Self.pk + " reason=" + reason))
    }

    // MARK: - B5: DELETED の後始末は遷移が先、ID を外すのは最後

    @Test("F-74 DELETED の遷移が DB で失敗したら ID と結果を残し（ID の無い SOURCE_DELETING を残さない）、次の回収でやり直す")
    func failedTransitionKeepsTheIDAndResult() async throws {
        let f = Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        try f.scene.writeResult(partkey: Self.pk, requestID: id, status: .deleted, detail: DeletionScene.relpath)
        try await f.scene.store.pool.write { db in
            try db.execute(
                sql: "CREATE TRIGGER " + Self.blockTrigger
                    + " BEFORE UPDATE OF status ON recordings WHEN NEW.status = '"
                    + PartStatus.completed.rawValue + "' BEGIN SELECT RAISE(ABORT, 'f74'); END")
        }
        await Self.collectAfterScan(f)
        var part = try Self.part(f.scene)
        #expect(part.status == .sourceDeleting)
        #expect(part.deleteRequestID == id)
        #expect(part.sourceDeletedAt == nil)
        #expect(f.scene.results().count == 1)
        #expect(f.scene.logLines.contains { $0.contains(" config_warning rule=store ") })
        try await f.scene.store.pool.write { db in try db.execute(sql: "DROP TRIGGER " + Self.blockTrigger) }
        await Self.collectAfterScan(f)
        part = try Self.part(f.scene)
        #expect(part.status == .completed)
        #expect(part.deleteRequestID == nil)
        #expect(part.sourceDeletedAt == "2026-09-12T12:00:00+09:00")
        #expect(f.scene.results() == [])
    }

    // MARK: - 空の入力

    @Test("F-74 TEST-28 queue が空なら要求は残っておらず結果も無い（request_id が空文字でも）")
    func emptyQueueHasNoRequestOrResult() throws {
        let scene = try DeletionScene()
        #expect(scene.requests() == [])
        #expect(scene.results() == [])
        for id in [Self.manualID, ""] {
            #expect(!DeleteQueue.hasRequest(partkey: Self.pk, requestID: id, layout: scene.layout))
            #expect(DeleteQueue.result(requestID: id, layout: scene.layout) == nil)
        }
    }
}
