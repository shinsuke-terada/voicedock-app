// 消せないまま待つのをやめる（PLAN §8.9.2・§8.9.5 の 5a・§8.11 の undeletableSources。F-69・issue #98）。
// 元ファイルは一覧に在るのに canDeleteSource が偽のまま変わらない RAW_SAVED を、期限で消さずに完了させ、要対応で知らせる。
// 舞台は DeletionScene（/Volumes には触れない）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

@Suite("UndeletableSettlement")
struct UndeletableSettlementTests {
    static let pk = DeletionScene.partkey
    static let key = DeletionScene.sessionKey
    /// 既定の backoff（60, 300, 900, 3600）の段の数と合計
    static let backoffCount = 4
    static let backoffTotal = 4860
    static let otherRelpath = "TX_MIC001_20260912_100000/TX00_MIC001_20260912_100000_orig.wav"

    static func stage(_ scene: DeletionScene, snapshot: DeviceSnapshot? = nil) -> SessionDeletionStage {
        SessionDeletionStage(
            deps: scene.deletionDependencies(ingest: ScriptedIngest(snapshot: snapshot ?? scene.snapshot())))
    }

    static func part(_ scene: DeletionScene) throws -> RecordingRow {
        try #require(try scene.store.recording(Self.pk))
    }

    static func session(_ scene: DeletionScene) throws -> SessionRow {
        try #require(try scene.store.session(Self.key))
    }

    static func lastEvent(_ scene: DeletionScene) throws -> EventRow {
        try #require(try scene.store.events(entity: .recording, key: Self.pk).last)
    }

    static func settledLog(_ scene: DeletionScene) -> Bool {
        scene.logLines.contains {
            $0.hasSuffix(" source_delete_skipped recording_key=" + Self.pk + " reason=not_deletable")
        }
    }

    static func settledParts(_ scene: DeletionScene) throws -> [RecordingRow] {
        let ro = try #require(ReadOnlyStore.open(url: scene.layout.database))
        return try ro.completedParts(lastDetail: DeletionReason.notDeletable)
    }

    /// canDeleteSource を偽にする（元ファイルはデバイスに在るまま。待っても変わらない原因）
    static func breakDeletability(_ scene: DeletionScene, _ cause: String) throws {
        switch cause {
        case "Raw ノートの手の編集":
            try scene.appendToRawNote("\n手で書き足した行\n")
        case "原本のサイズの食い違い":
            try scene.store.updateRecording(Self.pk, [.sourceSize(8192)])
        case "transcript の欠け":
            try FileManager.default.removeItem(at: scene.transcriptURL(Self.pk))
        default:
            // source_path が無い（一覧と照らせない）
            try StorePaths.setSourcePath(scene.store, partkey: Self.pk, nil)
        }
    }

    /// delete_attempts を attempts にし、Part を RAW_SAVED にした時刻（DeletionScene.now）から seconds 秒進める
    static func elapse(_ scene: DeletionScene, attempts: Int, seconds: Int) throws {
        try scene.store.updateSession(Self.key, [.deleteAttempts(attempts)])
        scene.clock.advance(seconds: seconds)
    }

    /// 決着せずに待った姿（delete_attempts += 1、遷移しない、ログなし）
    static func expectWaited(_ scene: DeletionScene, attempts: Int) throws {
        let session = try Self.session(scene)
        #expect(session.status == .saved)
        #expect(session.deleteAttempts == attempts + 1)
        let part = try Self.part(scene)
        #expect(part.status == .rawSaved)
        #expect(part.sourceDeletedAt == nil)
        #expect(!Self.settledLog(scene))
        #expect(scene.requests() == [])
    }

    // MARK: - 期限

