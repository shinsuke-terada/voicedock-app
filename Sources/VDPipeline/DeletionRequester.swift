// Part の削除要求（根拠 A）。Raw を保存した直後（§5.5）と Session の削除段から呼ばれる。
// PLAN §8.9.5 requestDeletions（voicedock pipeline.py:670-748 ＋ 本計画の差分）。
import VDCore
import VDDevice
import VDNotes
import VDStore

/// Part の削除要求（根拠 A）。Session の状態で門前払いしない（AY-1）。結果の回収はここでしない（§8.9.6）。
struct DeletionRequester {
    let deps: DeletionDependencies

    /// 書いた要求の数
    func requestDeletions(sessionKey: String) async -> Int {
        var requested = 0
        // 1. その時点の最新（DEL-20）
        guard let snapshot = await deps.freshSnapshot() else { return 0 }
        // 2.
        let ctx = await deps.context(snapshot: snapshot)
        if ctx.locks.readiness != .configured { return 0 }
        // 3.
        let session: SessionRow
        let parts: [RecordingRow]
        do {
            guard let row = try deps.store.session(sessionKey) else { return 0 }
            session = row
            parts = try deps.store.recordings(inSession: sessionKey)
        } catch {
            deps.warn(error)
            return 0
        }
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
                //     （F-64・F-78。手順 1〜3 の後に残るのはこの 2 つだけ）。要求を書かずに完了へ。
                //     source_deleted_at は入れない（アプリが消したのではない）。待っても変わらない条件で待たない（CR-15）
                if Self.sourceIsObservedAbsent(part, in: snapshot, zone: deps.zone) {
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
                        considerSettling(part, session: session, parts: parts, snapshot: snapshot, ctx: ctx)
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
                guard let id = try RequestWriter(deps: deps).write(part: part, sessionKey: session.sessionKey) else {
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

    /// 手順 5a で決着を考える状態（F-69 の RAW_SAVED と、F-74 の ID の無い SOURCE_DELETE_PENDING）
    static let settleableStatuses: Set<PartStatus> = [.rawSaved, .sourceDeletePending]

    /// 手順 5a（F-69・F-74）: 観測できた失敗なら連続回数を数え、期限を過ぎていて 2 回以上続いていれば消さずに完了させる。
    /// 観測できない評価は連続を切る（数え直し）。決着の直前に原因を調べ直して何も見つからなければ、決着を見送り連続を切る（F-74）
    func considerSettling(
        _ part: RecordingRow, session: SessionRow, parts: [RecordingRow], snapshot: DeviceSnapshot, ctx: DeletionContext
    ) {
        guard Self.failureIsObserved(part, parts: parts, snapshot: snapshot, ctx: ctx) else {
            deps.streaks.reset(part.partkey)
            return
        }
        let streak = deps.streaks.record(part.partkey, connectEpoch: snapshot.connectEpoch)
        guard streak >= Self.observedFailuresToSettle,
            Self.deadlineHasPassed(
                part, session: session, backoff: ctx.config.cleanup.deleteEvaluationBackoffSeconds,
                now: deps.clock.now(), zone: deps.zone)
        else { return }
        // 調べ直して全部の検査が通った（直前の評価の一時的な失敗か、原因の語の外の条件）。原因を偽って決着させない
        guard let cause = Self.undeletableCause(part, session: session, parts: parts, ctx: ctx) else {
            deps.streaks.reset(part.partkey)
            return
        }
        settleAsNotDeletable(part, cause: cause)
        deps.streaks.reset(part.partkey)
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
    /// a. Session の Part がすべて終端（後続の Part が処理中なら Raw ノートの照合は待てば変わる）
    /// 2. デバイスが snapshot に載り（接続中で列挙できた）、unavailable に無く、書き込み可能（.writable）
    /// 3. Vault が使える（使えないのは待てば戻り、要対応の vaultUnavailable が別に出る）
    /// 4. 元ファイルが一覧に在る。source_path が無い・空は一覧と照らせず待っても変わらないので真。
    ///    無い RAW_SAVED と ID の無い SOURCE_DELETE_PENDING は手順 4a（F-64・F-78）が先に完了させる
    ///    （期限の後の新鮮な snapshot は必ず RAW_SAVED / PENDING にした時刻より後）ので、4 は防御
    /// 新鮮さは呼び手が確かめる（DEL-20）
    static func failureIsObserved(
        _ part: RecordingRow, parts: [RecordingRow], snapshot: DeviceSnapshot, ctx: DeletionContext
    ) -> Bool {
        // a.
        guard parts.allSatisfy({ PartStates.terminal.contains($0.status) }) else { return false }
        // 2.
        guard snapshot.unavailable[part.deviceID] == nil, let observation = snapshot.devices[part.deviceID],
            DeviceWritability.observe(deviceID: part.deviceID, snapshot: snapshot) == .writable
        else { return false }
        // 3.
        guard VaultCheck.evaluate(path: ctx.config.vault.path, marker: ctx.config.vault.marker).isAvailable else {
            return false
        }
        // 4.
        guard let relpath = part.sourcePath, !relpath.isEmpty else { return true }
        return observation.relpaths.contains(where: { DeletionPolicy.sameKey($0, relpath) })
    }

    /// 決着した原因の語（F-69。状態の詳細に出す）。安い順・結果が原因を含む順に見る:
    /// 元の情報（source_path・source_size・source_mtime）→ 事前確認 → transcript（欠けると Raw ノートの照合も落ちる）→ Raw ノート。
    /// どれでもなければ nil（F-74。調べ直して全部通ったので決着させない）
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
        if session.rawOutputPath == nil || DeletionPolicy.verifyRawNote(session, parts, ctx) != .passed
            || !DeletionPolicy.frontmatterKeys(session.rawOutputPath, ctx).contains(where: {
                DeletionPolicy.sameKey($0, part.partkey)
            })
        {
            return DeletionReason.causeRawNote
        }
        return nil
    }

    /// 元ファイルが無いと観測できた（F-64・F-78）: デバイスが snapshot に載り（接続中で列挙できた）、unavailable に無く、
    /// snapshot がその Part の updated_at（RAW_SAVED / SOURCE_DELETE_PENDING にした時刻。取り込みより後）より確かに後に完了していて、
    /// relpath が一覧に無い。
    /// source_path が無い・空、updated_at が読めない、未接続・列挙できないときは偽（観測できたときだけ「無い」と言う）。
    /// updated_at は秒に切り捨てて記録されるので、completedAt ≥ updated_at + 1 秒で「後」とする。新鮮さは呼び手が確かめる（DEL-20）
    static func sourceIsObservedAbsent(_ part: RecordingRow, in snapshot: DeviceSnapshot, zone: ZonedTime) -> Bool {
        guard snapshot.unavailable[part.deviceID] == nil, let observation = snapshot.devices[part.deviceID],
            let relpath = part.sourcePath, !relpath.isEmpty
        else { return false }
        // 取り込む前の走査の snapshot で「無い」と言わない
        guard let updated = zone.parseISO(part.updatedAt),
            snapshot.completedAt.epochMillis >= updated.epochMillis + 1000
        else { return false }
        return !observation.relpaths.contains(where: { DeletionPolicy.sameKey($0, relpath) })
    }
}
