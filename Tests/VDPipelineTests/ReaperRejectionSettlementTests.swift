// reaper が拒否し続ける Part の打ち切り（PLAN §8.9.5 の手順 5b。F-78・issue #124）。
// アプリの canDeleteSource は真なのに reaper の独立した検証だけが偽になる Part は、要求 → 拒否 → 再要求を繰り返し
// Session が完了しなかった。DB の events で拒否の連続を数え、3 回続いたら要求を書かずに消さずに決着させる。
// reaper の拒否は「要求を消し、その request_id の SOURCE_IDENTITY_MISMATCH の結果を書く」姿で作る。舞台は DeletionScene。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

@Suite("ReaperRejectionSettlement")
struct ReaperRejectionSettlementTests {
    static let pk = DeletionScene.partkey
    static let key = DeletionScene.sessionKey

    static func deps(_ scene: DeletionScene) -> DeletionDependencies {
        scene.deletionDependencies(ingest: ScriptedIngest(snapshot: scene.snapshot()))
    }

    /// 削除段の評価を 1 回（新しい依存で。この tick で PENDING に落とした集合と連続回数の記録は空から）
    static func evaluate(_ scene: DeletionScene) async {
        await SessionDeletionStage(deps: Self.deps(scene)).deleteSourcesIfSafe(sessionKey: Self.key)
    }

    /// reaper の拒否: 要求を消し（reaper は拒否の後に要求を消す）、Part の request_id の拒否の結果を書いて回収する
    static func reject(_ scene: DeletionScene, reason: String) async throws {
        let id = try #require(try Self.part(scene).deleteRequestID)
        for url in scene.requests() { try FileManager.default.removeItem(at: url) }
        try scene.writeResult(partkey: Self.pk, requestID: id, status: .sourceIdentityMismatch, detail: reason)
        await ResultCollector(deps: Self.deps(scene)).collectDeleteResults(reaperScanGeneration: 0)
    }

    /// 評価で要求が書かれたことを確かめてから拒否する（1 巡）
    static func requestAndReject(_ scene: DeletionScene, reason: String) async throws {
        await Self.evaluate(scene)
        try Self.expectRequested(scene)
        try await Self.reject(scene, reason: reason)
        let part = try Self.part(scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.errorCode == .sourceIdentityMismatch)
        #expect(part.deleteRequestID == nil)
    }

    /// 要求を書いた姿（SOURCE_DELETING・ID あり・要求 1 件・打ち切りのログ無し）
    static func expectRequested(_ scene: DeletionScene) throws {
        let part = try Self.part(scene)
        #expect(part.status == .sourceDeleting)
        #expect(part.deleteRequestID != nil)
        #expect(scene.requests().count == 1)
        #expect(!Self.settledLog(scene))
    }

    static func part(_ scene: DeletionScene) throws -> RecordingRow {
        try #require(try scene.store.recording(Self.pk))
    }

    static func session(_ scene: DeletionScene) throws -> SessionRow {
        try #require(try scene.store.session(Self.key))
    }

    static func events(_ scene: DeletionScene) throws -> [EventRow] {
        try scene.store.events(entity: .recording, key: Self.pk)
    }

    static func settledLog(_ scene: DeletionScene) -> Bool {
        scene.logLines.contains {
            $0.contains(" source_delete_skipped recording_key=" + Self.pk + " reason=not_deletable")
        }
    }

    static func requestedCount(_ scene: DeletionScene) -> Int {
        scene.logLines.filter { $0.contains(" delete_requested ") }.count
    }

    static func settledParts(_ scene: DeletionScene) throws -> [RecordingRow] {
        let ro = try #require(ReadOnlyStore.open(url: scene.layout.database))
        return try ro.completedParts(lastDetail: DeletionReason.notDeletable)
    }

