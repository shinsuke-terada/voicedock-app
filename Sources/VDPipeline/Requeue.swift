// FAILED を戻り先へ戻す（PLAN §5.4 の 4 つの契機）。時間・retry_count・RetryPolicy を見ない。上限なし（SM-05）。
import VDCore
import VDStore

/// FAILED を戻り先へ戻す（PLAN §5.4）。
struct Requeue {
    let ctx: TickContext

    /// FAILED → 戻り先（events の直近の FAILED への遷移元が *RetryableFromFailed に在るときだけ）。TransitionConflict は false。
    func resumeFailed(entity: EntityType, key: String, resetRetry: Bool, detail: String) throws -> Bool {
        let store = ctx.deps.store
        do {
            switch entity {
            case .recording:
                guard let to = try store.failedFromPart(key), PartStates.retryableFromFailed.contains(to) else {
                    return false
                }
                try store.recordPartTransition(
                    partkey: key, from: .failed, to: to, detail: detail, resetRetry: resetRetry)
            case .session:
                guard let to = try store.failedFromSession(key), SessionStates.retryableFromFailed.contains(to)
                else { return false }
                try store.recordSessionTransition(
                    sessionKey: key, from: .failed, to: to, detail: detail, resetRetry: resetRetry)
            }
        } catch is TransitionConflict {
            return false
        }
        return true
    }

    /// 契機 1〜3（起動・接続・再試行ボタン）。戻した数。
    /// needs_recopy の Part は除く（再コピーより先に戻すと、inbox が無いので SOURCE_MISSING の SKIPPED（終端）に落ちる）。
    func requeueFailed(_ reason: RequeueReason) throws -> Int {
        let store = ctx.deps.store
        var n = 0
        for pk in try store.failedRecordingKeys() {
            guard let row = try store.recording(pk) else { continue }
            if row.needsRecopy { continue }
            if try resumeFailed(entity: .recording, key: pk, resetRetry: true, detail: "requeue") { n += 1 }
        }
        for key in try store.failedSessionKeys() {
            if try resumeFailed(entity: .session, key: key, resetRetry: true, detail: "requeue") { n += 1 }
        }
        if n > 0 {
            ctx.deps.log.info(.recoveryCompleted, [(.requeued, .of(n))])
        }
        return n
    }

    /// 契機 4（再コピーの完了）。SOURCE_HASH_MISMATCH / NORMALIZED_MISSING で needs_recopy が 0 に戻った Part だけ。戻した数。
    func requeueRecopied() throws -> Int {
        let store = ctx.deps.store
        var n = 0
        for pk in try store.failedRecordingKeys() {
            guard let row = try store.recording(pk) else { continue }
            guard row.errorCode == .sourceHashMismatch || row.errorCode == .normalizedMissing, !row.needsRecopy
            else { continue }
            if try resumeFailed(entity: .recording, key: pk, resetRetry: true, detail: "recopied") { n += 1 }
        }
        if n > 0 {
            ctx.deps.log.info(.recoveryCompleted, [(.requeued, .of(n))])
        }
        return n
    }
}
