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
                // 4a. 新鮮な snapshot で元ファイルが無いと観測できた RAW_SAVED は消す必要が無い（F-64）。要求を書かずに完了へ。
                //     source_deleted_at は入れない（アプリが消したのではない）。待っても変わらない条件で待たない（CR-15）
                if part.status == .rawSaved && Self.sourceIsObservedAbsent(part, in: snapshot, zone: deps.zone) {
                    do {
                        try deps.store.recordPartTransition(
                            partkey: part.partkey, from: .rawSaved, to: .completed,
                            detail: DeletionReason.alreadyAbsent)
                    } catch is TransitionConflict {
                        deps.logStatusChanged(recordingKey: part.partkey)
                        continue
                    }
                    deps.log.info(
                        .sourceDeleteSkipped,
                        [(.recordingKey, .string(part.partkey)), (.reason, .string(DeletionReason.alreadyAbsent))])
                    continue
                }
                // 5.
                guard
                    DeletionPolicy.canDeleteSource(
                        DeletionCandidate(part: part, session: session, parts: parts, twin: nil), ctx)
                else {
                    // 5a. 一覧に在るのに消せないまま期限を過ぎた RAW_SAVED は、消さずに完了へ（F-69）
                    if part.status == .rawSaved {
                        considerSettling(part, session: session, parts: parts, snapshot: snapshot, ctx: ctx)
                    }
                    continue
                }
                deps.streaks.reset(part.partkey)
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
        // 5.
        return requested
    }

    /// 決着に要る「観測できた状態で消せなかった評価」の連続回数（F-69。一時的な失敗 1 回で決着させない）
    static let observedFailuresToSettle = 2

    /// 手順 5a（F-69）: 観測できた失敗なら連続回数を数え、期限を過ぎていて 2 回以上続いていれば消さずに完了させる。
    /// 観測できない評価は連続を切る（数え直し）
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
        settleAsNotDeletable(part, cause: Self.undeletableCause(part, session: session, parts: parts, ctx: ctx))
        deps.streaks.reset(part.partkey)
    }

    /// RAW_SAVED→COMPLETED（detail not_deletable。原因の語は Part の error_message に）と
    /// source_delete_skipped recording_key=… reason=not_deletable detail=<原因>（F-69）。source_deleted_at は入れない
    func settleAsNotDeletable(_ part: RecordingRow, cause: String) {
        do {
            try deps.store.recordPartTransition(
                partkey: part.partkey, from: .rawSaved, to: .completed, errorMessage: cause,
                detail: DeletionReason.notDeletable)
        } catch is TransitionConflict {
            deps.logStatusChanged(recordingKey: part.partkey)
            return
        } catch {
            deps.warn(error)
            return
        }
        deps.log.info(
            .sourceDeleteSkipped,
            [
                (.recordingKey, .string(part.partkey)), (.reason, .string(DeletionReason.notDeletable)),
                (.detail, .string(cause)),
            ])
    }

    /// 期限（F-69 の条件 1）: backoff を使い切った（Session の delete_attempts ≥ 段の数）うえで、
    /// Part を RAW_SAVED にしてから（updated_at）backoff の合計が過ぎた。backoff が空（CV-52 違反）・updated_at が読めなければ偽
    static func deadlineHasPassed(
        _ part: RecordingRow, session: SessionRow, backoff: [Int], now: Instant, zone: ZonedTime
    ) -> Bool {
        guard !backoff.isEmpty, session.deleteAttempts >= backoff.count, let updated = zone.parseISO(part.updatedAt)
        else { return false }
        return now - updated >= Int64(backoff.reduce(0, +)) * 1000
    }

    /// 観測できた状態での失敗（F-69 の条件 a・2〜4。canDeleteSource が偽の RAW_SAVED について呼ぶ）。すべて満たすときだけ真:
    /// a. Session の Part がすべて終端（後続の Part が処理中なら Raw ノートの照合は待てば変わる）
    /// 2. デバイスが snapshot に載り（接続中で列挙できた）、unavailable に無く、書き込み可能（.writable）
    /// 3. Vault が使える（使えないのは待てば戻り、要対応の vaultUnavailable が別に出る）
    /// 4. 元ファイルが一覧に在る。source_path が無い・空は一覧と照らせず待っても変わらないので真。
    ///    無いものは手順 4a（F-64）が先に完了させる（期限の後の新鮮な snapshot は必ず取り込みより後）ので、4 は防御
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
    /// どれでもなければ事前確認（同定の共通項）
    static func undeletableCause(
        _ part: RecordingRow, session: SessionRow, parts: [RecordingRow], ctx: DeletionContext
    ) -> String {
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
        return DeletionReason.causePreIdentity
    }

    /// 元ファイルが無いと観測できた（F-64）: デバイスが snapshot に載り（接続中で列挙できた）、unavailable に無く、
    /// snapshot がその Part の updated_at（RAW_SAVED にした時刻。取り込みより後）より確かに後に完了していて、relpath が一覧に無い。
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
