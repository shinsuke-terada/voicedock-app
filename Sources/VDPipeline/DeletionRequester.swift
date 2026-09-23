// Part の削除要求（根拠 A）。Raw を保存した直後（§5.5）と Session の削除段から呼ばれる。
// PLAN §8.9.5 requestDeletions（voicedock pipeline.py:670-748 ＋ 本計画の差分）。
import VDCore
import VDDevice
import VDNotes
import VDStore

/// Part の削除要求（根拠 A）。Session の状態で門前払いしない（AY-1）。結果の回収はここでしない（§8.9.6）。
struct DeletionRequester {
    let deps: DeletionDependencies

    /// 書いた要求の数。途中で戻る評価（snapshot が無いか古い・readiness が configured でない・Session が読めない）は
    /// 観測できない評価なので、その Session の連続を全部切る（F-80）
    func requestDeletions(sessionKey: String) async -> Int {
        var requested = 0
        // 1. その時点の最新（DEL-20）
        guard let snapshot = await deps.freshSnapshot() else {
            deps.streaks.retain(session: sessionKey, keeping: [])
            return 0
        }
        // 2.
        let ctx = await deps.context(snapshot: snapshot)
        if ctx.locks.readiness != .configured {
            deps.streaks.retain(session: sessionKey, keeping: [])
            return 0
        }
        // 3.
        let session: SessionRow
        let parts: [RecordingRow]
        do {
            guard let row = try deps.store.session(sessionKey) else {
                deps.streaks.retain(session: sessionKey, keeping: [])
                return 0
            }
            session = row
            parts = try deps.store.recordings(inSession: sessionKey)
        } catch {
            deps.warn(error)
            deps.streaks.retain(session: sessionKey, keeping: [])
            return 0
        }
        // 手順 5a の Session で共通の観測（F-80。最初に要るときに 1 回だけ調べる）
        var facts: SettlingFacts? = nil
        // この評価で観測できた失敗として連続を残した Part（F-80。評価の終わりにそれ以外の項目を捨てる）
        var observed: [String] = []
        // 4.
        for part in parts {
            do {
                // 1.
                guard PartStates.deletable.contains(part.status) else { continue }
                // 2. 通常経路は COMPLETED を消しにいかない。二重に要求しない
                if part.status == .sourceDeleting || part.status == .completed { continue }
                // 3. 結果待ち
                if part.deleteRequestID != nil { continue }
                // 4. 同じ周回で再要求しない（DEL-11）
                if deps.pended.contains(part.partkey) { continue }
                // 4a. 新鮮な snapshot で元ファイルが無いと観測できた RAW_SAVED と ID の無い SOURCE_DELETE_PENDING は消す必要が無い
                //     （F-64・F-78）。要求を書かずに完了へ。状態は明示する（将来 deletable に状態が足されても、ここを黙って通さない）。
                //     source_deleted_at は入れない（アプリが消したのではない）。待っても変わらない条件で待たない（CR-15）
                if Self.settleableStatuses.contains(part.status)
                    && Self.sourceIsObservedAbsent(part, in: snapshot, zone: deps.zone)
                {
                    try completeAsAbsent(part)
                    continue
                }
                // 5.
                guard
                    DeletionPolicy.canDeleteSource(
                        DeletionCandidate(part: part, session: session, parts: parts, twin: nil), ctx)
                else {
                    // 5a. 一覧に在るのに消せないまま期限を過ぎた RAW_SAVED と、ID の無い SOURCE_DELETE_PENDING は、
                    //     消さずに完了へ（F-69・F-74。PENDING で ID を持つものは手順 3 が先に飛ばす）
                    if Self.settleableStatuses.contains(part.status) {
                        let shared = facts ?? SettlingFacts.observe(parts: parts, ctx: ctx)
                        facts = shared
                        if considerSettling(
                            part, session: session, parts: parts, snapshot: snapshot, ctx: ctx, facts: shared)
                        {
                            observed.append(part.partkey)
                        }
                    }
                    continue
                }
                deps.streaks.reset(part.partkey)
                // 5b. アプリは消せると判断するのに reaper が続けて拒否した ID の無い SOURCE_DELETE_PENDING は、要求を書かずに
                //     消さずに完了へ（F-78。原因の語は最後の拒否の理由語）。食い違いは待っても変わらず、要求と拒否を繰り返さない（CR-15）
                if part.status == .sourceDeletePending, let reason = try persistentRejection(part) {
                    settleAsNotDeletable(part, cause: reason)
                    continue
                }
                // 6. ①②
                guard let id = try await RequestWriter(deps: deps).write(part: part, sessionKey: session.sessionKey)
                else {
                    continue
                }
                // 7. ③（RAW_SAVED か SOURCE_DELETE_PENDING から）
                do {
                    try deps.store.recordPartTransition(partkey: part.partkey, from: part.status, to: .sourceDeleting)
                } catch is TransitionConflict {
                    deps.logStatusChanged(recordingKey: part.partkey)
                    continue
                }
                // 8.
                deps.log.info(
                    .deleteRequested,
                    [
                        (.requestID, .string(id)), (.recordingKey, .string(part.partkey)),
                        (.sessionKey, .string(session.sessionKey)),
                    ])
                // 9.
                requested += 1
            } catch {
                deps.warn(error)
            }
        }
        // 連続の記録を縮める（F-80。RAW_SAVED / ID の無い SOURCE_DELETE_PENDING でなくなった・観測できなかった Part の項目を残さない）
        deps.streaks.retain(session: session.sessionKey, keeping: observed)
        // 5.
        return requested
    }

