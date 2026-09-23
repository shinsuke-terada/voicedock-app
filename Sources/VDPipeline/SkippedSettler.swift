// 根拠 B（PLAN §8.9.5）: 保全すべき本文が無い SKIPPED の Part に、SKIPPED のまま削除要求を書く（①ID → ②要求ファイル。遷移しない。SM-20）。
// 回収・期限切れは T-38 の ResultCollector / RequestExpirer が根拠 A と同じ規則で拾う。
import VDContract
import VDCore
import VDStore

/// 根拠 B の削除要求（voicedock pipeline.py:814-884 の settle_skipped_deletions）。遷移しない（SM-20）。
struct SkippedSettler {
    let deps: DeletionDependencies

    /// 書いた要求の数
    func settleSkippedDeletions() async -> Int {
        var requested = 0
        // 1. 何も読まない
        if deps.config.cleanup.deleteSkippedSource == false { return 0 }
        // 2. 新鮮な snapshot だけを使う（DEL-20）
        guard let snapshot = await deps.freshSnapshot() else { return 0 }
        // 3. 式の共通項が必ず落とすので、ノートと transcript を読む前にやめる
        let ctx = await deps.context(snapshot: snapshot)
        if ctx.locks.readiness != .configured { return 0 }
        // 4. started_at, partkey 順
        let skipped: [RecordingRow]
        do {
            skipped = try deps.store.recordings(status: .skipped)
        } catch {
            deps.warn(error)
            return 0
        }
        // 5. デバイスに今在るものだけ（過去の件数に比例させない）
        let present = skipped.filter { p in
            guard let rel = p.sourcePath, let obs = snapshot.devices[p.deviceID] else { return false }
            return obs.relpaths.contains(where: { DeletionPolicy.sameKey($0, rel) })
        }
        // 6. 先頭の値（最小値ではない）
        let first = deps.config.cleanup.deleteEvaluationBackoffSeconds.first ?? 0
        let now = deps.clock.now()
        // 7.
        for stale in present {
            do {
                // 1. 読み直す
                guard let part = try deps.store.recording(stale.partkey), part.status == .skipped else { continue }
                // 2.
                guard let sessionKey = part.sessionKey else { continue }
                // 3. 決着済み・結果待ち
                guard part.sourceDeletedAt == nil, part.deleteRequestID == nil else { continue }
                // 4. この tick で拒否されたものを再要求しない（DEL-11）
                guard !deps.pended.contains(part.partkey) else { continue }
                // 5. 間引き（拒否の直後は pend が updated_at を今にするので、次の要求は backoff[0] 秒後。読めない updated_at は間引かない）
                if let updated = deps.zone.parseISO(part.updatedAt), now - updated < Int64(first) * 1000 { continue }
                // 6.
                guard let session = try deps.store.session(sessionKey) else { continue }
                // 7. 双子の引き方は T-36 §4.7.2
                let parts = try deps.store.recordings(inSession: sessionKey)
                let twin = try TwinPart.load(for: part, store: deps.store)
                // 8.
                guard
                    DeletionPolicy.canDeleteSource(
                        DeletionCandidate(part: part, session: session, parts: parts, twin: twin), ctx)
                else { continue }
                // 9. ① の updateRecordingIfStatus(status: .skipped) が状態の変化を捕まえる
                guard let id = try await RequestWriter(deps: deps).write(part: part, sessionKey: sessionKey) else {
                    continue
                }
                // 10.
                deps.log.info(
                    .deleteRequested,
                    [
                        (.requestID, .string(id)), (.recordingKey, .string(part.partkey)),
                        (.sessionKey, .string(sessionKey)),
                    ])
                // 11.
                requested += 1
            } catch {
                deps.warn(error)
            }
        }
        // 8.
        return requested
    }
}
