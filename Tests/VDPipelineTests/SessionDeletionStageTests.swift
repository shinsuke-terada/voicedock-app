// Session の削除段と後始末（PLAN §8.9.5 deleteSourcesIfSafe・completeWithoutDeleting・finishCleanup・evaluateDeletions の backoff。T-38 §6.4）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

@Suite("SessionDeletionStage")
struct SessionDeletionStageTests {
    static let pk = DeletionScene.partkey
    static let key = DeletionScene.sessionKey
    static let awaitingID = "20260912T030000Z-8483e42457304a9d-abcdef"

    static func stage(
        _ scene: DeletionScene, snapshot: DeviceSnapshot? = nil, pended: PendedPartkeys = PendedPartkeys()
    )
        -> SessionDeletionStage
    {
        let ingest = ScriptedIngest(snapshot: snapshot ?? scene.snapshot())
        return SessionDeletionStage(deps: scene.deletionDependencies(ingest: ingest, pended: pended))
    }

    static func part(_ scene: DeletionScene, _ pk: String = pk) throws -> RecordingRow {
        try #require(try scene.store.recording(pk))
    }

    static func session(_ scene: DeletionScene, _ key: String = key) throws -> SessionRow {
        try #require(try scene.store.session(key))
    }

    static func logged(_ scene: DeletionScene, _ body: String) -> Bool {
        scene.logLines.contains { $0.hasSuffix(" " + body) }
    }

    static func hasSkippedLog(_ scene: DeletionScene) -> Bool {
        scene.logLines.contains { $0.contains(" source_delete_skipped ") }
    }

    /// staging/<slug>/ に audio16k.wav・audio16k.wav.tmp・whisper.json・diarization.rttm を置く
    static func placeStaging(_ scene: DeletionScene, _ pk: String) throws {
        let slug = KeySlug.of(pk)
        try FileManager.default.createDirectory(
            at: scene.layout.stagingDirectory(slug: slug), withIntermediateDirectories: true)
        for url in [
            scene.layout.normalizedAudio(slug: slug), scene.layout.normalizedAudioTmp(slug: slug),
            scene.layout.whisperJSON(slug: slug), scene.layout.diarizationRTTM(slug: slug),
        ] {
            try Data("x".utf8).write(to: url)
        }
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test("要求を書いたら Session は SOURCE_DELETING")
    func requestMovesTheSessionToSourceDeleting() async throws {
        let scene = try DeletionScene()
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(try Self.session(scene).status == .sourceDeleting)
        #expect(try Self.part(scene).status == .sourceDeleting)
        #expect(scene.requests().count == 1)
    }

    @Test("SOURCE_DELETING の Part が在れば requested 0 でも待たずにそのまま")
    func secondEvaluationDoesNotRequestAgain() async throws {
        let scene = try DeletionScene()
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(scene.requests().count == 1)
        let session = try Self.session(scene)
        #expect(session.deleteAttempts == 0)
        #expect(session.status == .sourceDeleting)
    }

    @Test(
        "待つ Part が無ければ完了する（#160。パラメータ化: COMPLETED・SKIPPED(NO_SPEECH)・FAILED(WHISPER_FAILED)）",
        arguments: [
            (PartStatus.completed, ErrorCode?.none), (.skipped, .noSpeechDetected), (.failed, .whisperFailed),
        ])
    func nothingToDeleteCompletes(_ status: PartStatus, _ code: ErrorCode?) async throws {
        let scene = try DeletionScene(status: status, errorCode: code)
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(try Self.session(scene).status == .completed)
        #expect(scene.requests() == [])
        #expect(!Self.hasSkippedLog(scene))
    }

    @Test("RAW_SAVED で条件が偽なら完了させない（待てば真になりうる）")
    func waitingPartKeepsTheSessionOpen() async throws {
        let scene = try DeletionScene()
        try scene.replaceInRawNote(Self.pk, with: "DJIMIC3/other/other.wav", updateSHA: true)
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        let session = try Self.session(scene)
        #expect(session.status == .saved)
        #expect(session.deleteAttempts == 1)
        #expect(try Self.part(scene).status == .rawSaved)
    }

    @Test(
        "readiness が disabled なら理由を出して完了（パラメータ化: 5 語）",
        arguments: [
            "delete_source_audio_disabled", "lock_mismatch", "mount_mode_ro", "reaper_not_installed", "reaper_invalid",
        ])
    func disabledReadinessCompletesWithReason(_ reason: String) async throws {
        let scene = try DeletionScene()
        switch reason {
        case "delete_source_audio_disabled": scene.updateConfig { $0.cleanup.deleteSourceAudio = false }
        case "lock_mismatch": try scene.writeReaperConf(deleteSourceAudio: false)
        case "mount_mode_ro": scene.updateConfig { $0.device.mountMode = "ro" }
        case "reaper_not_installed": try scene.removeReaper()
        default: scene.verifier.setValid(false)
        }
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(Self.logged(scene, "source_delete_skipped session_key=DJIMIC3:20260912 reason=" + reason))
        #expect(try Self.part(scene).status == .completed)
        #expect(try Self.session(scene).status == .completed)
    }

    @Test("接続中で読み取り専用・不明なら device_readonly で完了（パラメータ化: true・nil）", arguments: [true, nil] as [Bool?])
    func readOnlyOrUnknownCompletes(_ readOnly: Bool?) async throws {
        let scene = try DeletionScene()
        await Self.stage(scene, snapshot: scene.snapshot(readOnly: readOnly)).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(Self.logged(scene, "source_delete_skipped session_key=DJIMIC3:20260912 reason=device_readonly"))
        #expect(try Self.part(scene).status == .completed)
        #expect(try Self.session(scene).status == .completed)
        #expect(scene.requests() == [])
    }

    @Test("未接続なら待つ（delete_attempts += 1、遷移しない）")
    func absentDeviceWaits() async throws {
        let scene = try DeletionScene()
        await Self.stage(scene, snapshot: scene.snapshot(includeDevice: false)).deleteSourcesIfSafe(
            sessionKey: Self.key)
        let session = try Self.session(scene)
        #expect(session.status == .saved)
        #expect(session.deleteAttempts == 1)
        #expect(try Self.part(scene).status == .rawSaved)
        #expect(!Self.hasSkippedLog(scene))
    }

    /// 既定の Part とは別の録音（一覧には在る。デバイスは接続中で列挙できている姿）
    static let otherRelpath = "TX_MIC001_20260912_100000/TX00_MIC001_20260912_100000_orig.wav"

    /// 元ファイルが無いと観測できて完了した姿（F-64）
    static func expectCompletedAsAbsent(_ scene: DeletionScene) throws {
        #expect(scene.requests() == [])
        let part = try Self.part(scene)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt == nil)
        #expect(part.deleteRequestID == nil)
        let last = try #require(try scene.store.events(entity: .recording, key: Self.pk).last)
        #expect(last.fromStatus == "RAW_SAVED")
        #expect(last.toStatus == "COMPLETED")
        #expect(last.detail == "already_absent")
        #expect(Self.logged(scene, "source_delete_skipped recording_key=" + Self.pk + " reason=already_absent"))
        let session = try Self.session(scene)
        #expect(session.status == .completed)
        #expect(session.deleteAttempts == 0)
    }

