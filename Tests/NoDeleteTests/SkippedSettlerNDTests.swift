// 根拠 B の ND（層 A）: 保全すべき本文が無いと言い切れない SKIPPED の元音声に削除要求を書かないこと（PLAN 付録 B.1・§8.9.5。T-39 §6.1）。
// 舞台は三重ロックを全部外した DeletionScene。/Volumes には触れない（volumesRoot は TempDirectory）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

@Suite("根拠 B の ND（層 A）")
struct SkippedSettlerNDTests {
    static let dupFileName = "TX00_MIC002_20260912_093000_orig.wav"
    static let dupStartedAt = "2026-09-12T09:30:00+09:00"

    /// 重複の舞台: 既定の舞台（既定の Part が双子）に重複の Part を足す。重複の partkey を返す
    static func addDuplicate(_ scene: DeletionScene) throws -> String {
        try scene.addPart(
            fileName: dupFileName, startedAt: dupStartedAt, status: .skipped, errorCode: .duplicateContent,
            duplicateOf: DeletionScene.partkey, transcript: false, inRawNote: false)
    }

    /// ロック B を開け、間引きを越え、今の設定の deps で 1 回 settle する
    static func openLockBAndSettle(_ scene: DeletionScene) async -> Int {
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
        scene.clock.advance(seconds: 60)
        let deps = scene.deletionDependencies(ingest: ScriptedIngest(snapshot: scene.snapshot()))
        return await SkippedSettler(deps: deps).settleSkippedDeletions()
    }

    static func onlyRequest(_ scene: DeletionScene) throws -> DeleteRequest {
        let files = scene.requests()
        #expect(files.count == 1)
        let url = try #require(files.first)
        return try ContractJSON.decodeRequest(try Data(contentsOf: url)).get()
    }

    static func part(_ scene: DeletionScene, _ pk: String) throws -> RecordingRow {
        try #require(try scene.store.recording(pk))
    }

    @Test("正の対照 [A] 無音の SKIPPED はロック B を開けると要求が 1 件書かれ SKIPPED のまま")
    func noSpeechActuallyRequestedWhenLockBIsOpen() async throws {
        let scene = try DeletionScene(status: .skipped, errorCode: .noSpeechDetected)
        let eventsBefore = try scene.store.events(entity: .recording, key: DeletionScene.partkey).count
        #expect(await Self.openLockBAndSettle(scene) == 1)
        let request = try Self.onlyRequest(scene)
        #expect(request.partkey == DeletionScene.partkey)
        let part = try Self.part(scene, DeletionScene.partkey)
        #expect(part.status == .skipped)
        #expect(part.errorCode == .noSpeechDetected)
        #expect(part.deleteRequestID == request.requestID)
        #expect(try scene.store.events(entity: .recording, key: DeletionScene.partkey).count == eventsBefore)
        let ctx = await scene.context(snapshot: scene.snapshot())
        #expect(DeletionPolicy.canDeleteSource(try scene.candidate(), ctx))
    }

    @Test("正の対照 [A] 重複は双子の本文が揃えばロック B で要求が 1 件（重複の側に）")
    func duplicateActuallyRequestedWhenTwinIsPreserved() async throws {
        let scene = try DeletionScene()
        let dup = try Self.addDuplicate(scene)
        #expect(await Self.openLockBAndSettle(scene) == 1)
        let request = try Self.onlyRequest(scene)
        #expect(request.partkey == dup)
        #expect(request.partkey != DeletionScene.partkey)
        let row = try Self.part(scene, dup)
        #expect(row.status == .skipped)
        #expect(row.errorCode == .duplicateContent)
        #expect(try Self.part(scene, DeletionScene.partkey).status == .rawSaved)
    }

    @Test("ND-33 [A] SOURCE_MISSING の SKIPPED はロックを開けても消さない")
    func nd33SourceMissingIsNeverDeleted() async throws {
        let scene = try DeletionScene(status: .skipped, errorCode: .sourceMissing)
        #expect(await Self.openLockBAndSettle(scene) == 0)
        #expect(scene.requests() == [])
        let ctx = await scene.context(snapshot: scene.snapshot())
        #expect(DeletionPolicy.canDeleteSource(try scene.candidate(), ctx) == false)
    }

    @Test("ND-34 [A] 無音でも transcript が無いか壊れていれば消さない（パラメータ化）", arguments: ["消す", "壊す"])
    func nd34NoSpeechWithoutTranscript(_ change: String) async throws {
        let scene = try DeletionScene(status: .skipped, errorCode: .noSpeechDetected)
        if change == "消す" {
            try FileManager.default.removeItem(at: scene.transcriptURL(DeletionScene.partkey))
        } else {
            try Data("{こわれた".utf8).write(to: scene.transcriptURL(DeletionScene.partkey))
        }
        #expect(await Self.openLockBAndSettle(scene) == 0)
        #expect(scene.requests() == [])
        let ctx = await scene.context(snapshot: scene.snapshot())
        #expect(DeletionPolicy.skipReasonIsBacked(try scene.candidate(), ctx) == false)
    }

    @Test(
        "ND-35 [A] 重複は双子の本文が Vault で確認できなければ消さない（パラメータ化）",
        arguments: ["Raw ノートを消す", "鍵を置き換える", "transcript を消す"])
    func nd35DuplicateWhoseTwinTextIsNotPreserved(_ change: String) async throws {
        let scene = try DeletionScene()
        let dup = try Self.addDuplicate(scene)
        switch change {
        case "Raw ノートを消す":
            try FileManager.default.removeItem(at: try scene.rawNoteURL())
        case "鍵を置き換える":
            try scene.replaceInRawNote(DeletionScene.partkey, with: "DJIMIC3/other/other.wav", updateSHA: true)
        case "transcript を消す":
            try FileManager.default.removeItem(at: scene.transcriptURL(DeletionScene.partkey))
        default:
            Issue.record("知らない壊し方: \(change)")
        }
        #expect(await Self.openLockBAndSettle(scene) == 0)
        #expect(scene.requests() == [])
        #expect(try Self.part(scene, dup).deleteRequestID == nil)
    }
}
