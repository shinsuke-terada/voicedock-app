// 削除まわりの残り（PLAN §8.9.5 の 5a・§8.9.9・§8.11・§8.12。F-80・issue #119）。
// 連続回数の数え方（時間の間隔・デバイスごとの挿し直し・途中で戻る評価・辞書の縮小）、FAILED の兄弟、
// 「一覧に在るか」の 1 か所、要対応と状態の詳細の新鮮さ・設定エラー中の停止理由、DB から数える要対応の件数、
// 状態の詳細の失敗した Part の注記、COMPLETED の Session に後から RAW_SAVED になった Part の評価。舞台は DeletionScene。
import Foundation
import GRDB
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice

@testable import VDPipeline
@testable import VDStore

@Suite("DeletionRemainder")
struct DeletionRemainderTests {
    static let pk = DeletionScene.partkey
    static let key = DeletionScene.sessionKey
    /// 既定の backoff（60, 300, 900, 3600）の段の数と合計
    static let backoffCount = 4
    static let backoffTotal = 4860
    /// 連続の 2 回目として数える観測の間隔の下限（既定の backoff の最初の値）
    static let spacing = 60
    static let otherRelpath = "TX_MIC001_20260912_100000/TX00_MIC001_20260912_100000_orig.wav"
    /// 兄弟の Part のファイル名（同じ Session）
    static let siblingFile = "TX00_MIC001_20260912_093000_orig.wav"
    static let siblingStartedAt = "2026-09-12T09:30:00+09:00"
    static let siblingKey = "DJIMIC3/TX_MIC001_20260912_090000/TX00_MIC001_20260912_093000_orig.wav"
    static let requestID = "20260912T030000Z-8483e42457304a9d-abcdef"

    static func deps(
        _ scene: DeletionScene, snapshot: DeviceSnapshot? = nil, streaks: UndeletableStreaks
    ) -> DeletionDependencies {
        scene.deletionDependencies(ingest: ScriptedIngest(snapshot: snapshot ?? scene.snapshot()), streaks: streaks)
    }

    /// Session の削除段を 1 回
    static func evaluate(_ scene: DeletionScene, snapshot: DeviceSnapshot? = nil, streaks: UndeletableStreaks) async {
        await SessionDeletionStage(deps: Self.deps(scene, snapshot: snapshot, streaks: streaks))
            .deleteSourcesIfSafe(sessionKey: Self.key)
    }

    static func part(_ scene: DeletionScene, _ pk: String = pk) throws -> RecordingRow {
        try #require(try scene.store.recording(pk))
    }

    static func session(_ scene: DeletionScene) throws -> SessionRow {
        try #require(try scene.store.session(Self.key))
    }

    static func settledLog(_ scene: DeletionScene) -> Bool {
        scene.logLines.contains {
            $0.contains(" source_delete_skipped recording_key=" + Self.pk + " reason=not_deletable")
        }
    }

    /// 原本のサイズを DB で食い違わせ（canDeleteSource が偽・原因 pre_identity）、期限を過ぎさせる
    static func stuckScene() throws -> DeletionScene {
        let scene = try DeletionScene()
        try scene.store.updateRecording(Self.pk, [.sourceSize(8192)])
        try scene.store.updateSession(Self.key, [.deleteAttempts(Self.backoffCount)])
        scene.clock.advance(seconds: Self.backoffTotal)
        return scene
    }

    /// 期限と 2 回連続で決着させた舞台
    static func settledScene() async throws -> DeletionScene {
        let scene = try Self.stuckScene()
        let streaks = UndeletableStreaks()
        await Self.evaluate(scene, streaks: streaks)
        scene.clock.advance(seconds: Self.spacing)
        await Self.evaluate(scene, streaks: streaks)
        #expect(try Self.part(scene).status == .completed)
        return scene
    }

    /// deviceNode だけを変えた snapshot（同じ connectEpoch。一覧は既定のまま）
    static func snapshot(_ scene: DeletionScene, deviceNode: String?) -> DeviceSnapshot {
        let base = scene.snapshot()
        let devices = base.devices.mapValues {
            DeviceObservation(
                deviceID: $0.deviceID, mountPath: $0.mountPath, deviceNode: deviceNode, readOnly: $0.readOnly,
                freeBytes: $0.freeBytes, relpaths: $0.relpaths)
        }
        return DeviceSnapshot(
            generation: base.generation, completedAt: base.completedAt, connectEpoch: base.connectEpoch,
            devices: devices, unavailable: [:], notListableErrno: [:])
    }

