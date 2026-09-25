// Session の削除段と後始末（PLAN §8.9.5 deleteSourcesIfSafe。voicedock pipeline.py:750-812・1075-1092 ＋ v1.1 の修正）。
// 呼ばれる契機は SAVED になった直後（backoff を見ずに 1 回）と evaluateDeletions（backoff に従う。DEL-14）。
import VDContract
import VDCore
import VDStore

/// Session の削除段と後始末。
struct SessionDeletionStage {
    let deps: DeletionDependencies

    func deleteSourcesIfSafe(sessionKey key: String) async {
        do {
            guard let first = try deps.store.session(key), try isEvaluated(first) else {
                return
            }
            if first.status == .cleanup {
                try finishCleanup(first)
                return
            }
            let requested = await DeletionRequester(deps: deps).requestDeletions(sessionKey: key)
            // 読み直し
            guard let row = try deps.store.session(key), try isEvaluated(row) else {
                return
            }
            let parts = try deps.store.recordings(inSession: key)
            // requestDeletions の中でも評価済み（キャッシュが効く）
            let readiness = await deps.locks.readiness(config: deps.config)
            if case .disabled(let reason) = readiness {
                deps.log.info(.sourceDeleteSkipped, [(.sessionKey, .string(key)), (.reason, .string(reason))])
                try completeWithoutDeleting(row, parts)
                return
            }
            // 未接続（.absent）は完了させずに待つ（PLAN §8.9.2）。有効化の直後で挿し直す前（.readOnly）は完了する
            let w = DeviceWritability.observe(deviceID: row.deviceID, snapshot: await deps.ingest.latestSnapshot())
            if w == .readOnly || w == .unknown {
                deps.log.info(
                    .sourceDeleteSkipped,
                    [(.sessionKey, .string(key)), (.reason, .string(DeletionReason.deviceReadonly))])
                try completeWithoutDeleting(row, parts)
                return
            }
            // ログなし
            if !parts.contains(where: { PartStates.awaitingDeletion.contains($0.status) }) {
                try completeWithoutDeleting(row, parts)
                return
            }
            // 遷移しない（未接続など。updated_at が進み backoff が効く）
            if requested == 0 && !parts.contains(where: { $0.status == .sourceDeleting }) {
                try deps.store.updateSession(key, [.deleteAttempts(row.deleteAttempts + 1)])
                return
            }
            if row.status == .saved || row.status == .sourceDeletePending {
                do {
                    try deps.store.recordSessionTransition(sessionKey: key, from: row.status, to: .sourceDeleting)
                } catch is TransitionConflict {
                    deps.logStatusChanged(sessionKey: key)
                }
            }
        } catch {
            deps.warn(error)
        }
    }

    func completeWithoutDeleting(_ row: SessionRow, _ parts: [RecordingRow]) throws {
        let key = row.sessionKey
        // ②の後・③の前に落ちた Part の結果か期限切れを待つ
        if parts.contains(where: { $0.status == .rawSaved && $0.deleteRequestID != nil }) {
            try deps.store.updateSession(key, [.deleteAttempts(row.deleteAttempts + 1)])
            return
        }
        for p in parts where p.status == .rawSaved {
            do {
                try deps.store.recordPartTransition(partkey: p.partkey, from: .rawSaved, to: .completed)
            } catch is TransitionConflict {
                deps.logStatusChanged(recordingKey: p.partkey)
            }
        }
        if SessionStates.cleanupFrom.contains(row.status) {
            do {
                try deps.store.recordSessionTransition(sessionKey: key, from: row.status, to: .cleanup)
            } catch is TransitionConflict {
                deps.logStatusChanged(sessionKey: key)
                return
            }
        }
        if let fresh = try deps.store.session(key), fresh.status == .cleanup {
            try finishCleanup(fresh)
        }
    }

