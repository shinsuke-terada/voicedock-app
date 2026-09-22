// 結果の来ない要求の期限切れ（PLAN §8.9.7。読み直しと衝突の捕捉の 2 層を別々に固定する。DEL-18 / TEST-17。T-38 §6.7）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

@Suite("RequestExpirer")
struct RequestExpirerTests {
    static let pk = DeletionScene.partkey
    static let manualID = "20260912T030000Z-8483e42457304a9d-abcdef"

    struct Fixture {
        let scene: DeletionScene
        let ingest: ScriptedIngest
        let deps: DeletionDependencies
    }

    /// 設定は作る前に変えておく（deps は今の設定で作る）
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
        try #require(try scene.store.recording(pk))
    }

    static func logged(_ scene: DeletionScene, _ body: String) -> Bool {
        scene.logLines.contains { $0.hasSuffix(" " + body) }
    }

    static func expire(_ f: Fixture) async {
        await RequestExpirer(deps: f.deps).expireDeleteRequests()
    }

    @Test("期限を過ぎたら要求と結果を取り下げ DELETE_TIMEOUT で PENDING")
    func expiresAfterTimeoutAndWithdraws() async throws {
        let f = Self.fixture(try DeletionScene())
        _ = try await Self.requestOne(f)
        try f.scene.writeResult(
            partkey: Self.pk, requestID: "20260101T000000Z-8483e42457304a9d-000000", status: .deleted,
            detail: DeletionScene.relpath)
        f.scene.clock.advance(seconds: 3600)
        await Self.expire(f)
        let part = try Self.part(f.scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.errorCode == .deleteTimeout)
        #expect(try f.scene.store.events(entity: .recording, key: Self.pk).last?.detail == "no_result")
        #expect(part.deleteRequestID == nil)
        #expect(f.scene.requests() == [])
        #expect(f.scene.results() == [])
        #expect(Self.logged(f.scene, "source_delete_pending recording_key=" + Self.pk + " reason=no_result"))
    }

    @Test("期限前は取り下げない")
    func freshRequestIsNotExpired() async throws {
        let f = Self.fixture(try DeletionScene())
        _ = try await Self.requestOne(f)
        f.scene.clock.advance(seconds: 3599)
        await Self.expire(f)
        #expect(try Self.part(f.scene).status == .sourceDeleting)
        #expect(f.scene.requests().count == 1)
    }

    @Test("CE cleanup.deleteResultTimeoutSeconds が期限になる")
    func ceDeleteResultTimeoutSeconds() async throws {
        let scene = try DeletionScene()
        scene.updateConfig { $0.cleanup.deleteResultTimeoutSeconds = 60 }
        let f = Self.fixture(scene)
        _ = try await Self.requestOne(f)
        f.scene.clock.advance(seconds: 61)
        await Self.expire(f)
        let part = try Self.part(f.scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.errorCode == .deleteTimeout)
        // 既定の 3600 では 61 秒後も SOURCE_DELETING のまま
        let base = Self.fixture(try DeletionScene())
        _ = try await Self.requestOne(base)
        base.scene.clock.advance(seconds: 61)
        await Self.expire(base)
        #expect(try Self.part(base.scene).status == .sourceDeleting)
    }

    @Test("その request_id の結果が在れば取り下げない（DELETED の観測待ち）")
    func resultWaitingForObservationIsNotExpired() async throws {
        let f = Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        try f.scene.writeResult(partkey: Self.pk, requestID: id, status: .deleted, detail: DeletionScene.relpath)
        f.scene.clock.advance(seconds: 3601)
        await Self.expire(f)
        #expect(try Self.part(f.scene).status == .sourceDeleting)
        #expect(f.scene.requests().count == 1)
        #expect(f.scene.results().count == 1)
    }

    @Test("層 1: 期限は読み直した行の updated_at で判定する")
    func rereadsTheCurrentRow() async throws {
        let f = Self.fixture(try DeletionScene())
        _ = try await Self.requestOne(f)
        let stale = try Self.part(f.scene)
        f.scene.clock.advance(seconds: 3600)
        // updated_at が今になる
        try f.scene.store.updateRecording(Self.pk, [.needsRecopy(false)])
        f.scene.clock.advance(seconds: 1)
        let store = f.scene.store
        RequestExpirer(deps: f.deps).expire(candidates: [stale], reread: { try store.recording($0) })
        #expect(try Self.part(f.scene).status == .sourceDeleting)
        #expect(f.scene.requests().count == 1)
    }

    @Test("層 2: 読み直しの後に状態が変わっていても落ちない")
    func survivesAConflict() async throws {
        let f = Self.fixture(try DeletionScene())
        let id = try await Self.requestOne(f)
        let stale = try Self.part(f.scene)
        try f.scene.writeResult(partkey: Self.pk, requestID: id, status: .deleted, detail: DeletionScene.relpath)
        await f.ingest.setSnapshot(f.scene.snapshot(generation: 2, relpaths: []))
        await ResultCollector(deps: f.deps).collectDeleteResults(reaperScanGeneration: 2)
        #expect(try Self.part(f.scene).status == .completed)
        f.scene.clock.advance(seconds: 3601)
        RequestExpirer(deps: f.deps).expire(candidates: [stale], reread: { _ in stale })
        #expect(try Self.part(f.scene).status == .completed)
        #expect(Self.logged(f.scene, "source_delete_skipped recording_key=" + Self.pk + " reason=status_changed"))
        #expect(!f.scene.logLines.contains { $0.contains(" config_warning ") })
    }

    @Test("根拠 B の要求の期限切れは SKIPPED のまま ID を外す")
    func skippedExpiryKeepsSkipped() async throws {
        let f = Self.fixture(try DeletionScene(status: .skipped, errorCode: .noSpeechDetected))
        try f.scene.store.updateRecording(Self.pk, [.deleteRequestID(Self.manualID)])
        f.scene.clock.advance(seconds: 3601)
        await Self.expire(f)
        let part = try Self.part(f.scene)
        #expect(part.status == .skipped)
        #expect(part.errorCode == .noSpeechDetected)
        #expect(part.deleteRequestID == nil)
    }

    @Test("対象は全 Part（Session で絞らない）")
    func targetsAllParts() async throws {
        let f = Self.fixture(try DeletionScene())
        _ = try await Self.requestOne(f)
        try f.scene.moveSession(to: .completed)
        f.scene.clock.advance(seconds: 3601)
        await Self.expire(f)
        #expect(try Self.part(f.scene).status == .sourceDeletePending)
    }

    @Test("待つ Part が無ければ何もしない（TEST-28）")
    func noAwaitingPartsDoNothing() async throws {
        let f = Self.fixture(try DeletionScene())
        let linesBefore = f.scene.logLines
        f.scene.clock.advance(seconds: 3601)
        await Self.expire(f)
        let part = try Self.part(f.scene)
        #expect(part.status == .rawSaved)
        #expect(part.deleteRequestID == nil)
        #expect(f.scene.logLines == linesBefore)
    }
}
