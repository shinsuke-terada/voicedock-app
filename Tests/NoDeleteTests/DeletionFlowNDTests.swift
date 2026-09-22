// 削除の流れの ND（層 A）: 要求を書く・reaper を起動する・結果を回収する側がアプリの段で消させないこと（PLAN 付録 B.1・§10.5。T-38 §6.1）。
// 舞台は三重ロックを全部外した DeletionScene。/Volumes には触れない（volumesRoot は TempDirectory）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

/// 層 A の故障（T-36 §6.1 と同じ注入）。1 件ごとに新しい舞台で注入する。
enum LayerAFault: String, CaseIterable, Sendable {
    case normalizing, normalizeVerifyFailed, whisperFailed, whisperTimeout, noSpeechLockB
    case rawOutputPathNil, rawNoteRemoved, rawNoteTampered, keyMissing, sourcePathNil, sourcePathEmpty
    case appLockOff, confLockOff, readOnlyObserved, readOnlyHandle, reaperMissing, otherDeviceKey
    case transcriptPathNil, transcriptMissing, transcriptBroken, emptyVault, signatureInvalid, versionMismatch
    case confMissing, confInvalid, emptySession, staleSnapshot

    static let emptySessionKey = "DJIMIC3:20260913"

    func scene() throws -> DeletionScene {
        switch self {
        case .normalizing: return try DeletionScene(status: .normalizing)
        case .normalizeVerifyFailed: return try DeletionScene(status: .failed, errorCode: .normalizeVerifyFailed)
        case .whisperFailed: return try DeletionScene(status: .failed, errorCode: .whisperFailed)
        case .whisperTimeout: return try DeletionScene(status: .failed, errorCode: .whisperTimeout)
        case .noSpeechLockB: return try DeletionScene(status: .skipped, errorCode: .noSpeechDetected)
        case .versionMismatch: return try DeletionScene(reaperVersionOutput: "0.0.1\n")
        default: return try DeletionScene()
        }
    }

    func inject(_ s: DeletionScene) throws {
        switch self {
        case .normalizing, .normalizeVerifyFailed, .whisperFailed, .whisperTimeout, .noSpeechLockB, .versionMismatch,
            .readOnlyObserved, .readOnlyHandle, .staleSnapshot:
            break
        case .rawOutputPathNil:
            try s.store.updateSession(DeletionScene.sessionKey, [.rawOutputPath(nil)])
        case .rawNoteRemoved:
            try FileManager.default.removeItem(at: try s.rawNoteURL())
        case .rawNoteTampered:
            try s.appendToRawNote("\n追記された行\n")
        case .keyMissing:
            try s.replaceInRawNote(DeletionScene.partkey, with: "DJIMIC3/other/other.wav", updateSHA: true)
        case .sourcePathNil:
            try StorePaths.setSourcePath(s.store, partkey: DeletionScene.partkey, nil)
        case .sourcePathEmpty:
            try StorePaths.setSourcePath(s.store, partkey: DeletionScene.partkey, "")
        case .appLockOff:
            s.updateConfig { $0.cleanup.deleteSourceAudio = false }
        case .confLockOff:
            try s.writeReaperConf(deleteSourceAudio: false)
        case .reaperMissing:
            try s.removeReaper()
        case .otherDeviceKey:
            let other = try PartKey.make(deviceID: "NO NAME", relpath: DeletionScene.relpath)
            try s.replaceInRawNote(DeletionScene.partkey, with: other, updateSHA: true)
        case .transcriptPathNil:
            try s.store.updateRecording(DeletionScene.partkey, [.transcriptPath(nil)])
        case .transcriptMissing:
            try FileManager.default.removeItem(at: s.transcriptURL(DeletionScene.partkey))
        case .transcriptBroken:
            try Data("{こわれた".utf8).write(to: s.transcriptURL(DeletionScene.partkey))
        case .emptyVault:
            try FileManager.default.removeItem(at: s.vault.appendingPathComponent(".obsidian", isDirectory: true))
        case .signatureInvalid:
            s.verifier.setValid(false)
        case .confMissing:
            try s.removeReaperConf()
        case .confInvalid:
            try s.writeReaperConfRaw(Data("SCHEMA=1\nDELETE_SOURCE_AUDIO=maybe\n".utf8))
        case .emptySession:
            try s.addSession(key: Self.emptySessionKey, dayDate: "2026-09-13")
        }
    }