    /// 打ち切った姿（消さずに PENDING→SOURCE_DELETING→COMPLETED。原因は最後の拒否の理由語。Session も完了）
    static func expectSettled(_ scene: DeletionScene, cause: String) throws {
        let part = try Self.part(scene)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt == nil)
        #expect(part.deleteRequestID == nil)
        #expect(part.errorCode == nil)
        #expect(part.errorMessage == cause)
        let last2 = Array(try Self.events(scene).suffix(2))
        #expect(last2.map(\.fromStatus) == ["SOURCE_DELETE_PENDING", "SOURCE_DELETING"])
        #expect(last2.map(\.toStatus) == ["SOURCE_DELETING", "COMPLETED"])
        #expect(last2.map(\.detail) == ["not_deletable", "not_deletable"])
        #expect(
            scene.logLines.contains {
                $0.hasSuffix(
                    " source_delete_skipped recording_key=" + Self.pk + " reason=not_deletable detail=" + cause)
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

    @Test(
        "F-78 アプリは消せると判断するのに reaper が続けて 3 回拒否したら、次の評価で要求を書かずに消さずに PENDING→SOURCE_DELETING→COMPLETED（detail not_deletable・原因は最後の拒否の理由語）で決着し Session も完了する（2 回までは要求を書く）"
    )
    func threeRejectionsSettleWithoutDeleting() async throws {
        let scene = try DeletionScene()
        // 評価ごとに新しい依存（Worker の記録を持ち越さない）。数えるのは DB の events
        for reason in ["size_mismatch", "size_mismatch", "mtime_mismatch"] {
            try await Self.requestAndReject(scene, reason: reason)
        }
        #expect(Self.requestedCount(scene) == 3)
        let streak = DeletionRequester.reaperRejectionStreak(try Self.events(scene))
        #expect(streak.count == 3)
        #expect(streak.lastReason == "mtime_mismatch")
        // 4 回目の評価: canDeleteSource は真のままだが、要求を書かずに決着する
        await Self.evaluate(scene)
        try Self.expectSettled(scene, cause: "mtime_mismatch")
        #expect(Self.requestedCount(scene) == 3)
    }

    @Test(
        "F-78 拒否の間に拒否でない結果（一覧にまだ在る・期限切れ・起動時の復旧）が挟まると 0 から数え直す（パラメータ化）",
        arguments: ["一覧にまだ在る", "期限切れ", "起動時の復旧"])
    func interveningOutcomeRestartsTheCount(_ outcome: String) async throws {
        let scene = try DeletionScene()
        for reason in ["size_mismatch", "size_mismatch"] {
            try await Self.requestAndReject(scene, reason: reason)
        }
        // 3 回目の要求（拒否 2 回なので書く）に、拒否でない結果が返る
        await Self.evaluate(scene)
        try Self.expectRequested(scene)
        let id = try #require(try Self.part(scene).deleteRequestID)
        switch outcome {
        case "一覧にまだ在る":
            // reaper は消したと言うが、その後の走査の一覧にまだ在る → pend（SOURCE_DELETE_FAILED・still_in_inventory）
            for url in scene.requests() { try FileManager.default.removeItem(at: url) }
            try scene.writeResult(partkey: Self.pk, requestID: id, status: .deleted, detail: DeletionScene.relpath)
            await ResultCollector(deps: Self.deps(scene)).collectDeleteResults(reaperScanGeneration: 0)
            #expect(try Self.part(scene).errorCode == .sourceDeleteFailed)
        case "期限切れ":
            // 結果が来ないまま期限を過ぎた → 取り下げて pend（DELETE_TIMEOUT・no_result）
            scene.clock.advance(seconds: 3600)
            await RequestExpirer(deps: Self.deps(scene)).expireDeleteRequests()
            #expect(try Self.part(scene).errorCode == .deleteTimeout)
        default:
            // 要求の途中で落ちた → 起動時の復旧で PENDING（ID を持ったまま）→ その要求の拒否は状態を動かさない pend
            let recovery = Recovery(
                store: scene.store, layout: scene.layout, log: scene.log, config: scene.config, zone: scene.zone)
            #expect(try recovery.run() == 2)
            #expect(try Self.part(scene).status == .sourceDeletePending)
            try await Self.reject(scene, reason: "size_mismatch")
        }
        var part = try Self.part(scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.deleteRequestID == nil)
        #expect(DeletionRequester.reaperRejectionStreak(try Self.events(scene)).count == 0)
        // 数え直し: 挟まった後の拒否 2 回では打ち切らず、3 回目の要求を書く
        for reason in ["size_mismatch", "size_mismatch"] {
            try await Self.requestAndReject(scene, reason: reason)
        }
        await Self.evaluate(scene)
        try Self.expectRequested(scene)
        // 挟まった後の 3 回目の拒否で打ち切る
        try await Self.reject(scene, reason: "unlink_failed")
        await Self.evaluate(scene)
        try Self.expectSettled(scene, cause: "unlink_failed")
        part = try Self.part(scene)
        #expect(part.status == .completed)
    }

    @Test(
        "F-78 canDeleteSource が偽になれば、拒否が 3 回続いていても 5b では決着させない（5a の期限と観測の条件に従って待つ。直して真に戻れば、保たれた回数で 5b が打ち切る）"
    )
    func undeletablePartIsLeftToTheDeadline() async throws {
        let scene = try DeletionScene()
        for reason in ["size_mismatch", "size_mismatch", "size_mismatch"] {
            try await Self.requestAndReject(scene, reason: reason)
        }
        // Raw ノートを手で編集した（canDeleteSource が偽。5a の期限はまだ）
        try scene.appendToRawNote("\n手で書き足した行\n")
        await Self.evaluate(scene)
        await Self.evaluate(scene)
        let part = try Self.part(scene)
        #expect(part.status == .sourceDeletePending)
        #expect(part.errorCode == .sourceIdentityMismatch)
        #expect(!Self.settledLog(scene))
        #expect(scene.requests() == [])
        #expect(try Self.settledParts(scene) == [])
        let session = try Self.session(scene)
        #expect(session.status == .sourceDeleting)
        #expect(session.deleteAttempts == 2)
        // Raw ノートを直す（canDeleteSource が真に戻る）。要求を書かなかった評価は回数を切らないので、要求を書かずに打ち切る
        try scene.writeRawNote()
        await Self.evaluate(scene)
        try Self.expectSettled(scene, cause: "size_mismatch")
        #expect(Self.requestedCount(scene) == 3)
    }

    @Test(
        "F-78 reaper の拒否で打ち切った Part も要対応・状態の詳細（削除モジュールの検証で拒否され続けた（<理由語>））に数え、「過去分を削除対象にする」で要求を書き、また拒否されたら COMPLETED の Session に PENDING を残さずに決着し直す"
    )
    func settledRejectionIsCountedAndRetargeted() async throws {
        let scene = try DeletionScene()
        for reason in ["size_mismatch", "size_mismatch", "size_mismatch"] {
            try await Self.requestAndReject(scene, reason: reason)
        }
        await Self.evaluate(scene)
        try Self.expectSettled(scene, cause: "size_mismatch")
        // 数え方（要対応は一覧にまだ在るものだけ・状態の詳細は全部）
        let settled = try Self.settledParts(scene)
        #expect(settled.map(\.partkey) == [Self.pk])
        #expect(
            AttentionEvaluator.undeletableStillListed(settled, snapshot: scene.snapshot()).map(\.partkey) == [Self.pk])
        let report = StatusReporter.build(
            layout: scene.layout, config: scene.config, snapshot: scene.snapshot(), now: scene.clock.now(),
            zone: scene.zone)
        #expect(report.undeletableTotal == 1)
        let lines = report.lines
        let index = try #require(lines.firstIndex(of: "消せなかった録音（1 件。消さずに完了にしたもの）"))
        #expect(lines[index + 1] == "  " + Self.pk)
        #expect(lines[index + 2] == "    削除モジュールの検証で拒否され続けた（size_mismatch）、デバイスに在る")
        // 後追い: canDeleteSource は真なので対象に入り、要求を書く（COMPLETED→SOURCE_DELETING）
        let planner = BacklogPlanner(deps: Self.deps(scene))
        let plan = try await planner.planBacklog()
        #expect(plan.eligible == [Self.pk])
        #expect(try await planner.executeBacklog(plan) == 1)
        #expect(try Self.part(scene).status == .sourceDeleting)
        // また拒否された → pend せずに SOURCE_DELETING→COMPLETED（not_deletable・理由語）で決着し直す
        let eventsBefore = try Self.events(scene).count
        try await Self.reject(scene, reason: "mtime_mismatch")
        try Self.expectResettled(scene, cause: "mtime_mismatch", eventsBefore: eventsBefore)
        #expect(try Self.session(scene).status == .completed)
        let again = StatusReporter.build(
            layout: scene.layout, config: scene.config, snapshot: scene.snapshot(), now: scene.clock.now(),
            zone: scene.zone)
        #expect(again.undeletableTotal == 1)
    }