    func finishCleanup(_ row: SessionRow) throws {
        guard row.status == .cleanup else { return }
        let key = row.sessionKey
        let layout = deps.layout
        var failed = false
        // FAILED の 16 kHz は残す（SM-23）
        for p in try deps.store.recordings(inSession: key) where PartStates.stagingDisposable.contains(p.status) {
            let slug = KeySlug.of(p.partkey)
            for url in [
                layout.normalizedAudio(slug: slug), layout.normalizedAudioTmp(slug: slug),
                layout.whisperJSON(slug: slug), layout.diarizationRTTM(slug: slug),
            ] {
                // 無いものは missingOK
                do { try SafeUnlink.remove(url, under: .staging, layout: layout) } catch { failed = true }
            }
            do {
                try SafeUnlink.removeEmptyDirectory(
                    layout.stagingDirectory(slug: slug), under: .staging, layout: layout)
            } catch {
                failed = true
            }
        }
        if failed {
            // CLEANUP のまま。次の評価でやり直す
            deps.log.warning(
                .diskSpaceLow, [(.sessionKey, .string(key)), (.reason, .string(DeletionReason.stagingUnlinkFailed))])
            return
        }
        do {
            try deps.store.recordSessionTransition(sessionKey: key, from: .cleanup, to: .completed)
        } catch is TransitionConflict {
            deps.logStatusChanged(sessionKey: key)
        }
    }

    /// 削除段で評価する Session か: deleteEvaluated に在るか、COMPLETED で ID の無い RAW_SAVED の Part を持つ（F-80。
    /// allowReopen が偽のとき、完了した Session に後から RAW_SAVED になった Part は再オープンされず、ここで拾わないと
    /// Raw の直後（§5.5）の 1 回の後は誰も評価しない。Session は COMPLETED のまま遷移させない）
    func isEvaluated(_ row: SessionRow) throws -> Bool {
        if SessionStates.deleteEvaluated.contains(row.status) { return true }
        guard row.status == .completed else { return false }
        return try deps.store.recordings(inSession: row.sessionKey).contains(where: Self.isLateRawSaved)
    }

    /// COMPLETED の Session で後から RAW_SAVED になった、要求を書いていない Part（F-80。ID を持つものは回収 §8.9.6 が先に片付ける）
    static func isLateRawSaved(_ part: RecordingRow) -> Bool {
        part.status == .rawSaved && part.deleteRequestID == nil
    }

    /// evaluateDeletions の対象（deleteEvaluated に在るか、COMPLETED で ID の無い RAW_SAVED の Part を持ち（F-80）、
    /// backoff を過ぎた Session。updated_at, session_key 順）
    func dueSessionKeys() -> [String] {
        let rows: [SessionRow]
        let late: Set<[Unicode.Scalar]>
        do {
            rows = try deps.store.sessionsForDeleteEvaluation()
            // RAW_SAVED は少ない（全 Session の Part を読まない）。照合はスカラー列
            late = Set(
                try deps.store.recordings(status: .rawSaved).filter(Self.isLateRawSaved).compactMap {
                    $0.sessionKey.map { Array($0.unicodeScalars) }
                })
        } catch {
            deps.warn(error)
            return []
        }
        let now = deps.clock.now()
        let backoff = deps.config.cleanup.deleteEvaluationBackoffSeconds
        return
            rows
            .filter {
                (SessionStates.deleteEvaluated.contains($0.status)
                    || ($0.status == .completed && late.contains(Array($0.sessionKey.unicodeScalars))))
                    && Self.isDue(
                        updatedAt: $0.updatedAt, attempts: $0.deleteAttempts, now: now, backoff: backoff,
                        zone: deps.zone)
            }
            .map(\.sessionKey)
    }

    /// now − updated_at >= delay(delete_attempts)。updated_at が読めなければ真（voicedock db.py:640-645 の datetime.min と同じ）
    static func isDue(updatedAt: String, attempts: Int, now: Instant, backoff: [Int], zone: ZonedTime) -> Bool {
        guard let updated = zone.parseISO(updatedAt) else { return true }
        return now - updated >= Int64(RetryDelay.deleteEvaluation(attempts: attempts, backoff: backoff)) * 1000
    }
}