    /// 手順 4a（F-64・F-78）: 元ファイルが無いと観測できた Part を、要求を書かずに完了させ、
    /// source_delete_skipped recording_key=… reason=already_absent を出す。source_deleted_at は入れない（アプリが消したのではない）。
    /// RAW_SAVED は RAW_SAVED→COMPLETED（detail already_absent。F-64）。ID の無い SOURCE_DELETE_PENDING は「手動で消した分を完了にする」
    /// （BacklogPlanner.executeResolveAbsent。PLAN §8.9.9）と同じく、辺を足さずに →SOURCE_DELETING（detail resolve_absent）
    /// →COMPLETED（detail already_absent）の 2 遷移の後、この Part の要求・結果を取り下げて ID を外す（F-78）。
    /// TransitionConflict は status_changed を出して戻る。ほかの例外は投げる。それ以外の状態では何もしない
    func completeAsAbsent(_ part: RecordingRow) throws {
        let pk = part.partkey
        do {
            switch part.status {
            case .rawSaved:
                try deps.store.recordPartTransition(
                    partkey: pk, from: .rawSaved, to: .completed, detail: DeletionReason.alreadyAbsent)
            case .sourceDeletePending:
                try deps.store.recordPartTransition(
                    partkey: pk, from: .sourceDeletePending, to: .sourceDeleting,
                    detail: DeletionReason.resolveAbsentDetail)
                try deps.store.recordPartTransition(
                    partkey: pk, from: .sourceDeleting, to: .completed, detail: DeletionReason.alreadyAbsent)
                // 対応する試行の無い要求・結果を残さない（#160。手順 3 で ID は無いと分かっているが、同じ形にそろえる）
                _ = DeleteQueue.withdrawRequests(partkey: pk, layout: deps.layout)
                _ = DeleteQueue.withdrawResults(partkey: pk, layout: deps.layout)
                try deps.store.updateRecording(pk, [.deleteRequestID(nil)])
            default:
                return
            }
        } catch is TransitionConflict {
            deps.logStatusChanged(recordingKey: pk)
            return
        }
        deps.log.info(
            .sourceDeleteSkipped, [(.recordingKey, .string(pk)), (.reason, .string(DeletionReason.alreadyAbsent))])
    }