    // MARK: - R5 / B9: 連続の数え方

    @Test("F-80 連続の記録は、前に数えた観測から間隔の下限以上たった観測だけを数える（59 秒後は据え置き、60 秒後に 2、その 1 秒後は据え置き）")
    func streakCountsOnlySpacedObservations() {
        let streaks = UndeletableStreaks()
        let connection = UndeletableStreaks.Connection(epoch: 1, deviceNode: "/dev/disk9")
        let t0 = DeletionScene.now
        func record(_ seconds: Int) -> Int {
            streaks.record(
                Self.pk, session: Self.key, connection: connection, now: t0.adding(seconds: seconds),
                minIntervalSeconds: 60)
        }
        #expect(record(0) == 1)
        #expect(record(59) == 1)
        #expect(record(60) == 2)
        #expect(record(61) == 2)
        #expect(record(120) == 3)
    }

    @Test("F-80 期限を過ぎた観測できた失敗でも、間隔の下限（60 秒）に満たない続けた評価では決着せず、60 秒後の評価で決着する")
    func quickSecondEvaluationDoesNotSettle() async throws {
        let scene = try Self.stuckScene()
        let streaks = UndeletableStreaks()
        await Self.evaluate(scene, streaks: streaks)
        scene.clock.advance(seconds: Self.spacing - 1)
        await Self.evaluate(scene, streaks: streaks)
        #expect(try Self.part(scene).status == .rawSaved)
        #expect(!Self.settledLog(scene))
        // 据え置き（切っていない）ので、前に数えた観測から 60 秒たった評価で決着する
        scene.clock.advance(seconds: 1)
        await Self.evaluate(scene, streaks: streaks)
        let part = try Self.part(scene)
        #expect(part.status == .completed)
        #expect(part.errorMessage == "pre_identity")
        #expect(part.sourceDeletedAt == nil)
        #expect(Self.settledLog(scene))
    }

    @Test("F-80 connectEpoch が同じでも、そのデバイスの deviceNode が変わった（マウントし直した）ら数え直す")
    func deviceNodeChangeRestartsTheStreak() async throws {
        let scene = try Self.stuckScene()
        let streaks = UndeletableStreaks()
        await Self.evaluate(scene, snapshot: Self.snapshot(scene, deviceNode: "/dev/disk9"), streaks: streaks)
        scene.clock.advance(seconds: Self.spacing)
        await Self.evaluate(scene, snapshot: Self.snapshot(scene, deviceNode: "/dev/disk10"), streaks: streaks)
        #expect(try Self.part(scene).status == .rawSaved)
        #expect(!Self.settledLog(scene))
        scene.clock.advance(seconds: Self.spacing)
        await Self.evaluate(scene, snapshot: Self.snapshot(scene, deviceNode: "/dev/disk10"), streaks: streaks)
        #expect(try Self.part(scene).status == .completed)
        #expect(Self.settledLog(scene))
    }

    // MARK: - R8: 途中で戻る評価は連続を切る

    @Test(
        "F-80 途中で戻る評価（パラメータ化: snapshot が古い・readiness が configured でない）は、その Session の連続を切る",
        arguments: ["snapshot が古い", "readiness が configured でない"])
    func earlyReturnRestartsTheStreak(_ condition: String) async throws {
        let scene = try Self.stuckScene()
        let streaks = UndeletableStreaks()
        _ = await DeletionRequester(deps: Self.deps(scene, streaks: streaks)).requestDeletions(sessionKey: Self.key)
        #expect(streaks.count == 1)
        scene.clock.advance(seconds: Self.spacing)
        let deps: DeletionDependencies
        switch condition {
        case "snapshot が古い":
            deps = Self.deps(
                scene, snapshot: scene.snapshot(completedAt: scene.clock.now().adding(seconds: -901)),
                streaks: streaks)
        default:
            scene.updateConfig { $0.cleanup.deleteSourceAudio = false }
            deps = Self.deps(scene, streaks: streaks)
        }
        #expect(await DeletionRequester(deps: deps).requestDeletions(sessionKey: Self.key) == 0)
        #expect(streaks.count == 0)
        #expect(try Self.part(scene).status == .rawSaved)
    }

    // MARK: - R10: 連続の記録が縮む

