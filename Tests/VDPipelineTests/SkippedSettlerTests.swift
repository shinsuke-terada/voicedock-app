// SkippedSettler（根拠 B。PLAN §8.9.5。T-39 §6.2）: ロック B・間引き・デバイスに在るもの・結果待ち・DEL-11・SKIPPED のまま（SM-20）。
// 舞台は三重ロックを全部外した DeletionScene。/Volumes には触れない（volumesRoot は TempDirectory）。
import Darwin
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

/// 最初の open のときに一度だけ side を呼ぶ VolumeOpener（中身は FakeVolumeOpener）。一覧の後・読み直しの前に行が変わる姿を作る
final class SideEffectVolumeOpener: VolumeOpener {
    private let inner = FakeVolumeOpener()
    private let fired = Mutex(false)
    private let side: @Sendable () -> Void

    init(side: @escaping @Sendable () -> Void) {
        self.side = side
    }

    func open(volumesRoot: String, deviceID: String) -> VolumeOpenResult {
        let first = fired.withLock { done in
            defer { done = true }
            return !done
        }
        if first { side() }
        return inner.open(volumesRoot: volumesRoot, deviceID: deviceID)
    }
}

@Suite("SkippedSettler")
struct SkippedSettlerTests {
    static let pk = DeletionScene.partkey

    /// 無音の舞台
    static func noSpeechScene() throws -> DeletionScene {
        try DeletionScene(status: .skipped, errorCode: .noSpeechDetected)
    }

    /// ロック B を開ける（その後で deps を作る）
    static func openLockB(_ scene: DeletionScene) {
        scene.updateConfig { $0.cleanup.deleteSkippedSource = true }
    }

    /// 今の設定と今の時刻の snapshot で deps を作る
    static func deps(
        _ scene: DeletionScene, snapshot: DeviceSnapshot? = nil, pended: PendedPartkeys = PendedPartkeys()
    ) -> DeletionDependencies {
        scene.deletionDependencies(ingest: ScriptedIngest(snapshot: snapshot ?? scene.snapshot()), pended: pended)
    }

    static func settle(_ deps: DeletionDependencies) async -> Int {
        await SkippedSettler(deps: deps).settleSkippedDeletions()
    }

    static func part(_ scene: DeletionScene, _ pk: String = Self.pk) throws -> RecordingRow {
        try #require(try scene.store.recording(pk))
    }

    static func requestedPartkeys(_ scene: DeletionScene) throws -> [String] {
        try scene.requests().map { try ContractJSON.decodeRequest(try Data(contentsOf: $0)).get().partkey }
    }

    @Test("CE cleanup.deleteSkippedSource 偽なら何も読まない")
    func lockBClosedReadsNothing() async throws {
        let scene = try Self.noSpeechScene()
        scene.clock.advance(seconds: 60)
        #expect(await Self.settle(Self.deps(scene)) == 0)
        // readiness も評価しない（署名の検証が 1 回も走らない）
        #expect(scene.verifier.verifiedURLs == [])
        #expect(scene.requests() == [])
        // 対照: ロック B を開けた同じ舞台では 1
        Self.openLockB(scene)
        #expect(await Self.settle(Self.deps(scene)) == 1)
    }

    @Test("SKIPPED になった直後は backoff の先頭の秒数だけ待つ")
    func recentSkipWaitsForTheFirstBackoff() async throws {
        let scene = try Self.noSpeechScene()
        Self.openLockB(scene)
        let deps = Self.deps(scene)
        #expect(await Self.settle(deps) == 0)
        scene.clock.advance(seconds: 59)
        #expect(await Self.settle(deps) == 0)
        scene.clock.advance(seconds: 1)
        #expect(await Self.settle(deps) == 1)
    }

    @Test("間引きは backoff の先頭の値（最小値ではない）")
    func backoffUsesTheFirstElementNotTheMinimum() async throws {
        let scene = try Self.noSpeechScene()
        scene.updateConfig {
            $0.cleanup.deleteSkippedSource = true
            $0.cleanup.deleteEvaluationBackoffSeconds = [300, 60, 900, 3600]
        }
        let deps = Self.deps(scene)
        scene.clock.advance(seconds: 60)
        #expect(await Self.settle(deps) == 0)
        scene.clock.advance(seconds: 240)
        #expect(await Self.settle(deps) == 1)
    }

