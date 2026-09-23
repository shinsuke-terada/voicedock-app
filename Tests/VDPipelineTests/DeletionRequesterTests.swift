// Part の削除要求（PLAN §8.9.5 requestDeletions・§4.4 の書く順。T-38 §6.3）。舞台は DeletionScene（/Volumes には触れない）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

@Suite("DeletionRequester")
struct DeletionRequesterTests {
    static let pk = DeletionScene.partkey
    static let awaitingID = "20260912T030000Z-8483e42457304a9d-abcdef"

    /// 既定の準備（ingest は既定の snapshot）
    static func setUp(_ scene: DeletionScene, snapshot: DeviceSnapshot? = nil) -> (ScriptedIngest, DeletionDependencies)
    {
        let ingest = ScriptedIngest(snapshot: snapshot ?? scene.snapshot())
        return (ingest, scene.deletionDependencies(ingest: ingest))
    }

    static func request(_ deps: DeletionDependencies, _ key: String = DeletionScene.sessionKey) async -> Int {
        await DeletionRequester(deps: deps).requestDeletions(sessionKey: key)
    }

    static func part(_ scene: DeletionScene, _ pk: String = pk) throws -> RecordingRow {
        try #require(try scene.store.recording(pk))
    }

    static func onlyRequest(_ scene: DeletionScene) throws -> (DeleteRequest, String) {
        let url = try #require(scene.requests().first)
        let data = try Data(contentsOf: url)
        return (try ContractJSON.decodeRequest(data).get(), String(decoding: data, as: UTF8.self))
    }

    static func logged(_ scene: DeletionScene, _ body: String) -> Bool {
        scene.logLines.contains { $0.hasSuffix(" " + body) }
    }

    @Test("DEL-12 要求の size / mtime は DB の値（原本）、時刻は UTC の Z 付き")
    func requestCarriesOriginalValues() async throws {
        let scene = try DeletionScene()
        let (_, deps) = Self.setUp(scene)
        #expect(await Self.request(deps) == 1)
        let (request, _) = try Self.onlyRequest(scene)
        #expect(request.target.size == 4096)
        #expect(request.target.mtime == (try Self.part(scene).sourceMtime))
        #expect(request.createdAt == "2026-09-12T12:00:00+09:00")
        #expect(request.requestID.hasPrefix("20260912T030000Z-8483e42457304a9d-"))
    }

    @Test("PR-17 要求に絶対パス・`..`・`.` 始まりの要素が無い")
    func requestHasNoAbsolutePath() async throws {
        let scene = try DeletionScene()
        let (_, deps) = Self.setUp(scene)
        #expect(await Self.request(deps) == 1)
        let (request, text) = try Self.onlyRequest(scene)
        #expect(!text.contains(scene.volumesRoot.path(percentEncoded: false)))
        #expect(!text.contains("/Volumes"))
        let elements = request.target.relpath.split(separator: "/", omittingEmptySubsequences: false)
        #expect(!elements.isEmpty)
        for element in elements {
            #expect(!element.isEmpty)
            #expect(element != "." && element != "..")
            #expect(!element.hasPrefix("."))
        }
    }