    /// 後追いの拒否で決着し直した姿（SOURCE_DELETING→COMPLETED が 1 本だけ増え、PENDING を経ない。消さない）
    static func expectResettled(_ scene: DeletionScene, cause: String, eventsBefore: Int) throws {
        let part = try Self.part(scene)
        #expect(part.status == .completed)
        #expect(part.errorMessage == cause)
        #expect(part.errorCode == nil)
        #expect(part.deleteRequestID == nil)
        #expect(part.sourceDeletedAt == nil)
        let events = try Self.events(scene)
        #expect(events.count == eventsBefore + 1)
        let last = try #require(events.last)
        #expect(last.fromStatus == "SOURCE_DELETING")
        #expect(last.toStatus == "COMPLETED")
        #expect(last.detail == "not_deletable")
        #expect(scene.results() == [])
        #expect(
            scene.logLines.contains {
                $0.hasSuffix(
                    " source_delete_skipped recording_key=" + Self.pk + " reason=not_deletable detail=" + cause)
            })
        #expect(
            !scene.logLines.contains {
                $0.hasSuffix(" source_delete_pending recording_key=" + Self.pk + " reason=" + cause)
            })
        #expect(try Self.settledParts(scene).map(\.partkey) == [Self.pk])
    }

    @Test(
        "F-78 後追いの拒否で決着し直すのは not_deletable で決着した Part だけ（パラメータ化: 5a で決着した Part は決着し直す・決着していない COMPLETED の Part は従来どおり PENDING）",
        arguments: ["5a で決着した", "決着していない"])
    func onlySettledPartsAreResettled(_ kind: String) async throws {
        let scene = try DeletionScene()
        if kind == "5a で決着した" {
            let row = try Self.part(scene)
            DeletionRequester(deps: Self.deps(scene)).settleAsNotDeletable(row, cause: "raw_note")
        } else {
            // 読み取り専用で完了したのと同じ姿（detail の無い RAW_SAVED→COMPLETED）
            try scene.movePart(Self.pk, to: .completed)
        }
        try scene.moveSession(to: .completed)
        // 後追い（原因は直っている・もともと無いので対象）
        let planner = BacklogPlanner(deps: Self.deps(scene))
        let plan = try await planner.planBacklog()
        #expect(plan.eligible == [Self.pk])
        #expect(try await planner.executeBacklog(plan) == 1)
        #expect(try Self.part(scene).status == .sourceDeleting)
        let eventsBefore = try Self.events(scene).count
        try await Self.reject(scene, reason: "size_mismatch")
        if kind == "5a で決着した" {
            try Self.expectResettled(scene, cause: "size_mismatch", eventsBefore: eventsBefore)
        } else {
            let part = try Self.part(scene)
            #expect(part.status == .sourceDeletePending)
            #expect(part.errorCode == .sourceIdentityMismatch)
            #expect(part.deleteRequestID == nil)
            #expect(try Self.events(scene).last?.detail == "size_mismatch")
            #expect(!Self.settledLog(scene))
            #expect(try Self.settledParts(scene) == [])
        }
    }

    @Test("F-78 TEST-28 events が 0 件なら決着した Part の後追いの試行ではない")
    func emptyHistoryIsNotARetry() {
        #expect(!ResultCollector.retriesASettledPart([]))
    }

    @Test(
        "F-78 TEST-28 原因の語が空・無い・どの表にも無いときは「原因不明」（パラメータ化: 空文字・nil・未知の語）",
        arguments: [String?.some(""), nil, "no_such_word"])
    func unknownCauseIsShownAsUnknown(_ cause: String?) {
        #expect(
            StatusReport.UndeletablePart(partkey: Self.pk, cause: cause, presence: .listed).detail
                == "原因不明、デバイスに在る")
        if let cause { #expect(StatusReporter.causeText(cause) == nil) }
    }

    @Test("F-78 TEST-28 events が 0 件なら reaper の拒否は 0 回（理由語も無い）")
    func emptyHistoryHasNoRejection() {
        let streak = DeletionRequester.reaperRejectionStreak([])
        #expect(streak.count == 0)
        #expect(streak.lastReason == nil)
    }
}
