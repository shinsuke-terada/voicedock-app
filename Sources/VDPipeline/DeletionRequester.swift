// Part の削除要求（根拠 A）。Raw を保存した直後（§5.5）と Session の削除段から呼ばれる。
// PLAN §8.9.5 requestDeletions（voicedock pipeline.py:670-748 ＋ 本計画の差分）。
import VDCore
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
                // 5.
                guard
                    DeletionPolicy.canDeleteSource(
                        DeletionCandidate(part: part, session: session, parts: parts, twin: nil), ctx)
                else { continue }
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
}