    @Test("F-80 連続の記録は、RAW_SAVED / ID の無い PENDING でなくなった Part の項目を評価の終わりに捨てる")
    func streakRecordShrinksWhenThePartMovesOn() async throws {
        let scene = try Self.stuckScene()
        let streaks = UndeletableStreaks()
        let requester = DeletionRequester(deps: Self.deps(scene, streaks: streaks))
        _ = await requester.requestDeletions(sessionKey: Self.key)
        #expect(streaks.count == 1)
        // 別の経路で完了した（例: 削除の無効化で消さずに完了）
        try scene.movePart(Self.pk, to: .completed)
        _ = await requester.requestDeletions(sessionKey: Self.key)
        #expect(streaks.count == 0)
    }

    @Test("F-80 retain は渡した Session の項目だけを捨て、ほかの Session の項目は残す")
    func retainOnlyTouchesTheSession() {
        let streaks = UndeletableStreaks()
        let connection = UndeletableStreaks.Connection(epoch: 1, deviceNode: nil)
        let now = DeletionScene.now
        _ = streaks.record(Self.pk, session: Self.key, connection: connection, now: now, minIntervalSeconds: 60)
        _ = streaks.record(
            Self.siblingKey, session: "DJIMIC3:20260913", connection: connection, now: now, minIntervalSeconds: 60)
        streaks.retain(session: Self.key, keeping: [])
        #expect(streaks.count == 1)
        streaks.retain(session: "DJIMIC3:20260913", keeping: [Self.siblingKey])
        #expect(streaks.count == 1)
    }

    // MARK: - R7: FAILED の兄弟

    /// FAILED の兄弟の姿（R7）
    struct SiblingCase: Sendable, CustomTestStringConvertible {
        let name: String
        let code: ErrorCode
        let maxAttempts: Int
        let needsRecopy: Bool
        /// 兄弟の原本をデバイスに置く（snapshot の一覧に載る）
        let onDevice: Bool
        /// 兄弟の events を消す（FAILED の戻り先が読めない。InProcessRetry.delay も戻さない）
        let dropEvents: Bool
        let settles: Bool
        var testDescription: String { name }
    }

    static let siblingCases = [
        SiblingCase(
            name: "工程内リトライが残る", code: .whisperFailed, maxAttempts: 3, needsRecopy: false, onDevice: true,
            dropEvents: false, settles: false),
        SiblingCase(
            name: "再コピー待ちで原本が一覧に在る", code: .sourceHashMismatch, maxAttempts: 1, needsRecopy: true,
            onDevice: true, dropEvents: false, settles: false),
        SiblingCase(
            name: "再コピー待ちだが原本が一覧に無い", code: .sourceHashMismatch, maxAttempts: 1, needsRecopy: true,
            onDevice: false, dropEvents: false, settles: true),
        SiblingCase(
            name: "工程内リトライを使い切った", code: .whisperFailed, maxAttempts: 1, needsRecopy: false, onDevice: true,
            dropEvents: false, settles: true),
        SiblingCase(
            name: "再試行の区分が none", code: .whisperExecMissing, maxAttempts: 3, needsRecopy: false, onDevice: true,
            dropEvents: false, settles: true),
        SiblingCase(
            name: "FAILED の戻り先が読めない（InProcessRetry も戻さない）", code: .whisperFailed, maxAttempts: 3,
            needsRecopy: false, onDevice: true, dropEvents: true, settles: true),
    ]

    @Test(
        "F-80 FAILED の兄弟が自動で戻りうる間は待ち、戻らないなら終端として数えて決着する（パラメータ化: リトライが残る・再コピー待ち（原本が在る・無い）・使い切った・区分 none・戻り先が読めない）",
        arguments: siblingCases)
    func failedSiblingWaitsWhileItCanReturn(_ c: SiblingCase) async throws {
        let name = c.name
        let settles = c.settles
        let scene = try Self.stuckScene()
        // 兄弟は FAILED（retry_count 1）。transcript が無いので Raw ノートの照合の対象に入らない
        let sibling = try scene.addPart(
            fileName: Self.siblingFile, startedAt: Self.siblingStartedAt, status: .failed, errorCode: c.code,
            onDevice: c.onDevice, transcript: false, inRawNote: false)
        #expect(try Self.part(scene, sibling).retryCount == 1)
        if c.needsRecopy { try scene.store.updateRecording(sibling, [.needsRecopy(true)]) }
        if c.dropEvents {
            try await scene.store.pool.write { db in
                try db.execute(
                    sql: "DELETE FROM events WHERE entity_type = 'recording' AND entity_key = ?", arguments: [sibling])
            }
            #expect(try scene.store.failedFromPart(sibling) == nil)
        }
        let maxAttempts = c.maxAttempts
        scene.updateConfig { $0.retry.maxAttempts = maxAttempts }
        let streaks = UndeletableStreaks()
        await Self.evaluate(scene, streaks: streaks)
        scene.clock.advance(seconds: Self.spacing)
        await Self.evaluate(scene, streaks: streaks)
        #expect(try Self.part(scene).status == (settles ? .completed : .rawSaved), "\(name)")
        #expect(Self.settledLog(scene) == settles, "\(name)")
        #expect(try Self.part(scene, sibling).status == .failed)
    }