    /// ingest に置く snapshot（readOnlyObserved・staleSnapshot だけ差し替える）
    func snapshot(_ s: DeletionScene) -> DeviceSnapshot {
        switch self {
        case .readOnlyObserved: return s.snapshot(readOnly: true)
        case .staleSnapshot: return s.snapshot(completedAt: DeletionScene.now.adding(seconds: -901))
        default: return s.snapshot()
        }
    }

    /// 事前確認のボリュームを開く（readOnlyHandle だけ差し替える）
    var opener: (any VolumeOpener)? {
        self == .readOnlyHandle ? FakeVolumeOpener(readOnly: true) : nil
    }

    /// 評価する Session（emptySession だけ Part 0 件の Session）
    var sessionKey: String {
        self == .emptySession ? Self.emptySessionKey : DeletionScene.sessionKey
    }
}

@Suite("削除の流れの ND（層 A）")
struct DeletionFlowNDTests {
    /// 起動ができる有効な要求（queue/delete に置く）
    static func validRequest() -> DeleteRequest {
        DeleteRequest(
            requestID: RequestID.make(
                partkey: DeletionScene.partkey, utcEpochSeconds: 1_789_182_000, randomHex6: "abcdef"),
            createdAt: "2026-09-12T12:00:00+09:00", deviceID: DeletionScene.deviceID, partkey: DeletionScene.partkey,
            sessionKey: DeletionScene.sessionKey,
            target: DeleteTarget(relpath: DeletionScene.relpath, size: 4096, mtime: DeletionScene.sourceMtime))
    }

    static func logged(_ scene: DeletionScene, _ body: String) -> Bool {
        scene.logLines.contains { $0.hasSuffix(" " + body) }
    }

    static func part(_ scene: DeletionScene) throws -> RecordingRow {
        try #require(try scene.store.recording(DeletionScene.partkey))
    }

    /// 要求を 1 件書いた状態（Part は SOURCE_DELETING）。request_id を返す
    static func requestOne(_ scene: DeletionScene, _ deps: DeletionDependencies) async throws -> String {
        #expect(await DeletionRequester(deps: deps).requestDeletions(sessionKey: DeletionScene.sessionKey) == 1)
        return try #require(try part(scene).deleteRequestID)
    }

    @Test("正の対照 [A] 三重ロックを外し本文が揃えば要求ファイルが書かれ RAW_SAVED→SOURCE_DELETING が記録される")
    func deletionActuallyHappensWhenEverythingIsValid() async throws {
        let scene = try DeletionScene()
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        let deps = scene.deletionDependencies(ingest: ingest)
        #expect(await DeletionRequester(deps: deps).requestDeletions(sessionKey: DeletionScene.sessionKey) == 1)
        let files = scene.requests()
        #expect(files.count == 1)
        let url = try #require(files.first)
        let request = try ContractJSON.decodeRequest(try Data(contentsOf: url)).get()
        let part = try Self.part(scene)
        #expect(request.schema == 1)
        #expect(request.partkey == DeletionScene.partkey)
        #expect(request.deviceID == "DJIMIC3")
        #expect(request.sessionKey == DeletionScene.sessionKey)
        #expect(
            request.target
                == DeleteTarget(relpath: DeletionScene.relpath, size: 4096, mtime: try #require(part.sourceMtime)))
        #expect(RequestID.isValid(request.requestID))
        #expect(request.requestID == part.deleteRequestID)
        #expect(url.lastPathComponent == request.requestID + ".json")
        #expect(part.status == .sourceDeleting)
        let last = try #require(try scene.store.events(entity: .recording, key: DeletionScene.partkey).last)
        #expect(last.fromStatus == "RAW_SAVED" && last.toStatus == "SOURCE_DELETING")
        #expect(
            Self.logged(
                scene,
                "delete_requested request_id=" + request.requestID + " recording_key=" + DeletionScene.partkey
                    + " session_key=DJIMIC3:20260912"))
    }

    @Test("層 A の故障の一覧が空でない")
    func layerAFaultsAreNotEmpty() {
        #expect(!LayerAFault.allCases.isEmpty)
    }

    @Test("層 A の全故障で要求ファイルが書かれない（パラメータ化: LayerAFault.allCases）", arguments: LayerAFault.allCases)
    func everyLayerAFaultWritesNoRequest(_ fault: LayerAFault) async throws {
        let scene = try fault.scene()
        try fault.inject(scene)
        let before = try Self.part(scene).status
        let ingest = ScriptedIngest(snapshot: fault.snapshot(scene))
        let deps = scene.deletionDependencies(ingest: ingest, opener: fault.opener)
        #expect(await DeletionRequester(deps: deps).requestDeletions(sessionKey: fault.sessionKey) == 0)
        #expect(scene.requests() == [])
        let after = try Self.part(scene)
        #expect(after.status == before)
        #expect(after.deleteRequestID == nil)
    }

