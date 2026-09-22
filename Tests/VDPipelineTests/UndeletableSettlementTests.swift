// 消せないまま待つのをやめる（PLAN §8.9.2・§8.9.5 の 5a・§8.11 の undeletableSources。F-69・issue #98）。
// 元ファイルは一覧に在るのに canDeleteSource が偽のまま変わらない RAW_SAVED を、期限と「観測できた失敗の 2 回連続」で
// 消さずに完了させ、要対応で知らせる。舞台は DeletionScene（/Volumes には触れない）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

/// ボリュームを開けない（一時的な失敗の姿。事前確認が偽になる）
struct RejectingVolumeOpener: VolumeOpener {
    func open(volumesRoot: String, deviceID: String) -> VolumeOpenResult {
        .rejected(IdentityMismatch(IdentityReason.notAMountPoint))
    }
}

@Suite("UndeletableSettlement")
struct UndeletableSettlementTests {
    static let pk = DeletionScene.partkey
    static let key = DeletionScene.sessionKey
    /// 既定の backoff（60, 300, 900, 3600）の段の数と合計
    static let backoffCount = 4
    static let backoffTotal = 4860
    static let otherRelpath = "TX_MIC001_20260912_100000/TX00_MIC001_20260912_100000_orig.wav"

    static func stage(
        _ scene: DeletionScene, snapshot: DeviceSnapshot? = nil, streaks: UndeletableStreaks,
        opener: (any VolumeOpener)? = nil
    ) -> SessionDeletionStage {
        SessionDeletionStage(
            deps: scene.deletionDependencies(
                ingest: ScriptedIngest(snapshot: snapshot ?? scene.snapshot()), opener: opener, streaks: streaks))
    }

    /// 同じ連続回数の記録で times 回評価する
    static func evaluate(
        _ scene: DeletionScene, snapshot: DeviceSnapshot? = nil, streaks: UndeletableStreaks, times: Int = 2
    ) async {
        for _ in 0..<times {
            await Self.stage(scene, snapshot: snapshot, streaks: streaks).deleteSourcesIfSafe(sessionKey: Self.key)
        }
    }

    static func part(_ scene: DeletionScene, _ pk: String = pk) throws -> RecordingRow {
        try #require(try scene.store.recording(pk))
    }

    static func session(_ scene: DeletionScene) throws -> SessionRow {
        try #require(try scene.store.session(Self.key))
    }

    static func lastEvent(_ scene: DeletionScene, _ pk: String = pk) throws -> EventRow {
        try #require(try scene.store.events(entity: .recording, key: pk).last)
    }

    static func settledLog(_ scene: DeletionScene, _ pk: String = pk) -> Bool {
        scene.logLines.contains {
            $0.contains(" source_delete_skipped recording_key=" + pk + " reason=not_deletable")
        }
    }

    static func settledParts(_ scene: DeletionScene) throws -> [RecordingRow] {
        let ro = try #require(ReadOnlyStore.open(url: scene.layout.database))
        return try ro.completedParts(lastDetail: DeletionReason.notDeletable)
    }

    /// 原因（表示名の語）→ 決着のときに記録される原因の語
    static let causeWords: [String: String] = [
        "Raw ノートの手の編集": "raw_note", "原本のサイズの食い違い": "pre_identity", "transcript の欠け": "transcript",
        "source_path が無い": "source_info",
    ]

    /// canDeleteSource を偽にする（元ファイルはデバイスに在るまま。待っても変わらない原因）
    static func breakDeletability(_ scene: DeletionScene, _ cause: String, _ pk: String = pk) throws {
        switch cause {
        case "Raw ノートの手の編集":
            try scene.appendToRawNote("\n手で書き足した行\n")
        case "原本のサイズの食い違い":
            try scene.store.updateRecording(pk, [.sourceSize(8192)])
        case "transcript の欠け":
            try FileManager.default.removeItem(at: scene.transcriptURL(pk))
        default:
            try StorePaths.setSourcePath(scene.store, partkey: pk, nil)
        }
    }

