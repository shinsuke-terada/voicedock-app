// 根拠 B の往復: 無音の SKIPPED に要求 → 回収・拒否・期限切れ（PLAN §8.9.5〜§8.9.7。T-39 §6.3）。SKIPPED のまま（SM-20）。
// 本物の reaper の 1 本だけ FAT32 のディスクイメージを <tmp>/Volumes/VDT… に attach する（/Volumes の下には決して attach しない。
// ボリューム名に DJIMIC3 を使わない。PLAN §10.2）。Part はインスタンスの値（scene.partkey。T-36 §4.10）で指す。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDProcess
import VDStore

@testable import VDPipeline

@Suite("根拠 B の往復", .serialized)
struct SkippedDeletionRoundTripTests {
    struct Stage {
        let scene: DeletionScene
        let ingest: ScriptedIngest
        let deps: DeletionDependencies
        /// DB の delete_request_id
        let id: String
    }

    /// 無音の舞台、ロック B、間引きを越える、settle == 1。removeRequest が真なら要求ファイルを消す（reaper の姿）
    static func stage(removeRequest: Bool = true) async throws -> Stage {
        let scene = try DeletionScene(status: .skipped, errorCode: .noSpeechDetected)
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        scene.clock.advance(seconds: 60)
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        let deps = scene.deletionDependencies(ingest: ingest)
        #expect(await SkippedSettler(deps: deps).settleSkippedDeletions() == 1)
        let id = try #require(try part(scene).deleteRequestID)
        if removeRequest {
            for url in scene.requests() {
                try FileManager.default.removeItem(at: url)
            }
        }
        return Stage(scene: scene, ingest: ingest, deps: deps, id: id)
    }

    static func part(_ scene: DeletionScene) throws -> RecordingRow {
        try #require(try scene.store.recording(scene.partkey))
    }

    static func collect(_ deps: DeletionDependencies) async {
        await ResultCollector(deps: deps).collectDeleteResults(reaperScanGeneration: 2)
    }

    static func logged(_ scene: DeletionScene, _ body: String) -> Bool {
        scene.logLines.contains { $0.hasSuffix(" " + body) }
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path(percentEncoded: false), &st) == 0
    }

    @Test("往復: DELETED を回収すると SKIPPED のまま source_deleted_at が入る")
    func deletedNoSpeechIsRecordedAndStaysSkipped() async throws {
        let s = try await Self.stage()
        try s.scene.writeResult(
            partkey: s.scene.partkey, requestID: s.id, status: .deleted, detail: DeletionScene.relpath)
        await s.ingest.setSnapshot(s.scene.snapshot(generation: 2, relpaths: []))
        await Self.collect(s.deps)
        let part = try Self.part(s.scene)
        #expect(part.status == .skipped)
        #expect(part.errorCode == .noSpeechDetected)
        #expect(part.sourceDeletedAt == "2026-09-12T12:01:00+09:00")
        #expect(part.deleteRequestID == nil)
        #expect(s.scene.results() == [])
        #expect(
            Self.logged(s.scene, "source_deleted recording_key=" + s.scene.partkey + " request_id=" + s.id))
        s.scene.clock.advance(seconds: 60)
        #expect(await SkippedSettler(deps: s.deps).settleSkippedDeletions() == 0)
    }

    @Test("往復: 拒否されたら SKIPPED のまま ID を外し、同じ周回で再要求しない")
    func rejectedNoSpeechIsNotRetriedAtOnce() async throws {
        let s = try await Self.stage()
        try s.scene.writeResult(
            partkey: s.scene.partkey, requestID: s.id, status: .sourceIdentityMismatch, detail: "size_mismatch")
        await Self.collect(s.deps)
        let part = try Self.part(s.scene)
        #expect(part.status == .skipped)
        #expect(part.errorCode == .noSpeechDetected)
        #expect(part.deleteRequestID == nil)
        #expect(part.sourceDeletedAt == nil)
        #expect(
            Self.logged(s.scene, "source_delete_pending recording_key=" + s.scene.partkey + " reason=size_mismatch"))
        #expect(await SkippedSettler(deps: s.deps).settleSkippedDeletions() == 0)
        #expect(s.scene.requests() == [])
        // 対照: 新しい deps（次の tick）で間引きを越えれば 1
        s.scene.clock.advance(seconds: 60)
        let next = s.scene.deletionDependencies(ingest: ScriptedIngest(snapshot: s.scene.snapshot()))
        #expect(await SkippedSettler(deps: next).settleSkippedDeletions() == 1)
    }

    @Test("往復: DELETED なのに走査に在れば SKIPPED のまま ID を外す")
    func stillInInventoryKeepsSkipped() async throws {
        let s = try await Self.stage()
        try s.scene.writeResult(
            partkey: s.scene.partkey, requestID: s.id, status: .deleted, detail: DeletionScene.relpath)
        await s.ingest.setSnapshot(s.scene.snapshot(generation: 2))
        await Self.collect(s.deps)
        let part = try Self.part(s.scene)
        #expect(part.status == .skipped)
        #expect(part.deleteRequestID == nil)
        #expect(
            Self.logged(
                s.scene, "source_delete_pending recording_key=" + s.scene.partkey + " reason=still_in_inventory"))
    }

    @Test("往復: 結果が来ないまま期限を過ぎたら取り下げる（reaper が居ないときの正常な姿）")
    func unansweredNoSpeechRequestExpires() async throws {
        let s = try await Self.stage(removeRequest: false)
        #expect(s.scene.requests().count == 1)
        s.scene.clock.advance(seconds: 3601)
        await RequestExpirer(deps: s.deps).expireDeleteRequests()
        let part = try Self.part(s.scene)
        #expect(part.status == .skipped)
        #expect(part.errorCode == .noSpeechDetected)
        #expect(part.deleteRequestID == nil)
        #expect(s.scene.requests() == [])
    }

    @Test(
        "往復（本物の reaper × FAT32）: 無音の元音声が消え、SKIPPED のまま記録される", .enabled(if: TestEnvironment.diskTests))
    func realReaperDeletesANoSpeechPart() async throws {
        let tmp = try TempDirectory()
        let image = try DiskImageVolume(in: tmp, deviceID: DiskImageVolume.uniqueName(), filesystem: .fat32)
        defer { image.detach() }
        let scene = try DeletionScene(status: .skipped, errorCode: .noSpeechDetected, in: tmp, diskImage: image)
        try scene.installRealReaper()
        let locks = LockEvaluator(
            layout: scene.layout, verifier: FakeSignatureVerifier(), runner: ProcessRunner(), log: scene.log)
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        scene.clock.advance(seconds: 60)
        let ingest = ScriptedIngest(snapshot: scene.scannedSnapshot(generation: 1))
        await ingest.setScanner { scene.scannedSnapshot(generation: $0) }
        let deps = scene.deletionDependencies(ingest: ingest, locks: locks)
        #expect(await SkippedSettler(deps: deps).settleSkippedDeletions() == 1)
        _ = await ResultCollector(deps: deps).runReaperIfNeeded(reaperScanGeneration: 0)
        #expect(!Self.exists(scene.deviceRoot.appendingPathComponent(DeletionScene.relpath, isDirectory: false)))
        let part = try Self.part(scene)
        #expect(part.status == .skipped)
        #expect(part.sourceDeletedAt != nil)
        #expect(part.deleteRequestID == nil)
    }
}
