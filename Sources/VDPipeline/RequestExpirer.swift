// 結果の来ない要求の期限切れ（PLAN §8.9.7。voicedock pipeline.py:1004-1038）。対象は全 Part（Session で絞らない）。
// 読み直しと衝突の捕捉の 2 層を、それぞれ独立したテストで固定する（DEL-18 / TEST-17）。
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
                let pk = part.partkey
                // その request_id の結果を回収がいずれ拾える（DELETED の観測待ち）。取り下げない。
                // 読めない・partkey が合わない結果（reaper が読めない要求に partkey "" で書いたもの など）は妨げない（F-74）
                let own = DeleteQueue.result(requestID: id, layout: layout)
                if let r = own?.result, DeletionPolicy.sameKey(r.requestID, id), DeletionPolicy.sameKey(r.partkey, pk) {
                    continue
                }
                _ = DeleteQueue.withdrawRequests(partkey: pk, layout: layout)
                // 取り下げきれない要求が残れば ID を外さない。次の tick でやり直す（残った要求を reaper が再評価なしで
                // 実行し、結果が ID 不一致で捨てられるのを防ぐ。F-74）
                if DeleteQueue.hasRequest(partkey: pk, requestID: id, layout: layout) { continue }
                _ = DeleteQueue.withdrawResults(partkey: pk, layout: layout)
                // 層 2: 衝突は pend の中で捕まえる（status_changed）
                guard try ResultCollector(deps: deps).pend(part, code: .deleteTimeout, reason: DeletionReason.noResult)
                else { continue }
                // この試行の partkey の合わない結果は回収できない（回収は partkey で Part を引く）ので捨てる。読めない結果は残す（F-74）
                if let own, let r = own.result, DeletionPolicy.sameKey(r.requestID, id),
                    !DeletionPolicy.sameKey(r.partkey, pk)
                {
                    DeleteQueue.discard(own.url, layout: layout)
                }
            } catch {
                deps.warn(error)
            }
        }
    }
}