    @Test("F-64 接続中で列挙できた一覧に元ファイルが無い RAW_SAVED は、要求を書かずに完了する（source_deleted_at は入れない）")
    func observedAbsentSourceCompletes() async throws {
        let scene = try DeletionScene()
        // RAW_SAVED にした（updated_at）後の走査
        scene.clock.advance(seconds: 60)
        await Self.stage(scene, snapshot: scene.snapshot(relpaths: [Self.otherRelpath])).deleteSourcesIfSafe(
            sessionKey: Self.key)
        try Self.expectCompletedAsAbsent(scene)
    }

    @Test("TEST-28 一覧が空（録音 0 件）でも、接続中で列挙できていれば無いと観測できたとして完了する")
    func emptyListingCompletes() async throws {
        let scene = try DeletionScene()
        scene.clock.advance(seconds: 60)
        await Self.stage(scene, snapshot: scene.snapshot(relpaths: [])).deleteSourcesIfSafe(sessionKey: Self.key)
        try Self.expectCompletedAsAbsent(scene)
    }

    @Test(
        "F-64 無いと観測できなければ完了にしない（パラメータ化: 未接続・列挙できない・unavailable が観測より優先・snapshot が古い・取り込み前の snapshot）",
        arguments: ["未接続", "列挙できない", "unavailable が優先", "snapshot が古い", "取り込み前"])
    func unobservedAbsenceWaits(_ condition: String) async throws {
        let scene = try DeletionScene()
        // 既定の Part の updated_at は DeletionScene.now。以下の snapshot は（取り込み前を除き）その後の走査
        scene.clock.advance(seconds: 60)
        let listed = scene.snapshot(relpaths: [Self.otherRelpath])
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
            // 取り込みの後の走査だが、評価の時点では 901 秒たっている
            snapshot = scene.snapshot(relpaths: [Self.otherRelpath])
            scene.clock.advance(seconds: 901)
        default:
            // updated_at（秒に切り捨て）と同じ秒の中の走査 = RAW_SAVED より前でありうる
            snapshot = scene.snapshot(
                relpaths: [Self.otherRelpath], completedAt: DeletionScene.now.adding(milliseconds: 999))
        }
        await Self.stage(scene, snapshot: snapshot).deleteSourcesIfSafe(sessionKey: Self.key)
        let session = try Self.session(scene)
        #expect(session.status == .saved)
        #expect(session.deleteAttempts == 1)
        let part = try Self.part(scene)
        #expect(part.status == .rawSaved)
        #expect(part.sourceDeletedAt == nil)
        #expect(scene.requests() == [])
        #expect(!Self.hasSkippedLog(scene))
    }

    @Test("RAW_SAVED で ID を持つ Part が在れば完了させない")
    func rawSavedWithRequestIDDoesNotComplete() async throws {
        let scene = try DeletionScene()
        scene.updateConfig { $0.cleanup.deleteSourceAudio = false }
        try scene.store.updateRecording(Self.pk, [.deleteRequestID(Self.awaitingID)])
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        let session = try Self.session(scene)
        #expect(session.status == .saved)
        #expect(session.deleteAttempts == 1)
        #expect(try Self.part(scene).status == .rawSaved)
    }

    @Test("完了のとき staging を消し、FAILED の 16 kHz は残す（SM-23）")
    func cleanupFreesStagingButKeepsFailed() async throws {
        let scene = try DeletionScene()
        let failed = try scene.addPart(
            fileName: "TX00_MIC001_20260912_100000_orig.wav", folder: "TX_MIC001_20260912_100000",
            startedAt: "2026-09-12T10:00:00+09:00", status: .failed, errorCode: .whisperFailed, inRawNote: false)
        try Self.placeStaging(scene, Self.pk)
        try Self.placeStaging(scene, failed)
        await Self.stage(scene, snapshot: scene.snapshot(readOnly: true)).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(!Self.exists(scene.layout.stagingDirectory(slug: KeySlug.of(Self.pk))))
        #expect(Self.exists(scene.layout.normalizedAudio(slug: KeySlug.of(failed))))
        #expect(try Self.session(scene).status == .completed)
    }

    @Test("staging を消せなければ CLEANUP のまま、次でやり直す")
    func stagingUnlinkFailureStaysInCleanup() async throws {
        let scene = try DeletionScene()
        let blocker = scene.layout.normalizedAudio(slug: KeySlug.of(Self.pk))
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        let snapshot = scene.snapshot(readOnly: true)
        await Self.stage(scene, snapshot: snapshot).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(try Self.session(scene).status == .cleanup)
        #expect(
            scene.logLines.contains {
                $0.contains(" WARNING ")
                    && $0.hasSuffix(" disk_space_low session_key=DJIMIC3:20260912 reason=staging_unlink_failed")
            })
        try FileManager.default.removeItem(at: blocker)
        await Self.stage(scene, snapshot: snapshot).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(try Self.session(scene).status == .completed)
    }

    @Test("CLEANUP の Session は後始末だけ（ロックを見ない）")
    func cleanupSessionOnlyFinishes() async throws {
        let scene = try DeletionScene()
        try scene.moveSession(to: .cleanup)
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(try Self.session(scene).status == .completed)
        #expect(scene.requests() == [])
        #expect(await scene.runner.recorded == [])
    }

    @Test(
        "deleteEvaluated に無い Session は何もしない（パラメータ化: READY・COMPLETED）", arguments: [SessionStatus.ready, .completed])
    func notEvaluatedStatesAreIgnored(_ status: SessionStatus) async throws {
        let scene = try DeletionScene(sessionStatus: status)
        // COMPLETED の Session の Part は COMPLETED（後から RAW_SAVED になった Part は F-80 で評価する。DeletionRemainderTests）
        if status == .completed { try scene.movePart(Self.pk, to: .completed) }
        let partBefore = try Self.part(scene)
        let before = try Self.session(scene)
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        let after = try Self.session(scene)
        #expect(after.status == status)
        #expect(after.deleteAttempts == before.deleteAttempts)
        #expect(try Self.part(scene).status == partBefore.status)
        #expect(scene.requests() == [])
    }

    @Test("SOURCE_DELETE_PENDING の Session から再要求して SOURCE_DELETING へ")
    func pendingSessionRequestsAgain() async throws {
        let scene = try DeletionScene()
        try scene.movePart(Self.pk, to: .sourceDeletePending)
        try scene.moveSession(to: .sourceDeletePending)
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(scene.requests().count == 1)
        #expect(try Self.session(scene).status == .sourceDeleting)
    }

    @Test("DEL-11 回収で PENDING に落とした Part を同じ周回で再要求しない（#156）")
    func pendedPartIsNotRequestedInTheSameTick() async throws {
        let scene = try DeletionScene()
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        let deps = scene.deletionDependencies(ingest: ingest)
        #expect(await DeletionRequester(deps: deps).requestDeletions(sessionKey: Self.key) == 1)
        let id = try #require(try Self.part(scene).deleteRequestID)
        // reaper の姿: 要求を消し、拒否の結果を書く
        for url in scene.requests() { try FileManager.default.removeItem(at: url) }
        try scene.writeResult(partkey: Self.pk, requestID: id, status: .sourceIdentityMismatch, detail: "size_mismatch")
        await ResultCollector(deps: deps).collectDeleteResults(reaperScanGeneration: 0)
        await SessionDeletionStage(deps: deps).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(try Self.part(scene).status == .sourceDeletePending)
        #expect(scene.requests() == [])
        // 対照: 新しい PendedPartkeys なら要求する
        let fresh = scene.deletionDependencies(ingest: ingest, pended: PendedPartkeys())
        await SessionDeletionStage(deps: fresh).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(scene.requests().count == 1)
    }

    @Test(
        "CE cleanup.deleteEvaluationBackoffSeconds 削除評価の backoff（voicedock の 4 事例と境界。パラメータ化）",
        arguments: [
            (1, 30, false), (1, 120, true), (4, 1800, false), (4, 7200, true), (0, 60, true), (0, 59, false),
            (1, 60, true),
        ])
    func dueFollowsBackoff(_ attempts: Int, _ secondsAgo: Int, _ expected: Bool) throws {
        let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        let now = DeletionScene.now
        let updatedAt = zone.iso(now.adding(seconds: -secondsAgo))
        #expect(
            SessionDeletionStage.isDue(
                updatedAt: updatedAt, attempts: attempts, now: now, backoff: [60, 300, 900, 3600], zone: zone)
                == expected)
        // backoff を [5] にすると (1, 30) は真（既定では偽）
        if attempts == 1 && secondsAgo == 30 {
            #expect(SessionDeletionStage.isDue(updatedAt: updatedAt, attempts: 1, now: now, backoff: [5], zone: zone))
        }
    }

    @Test("updated_at が読めなければすぐ評価")
    func brokenUpdatedAtIsDue() throws {
        let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        #expect(
            SessionDeletionStage.isDue(
                updatedAt: "not-a-time", attempts: 1, now: DeletionScene.now, backoff: [60, 300, 900, 3600], zone: zone)
        )
    }

    @Test("TEST-28 Part 0 件の Session は要求を書かずに完了する")
    func emptySessionCompletesWithoutRequest() async throws {
        let scene = try DeletionScene()
        let empty = "DJIMIC3:20260913"
        try scene.addSession(key: empty, dayDate: "2026-09-13")
        try scene.moveSession(to: .saved, sessionKey: empty)
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: empty)
        #expect(scene.requests() == [])
        #expect(try Self.session(scene, empty).status == .completed)
        #expect(!Self.hasSkippedLog(scene))
    }

    @Test("対象は deleteEvaluated だけ、updated_at, session_key の順")
    func dueSessionKeysFiltersAndOrders() throws {
        let scene = try DeletionScene()
        scene.clock.set(DeletionScene.now.adding(seconds: -3600))
        try scene.addSession(key: "DJIMIC3:20260911", dayDate: "2026-09-11")
        try scene.moveSession(to: .saved, sessionKey: "DJIMIC3:20260911")
        scene.clock.set(DeletionScene.now.adding(seconds: -7200))
        try scene.addSession(key: "DJIMIC3:20260910", dayDate: "2026-09-10")
        try scene.moveSession(to: .saved, sessionKey: "DJIMIC3:20260910")
        try scene.addSession(key: "DJIMIC3:20260909", dayDate: "2026-09-09")
        try scene.moveSession(to: .completed, sessionKey: "DJIMIC3:20260909")
        scene.clock.set(DeletionScene.now)
        #expect(Self.stage(scene).dueSessionKeys() == ["DJIMIC3:20260910", "DJIMIC3:20260911"])
    }
}