    @Test("②が失敗したら ID を外し DELETE_QUEUE_FAILED を出して遷移しない")
    func queueWriteFailureRollsBackTheID() async throws {
        let scene = try DeletionScene()
        let (_, deps) = Self.setUp(scene)
        let dir = scene.layout.queueDelete.path(percentEncoded: false)
        #expect(chmod(dir, 0o555) == 0)
        defer { _ = chmod(dir, 0o755) }
        #expect(await Self.request(deps) == 0)
        let part = try Self.part(scene)
        #expect(part.deleteRequestID == nil)
        #expect(part.status == .rawSaved)
        #expect(
            scene.logLines.contains {
                $0.contains(" WARNING ")
                    && $0.hasSuffix(
                        " source_delete_pending recording_key=" + Self.pk
                            + " reason=queue_write_failed error_code=DELETE_QUEUE_FAILED")
            })
    }

    @Test("① は状態が変わっていれば書かない（status_changed）")
    func writerRefusesAStaleRow() async throws {
        let scene = try DeletionScene()
        let (_, deps) = Self.setUp(scene)
        let stale = try Self.part(scene)
        try scene.movePart(Self.pk, to: .completed)
        #expect(try RequestWriter(deps: deps).write(part: stale, sessionKey: DeletionScene.sessionKey) == nil)
        #expect(try Self.part(scene).deleteRequestID == nil)
        #expect(scene.requests() == [])
        #expect(Self.logged(scene, "source_delete_skipped recording_key=" + Self.pk + " reason=status_changed"))
    }

    @Test("DEL-20 snapshot が古い・無ければ 0（パラメータ化）", arguments: ["901 秒前", "無い"])
    func staleSnapshotWritesNothing(_ kind: String) async throws {
        let scene = try DeletionScene()
        let ingest = ScriptedIngest(
            snapshot: kind == "無い" ? nil : scene.snapshot(completedAt: DeletionScene.now.adding(seconds: -901)))
        let deps = scene.deletionDependencies(ingest: ingest)
        #expect(await Self.request(deps) == 0)
        // ロックも評価しない
        #expect(scene.verifier.verifiedURLs == [])
    }

    @Test("ちょうど 900 秒は新鮮")
    func freshnessBoundaryIsInclusive() async throws {
        let scene = try DeletionScene()
        let (_, deps) = Self.setUp(
            scene, snapshot: scene.snapshot(completedAt: DeletionScene.now.adding(seconds: -900)))
        #expect(await Self.request(deps) == 1)
    }

    @Test("CE device.snapshotMaxAgeSeconds が新鮮さの境になる")
    func ceSnapshotMaxAgeSeconds() async throws {
        // 既定の 900 では 100 秒前は新鮮
        let base = try DeletionScene()
        let (_, baseDeps) = Self.setUp(
            base, snapshot: base.snapshot(completedAt: DeletionScene.now.adding(seconds: -100)))
        #expect(await Self.request(baseDeps) == 1)
        // 61 にすると 100 秒前は古い（scanIntervalSeconds は CV-46 を満たすよう 60 にする）
        let tight = try DeletionScene()
        tight.updateConfig {
            $0.device.snapshotMaxAgeSeconds = 61
            $0.device.scanIntervalSeconds = 60
        }
        let (_, tightDeps) = Self.setUp(
            tight, snapshot: tight.snapshot(completedAt: DeletionScene.now.adding(seconds: -100)))
        #expect(await Self.request(tightDeps) == 0)
        // 61 秒前なら新鮮
        let edge = try DeletionScene()
        edge.updateConfig {
            $0.device.snapshotMaxAgeSeconds = 61
            $0.device.scanIntervalSeconds = 60
        }
        let (_, edgeDeps) = Self.setUp(
            edge, snapshot: edge.snapshot(completedAt: DeletionScene.now.adding(seconds: -61)))
        #expect(await Self.request(edgeDeps) == 1)
    }

    @Test("CE cleanup.deleteSourceAudio false なら要求を 1 件も書かない")
    func disabledReadinessWritesNothing() async throws {
        let scene = try DeletionScene()
        scene.updateConfig { $0.cleanup.deleteSourceAudio = false }
        let (_, deps) = Self.setUp(scene)
        #expect(await Self.request(deps) == 0)
        #expect(scene.requests() == [])
        // 対照: 既定の舞台（true）は 1 件書く
        let enabled = try DeletionScene()
        let (_, enabledDeps) = Self.setUp(enabled)
        #expect(await Self.request(enabledDeps) == 1)
    }

    @Test("SOURCE_DELETING と COMPLETED は飛ばす（パラメータ化）", arguments: [PartStatus.sourceDeleting, .completed])
    func skipsSourceDeletingAndCompleted(_ status: PartStatus) async throws {
        let scene = try DeletionScene()
        try scene.movePart(Self.pk, to: status)
        let (_, deps) = Self.setUp(scene)
        #expect(await Self.request(deps) == 0)
        #expect(scene.requests() == [])
    }

    @Test("delete_request_id が在れば飛ばす")
    func skipsPartsAwaitingAResult() async throws {
        let scene = try DeletionScene()
        try scene.store.updateRecording(Self.pk, [.deleteRequestID(Self.awaitingID)])
        let (_, deps) = Self.setUp(scene)
        #expect(await Self.request(deps) == 0)
    }

    @Test("DEL-11 この tick で PENDING に落とした Part は再要求しない")
    func skipsPartsPendedThisTick() async throws {
        let scene = try DeletionScene()
        try scene.movePart(Self.pk, to: .sourceDeletePending)
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        let pended = PendedPartkeys()
        pended.insert(Self.pk)
        #expect(await Self.request(scene.deletionDependencies(ingest: ingest, pended: pended)) == 0)
        // 対照: 新しい PendedPartkeys なら要求する
        #expect(await Self.request(scene.deletionDependencies(ingest: ingest, pended: PendedPartkeys())) == 1)
        #expect(try Self.part(scene).status == .sourceDeleting)
    }

    @Test("SOURCE_DELETE_PENDING から再要求できる（#154）")
    func pendingPartIsRetried() async throws {
        let scene = try DeletionScene()
        try scene.movePart(Self.pk, to: .sourceDeletePending)
        let (_, deps) = Self.setUp(scene)
        #expect(await Self.request(deps) == 1)
        let last = try #require(try scene.store.events(entity: .recording, key: Self.pk).last)
        #expect(last.fromStatus == "SOURCE_DELETE_PENDING" && last.toStatus == "SOURCE_DELETING")
    }

    @Test("先の Part を飛ばしても残りを評価する")
    func oneSkippedPartDoesNotStopTheRest() async throws {
        let scene = try DeletionScene()
        try scene.addPart(
            fileName: "TX00_MIC001_20260912_080000_orig.wav", folder: "TX_MIC001_20260912_080000",
            startedAt: "2026-09-12T08:00:00+09:00", status: .sourceDeleting, inRawNote: true)
        try scene.writeRawNote()
        let (_, deps) = Self.setUp(scene)
        #expect(await Self.request(deps) == 1)
        #expect(try Self.part(scene).status == .sourceDeleting)
    }

    @Test("Session の全 Part を評価する（その Part だけでない）")
    func everyEligiblePartIsRequested() async throws {
        let scene = try DeletionScene()
        try scene.addPart(
            fileName: "TX00_MIC001_20260912_100000_orig.wav", folder: "TX_MIC001_20260912_100000",
            startedAt: "2026-09-12T10:00:00+09:00", status: .rawSaved)
        try scene.writeRawNote()
        let (_, deps) = Self.setUp(scene)
        #expect(await Self.request(deps) == 2)
        #expect(scene.requests().count == 2)
    }

    @Test("Session が OPEN でも要求を書く（AY-1）")
    func doesNotGateOnSessionStatus() async throws {
        let scene = try DeletionScene(sessionStatus: .open)
        let (_, deps) = Self.setUp(scene)
        #expect(await Self.request(deps) == 1)
    }

    static let otherRelpath = "TX_MIC001_20260912_100000/TX00_MIC001_20260912_100000_orig.wav"

    /// 既定の Part とは別の録音だけが一覧に在る snapshot（接続中で列挙できている）。
    /// 時計を 60 秒進め、Part を RAW_SAVED にした（updated_at = DeletionScene.now）後の走査にする
    static func absentSnapshot(_ scene: DeletionScene) -> DeviceSnapshot {
        scene.clock.advance(seconds: 60)
        return scene.snapshot(relpaths: [otherRelpath])
    }

    @Test("F-64 一覧に在る RAW_SAVED は無いと扱わず、要求を書く通常の経路へ進む")
    func listedSourceIsRequested() async throws {
        let scene = try DeletionScene()
        // 取り込みより後の走査（ほかの条件はすべて「無い」と言える姿にし、一覧に在ることだけで要求の経路へ進むことを見る）
        scene.clock.advance(seconds: 60)
        let (_, deps) = Self.setUp(
            scene, snapshot: scene.snapshot(relpaths: [DeletionScene.relpath, Self.otherRelpath]))
        #expect(await Self.request(deps) == 1)
        #expect(try Self.part(scene).status == .sourceDeleting)
        #expect(!scene.logLines.contains { $0.contains(" source_delete_skipped ") })
    }

    @Test("F-64 一覧に無い RAW_SAVED は要求を書かずに RAW_SAVED→COMPLETED（detail already_absent）")
    func absentRawSavedCompletesWithoutRequest() async throws {
        let scene = try DeletionScene()
        let (_, deps) = Self.setUp(scene, snapshot: Self.absentSnapshot(scene))
        #expect(await Self.request(deps) == 0)
        #expect(scene.requests() == [])
        let part = try Self.part(scene)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt == nil)
        #expect(part.deleteRequestID == nil)
        #expect(Self.logged(scene, "source_delete_skipped recording_key=" + Self.pk + " reason=already_absent"))
    }

    @Test(
        "F-64 取り込み前の snapshot では完了にしない（updated_at と同じ秒・前の走査。境界: ちょうど 1 秒後なら完了）",
        arguments: [(Int64(-60_000), false), (0, false), (999, false), (1000, true)])
    func snapshotBeforeIngestionDoesNotComplete(_ offsetMillis: Int64, _ completes: Bool) async throws {
        let scene = try DeletionScene()
        scene.clock.advance(seconds: 60)
        let snapshot = scene.snapshot(
            relpaths: [Self.otherRelpath], completedAt: DeletionScene.now.adding(milliseconds: offsetMillis))
        let (_, deps) = Self.setUp(scene, snapshot: snapshot)
        #expect(await Self.request(deps) == 0)
        #expect(try Self.part(scene).status == (completes ? .completed : .rawSaved))
        #expect(scene.requests() == [])
    }

    @Test("F-64 結果待ち（delete_request_id が在る）の RAW_SAVED は一覧に無くても完了にしない")
    func absentAwaitingResultIsNotCompleted() async throws {
        let scene = try DeletionScene()
        try scene.store.updateRecording(Self.pk, [.deleteRequestID(Self.awaitingID)])
        let (_, deps) = Self.setUp(scene, snapshot: Self.absentSnapshot(scene))
        #expect(await Self.request(deps) == 0)
        #expect(try Self.part(scene).status == .rawSaved)
    }

    @Test("F-64 source_path が無い・空なら無いと確かめられないので完了にしない（パラメータ化）", arguments: [String?.none, ""])
    func missingSourcePathIsNotAbsent(_ sourcePath: String?) async throws {
        let scene = try DeletionScene()
        try StorePaths.setSourcePath(scene.store, partkey: Self.pk, sourcePath)
        let (_, deps) = Self.setUp(scene, snapshot: Self.absentSnapshot(scene))
        #expect(await Self.request(deps) == 0)
        #expect(try Self.part(scene).status == .rawSaved)
        #expect(!scene.logLines.contains { $0.contains(" source_delete_skipped ") })
    }

    @Test("F-64 読み取り専用で接続中でも、無いと観測できれば完了する（消さないので観測値の書き込み可否は問わない）")
    func absentOnReadOnlyDeviceCompletes() async throws {
        let scene = try DeletionScene()
        scene.clock.advance(seconds: 60)
        let snapshot = scene.snapshot(readOnly: true, relpaths: [Self.otherRelpath])
        let (_, deps) = Self.setUp(scene, snapshot: snapshot)
        #expect(await Self.request(deps) == 0)
        #expect(try Self.part(scene).status == .completed)
    }

    @Test("TEST-28 Part 0 件の Session は 0")
    func emptySessionWritesNothing() async throws {
        let scene = try DeletionScene()
        try scene.addSession(key: "DJIMIC3:20260913", dayDate: "2026-09-13")
        let (_, deps) = Self.setUp(scene)
        #expect(await Self.request(deps, "DJIMIC3:20260913") == 0)
    }

    @Test("Session が無ければ 0")
    func missingSessionWritesNothing() async throws {
        let scene = try DeletionScene()
        let (_, deps) = Self.setUp(scene)
        #expect(await Self.request(deps, "DJIMIC3:20990101") == 0)
        #expect(!scene.logLines.contains { $0.contains(" config_warning ") })
    }
}