    @Test(
        "F-69 期限の前は待つ（パラメータ化: backoff を使い切っていない・RAW_SAVED から合計に 1 秒足りない）",
        arguments: [(3, 100_000), (4, 4859)])
    func beforeTheDeadlineWaits(_ attempts: Int, _ seconds: Int) async throws {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, "Raw ノートの手の編集")
        try Self.elapse(scene, attempts: attempts, seconds: seconds)
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        try Self.expectWaited(scene, attempts: attempts)
    }

    @Test(
        "F-69 期限を過ぎたら消さずに RAW_SAVED→COMPLETED（detail not_deletable）で Session も完了する（パラメータ化: 原因 4 つ）",
        arguments: ["Raw ノートの手の編集", "原本のサイズの食い違い", "transcript の欠け", "source_path が無い"])
    func atTheDeadlineSettlesWithoutDeleting(_ cause: String) async throws {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, cause)
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        let part = try Self.part(scene)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt == nil)
        #expect(part.deleteRequestID == nil)
        let last = try Self.lastEvent(scene)
        #expect(last.fromStatus == "RAW_SAVED")
        #expect(last.toStatus == "COMPLETED")
        #expect(last.detail == "not_deletable")
        #expect(Self.settledLog(scene))
        #expect(scene.requests() == [])
        // 元ファイルはデバイスに残る
        #expect(
            FileManager.default.fileExists(
                atPath: scene.deviceRoot.appendingPathComponent(DeletionScene.relpath).path(percentEncoded: false)))
        let session = try Self.session(scene)
        #expect(session.status == .completed)
        #expect(session.sourceDeletedAt == nil)
    }

    @Test("F-69 backoff どおりに評価を重ねると、使い切った次の評価（SAVED から合計 4860 秒）で決着する")
    func evaluationsFollowTheBackoffUntilSettled() async throws {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, "原本のサイズの食い違い")
        // SAVED の直後の 1 回（backoff を見ない）
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(try Self.session(scene).deleteAttempts == 1)
        for (index, delay) in [60, 300, 900, 3600].enumerated() {
            scene.clock.advance(seconds: delay - 1)
            #expect(Self.stage(scene).dueSessionKeys() == [])
            scene.clock.advance(seconds: 1)
            let stage = Self.stage(scene)
            #expect(stage.dueSessionKeys() == [Self.key])
            await stage.deleteSourcesIfSafe(sessionKey: Self.key)
            if index < 3 {
                #expect(try Self.part(scene).status == .rawSaved)
                #expect(try Self.session(scene).deleteAttempts == index + 2)
            }
        }
        #expect(try Self.part(scene).status == .completed)
        #expect(try Self.lastEvent(scene).detail == "not_deletable")
        #expect(try Self.session(scene).status == .completed)
    }

    // MARK: - 観測できないうちは決着させない

    @Test(
        "F-69 期限を過ぎても観測できなければ決着しない（パラメータ化: 未接続・列挙できない・unavailable が優先・snapshot が古い・Vault が使えない）",
        arguments: ["未接続", "列挙できない", "unavailable が優先", "snapshot が古い", "Vault が使えない"])
    func unobservedDoesNotSettle(_ condition: String) async throws {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, "Raw ノートの手の編集")
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        let listed = scene.snapshot()
        let snapshot: DeviceSnapshot
        switch condition {
        case "未接続":
            snapshot = scene.snapshot(includeDevice: false)
        case "列挙できない":
            snapshot = DeviceSnapshot(
                generation: 1, completedAt: scene.clock.now(), connectEpoch: 1, devices: [:],
                unavailable: [scene.deviceID: "not_listable"], notListableErrno: [:])
        case "unavailable が優先":
            snapshot = DeviceSnapshot(
                generation: 1, completedAt: scene.clock.now(), connectEpoch: 1, devices: listed.devices,
                unavailable: [scene.deviceID: "not_listable"], notListableErrno: [:])
        case "snapshot が古い":
            snapshot = listed
            scene.clock.advance(seconds: 901)
        default:
            snapshot = listed
            try FileManager.default.removeItem(at: scene.vault.appendingPathComponent(".obsidian", isDirectory: true))
        }
        await Self.stage(scene, snapshot: snapshot).deleteSourcesIfSafe(sessionKey: Self.key)
        try Self.expectWaited(scene, attempts: Self.backoffCount)
    }

    @Test("F-69 一覧に無いのは F-64 の担当（detail already_absent。not_deletable にしない）")
    func absentSourceIsLeftToF64() async throws {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, "Raw ノートの手の編集")
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.stage(scene, snapshot: scene.snapshot(relpaths: [Self.otherRelpath])).deleteSourcesIfSafe(
            sessionKey: Self.key)
        #expect(try Self.part(scene).status == .completed)
        #expect(try Self.lastEvent(scene).detail == "already_absent")
        #expect(!Self.settledLog(scene))
        #expect(try Self.settledParts(scene) == [])
    }

    @Test("F-69 接続中で読み取り専用なら従来どおり device_readonly の完了（not_deletable にしない・要対応に数えない）")
    func readOnlyDeviceIsNotSettledAsUndeletable() async throws {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, "Raw ノートの手の編集")
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.stage(scene, snapshot: scene.snapshot(readOnly: true)).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(try Self.part(scene).status == .completed)
        #expect(try Self.lastEvent(scene).detail == nil)
        #expect(!Self.settledLog(scene))
        #expect(try Self.settledParts(scene) == [])
    }

    @Test("F-69 消せるなら期限を過ぎていても要求を書く（決着は canDeleteSource が偽のときだけ）")
    func deletablePartIsRequestedEvenPastTheDeadline() async throws {
        let scene = try DeletionScene()
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(try Self.part(scene).status == .sourceDeleting)
        #expect(scene.requests().count == 1)
        #expect(!Self.settledLog(scene))
    }

    // MARK: - 数え方（要対応と状態の詳細）

    /// 期限で決着させた舞台（決着の時刻は DeletionScene.now + 4860 秒）
    static func settledScene() async throws -> DeletionScene {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, "Raw ノートの手の編集")
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        return scene
    }

    @Test("F-69 決着した Part を DB から数え、デバイスに残りうるものを要対応に出す（未接続・snapshot 無しも数える）")
    func settledPartIsCountedWhileItMayRemain() async throws {
        let scene = try await Self.settledScene()
        let settled = try Self.settledParts(scene)
        #expect(settled.map(\.partkey) == [Self.pk])
        for snapshot in [scene.snapshot(), scene.snapshot(includeDevice: false), nil] as [DeviceSnapshot?] {
            let remaining = AttentionEvaluator.remainingUndeletable(settled, snapshot: snapshot, zone: scene.zone)
            #expect(remaining.map(\.partkey) == [Self.pk])
        }
        var input = AttentionInput(now: scene.clock.now())
        input.configPresent = true
        input.undeletableSources = 1
        let items = AttentionEvaluator.items(input)
        #expect(items == [.undeletableSources(1)])
        #expect(items.first?.actions == [.openDetails])
    }

    @Test("F-69 決着より後の走査で一覧から消えたら数えない（利用者が手で消した）。同じ秒の走査では消えたと言わない")
    func removedByHandIsNoLongerCounted() async throws {
        let scene = try await Self.settledScene()
        let settled = try Self.settledParts(scene)
        scene.clock.advance(seconds: 60)
        let gone = scene.snapshot(relpaths: [Self.otherRelpath])
        #expect(AttentionEvaluator.remainingUndeletable(settled, snapshot: gone, zone: scene.zone) == [])
        let sameSecond = scene.snapshot(
            relpaths: [Self.otherRelpath], completedAt: DeletionScene.now.adding(seconds: Self.backoffTotal))
        #expect(AttentionEvaluator.remainingUndeletable(settled, snapshot: sameSecond, zone: scene.zone).count == 1)
    }

    @Test("F-69 過去分の削除で消えた（source_deleted_at が在る）・再び対象になった Part は数えない")
    func deletedOrRetargetedPartIsNotCounted() async throws {
        let scene = try await Self.settledScene()
        try scene.store.updateRecording(Self.pk, [.sourceDeletedAt("2026-09-12T14:00:00+09:00")])
        #expect(try Self.settledParts(scene) == [])
        let other = try await Self.settledScene()
        try other.store.recordPartTransition(partkey: Self.pk, from: .completed, to: .sourceDeleting)
        #expect(try Self.settledParts(other) == [])
    }

    @Test("F-69 決着した Part は「過去分を削除対象にする」で再び評価され、原因が直れば対象になる")
    func settledPartIsRetargetedByBacklog() async throws {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, "原本のサイズの食い違い")
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.stage(scene).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(try Self.session(scene).status == .completed)
        let planner = BacklogPlanner(
            deps: scene.deletionDependencies(ingest: ScriptedIngest(snapshot: scene.snapshot())))
        let before = try await planner.planBacklog()
        #expect(before.eligible == [])
        #expect(before.skipped == [BacklogSkip(partkey: Self.pk, reason: DeletionReason.notDeletable)])
        // 原因を直す（DB の size を原本に戻す）
        try scene.store.updateRecording(Self.pk, [.sourceSize(4096)])
        let after = try await planner.planBacklog()
        #expect(after.eligible == [Self.pk])
    }

    @Test("F-69 状態の詳細に一覧を出す（件数と partkey）。0 件なら行を出さない（TEST-28）")
    func statusReportListsSettledParts() async throws {
        let empty = try DeletionScene()
        let none = StatusReporter.build(
            layout: empty.layout, config: empty.config, snapshot: empty.snapshot(), now: empty.clock.now(),
            zone: empty.zone)
        #expect(none.undeletableTotal == 0)
        #expect(!none.lines.contains { $0.hasPrefix("消せなかった録音") })
        let scene = try await Self.settledScene()
        let report = StatusReporter.build(
            layout: scene.layout, config: scene.config, snapshot: scene.snapshot(), now: scene.clock.now(),
            zone: scene.zone)
        #expect(report.undeletable == [Self.pk])
        #expect(report.undeletableTotal == 1)
        let lines = report.lines
        let index = try #require(lines.firstIndex(of: "消せなかった録音（1 件。デバイスに残っています）"))
        #expect(lines[index + 1] == "  " + Self.pk)
    }

    @Test("TEST-28 決着した Part が 0 件なら空・要対応に出さない")
    func noSettledPartsIsEmpty() throws {
        let scene = try DeletionScene()
        #expect(try Self.settledParts(scene) == [])
        #expect(AttentionEvaluator.remainingUndeletable([], snapshot: scene.snapshot(), zone: scene.zone) == [])
        var input = AttentionInput(now: scene.clock.now())
        input.configPresent = true
        #expect(AttentionEvaluator.items(input) == [])
    }
}