    /// delete_attempts を attempts にし、Part を RAW_SAVED にした時刻（DeletionScene.now）から seconds 秒進める
    static func elapse(_ scene: DeletionScene, attempts: Int, seconds: Int) throws {
        try scene.store.updateSession(Self.key, [.deleteAttempts(attempts)])
        scene.clock.advance(seconds: seconds)
    }

    /// 決着せずに待った姿（delete_attempts が evaluations 回増え、遷移しない、ログなし）
    static func expectWaited(_ scene: DeletionScene, attempts: Int, evaluations: Int = 2) throws {
        let session = try Self.session(scene)
        #expect(session.status == .saved)
        #expect(session.deleteAttempts == attempts + evaluations)
        let part = try Self.part(scene)
        #expect(part.status == .rawSaved)
        #expect(part.sourceDeletedAt == nil)
        #expect(!Self.settledLog(scene))
        #expect(scene.requests() == [])
    }

    /// 接続し直した（connectEpoch が違う）snapshot。一覧は既定のまま
    static func reconnected(_ scene: DeletionScene, epoch: UInt64) -> DeviceSnapshot {
        DeviceSnapshot(
            generation: epoch, completedAt: scene.clock.now(), connectEpoch: epoch, devices: scene.snapshot().devices,
            unavailable: [:], notListableErrno: [:])
    }

    // MARK: - 期限と連続回数

