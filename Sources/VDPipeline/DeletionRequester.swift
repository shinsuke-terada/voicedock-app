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
                    // 5a. 一覧に在るのに消せないまま期限を過ぎた RAW_SAVED は、消さずに完了へ（F-69）。
                    //     source_deleted_at は入れない（消していない）。要対応に「消せなかった録音」として出る（§8.11）
                    if part.status == .rawSaved
                        && Self.settlesAsNotDeletable(
                            part, session: session, snapshot: snapshot, ctx: ctx, now: deps.clock.now(),
                            zone: deps.zone)
                    {
                        settleAsNotDeletable(part)
                    }
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

    /// RAW_SAVED→COMPLETED（detail not_deletable）と source_delete_skipped … reason=not_deletable（F-69）
    private func settleAsNotDeletable(_ part: RecordingRow) {
        do {
            try deps.store.recordPartTransition(
                partkey: part.partkey, from: .rawSaved, to: .completed, detail: DeletionReason.notDeletable)
        } catch is TransitionConflict {
            deps.logStatusChanged(recordingKey: part.partkey)
            return
        } catch {
            deps.warn(error)
            return
        }
        deps.log.info(
            .sourceDeleteSkipped,
            [(.recordingKey, .string(part.partkey)), (.reason, .string(DeletionReason.notDeletable))])
    }

    /// 消せないまま待つのをやめる（F-69。canDeleteSource が偽の RAW_SAVED について呼ぶ）。すべて満たすときだけ真:
    /// 1. 期限: backoff を使い切った（Session の delete_attempts ≥ 段の数）うえで、Part を RAW_SAVED にしてから backoff の合計が過ぎた
    ///    （既定 60+300+900+3600 秒 = 81 分。新しい設定キーは作らない）。backoff が空（CV-52 違反）なら偽
    /// 2. 観測: デバイスが snapshot に載り（接続中で列挙できた）、unavailable に無く、書き込み可能（.writable）
    /// 3. Vault が使える（使えないのは待てば戻り、要対応の vaultUnavailable が別に出る）
    /// 4. 元ファイルが一覧に在る（無いのは F-64 の already_absent）。source_path が無い・空は一覧と照らせず、待っても変わらないので真
    /// 観測できないうち（未接続・列挙できない・snapshot が古い）は決着させない。新鮮さは呼び手が確かめる（DEL-20）
    static func settlesAsNotDeletable(
        _ part: RecordingRow, session: SessionRow, snapshot: DeviceSnapshot, ctx: DeletionContext, now: Instant,
        zone: ZonedTime
    ) -> Bool {
        // 1.
        let backoff = ctx.config.cleanup.deleteEvaluationBackoffSeconds
        guard !backoff.isEmpty, session.deleteAttempts >= backoff.count, let updated = zone.parseISO(part.updatedAt),
            now - updated >= Int64(backoff.reduce(0, +)) * 1000
        else { return false }
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