    /// 手順 5b（F-78）: アプリの canDeleteSource は真なのに reaper が同じ Part を続けて拒否した回数がこれに達したら、
    /// 次の評価で要求を書かずに消さずに完了させる（定数。設定キーは作らない。PLAN §8.9.5）
    static let reaperRejectionsToSettle = 3

    /// 手順 5b（F-78）: この Part を reaper が続けて reaperRejectionsToSettle 回以上拒否していれば、最後の拒否の理由語
    /// （その pend の events.detail。無ければ空文字）。届いていなければ nil。DB の履歴で数える（再起動で 0 に戻らない）
    func persistentRejection(_ part: RecordingRow) throws -> String? {
        let streak = Self.reaperRejectionStreak(try deps.store.events(entity: .recording, key: part.partkey))
        guard streak.count >= Self.reaperRejectionsToSettle else { return nil }
        return streak.lastReason ?? ""
    }

    /// reaper が続けて拒否した回数と、最後の拒否の理由語（F-78。PLAN §8.9.5 の 5b）。events を新しい順に見て、
    /// 回収の pend（SOURCE_DELETING→SOURCE_DELETE_PENDING で error_code が SOURCE_IDENTITY_MISMATCH）を数え、
    /// 間の要求の遷移（RAW_SAVED / SOURCE_DELETE_PENDING →SOURCE_DELETING で detail の無いもの）は読み飛ばし、それ以外の遷移で止まる
    /// （拒否でない結果・起動時の復旧・決着・手動で消した分・後追いの要求で数え直す）
    static func reaperRejectionStreak(_ events: [EventRow]) -> (count: Int, lastReason: String?) {
        var count = 0
        var lastReason: String?
        for event in events.reversed() {
            let from = event.fromStatus.flatMap(PartStatus.init(rawValue:))
            let to = PartStatus(rawValue: event.toStatus)
            if from == .sourceDeleting && to == .sourceDeletePending
                && event.errorCode == ErrorCode.sourceIdentityMismatch.rawValue
            {
                if count == 0 { lastReason = event.detail }
                count += 1
                continue
            }
            let isRequest =
                to == .sourceDeleting && event.detail == nil && (from == .rawSaved || from == .sourceDeletePending)
            if !isRequest { break }
        }
        return (count, lastReason)
    }

    /// 決着に要る「観測できた状態で消せなかった評価」の連続回数（F-69。一時的な失敗 1 回で決着させない）
    static let observedFailuresToSettle = 2

    /// 2 回目以降として数える観測の間隔の下限（F-80）: 削除評価の backoff の最初の値（既定 60 秒）。新しい設定キーは作らない。
    /// 評価の契機（Raw の直後・SAVED の直後・evaluateDeletions）が重なって、挿し直した直後の数秒のうちに 2 回と数えない。
    /// backoff が空（CV-52 違反）なら 0（期限が満たされないので決着しない）
    static func minimumStreakIntervalSeconds(backoff: [Int]) -> Int {
        backoff.first ?? 0
    }

    /// 連続を数える接続の区切り（F-69・F-80）: 全体の connectEpoch と、そのデバイスの deviceNode
    static func connection(of part: RecordingRow, in snapshot: DeviceSnapshot) -> UndeletableStreaks.Connection {
        UndeletableStreaks.Connection(
            epoch: snapshot.connectEpoch, deviceNode: snapshot.devices[part.deviceID]?.deviceNode)
    }

    /// 手順 5a の Session で共通の観測（F-80。1 回の requestDeletions で 1 回だけ調べ、Part ごとに繰り返さない）
    struct SettlingFacts: Equatable, Sendable {
        /// a. Session の Part がすべて終端で、FAILED は自動では戻らない（partIsAtRest）
        let siblingsAtRest: Bool
        /// c. Vault が使える（VaultCheck が .available）
        let vaultAvailable: Bool