    // MARK: - R11: 「一覧に在るか」の 1 か所

    @Test(
        "F-80 SourcePresence.of（パラメータ化: 在る・一覧に無い・未接続・unavailable が優先・snapshot 無し・source_path が空）",
        arguments: [
            ("在る", SourcePresence.listed), ("一覧に無い", .notListed), ("未接続", .unobserved),
            ("unavailable が優先", .unobserved), ("snapshot 無し", .unobserved), ("source_path が空", .unobserved),
        ])
    func sourcePresenceTable(_ kind: String, _ expected: SourcePresence) throws {
        let scene = try DeletionScene()
        let listed = scene.snapshot()
        var snapshot: DeviceSnapshot? = listed
        switch kind {
        case "一覧に無い": snapshot = scene.snapshot(relpaths: [Self.otherRelpath])
        case "未接続": snapshot = scene.snapshot(includeDevice: false)
        case "unavailable が優先":
            snapshot = DeviceSnapshot(
                generation: 1, completedAt: scene.clock.now(), connectEpoch: 1, devices: listed.devices,
                unavailable: [scene.deviceID: "not_listable"], notListableErrno: [:])
        case "snapshot 無し": snapshot = nil
        case "source_path が空": try StorePaths.setSourcePath(scene.store, partkey: Self.pk, "")
        default: break
        }
        #expect(SourcePresence.of(try Self.part(scene), in: snapshot) == expected)
    }

    @Test(
        "F-80 削除の段の (d) と一覧に無いの判定は SourcePresence.of と同じ答え（パラメータ化: 在る・一覧に無い・source_path が空）",
        arguments: ["在る", "一覧に無い", "source_path が空"])
    func deletionChecksAgreeWithPresence(_ kind: String) async throws {
        let scene = try DeletionScene()
        var snapshot = scene.snapshot()
        switch kind {
        case "一覧に無い": snapshot = scene.snapshot(relpaths: [Self.otherRelpath])
        case "source_path が空": try StorePaths.setSourcePath(scene.store, partkey: Self.pk, "")
        default: break
        }
        // RAW_SAVED にした時刻より確かに後の走査
        scene.clock.advance(seconds: 1)
        snapshot = DeviceSnapshot(
            generation: 2, completedAt: scene.clock.now(), connectEpoch: 1, devices: snapshot.devices,
            unavailable: [:], notListableErrno: [:])
        let part = try Self.part(scene)
        let parts = try scene.store.recordings(inSession: Self.key)
        let ctx = await scene.context(snapshot: snapshot)
        let absent = kind == "一覧に無い"
        #expect(DeletionRequester.failureIsObserved(part, parts: parts, snapshot: snapshot, ctx: ctx) == !absent)
        #expect(DeletionRequester.sourceIsObservedAbsent(part, in: snapshot, zone: scene.zone) == absent)
    }

    @Test("F-80 手動で消した分も「一覧に無い」は SourcePresence.of で判定する（source_path が空・unavailable に在るなら完了にしない）")
    func resolveAbsentUsesPresence() async throws {
        for kind in ["source_path が空", "unavailable に在る"] {
            let scene = try DeletionScene(
                status: .sourceDeletePending, errorCode: .sourceIdentityMismatch, sessionStatus: .completed)
            var snapshot = scene.snapshot(relpaths: [Self.otherRelpath])
            var reason = DeletionReason.stillPresent
            if kind == "source_path が空" {
                try StorePaths.setSourcePath(scene.store, partkey: Self.pk, "")
            } else {
                snapshot = DeviceSnapshot(
                    generation: 1, completedAt: scene.clock.now(), connectEpoch: 1, devices: snapshot.devices,
                    unavailable: [scene.deviceID: "not_listable"], notListableErrno: [:])
                reason = DeletionReason.deviceAbsent
            }
            let planner = BacklogPlanner(deps: Self.deps(scene, snapshot: snapshot, streaks: UndeletableStreaks()))
            let plan = try await planner.planResolveAbsent()
            #expect(plan.eligible == [], "\(kind)")
            #expect(plan.skipped == [BacklogSkip(partkey: Self.pk, reason: reason)], "\(kind)")
            #expect(try await planner.executeResolveAbsent(BacklogPlan(eligible: [Self.pk], skipped: [])) == 0)
            #expect(try Self.part(scene).status == .sourceDeletePending, "\(kind)")
        }
    }