    @Test(
        "F-69 期限の前は待つ（パラメータ化: backoff を使い切っていない・RAW_SAVED から合計に 1 秒足りない）",
        arguments: [(2, 100_000), (4, 4859)])
    func beforeTheDeadlineWaits(_ attempts: Int, _ seconds: Int) async throws {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, "Raw ノートの手の編集")
        try Self.elapse(scene, attempts: attempts, seconds: seconds)
        await Self.evaluate(scene, streaks: UndeletableStreaks())
        try Self.expectWaited(scene, attempts: attempts)
    }

    @Test(
        "F-69 期限を過ぎ、観測できた失敗が 2 回続いたら消さずに RAW_SAVED→COMPLETED（detail not_deletable・原因を記録）で Session も完了する（パラメータ化: 原因 4 つ）",
        arguments: ["Raw ノートの手の編集", "原本のサイズの食い違い", "transcript の欠け", "source_path が無い"])
    func atTheDeadlineSettlesWithoutDeleting(_ cause: String) async throws {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, cause)
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        let streaks = UndeletableStreaks()
        // 1 回目は観測できた失敗が 1 回なので待つ
        await Self.evaluate(scene, streaks: streaks, times: 1)
        try Self.expectWaited(scene, attempts: Self.backoffCount, evaluations: 1)
        // 2 回目で決着
        await Self.evaluate(scene, streaks: streaks, times: 1)
        let word = try #require(Self.causeWords[cause])
        let part = try Self.part(scene)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt == nil)
        #expect(part.deleteRequestID == nil)
        #expect(part.errorMessage == word)
        let last = try Self.lastEvent(scene)
        #expect(last.fromStatus == "RAW_SAVED")
        #expect(last.toStatus == "COMPLETED")
        #expect(last.detail == "not_deletable")
        #expect(
            scene.logLines.contains {
                $0.hasSuffix(" source_delete_skipped recording_key=" + Self.pk + " reason=not_deletable detail=" + word)
            })
        #expect(scene.requests() == [])
        // 元ファイルはデバイスに残る
        #expect(
            FileManager.default.fileExists(
                atPath: scene.deviceRoot.appendingPathComponent(DeletionScene.relpath).path(percentEncoded: false)))
        let session = try Self.session(scene)
        #expect(session.status == .completed)
        #expect(session.sourceDeletedAt == nil)
    }

    @Test("F-69 backoff どおりに評価を重ねると、直後の 1 回と backoff の 3 回が偽で、backoff の 4 回目（SAVED から 4860 秒）の評価で決着する")
    func evaluationsFollowTheBackoffUntilSettled() async throws {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, "原本のサイズの食い違い")
        let streaks = UndeletableStreaks()
        // SAVED の直後の 1 回（backoff を見ない）
        await Self.stage(scene, streaks: streaks).deleteSourcesIfSafe(sessionKey: Self.key)
        #expect(try Self.session(scene).deleteAttempts == 1)
        for (index, delay) in [60, 300, 900, 3600].enumerated() {
            scene.clock.advance(seconds: delay - 1)
            #expect(Self.stage(scene, streaks: streaks).dueSessionKeys() == [])
            scene.clock.advance(seconds: 1)
            let stage = Self.stage(scene, streaks: streaks)
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

    @Test(
        "F-69 長く抜いた後の最初の評価では、一時的な失敗で決着しない（パラメータ化: ボリュームを開けない・後続の Part が処理中で Raw ノートが未更新）",
        arguments: ["開けない", "Raw ノートが未更新"])
    func firstEvaluationAfterLongAbsenceDoesNotSettle(_ kind: String) async throws {
        let scene = try DeletionScene()
        // 抜いている間も delete_attempts は増え、時間もたっている（期限は過ぎている）
        try Self.elapse(scene, attempts: 30, seconds: 7 * 86_400)
        let streaks = UndeletableStreaks()
        let snapshot = Self.reconnected(scene, epoch: 2)
        switch kind {
        case "開けない":
            await Self.stage(scene, snapshot: snapshot, streaks: streaks, opener: RejectingVolumeOpener())
                .deleteSourcesIfSafe(sessionKey: Self.key)
            try Self.expectWaited(scene, attempts: 30, evaluations: 1)
            // 次の評価で開ければ、決着ではなく要求を書く
            await Self.stage(scene, snapshot: snapshot, streaks: streaks).deleteSourcesIfSafe(sessionKey: Self.key)
            #expect(try Self.part(scene).status == .sourceDeleting)
            #expect(scene.requests().count == 1)
        default:
            // 同じ Session の後続の Part がまだ TRANSCRIBED（Raw ノートに載っていない）。何度評価しても決着しない
            try scene.addPart(
                fileName: "TX00_MIC001_20260912_093000_orig.wav", startedAt: "2026-09-12T09:30:00+09:00",
                status: .transcribed, inRawNote: false)
            await Self.evaluate(scene, snapshot: snapshot, streaks: streaks, times: 3)
            #expect(try Self.part(scene).status != .completed)
            #expect(!Self.settledLog(scene))
            #expect(try Self.settledParts(scene) == [])
        }
        #expect(!Self.settledLog(scene))
    }

    @Test("F-69 観測できた失敗が同じ接続で 2 回続いて初めて決着する。挿し直す（connectEpoch が変わる）と数え直す")
    func streakRestartsOnReconnect() async throws {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, "原本のサイズの食い違い")
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        let streaks = UndeletableStreaks()
        await Self.stage(scene, snapshot: Self.reconnected(scene, epoch: 1), streaks: streaks).deleteSourcesIfSafe(
            sessionKey: Self.key)
        await Self.stage(scene, snapshot: Self.reconnected(scene, epoch: 2), streaks: streaks).deleteSourcesIfSafe(
            sessionKey: Self.key)
        try Self.expectWaited(scene, attempts: Self.backoffCount)
        await Self.stage(scene, snapshot: Self.reconnected(scene, epoch: 2), streaks: streaks).deleteSourcesIfSafe(
            sessionKey: Self.key)
        #expect(try Self.part(scene).status == .completed)
        #expect(Self.settledLog(scene))
    }

    // MARK: - 観測できないうちは決着させない

    @Test(
        "F-69 期限を過ぎても観測できなければ決着しない（パラメータ化: 未接続・列挙できない・unavailable が優先・snapshot が古い（呼び手の新鮮さで）・Vault が使えない）",
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
        await Self.evaluate(scene, snapshot: snapshot, streaks: UndeletableStreaks())
        try Self.expectWaited(scene, attempts: Self.backoffCount)
    }

    @Test("F-69 一覧に無いのは F-64 の担当（detail already_absent。not_deletable にしない）")
    func absentSourceIsLeftToF64() async throws {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, "Raw ノートの手の編集")
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.evaluate(
            scene, snapshot: scene.snapshot(relpaths: [Self.otherRelpath]), streaks: UndeletableStreaks())
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
        await Self.evaluate(scene, snapshot: scene.snapshot(readOnly: true), streaks: UndeletableStreaks())
        #expect(try Self.part(scene).status == .completed)
        #expect(try Self.lastEvent(scene).detail == nil)
        #expect(!Self.settledLog(scene))
        #expect(try Self.settledParts(scene) == [])
    }

    @Test("F-69 消せるなら期限を過ぎていても要求を書く（決着は canDeleteSource が偽のときだけ）")
    func deletablePartIsRequestedEvenPastTheDeadline() async throws {
        let scene = try DeletionScene()
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.evaluate(scene, streaks: UndeletableStreaks())
        #expect(try Self.part(scene).status == .sourceDeleting)
        #expect(scene.requests().count == 1)
        #expect(!Self.settledLog(scene))
    }

    @Test("F-69 同じ Session に消せる Part と決着する Part が混ざれば、前者は要求を書き、後者だけ消さずに完了する")
    func mixedSessionRequestsOneAndSettlesTheOther() async throws {
        let scene = try DeletionScene()
        let broken = try scene.addPart(
            fileName: "TX00_MIC001_20260912_093000_orig.wav", startedAt: "2026-09-12T09:30:00+09:00", status: .rawSaved)
        try scene.writeRawNote()
        try Self.breakDeletability(scene, "原本のサイズの食い違い", broken)
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.evaluate(scene, streaks: UndeletableStreaks())
        #expect(try Self.part(scene).status == .sourceDeleting)
        #expect(scene.requests().count == 1)
        let settled = try Self.part(scene, broken)
        #expect(settled.status == .completed)
        #expect(settled.sourceDeletedAt == nil)
        #expect(try Self.lastEvent(scene, broken).detail == "not_deletable")
        #expect(Self.settledLog(scene, broken))
        #expect(!Self.settledLog(scene))
        #expect(try Self.session(scene).status == .sourceDeleting)
    }

    @Test("F-69 決着の遷移が衝突したら status_changed を出して飛ばす（not_deletable のログを出さない）")
    func settleConflictLogsStatusChanged() async throws {
        let scene = try DeletionScene()
        let stale = try Self.part(scene)
        // 読んだ後に状態が変わった
        try scene.movePart(Self.pk, to: .completed)
        let deps = scene.deletionDependencies(ingest: ScriptedIngest(snapshot: scene.snapshot()))
        DeletionRequester(deps: deps).settleAsNotDeletable(stale, cause: DeletionReason.causeRawNote)
        #expect(
            scene.logLines.contains {
                $0.hasSuffix(" source_delete_skipped recording_key=" + Self.pk + " reason=status_changed")
            })
        #expect(!Self.settledLog(scene))
        #expect(!scene.logLines.contains { $0.contains(" config_warning ") })
        #expect(try Self.lastEvent(scene).detail != "not_deletable")
    }

    // MARK: - 数え方（要対応と状態の詳細）

    /// 期限と 2 回連続で決着させた舞台
    static func settledScene(_ cause: String = "Raw ノートの手の編集") async throws -> DeletionScene {
        let scene = try DeletionScene()
        try Self.breakDeletability(scene, cause)
        try Self.elapse(scene, attempts: Self.backoffCount, seconds: Self.backoffTotal)
        await Self.evaluate(scene, streaks: UndeletableStreaks())
        return scene
    }

    @Test("F-69 要対応に数えるのは、最新の snapshot で接続中かつ一覧にまだ在るものだけ（抜いている・一覧に無い・snapshot 無しは数えない）")
    func onlyStillListedPartsAreAttention() async throws {
        let scene = try await Self.settledScene()
        let settled = try Self.settledParts(scene)
        #expect(settled.map(\.partkey) == [Self.pk])
        #expect(
            AttentionEvaluator.undeletableStillListed(settled, snapshot: scene.snapshot()).map(\.partkey) == [Self.pk])
        for snapshot in [
            scene.snapshot(includeDevice: false), scene.snapshot(relpaths: [Self.otherRelpath]), nil,
        ] as [DeviceSnapshot?] {
            #expect(AttentionEvaluator.undeletableStillListed(settled, snapshot: snapshot) == [])
        }
        var input = AttentionInput(now: scene.clock.now())
        input.configPresent = true
        input.undeletableSources = 1
        let items = AttentionEvaluator.items(input)
        #expect(items == [.undeletableSources(1)])
        #expect(items.first?.actions == [.openDetails])
    }

    @Test("F-69 source_path が無いまま決着した Part は要対応に数えない（一覧と照らせない）")
    func settledWithoutSourcePathIsNotAttention() async throws {
        let scene = try await Self.settledScene("source_path が無い")
        let settled = try Self.settledParts(scene)
        #expect(settled.count == 1)
        #expect(AttentionEvaluator.undeletableStillListed(settled, snapshot: scene.snapshot()) == [])
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
        let scene = try await Self.settledScene("原本のサイズの食い違い")
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

    @Test(
        "F-69 状態の詳細に決着した Part を全部、原因とデバイスでの在否を添えて出す（パラメータ化: 在る・一覧に無い・観測できない）",
        arguments: ["在る", "一覧に無い", "観測できない"])
    func statusReportListsSettledParts(_ presence: String) async throws {
        let scene = try await Self.settledScene()
        let snapshot: DeviceSnapshot
        let word: String
        switch presence {
        case "在る":
            snapshot = scene.snapshot()
            word = "デバイスに在る"
        case "一覧に無い":
            snapshot = scene.snapshot(relpaths: [Self.otherRelpath])
            word = "デバイスの一覧に無い"
        default:
            snapshot = scene.snapshot(includeDevice: false)
            word = "デバイスを観測できない"
        }
        let report = StatusReporter.build(
            layout: scene.layout, config: scene.config, snapshot: snapshot, now: scene.clock.now(), zone: scene.zone)
        #expect(report.undeletableTotal == 1)
        #expect(report.undeletable.map(\.partkey) == [Self.pk])
        let lines = report.lines
        let index = try #require(lines.firstIndex(of: "消せなかった録音（1 件。消さずに完了にしたもの）"))
        #expect(lines[index + 1] == "  " + Self.pk)
        #expect(lines[index + 2] == "    Raw ノートの照合が合わない、" + word)
    }

    @Test("TEST-28 決着した Part が 0 件なら空・要対応に出さない・状態の詳細に行を出さない")
    func noSettledPartsIsEmpty() throws {
        let scene = try DeletionScene()
        #expect(try Self.settledParts(scene) == [])
        #expect(AttentionEvaluator.undeletableStillListed([], snapshot: scene.snapshot()) == [])
        var input = AttentionInput(now: scene.clock.now())
        input.configPresent = true
        #expect(AttentionEvaluator.items(input) == [])
        let report = StatusReporter.build(
            layout: scene.layout, config: scene.config, snapshot: scene.snapshot(), now: scene.clock.now(),
            zone: scene.zone)
        #expect(report.undeletableTotal == 0)
        #expect(!report.lines.contains { $0.hasPrefix("消せなかった録音") })
    }
}