    @Test("ND-41 [A] 署名が不正・版が違えば reaper を起動しない（パラメータ化）", arguments: ["署名", "版"])
    func nd41ReaperNotLaunchedWhenInvalid(_ fault: String) async throws {
        let scene: DeletionScene
        if fault == "署名" {
            scene = try DeletionScene()
            scene.verifier.setValid(false)
        } else {
            scene = try DeletionScene(reaperVersionOutput: "0.0.1\n")
        }
        try DeleteQueue.write(Self.validRequest(), layout: scene.layout)
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        let deps = scene.deletionDependencies(ingest: ingest)
        let next = await ResultCollector(deps: deps).runReaperIfNeeded(reaperScanGeneration: 0)
        #expect(!(await scene.runner.recorded).contains { $0.arguments.first == "--home" })
        #expect(next == 0)
        #expect(await ingest.scanNowCalls == 0)
        let reason = fault == "署名" ? "signature" : "version_mismatch"
        #expect(Self.logged(scene, "reaper_failed reason=" + reason))
    }

    @Test("ND-42 [A] 古い試行の DELETED 結果（request_id 不一致）は捨て、消えたと判定しない")
    func nd42OlderAttemptResultIsDiscarded() async throws {
        let scene = try DeletionScene()
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        let deps = scene.deletionDependencies(ingest: ingest)
        let id = try await Self.requestOne(scene, deps)
        try scene.writeResult(
            partkey: DeletionScene.partkey, requestID: "20260101T000000Z-0000000000000000-000000", status: .deleted,
            detail: DeletionScene.relpath)
        await ingest.setSnapshot(scene.snapshot(generation: 2, relpaths: []))
        await ResultCollector(deps: deps).collectDeleteResults(reaperScanGeneration: 2)
        #expect(scene.results() == [])
        let part = try Self.part(scene)
        #expect(part.status == .sourceDeleting)
        #expect(part.sourceDeletedAt == nil)
        #expect(part.deleteRequestID == id)
    }

    @Test(
        "ND-46 [A] reaper の後の走査が無い・デバイスが snapshot に無ければ DELETED でも完了にしない（パラメータ化）",
        arguments: ["走査が古い", "デバイスが無い", "snapshot が無い"])
    func nd46DeletedWaitsForAScanAfterTheReaper(_ fault: String) async throws {
        let scene = try DeletionScene()
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        let deps = scene.deletionDependencies(ingest: ingest)
        let id = try await Self.requestOne(scene, deps)
        try scene.writeResult(
            partkey: DeletionScene.partkey, requestID: id, status: .deleted, detail: DeletionScene.relpath)
        switch fault {
        case "走査が古い": await ingest.setSnapshot(scene.snapshot(generation: 1, relpaths: []))
        case "デバイスが無い": await ingest.setSnapshot(scene.snapshot(generation: 2, includeDevice: false))
        default: await ingest.setSnapshot(nil)
        }
        await ResultCollector(deps: deps).collectDeleteResults(reaperScanGeneration: 2)
        #expect(scene.results().count == 1)
        let part = try Self.part(scene)
        #expect(part.status == .sourceDeleting)
        #expect(part.sourceDeletedAt == nil)
        // 対照: reaper の後の走査にファイルが無ければ完了する
        await ingest.setSnapshot(scene.snapshot(generation: 2, relpaths: []))
        await ResultCollector(deps: deps).collectDeleteResults(reaperScanGeneration: 2)
        #expect(try Self.part(scene).status == .completed)
    }

    @Test("ND-47 [A] 接続中で readOnly が nil（観測できない）なら要求を書かない")
    func nd47UnknownReadOnlyWritesNoRequest() async throws {
        let scene = try DeletionScene()
        let ingest = ScriptedIngest(snapshot: scene.snapshot(readOnly: nil))
        let deps = scene.deletionDependencies(ingest: ingest)
        await SessionDeletionStage(deps: deps).deleteSourcesIfSafe(sessionKey: DeletionScene.sessionKey)
        #expect(scene.requests() == [])
        #expect(try Self.part(scene).status == .completed)
        #expect(try scene.store.session(DeletionScene.sessionKey)?.status == .completed)
        #expect(Self.logged(scene, "source_delete_skipped session_key=DJIMIC3:20260912 reason=device_readonly"))
    }
}