    // MARK: - R9 / R13: 要対応と状態の詳細の新鮮さ、DB から数える件数

    static func counted(_ scene: DeletionScene, snapshot: DeviceSnapshot?) throws -> AttentionInput {
        let ro = try #require(ReadOnlyStore.open(url: scene.layout.database))
        var input = AttentionInput(now: scene.clock.now())
        input.configPresent = true
        input.snapshot = snapshot
        input.snapshotMaxAgeSeconds = 900
        input.countStoredItems(from: ro)
        return input
    }

    /// F-75 の書き直すと本文が消える失敗（逐語。PLAN §8.6）
    static let lostMessage =
        "書き直すと Raw ノートから本文が消える Part があります（1 本）: " + DeletionScene.partkey
        + "。文字起こしを読めません: transcripts/parts/a5d046dce76cfedc.json"

    /// 同じ Session に FAILED の兄弟を足し、error_message を書く
    @discardableResult
    static func addFailed(_ scene: DeletionScene, code: ErrorCode, message: String) throws -> String {
        let sibling = try scene.addPart(
            fileName: Self.siblingFile, startedAt: Self.siblingStartedAt, status: .failed, errorCode: code,
            transcript: false, inRawNote: false)
        try scene.store.updateRecording(sibling, [.errorMessage(message)])
        return sibling
    }

    @Test("F-80 countStoredItems は DB から undeletableSources（一覧に在る決着）と rawNoteBlocked（Session 数）を入れる（LiveServices の配線）")
    func countStoredItemsFillsBothCounts() async throws {
        let scene = try await Self.settledScene()
        try Self.addFailed(scene, code: .obsidianRawWriteFailed, message: Self.lostMessage)
        let input = try Self.counted(scene, snapshot: scene.snapshot())
        #expect(input.undeletableSources == 1)
        #expect(input.rawNoteBlocked == 1)
        #expect(AttentionEvaluator.items(input) == [.undeletableSources(1), .rawNoteBlocked(1)])
    }

    @Test(
        "F-80 要対応の undeletableSources は snapshotMaxAgeSeconds より古い snapshot では数えない（境界: ちょうど 900 秒前は数える）",
        arguments: [(900, 1), (901, 0)])
    func staleSnapshotIsNotCountedForAttention(_ age: Int, _ expected: Int) async throws {
        let scene = try await Self.settledScene()
        let snapshot = scene.snapshot(completedAt: scene.clock.now().adding(seconds: -age))
        #expect(try Self.counted(scene, snapshot: snapshot).undeletableSources == expected)
    }

    @Test("F-80 状態の詳細の在否も snapshotMaxAgeSeconds より古い snapshot では「デバイスを観測できない」")
    func staleSnapshotIsUnobservedInTheStatusReport() async throws {
        let scene = try await Self.settledScene()
        let stale = scene.snapshot(completedAt: scene.clock.now().adding(seconds: -901))
        let report = StatusReporter.build(
            layout: scene.layout, config: scene.config, snapshot: stale, now: scene.clock.now(), zone: scene.zone)
        let lines = report.lines
        let index = try #require(lines.firstIndex(of: "消せなかった録音（1 件。消さずに完了にしたもの）"))
        try #require(index + 2 < lines.count)
        #expect(lines[index + 1] == "  " + Self.pk)
        #expect(lines[index + 2] == "    事前確認で原本が合わない（サイズ・時刻・場所）、デバイスを観測できない")
    }

    @Test("F-80 TEST-28 決着も FAILED も無い DB なら countStoredItems の件数は 0 のまま")
    func countStoredItemsOnAnEmptyStore() throws {
        let scene = try DeletionScene()
        let input = try Self.counted(scene, snapshot: scene.snapshot())
        #expect(input.undeletableSources == 0)
        #expect(input.rawNoteBlocked == 0)
        #expect(AttentionEvaluator.items(input) == [])
    }

    // MARK: - G9: 設定エラー中の停止理由