        static func observe(parts: [RecordingRow], ctx: DeletionContext) -> SettlingFacts {
            SettlingFacts(
                siblingsAtRest: parts.allSatisfy { DeletionRequester.partIsAtRest($0, retry: ctx.config.retry) },
                vaultAvailable: VaultCheck.evaluate(path: ctx.config.vault.path, marker: ctx.config.vault.marker)
                    .isAvailable)
        }
    }

    /// 手順 5a の a（F-69・F-80）: Part が終端で、待っても自動では変わらない。FAILED は終端だが、再試行で Raw ノートを書き直しうるので、
    /// 自動で戻りうる間は数えない（待つ）: 再コピーを待つ（needs_recopy。再コピーの完了で requeueRecopied が戻す）・工程内リトライが残る
    /// （error_code の再試行の区分が attempts で、InProcessRetry と同じ式 RetryDelay.inProcess が次の待ちを返す）。
    /// それ以外の FAILED（区分が none / nextPoll / nextConnect・読めないコード・工程内リトライを使い切った）は、起動・接続・再試行ボタンの
    /// 契機でしか戻らず（戻れば処理中になり、その評価は観測できない側になる）、待っても変わらないので終端として数える（永久に待たない）
    static func partIsAtRest(_ part: RecordingRow, retry: RetryConfig) -> Bool {
        guard PartStates.terminal.contains(part.status) else { return false }
        guard part.status == .failed else { return true }
        if part.needsRecopy { return false }
        guard let code = part.errorCode, code.retryPolicy == .attempts else { return true }
        return RetryDelay.inProcess(
            retryCount: part.retryCount, maxAttempts: retry.maxAttempts, backoff: retry.backoffSeconds) == nil
    }

    /// 手順 4a で完了させ、手順 5a で決着を考える状態（F-64・F-69 の RAW_SAVED と、F-74・F-78 の ID の無い SOURCE_DELETE_PENDING）
    static let settleableStatuses: Set<PartStatus> = [.rawSaved, .sourceDeletePending]

    /// 手順 5a（F-69・F-74）: 観測できた失敗なら連続回数を数え、期限を過ぎていて 2 回以上続いていれば消さずに完了させる。
    /// 観測できない評価は連続を切る（数え直し）。決着の直前に原因を調べ直して何も見つからなければ、決着を見送り連続を切る（F-74）。
    /// 2 回目以降は、前に数えた観測から minimumStreakIntervalSeconds 以上たった観測だけを数える（F-80）。
    /// facts は Session で共通の観測（渡さなければここで調べる）。戻り値は連続を残したか（観測できた失敗として記録し、決着していない）
    @discardableResult
    func considerSettling(
        _ part: RecordingRow, session: SessionRow, parts: [RecordingRow], snapshot: DeviceSnapshot,
        ctx: DeletionContext, facts: SettlingFacts? = nil
    ) -> Bool {
        let facts = facts ?? SettlingFacts.observe(parts: parts, ctx: ctx)
        guard Self.failureIsObserved(part, facts: facts, snapshot: snapshot) else {
            deps.streaks.reset(part.partkey)
            return false
        }
        let backoff = ctx.config.cleanup.deleteEvaluationBackoffSeconds
        let streak = deps.streaks.record(
            part.partkey, session: session.sessionKey, connection: Self.connection(of: part, in: snapshot),
            now: deps.clock.now(), minIntervalSeconds: Self.minimumStreakIntervalSeconds(backoff: backoff))
        guard streak >= Self.observedFailuresToSettle,
            Self.deadlineHasPassed(part, session: session, backoff: backoff, now: deps.clock.now(), zone: deps.zone)
        else { return true }
        // 調べ直して全部の検査が通った（直前の評価の一時的な失敗か、原因の語の外の条件）。原因を偽って決着させない
        guard let cause = Self.undeletableCause(part, session: session, parts: parts, ctx: ctx) else {
            deps.streaks.reset(part.partkey)
            return false
        }
        settleAsNotDeletable(part, cause: cause)
        deps.streaks.reset(part.partkey)
        return false
    }

