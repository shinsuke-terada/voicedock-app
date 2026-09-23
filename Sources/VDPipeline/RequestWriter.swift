// 削除要求の ①ID → ②要求ファイル（PLAN §4.4 の書く順）。③の遷移は呼び手（根拠 A と後追いは SOURCE_DELETING へ、根拠 B は遷移しない）。
import VDContract
import VDCore
import VDStore

/// 削除要求を書く唯一の場所（PR-09）。
struct RequestWriter {
    let deps: DeletionDependencies
    /// ロック 1（reaper.conf）の読み。本番は `deps.locks.observeReaperConf()`（F-72）
    let observeLock1: @Sendable () async -> ReaperConfObservation

    init(deps: DeletionDependencies) {
        let locks = deps.locks
        self.init(deps: deps, observeLock1: { await locks.observeReaperConf() })
    }

    /// テスト用（@testable）: ロック 1 の読みを差し替える（② の前後で無効化が走った状況を作る）
    init(deps: DeletionDependencies, observeLock1: @escaping @Sendable () async -> ReaperConfObservation) {
        self.deps = deps
        self.observeLock1 = observeLock1
    }

    /// 書けたら request_id。書けなければ nil（理由はログに出してある）。Store の予期しない例外は投げる。
    /// F-72: ② の前後で reaper.conf を読み直す（readiness は各段の先頭で 1 回だけ評価する。その後に無効化が走っていたら要求を残さない）
    func write(part: RecordingRow, sessionKey: String) async throws -> String? {
        // 1. 削除条件が真なら揃っている。防御
        guard let relpath = part.sourcePath, let size = part.sourceSize, let mtime = part.sourceMtime else {
            return nil
        }
        // 2.
        let now = deps.clock.now()
        let seconds = now.epochMillis >= 0 ? now.epochMillis / 1000 : -((-now.epochMillis + 999) / 1000)
        let id = RequestID.make(partkey: part.partkey, utcEpochSeconds: seconds, randomHex6: RequestID.randomHex6())
        // 3. ① ID を先に
        guard try deps.store.updateRecordingIfStatus(part.partkey, status: part.status, [.deleteRequestID(id)]) else {
            deps.logStatusChanged(recordingKey: part.partkey)
            return nil
        }
        // 4. F-72: ロック 1 を読み直す。DELETE_SOURCE_AUDIO=true で読めなければ書かない（無い・不正も書かない。② の失敗と同じく ID を外す）
        guard await lock1IsReleased() else {
            try deps.store.updateRecording(part.partkey, [.deleteRequestID(nil)])
            logLockMismatch(part.partkey, level: .info)
            return nil
        }
        // 5. DEL-12: size / mtime は DB の値 = デバイス上の原本。PR-17: 絶対パスを持たない
        let request = DeleteRequest(
            requestID: id, createdAt: deps.zone.iso(now), deviceID: part.deviceID, partkey: part.partkey,
            sessionKey: sessionKey, target: DeleteTarget(relpath: relpath, size: size, mtime: mtime))
        // 6. ② 要求ファイル
        do {
            try DeleteQueue.write(request, layout: deps.layout)
        } catch {
            try deps.store.updateRecording(part.partkey, [.deleteRequestID(nil)])
            deps.log.warning(
                .sourceDeletePending,
                [
                    (.recordingKey, .string(part.partkey)), (.reason, .string(DeletionReason.queueWriteFailed)),
                    (.errorCode, .string(ErrorCode.deleteQueueFailed.rawValue)),
                ])
            return nil
        }
        // 7. F-72: ② の後にもう一度読む。偽が見えたら無効化の段 1 は済んでいる（段 4 の取り下げが自分の要求より先に
        // 終わっていたかもしれない）ので、自分で取り下げて ID を外す。真が見えたら段 1 はこの後に来るので段 4 が取り下げる
        guard await lock1IsReleased() else {
            do {
                try SafeUnlink.remove(
                    DeleteQueue.requestURL(id, layout: deps.layout), under: .queueDelete, layout: deps.layout,
                    missingOK: true)
            } catch {
                // 取り下げられない: ID を持ったまま nil（呼び手は ③ に進まない）。期限切れ（§8.9.7）が取り下げてから ID を外す
                logLockMismatch(part.partkey, level: .warning)
                return nil
            }
            try deps.store.updateRecording(part.partkey, [.deleteRequestID(nil)])
            logLockMismatch(part.partkey, level: .info)
            return nil
        }
        // 8.
        return id
    }

    /// reaper.conf が `DELETE_SOURCE_AUDIO=true` で読める（無い・不正・false は偽）
    private func lock1IsReleased() async -> Bool {
        guard case .valid(let conf) = await observeLock1() else { return false }
        return conf.deleteSourceAudio
    }

    /// `source_delete_skipped recording_key=… reason=lock_mismatch`（取り下げに失敗して要求が残るときは WARNING）
    private func logLockMismatch(_ partkey: String, level: LogLevel) {
        deps.log.log(
            level, .sourceDeleteSkipped,
            [(.recordingKey, .string(partkey)), (.reason, .string(DeletionReason.lockMismatch))])
    }
}
