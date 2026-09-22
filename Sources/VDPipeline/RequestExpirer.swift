// 結果の来ない要求の期限切れ（PLAN §8.9.7。voicedock pipeline.py:1004-1038）。対象は全 Part（Session で絞らない）。
// 読み直しと衝突の捕捉の 2 層を、それぞれ独立したテストで固定する（DEL-18 / TEST-17）。
import Darwin
import VDContract
import VDCore
import VDStore

/// 結果の来ない要求の期限切れ。
struct RequestExpirer {
    let deps: DeletionDependencies

    /// = expire(candidates: store.recordingsAwaitingDeleteResult(), reread: { try deps.store.recording($0) })
    func expireDeleteRequests() async {
        let candidates: [RecordingRow]
        do {
            candidates = try deps.store.recordingsAwaitingDeleteResult()
        } catch {
            deps.warn(error)
            return
        }
        let store = deps.store
        expire(candidates: candidates, reread: { try store.recording($0) })
    }

    /// テスト用（@testable）: 候補の一覧と読み直しを差し替える
    func expire(candidates: [RecordingRow], reread: (String) throws -> RecordingRow?) {
        let now = deps.clock.now()
        let timeoutMillis = Int64(deps.config.cleanup.deleteResultTimeoutSeconds) * 1000
        let layout = deps.layout
        // started_at, partkey 順
        for stale in candidates {
            do {
                // 層 1: 読み直す（一覧の写しの updated_at を使わない）
                guard let part = try reread(stale.partkey), let id = part.deleteRequestID else { continue }
                // 読めない updated_at は期限切れ扱い（取り下げるだけで消さない）
                if let updated = deps.zone.parseISO(part.updatedAt), now - updated < timeoutMillis { continue }
                // その request_id の結果が在る（DELETED の観測待ち）。取り下げない
                var st = stat()
                if RequestID.isValid(id),
                    lstat(DeleteQueue.resultURL(id, layout: layout).path(percentEncoded: false), &st) == 0
                {
                    continue
                }
                let pk = part.partkey
                _ = DeleteQueue.withdrawRequests(partkey: pk, layout: layout)
                _ = DeleteQueue.withdrawResults(partkey: pk, layout: layout)
                // 層 2: 衝突は pend の中で捕まえる（status_changed）
                _ = try ResultCollector(deps: deps).pend(part, code: .deleteTimeout, reason: DeletionReason.noResult)
            } catch {
                deps.warn(error)
            }
        }
    }
}