    /// 消さずに完了させ（原因の語は Part の error_message に）、source_delete_skipped recording_key=… reason=not_deletable
    /// detail=<原因> を出す（F-69・F-74。手順 5b の reaper の拒否の打ち切りも。F-78）。source_deleted_at は入れない。
    /// RAW_SAVED は RAW_SAVED→COMPLETED、SOURCE_DELETE_PENDING は辺を足さずに →SOURCE_DELETING→COMPLETED の 2 遷移
    /// （「手動で消した分を完了にする」と同じ。detail はどちらも not_deletable）。それ以外の状態では何もしない
    func settleAsNotDeletable(_ part: RecordingRow, cause: String) {
        let pk = part.partkey
        do {
            switch part.status {
            case .rawSaved:
                try deps.store.recordPartTransition(
                    partkey: pk, from: .rawSaved, to: .completed, errorMessage: cause,
                    detail: DeletionReason.notDeletable)
            case .sourceDeletePending:
                try deps.store.recordPartTransition(
                    partkey: pk, from: .sourceDeletePending, to: .sourceDeleting, detail: DeletionReason.notDeletable)
                try deps.store.recordPartTransition(
                    partkey: pk, from: .sourceDeleting, to: .completed, errorMessage: cause,
                    detail: DeletionReason.notDeletable)
            default:
                return
            }
        } catch is TransitionConflict {
            deps.logStatusChanged(recordingKey: pk)
            return
        } catch {
            deps.warn(error)
            return
        }
        deps.log.info(
            .sourceDeleteSkipped,
            [
                (.recordingKey, .string(pk)), (.reason, .string(DeletionReason.notDeletable)),
                (.detail, .string(cause)),
            ])
    }

    /// 期限（F-69 の条件 1）: backoff を使い切った（Session の delete_attempts ≥ 段の数）うえで、
    /// Part を RAW_SAVED / SOURCE_DELETE_PENDING にしてから（updated_at）backoff の合計が過ぎた。
    /// backoff が空（CV-52 違反）・updated_at が読めなければ偽
    static func deadlineHasPassed(
        _ part: RecordingRow, session: SessionRow, backoff: [Int], now: Instant, zone: ZonedTime
    ) -> Bool {
        guard !backoff.isEmpty, session.deleteAttempts >= backoff.count, let updated = zone.parseISO(part.updatedAt)
        else { return false }
        return now - updated >= Int64(backoff.reduce(0, +)) * 1000
    }

    /// 観測できた状態での失敗（F-69 の条件 a・2〜4。canDeleteSource が偽の RAW_SAVED と ID の無い SOURCE_DELETE_PENDING
    /// について呼ぶ）。すべて満たすときだけ真:
    /// a. Session の Part がすべて終端で、FAILED は自動では戻らない（facts.siblingsAtRest。partIsAtRest。後続の Part が処理中・
    ///    FAILED の兄弟が再試行で戻りうる間は、Raw ノートの照合が待てば変わる。F-80）
    /// 2. デバイスが snapshot に載り（接続中で列挙できた）、unavailable に無く、書き込み可能（.writable）
    /// 3. Vault が使える（facts.vaultAvailable。使えないのは待てば戻り、要対応の vaultUnavailable が別に出る）
    /// 4. 元ファイルが一覧に無いと観測できていない（SourcePresence.of が .notListed でない）。source_path が無い・空は一覧と
    ///    照らせず待っても変わらないので真。無い RAW_SAVED と ID の無い SOURCE_DELETE_PENDING は手順 4a（F-64・F-78）が先に完了させる
    ///    （期限の後の新鮮な snapshot は必ず RAW_SAVED / PENDING にした時刻より後）ので、4 は防御
    /// 新鮮さは呼び手が確かめる（DEL-20）
    static func failureIsObserved(_ part: RecordingRow, facts: SettlingFacts, snapshot: DeviceSnapshot) -> Bool {
        // a.
        guard facts.siblingsAtRest else { return false }
        // 2.
        guard snapshot.unavailable[part.deviceID] == nil, snapshot.devices[part.deviceID] != nil,
            DeviceWritability.observe(deviceID: part.deviceID, snapshot: snapshot) == .writable
        else { return false }
        // 3.
        guard facts.vaultAvailable else { return false }
        // 4.
        return SourcePresence.of(part, in: snapshot) != .notListed
    }