    @Test("F-80 設定エラー中は停止理由から作る要対応を出さない（configInvalid と、snapshot・DB から作る項目は出す）")
    func configErrorHidesStalePauseReasons() {
        var input = AttentionInput(now: DeletionScene.now)
        input.configPresent = false
        input.paused = PauseReason.allCases
        input.vault = .missingRoot
        input.snapshot = DeviceSnapshot(
            generation: 1, completedAt: DeletionScene.now, connectEpoch: 1, devices: [:],
            unavailable: ["B": "not_listable"], notListableErrno: [:])
        input.undeletableSources = 1
        #expect(AttentionEvaluator.items(input) == [.configInvalid, .deviceNotListable("B"), .undeletableSources(1)])
        // 設定が読めれば停止理由の項目も出る
        input.configPresent = true
        #expect(AttentionEvaluator.items(input).contains(.vaultNotConfigured))
        #expect(AttentionEvaluator.items(input).contains(.diskSpaceLow))
    }

    // MARK: - 状態の詳細の失敗した Part の注記（F-75 の残り）

    @Test("F-80 状態の詳細の失敗した Part に、F-75 の書き直すと本文が消える失敗は error_message（読めない録音の partkey）を添える")
    func failedPartShowsTheBlockedRecording() throws {
        let scene = try DeletionScene()
        let sibling = try Self.addFailed(scene, code: .obsidianRawWriteFailed, message: Self.lostMessage)
        let report = StatusReporter.build(
            layout: scene.layout, config: scene.config, snapshot: scene.snapshot(), now: scene.clock.now(),
            zone: scene.zone)
        let lines = report.lines
        let index = try #require(lines.firstIndex(of: "失敗した Part（1 件）"))
        // 見出し・partkey・詳細・注記の 4 行（落ちるときは添字の外で止まらずに失敗する）
        try #require(index + 3 < lines.count)
        #expect(lines[index + 1] == "  " + sibling)
        #expect(lines[index + 2] == "    2026-09-12 09:30  OBSIDIAN_RAW_WRITE_FAILED  retry 1/3")
        #expect(
            lines[index + 3]
                == "    書き直すと Raw ノートから本文が消える Part があります（1 本）: "
                + "DJIMIC3/TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"
                + "。文字起こしを読めません: transcripts/parts/a5d046dce76cfedc.json")
    }

    @Test(
        "F-80 ほかの失敗の error_message（ツールの stderr など）は状態の詳細に出さない（パラメータ化: WHISPER_FAILED・OBSIDIAN_RAW_WRITE_FAILED のほかの文言）",
        arguments: [
            (ErrorCode.whisperFailed, "exit 1: whisper_init_from_file: failed to load model"),
            (.obsidianRawWriteFailed, "書き込めません: Daily/Voice/Raw/20260912/2026-09-12 raw.md"),
        ])
    func otherFailureMessagesAreNotShown(_ code: ErrorCode, _ message: String) throws {
        let scene = try DeletionScene()
        let sibling = try Self.addFailed(scene, code: code, message: message)
        let report = StatusReporter.build(
            layout: scene.layout, config: scene.config, snapshot: scene.snapshot(), now: scene.clock.now(),
            zone: scene.zone)
        let lines = report.lines
        let index = try #require(lines.firstIndex(of: "失敗した Part（1 件）"))
        try #require(index + 2 < lines.count)
        #expect(lines[index + 1] == "  " + sibling)
        #expect(lines[index + 2] == "    2026-09-12 09:30  " + code.rawValue + "  retry 1/3")
        #expect(index + 3 == lines.count)
        #expect(!lines.contains { $0.contains(message) })
    }

    // MARK: - B8: COMPLETED の Session に後から RAW_SAVED になった Part

    /// COMPLETED の Session に、要求を書いていない RAW_SAVED の Part（allowReopen が偽で再オープンされなかった姿）
    static func lateScene() throws -> DeletionScene {
        let scene = try DeletionScene(sessionStatus: .completed)
        scene.updateConfig { $0.session.allowReopen = false }
        return scene
    }

    @Test("F-80 COMPLETED の Session に後から RAW_SAVED になった ID の無い Part を evaluateDeletions が拾う（60 秒で対象、59 秒では対象外）")
    func lateRawSavedSessionIsDue() throws {
        let scene = try Self.lateScene()
        scene.clock.advance(seconds: Self.spacing - 1)
        #expect(SessionDeletionStage(deps: Self.deps(scene, streaks: UndeletableStreaks())).dueSessionKeys() == [])
        scene.clock.advance(seconds: 1)
        #expect(
            SessionDeletionStage(deps: Self.deps(scene, streaks: UndeletableStreaks())).dueSessionKeys() == [Self.key])
    }

    @Test(
        "F-80 COMPLETED の Session でも、後から RAW_SAVED になった ID の無い Part が無ければ対象にしない（パラメータ化: Part が COMPLETED・RAW_SAVED で ID を持つ）",
        arguments: ["COMPLETED", "ID を持つ"])
    func completedSessionWithoutLatePartIsNotDue(_ kind: String) throws {
        let scene = try Self.lateScene()
        if kind == "COMPLETED" {
            try scene.movePart(Self.pk, to: .completed)
        } else {
            try scene.store.updateRecording(Self.pk, [.deleteRequestID(Self.requestID)])
        }
        scene.clock.advance(seconds: Self.backoffTotal)
        #expect(SessionDeletionStage(deps: Self.deps(scene, streaks: UndeletableStreaks())).dueSessionKeys() == [])
    }

    @Test("F-80 COMPLETED の Session の後から RAW_SAVED になった Part は、消せるなら要求を書く（Session は COMPLETED のまま）")
    func lateRawSavedIsRequested() async throws {
        let scene = try Self.lateScene()
        scene.clock.advance(seconds: Self.spacing)
        await Self.evaluate(scene, streaks: UndeletableStreaks())
        #expect(try Self.part(scene).status == .sourceDeleting)
        #expect(scene.requests().count == 1)
        let session = try Self.session(scene)
        #expect(session.status == .completed)
        #expect(session.deleteAttempts == 0)
    }

    @Test("F-80 削除が無効なら、COMPLETED の Session の後から RAW_SAVED になった Part を消さずに COMPLETED にする")
    func lateRawSavedCompletesWhenDisabled() async throws {
        let scene = try Self.lateScene()
        scene.updateConfig { $0.cleanup.deleteSourceAudio = false }
        scene.clock.advance(seconds: Self.spacing)
        await Self.evaluate(scene, streaks: UndeletableStreaks())
        let part = try Self.part(scene)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt == nil)
        #expect(scene.requests() == [])
        #expect(
            scene.logLines.contains {
                $0.hasSuffix(" source_delete_skipped session_key=" + Self.key + " reason=delete_source_audio_disabled")
            })
        #expect(try Self.session(scene).status == .completed)
    }

    @Test("F-80 未接続なら、COMPLETED の Session の後から RAW_SAVED になった Part は待つ（delete_attempts += 1 で backoff に従う）")
    func lateRawSavedWaitsWhileAbsent() async throws {
        let scene = try Self.lateScene()
        scene.clock.advance(seconds: Self.spacing)
        await Self.evaluate(scene, snapshot: scene.snapshot(includeDevice: false), streaks: UndeletableStreaks())
        #expect(try Self.part(scene).status == .rawSaved)
        #expect(scene.requests() == [])
        let session = try Self.session(scene)
        #expect(session.status == .completed)
        #expect(session.deleteAttempts == 1)
    }

    // MARK: - レビューの後: B8 の対象・R8 の Session が読めない・決着の直前の Vault

    @Test(
        "F-80 COMPLETED の Session では後から RAW_SAVED になった Part だけを評価し、同じ Session の ID の無い PENDING は要求も完了もしない（パラメータ化: PENDING の原本が一覧に在る（canDeleteSource が真）・無い）",
        arguments: [true, false])
    func completedSessionLeavesPendingToBacklog(_ pendingListed: Bool) async throws {
        let scene = try Self.lateScene()
        let pending = try scene.addPart(
            fileName: Self.siblingFile, startedAt: Self.siblingStartedAt, status: .sourceDeletePending,
            onDevice: pendingListed)
        try scene.writeRawNote()
        scene.clock.advance(seconds: Self.spacing)
        if pendingListed {
            // 評価すれば要求を書ける PENDING であること（空振りしない）
            let ctx = await scene.context(snapshot: scene.snapshot())
            #expect(DeletionPolicy.canDeleteSource(try scene.candidate(pending), ctx))
        }
        await Self.evaluate(scene, streaks: UndeletableStreaks())
        // 後から RAW_SAVED になった Part には要求を書く
        #expect(try Self.part(scene).status == .sourceDeleting)
        #expect(scene.requests().count == 1)
        // PENDING は後追い・手動で消した分の担当のまま
        let row = try Self.part(scene, pending)
        #expect(row.status == .sourceDeletePending)
        #expect(row.deleteRequestID == nil)
        #expect(!scene.logLines.contains { $0.contains("recording_key=" + pending) })
        #expect(try Self.session(scene).status == .completed)
    }

    @Test("F-80 Raw の直後の requestDeletions も、COMPLETED の Session では ID の無い RAW_SAVED だけを見る（TEST-28: 対象が 0 件なら何もしない）")
    func requestDeletionsOnCompletedSessionWithoutLatePart() async throws {
        let scene = try Self.lateScene()
        // 後から RAW_SAVED になった Part は無い（既定の Part を PENDING にした）
        try scene.movePart(Self.pk, to: .sourceDeletePending)
        let requested = await DeletionRequester(deps: Self.deps(scene, streaks: UndeletableStreaks()))
            .requestDeletions(sessionKey: Self.key)
        #expect(requested == 0)
        #expect(scene.requests() == [])
        #expect(try Self.part(scene).status == .sourceDeletePending)
    }

    @Test("F-80 途中で戻る評価（Session が読めない）も、その Session の連続を切る")
    func missingSessionRestartsTheStreak() async throws {
        let scene = try DeletionScene()
        let streaks = UndeletableStreaks()
        let missing = "DJIMIC3:20990101"
        _ = streaks.record(
            Self.pk, session: missing, connection: UndeletableStreaks.Connection(epoch: 1, deviceNode: nil),
            now: scene.clock.now(), minIntervalSeconds: 60)
        #expect(streaks.count == 1)
        let requested = await DeletionRequester(deps: Self.deps(scene, streaks: streaks))
            .requestDeletions(sessionKey: missing)
        #expect(requested == 0)
        #expect(streaks.count == 0)
    }

    @Test("F-80 決着の直前に Vault をもう一度確かめ、使えなくなっていれば決着を見送る（原因を raw_note と誤って書かない）")
    func vaultIsRecheckedJustBeforeSettling() async throws {
        let scene = try DeletionScene()
        try scene.store.updateSession(Self.key, [.deleteAttempts(Self.backoffCount)])
        scene.clock.advance(seconds: Self.backoffTotal)
        let snapshot = scene.snapshot()
        let ctx = await scene.context(snapshot: snapshot)
        let streaks = UndeletableStreaks()
        let requester = DeletionRequester(deps: Self.deps(scene, snapshot: snapshot, streaks: streaks))
        let session = try Self.session(scene)
        let parts = try scene.store.recordings(inSession: Self.key)
        let part = try Self.part(scene)
        // 評価の始めの観測では Vault が使えた
        let facts = DeletionRequester.SettlingFacts(siblingsAtRest: true, vaultAvailable: true)
        #expect(
            requester.considerSettling(part, session: session, parts: parts, snapshot: snapshot, ctx: ctx, facts: facts)
        )
        // その後に Vault が外れた
        try FileManager.default.removeItem(at: scene.vault.appendingPathComponent(".obsidian", isDirectory: true))
        scene.clock.advance(seconds: Self.spacing)
        #expect(
            !requester.considerSettling(
                part, session: session, parts: parts, snapshot: snapshot, ctx: ctx, facts: facts))
        #expect(try Self.part(scene).status == .rawSaved)
        #expect(!Self.settledLog(scene))
        #expect(streaks.count == 0)
    }

    // MARK: - 要対応: mount_failed と削除が無効な間の reaper の版

    @Test("F-80 unavailable の理由語 mount_failed（再マウントの mount の失敗。F-81）も deviceNeedsReplug に写す（バイト順）")
    func mountFailedNeedsReplug() {
        #expect(AttentionEvaluator.mountFailedReason == "mount_failed")
        var input = AttentionInput(now: DeletionScene.now)
        input.configPresent = true
        input.snapshot = DeviceSnapshot(
            generation: 1, completedAt: DeletionScene.now, connectEpoch: 1, devices: [:],
            unavailable: [
                "B": "mount_failed", "A": "mount_name_mismatch", "C": "not_listable", "D": "invalid_device_id",
            ],
            notListableErrno: [:])
        #expect(
            AttentionEvaluator.items(input) == [
                .deviceNotListable("C"), .deviceNeedsReplug("A"), .deviceNeedsReplug("B"), .deviceNameInvalid("D"),
            ])
    }

    @Test(
        "F-80 reaperUpdateRequired は削除が有効な間だけ出す（パラメータ化: 有効・無効）",
        arguments: [(true, [AttentionItem.reaperUpdateRequired]), (false, [])])
    func reaperUpdateOnlyWhileDeletionIsEnabled(_ enabled: Bool, _ expected: [AttentionItem]) {
        var input = AttentionInput(now: DeletionScene.now)
        input.configPresent = true
        input.reaper = .versionMismatch(found: "0.9.0")
        input.deletionEnabled = enabled
        #expect(AttentionEvaluator.items(input) == expected)
    }
}