    @Test("デバイスに今在るものだけを評価する")
    func onlyPartsOnTheDeviceAreEvaluated() async throws {
        let scene = try Self.noSpeechScene()
        let gone = try scene.addPart(
            fileName: "TX00_MIC001_20260912_100000_orig.wav", folder: "TX_MIC001_20260912_100000",
            startedAt: "2026-09-12T10:00:00+09:00", status: .skipped, errorCode: .noSpeechDetected, onDevice: false)
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        #expect(await Self.settle(Self.deps(scene)) == 1)
        #expect(try Self.requestedPartkeys(scene) == [DeletionScene.partkey])
        #expect(try Self.part(scene, gone).deleteRequestID == nil)
    }

    @Test("snapshot が古い・無ければ何もしない（パラメータ化）", arguments: [901, nil] as [Int?])
    func staleSnapshotDoesNothing(_ ageSeconds: Int?) async throws {
        let scene = try Self.noSpeechScene()
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        let snapshot = ageSeconds.map { scene.snapshot(completedAt: scene.clock.now().adding(seconds: -$0)) }
        let deps = scene.deletionDependencies(ingest: ScriptedIngest(snapshot: snapshot))
        #expect(await Self.settle(deps) == 0)
        #expect(scene.requests() == [])
    }

    @Test("ロック 1 は根拠 B にも掛かる")
    func lockOneAlsoStopsGroundB() async throws {
        let scene = try Self.noSpeechScene()
        scene.updateConfig {
            $0.cleanup.deleteSkippedSource = true
            $0.cleanup.deleteSourceAudio = false
        }
        scene.clock.advance(seconds: 60)
        #expect(await Self.settle(Self.deps(scene)) == 0)
        #expect(scene.requests() == [])
    }

    @Test("ロック 2-B も根拠 B に掛かる")
    func readOnlyAlsoStopsGroundB() async throws {
        let scene = try Self.noSpeechScene()
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        #expect(await Self.settle(Self.deps(scene, snapshot: scene.snapshot(readOnly: true))) == 0)
        #expect(scene.requests() == [])
    }

    @Test("要求を書いても SKIPPED と error_code が変わらない（SM-20）")
    func staysSkippedAndKeepsItsReason() async throws {
        let scene = try Self.noSpeechScene()
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        let before = try scene.store.events(entity: .recording, key: Self.pk).count
        #expect(await Self.settle(Self.deps(scene)) == 1)
        let part = try Self.part(scene)
        #expect(part.status == .skipped)
        #expect(part.errorCode == .noSpeechDetected)
        #expect(part.deleteRequestID != nil)
        #expect(try scene.store.events(entity: .recording, key: Self.pk).count == before)
    }

    @Test("結果待ち（ID が在る）は再要求しない")
    func awaitingPartIsNotRequestedAgain() async throws {
        let scene = try Self.noSpeechScene()
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        let deps = Self.deps(scene)
        #expect(await Self.settle(deps) == 1)
        scene.clock.advance(seconds: 60)
        #expect(await Self.settle(deps) == 0)
        #expect(scene.requests().count == 1)
    }

    @Test("source_deleted_at が在れば要求しない")
    func alreadyDeletedIsNotRequested() async throws {
        // ファイルはデバイスに置いたまま（事前確認はデバイスに在ることで通る）
        let scene = try Self.noSpeechScene()
        try scene.store.updateRecording(Self.pk, [.sourceDeletedAt("2026-09-12T11:00:00+09:00")])
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        #expect(await Self.settle(Self.deps(scene)) == 0)
        #expect(scene.requests() == [])
    }

    @Test("session_key が無ければ飛ばす")
    func withoutSessionKeyIsSkipped() async throws {
        let scene = try Self.noSpeechScene()
        try scene.store.updateRecording(Self.pk, [.sessionKey(nil)])
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        #expect(await Self.settle(Self.deps(scene)) == 0)
        #expect(scene.requests() == [])
    }

    @Test("この tick で拒否した Part は再要求しない（DEL-11）")
    func pendedThisTickIsNotRequested() async throws {
        let scene = try Self.noSpeechScene()
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        let pended = PendedPartkeys()
        pended.insert(Self.pk)
        #expect(await Self.settle(Self.deps(scene, pended: pended)) == 0)
        #expect(scene.requests() == [])
        // 対照: 新しい PendedPartkeys では 1
        #expect(await Self.settle(Self.deps(scene, pended: PendedPartkeys())) == 1)
    }