    /// 1 件だけ調べるときの形（Session で共通の観測をここで調べる）
    static func failureIsObserved(
        _ part: RecordingRow, parts: [RecordingRow], snapshot: DeviceSnapshot, ctx: DeletionContext
    ) -> Bool {
        failureIsObserved(part, facts: SettlingFacts.observe(parts: parts, ctx: ctx), snapshot: snapshot)
    }

    /// 決着した原因の語（F-69。状態の詳細に出す）。安い順・結果が原因を含む順に見る:
    /// 元の情報（source_path・source_size・source_mtime）→ 事前確認 → transcript（欠けると Raw ノートの照合も落ちる）→ Raw ノート。
    /// どれでもなければ nil（F-74。調べ直して全部通ったので決着させない）。RAW_SAVED / SOURCE_DELETE_PENDING（deletable）について呼ぶ
    static func undeletableCause(
        _ part: RecordingRow, session: SessionRow, parts: [RecordingRow], ctx: DeletionContext
    ) -> String? {
        guard let relpath = part.sourcePath, !relpath.isEmpty, part.sourceSize != nil, part.sourceMtime != nil else {
            return DeletionReason.causeSourceInfo
        }
        if !DeletionPolicy.preIdentityCheck(part, ctx) { return DeletionReason.causePreIdentity }
        if part.transcriptPath == nil || !DeletionPolicy.partTranscriptIsValid(part, ctx) {
            return DeletionReason.causeTranscript
        }
        // Raw ノートの節は根拠 A の式そのもの（写しを持たない。CR-06。F-80）。状態（deletable）と transcript は手前で通っているので、
        // 偽なら Raw ノートの照合（raw_output_path・verifyRawNote・frontmatter の鍵）のどれかが落ちている
        if !DeletionPolicy.textIsPreserved(part, session, parts, ctx) { return DeletionReason.causeRawNote }
        return nil
    }

    /// 元ファイルが無いと観測できた（F-64・F-78）: デバイスが snapshot に載り（接続中で列挙できた）、unavailable に無く、
    /// snapshot がその Part の updated_at（RAW_SAVED / SOURCE_DELETE_PENDING にした時刻。取り込みより後）より確かに後に完了していて、
    /// relpath が一覧に無い。
    /// source_path が無い・空、updated_at が読めない、未接続・列挙できないときは偽（観測できたときだけ「無い」と言う）。
    /// updated_at は秒に切り捨てて記録されるので、completedAt ≥ updated_at + 1 秒で「後」とする。新鮮さは呼び手が確かめる（DEL-20）
    static func sourceIsObservedAbsent(_ part: RecordingRow, in snapshot: DeviceSnapshot, zone: ZonedTime) -> Bool {
        // 接続中で列挙でき、source_path が在って一覧に無い（「一覧に在るか」は SourcePresence.of の 1 か所。F-80）
        guard SourcePresence.of(part, in: snapshot) == .notListed else { return false }
        // 取り込む前の走査の snapshot で「無い」と言わない
        guard let updated = zone.parseISO(part.updatedAt) else { return false }
        return snapshot.completedAt.epochMillis >= updated.epochMillis + 1000
    }
}