    @Test("要求を出していない古い SKIPPED を結果待ちと見ない")
    func oldSkippedWithoutRequestIsNotTreatedAsWaiting() async throws {
        let scene = try Self.noSpeechScene()
        Self.openLockB(scene)
        scene.clock.advance(seconds: 3600 + 60)
        let deps = Self.deps(scene)
        await RequestExpirer(deps: deps).expireDeleteRequests()
        #expect(!scene.logLines.contains { $0.contains(" source_delete_pending ") })
        #expect(await Self.settle(deps) == 1)
    }

    @Test("② が書けなければ ID を外して SKIPPED のまま")
    func queueWriteFailureKeepsSkipped() async throws {
        let scene = try Self.noSpeechScene()
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        let dir = scene.layout.queueDelete.path(percentEncoded: false)
        #expect(chmod(dir, 0o555) == 0)
        defer { _ = chmod(dir, 0o755) }
        #expect(await Self.settle(Self.deps(scene)) == 0)
        let part = try Self.part(scene)
        #expect(part.deleteRequestID == nil)
        #expect(part.status == .skipped)
        #expect(
            scene.logLines.contains {
                $0.contains(" WARNING ")
                    && $0.hasSuffix(
                        " source_delete_pending recording_key=" + Self.pk
                            + " reason=queue_write_failed error_code=DELETE_QUEUE_FAILED")
            })
    }

    @Test("duplicate_of が nil の重複は要求しない（v5.55 以前の重複）")
    func duplicateWithoutRecordedTwinIsNotRequested() async throws {
        let scene = try DeletionScene()
        let dup = try scene.addPart(
            fileName: "TX00_MIC002_20260912_093000_orig.wav", startedAt: "2026-09-12T09:30:00+09:00",
            status: .skipped, errorCode: .duplicateContent, duplicateOf: nil, transcript: false, inRawNote: false)
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        #expect(await Self.settle(Self.deps(scene)) == 0)
        #expect(scene.requests() == [])
        #expect(try Self.part(scene, dup).deleteRequestID == nil)
    }

    @Test("双子が別の日でも双子の Session で根拠 A を見る")
    func twinInAnotherSessionIsUsed() async throws {
        let scene = try DeletionScene()
        let otherDay = "DJIMIC3:20260911"
        try scene.addSession(key: otherDay, dayDate: "2026-09-11")
        let twin = try scene.addPart(
            fileName: "TX00_MIC001_20260911_090000_orig.wav", folder: "TX_MIC001_20260911_090000",
            startedAt: "2026-09-11T09:00:00+09:00", status: .rawSaved, sessionKey: otherDay)
        try scene.writeRawNote(sessionKey: otherDay)
        let dup = try scene.addPart(
            fileName: "TX00_MIC002_20260912_093000_orig.wav", startedAt: "2026-09-12T09:30:00+09:00",
            status: .skipped, errorCode: .duplicateContent, duplicateOf: twin, transcript: false, inRawNote: false)
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        #expect(await Self.settle(Self.deps(scene)) == 1)
        #expect(try Self.requestedPartkeys(scene) == [dup])
    }

    @Test("一覧の後に決着した Part には要求しない（読み直し）")
    func readsTheRowAgainBeforeRequesting() async throws {
        let scene = try Self.noSpeechScene()
        let pk2 = try scene.addPart(
            fileName: "TX00_MIC001_20260912_100000_orig.wav", folder: "TX_MIC001_20260912_100000",
            startedAt: "2026-09-12T10:00:00+09:00", status: .skipped, errorCode: .noSpeechDetected)
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        let store = scene.store
        // 既定の Part の事前確認で最初に open したとき、2 本目の行を決着済みにする（一覧はもう取ってある）
        let opener = SideEffectVolumeOpener {
            _ = try? store.updateRecording(pk2, [.sourceDeletedAt("2026-09-12T12:00:30+09:00")])
        }
        let deps = scene.deletionDependencies(ingest: ScriptedIngest(snapshot: scene.snapshot()), opener: opener)
        #expect(await Self.settle(deps) == 1)
        #expect(try Self.requestedPartkeys(scene) == [DeletionScene.partkey])
        #expect(try Self.part(scene, pk2).deleteRequestID == nil)
    }

    @Test("SKIPPED が無ければ 0（TEST-28）")
    func emptySkippedListDoesNothing() async throws {
        let scene = try DeletionScene()
        Self.openLockB(scene)
        scene.clock.advance(seconds: 60)
        #expect(await Self.settle(Self.deps(scene)) == 0)
        #expect(scene.requests() == [])
    }
}
