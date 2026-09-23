// reaper の起動と結果の回収（PLAN §8.9.6。同じ秒問題を構造的に消す）。
// 回収は結果ファイル全件が対象（snapshot で絞らない）。根拠 A と B で同じ規則を使い、分かれるのは状態の扱いだけ。
import VDContract
import VDCore
import VDDevice
import VDProcess
import VDStore

/// reaper の起動と結果の回収。時刻を比べない（reaper の終了を待ってから始まった走査の generation で判定する。voicedock #156 / #182）。
struct ResultCollector {
    let deps: DeletionDependencies

    /// 回収を待つ Part の状態（PLAN §8.9.6）= awaitingDeletion ∪ {SKIPPED, COMPLETED}。
    /// COMPLETED は「過去分」の ①② の後・③ の前に止まり、ID と要求を持ったまま残った Part（F-74）
    static let collectableStatuses: Set<PartStatus> = PartStates.awaitingDeletion.union([.skipped, .completed])

    /// 毎 tick（新鮮でなくても）と reaper の後。
    func collectDeleteResults(reaperScanGeneration: UInt64) async {
        let snapshot = await deps.ingest.latestSnapshot()
        let layout = deps.layout
        for q in DeleteQueue.results(layout: layout) {
            do {
                // 読めない → 残す
                guard let result = q.result else { continue }
                // 無い → 残す（別の用途かもしれない）
                guard let part = try deps.store.recording(result.partkey) else { continue }
                let pk = part.partkey
                // 待っていない → 捨てる
                if part.deleteRequestID == nil || !Self.collectableStatuses.contains(part.status) {
                    DeleteQueue.discard(q.url, layout: layout)
                    continue
                }
                // 古い試行（DEL-08 / ND-42）
                if !DeletionPolicy.sameKey(result.requestID, part.deleteRequestID) {
                    DeleteQueue.discard(q.url, layout: layout)
                    continue
                }
                switch result.status {
                case .sourceIdentityMismatch:
                    // 決着した Part を後追いで要求し、reaper がまた拒否した → pend せずに決着し直す（F-78）
                    let retried =
                        try part.status == .sourceDeleting
                        && Self.retriesASettledPart(deps.store.events(entity: .recording, key: pk))
                    if try retried
                        ? resettle(part, reason: result.detail)
                        : pend(part, code: .sourceIdentityMismatch, reason: result.detail)
                    {
                        DeleteQueue.discard(q.url, layout: layout)
                    }
                case .deleted:
                    // 残す（判定できる観測を待つ。ND-46）
                    guard let s = snapshot, s.generation >= reaperScanGeneration, let obs = s.devices[part.deviceID]
                    else { continue }
                    // source_path が nil なら「消えた」と判定しない（観測と照らせない。消さない側）
                    if part.sourcePath == nil
                        || obs.relpaths.contains(where: { DeletionPolicy.sameKey($0, part.sourcePath) })
                    {
                        if try pend(part, code: .sourceDeleteFailed, reason: DeletionReason.stillInInventory) {
                            DeleteQueue.discard(q.url, layout: layout)
                        }
                    } else {
                        // 遷移が先、ID を外すのは最後（F-74）。遷移が失敗したら ID と結果が残り、次の tick に同じ結果でやり直す
                        try advanceToCompleted(part)
                        try deps.store.updateRecording(
                            pk, [.sourceDeletedAt(deps.zone.iso(deps.clock.now())), .deleteRequestID(nil)])
                        deps.log.info(
                            .sourceDeleted, [(.recordingKey, .string(pk)), (.requestID, .string(result.requestID))])
                        DeleteQueue.discard(q.url, layout: layout)
                    }
                }
            } catch {
                deps.warn(error)
            }
        }
    }

    /// SKIPPED・COMPLETED 以外を COMPLETED まで進める（付録 A.2。COMPLETED は遷移させない。F-74）。
    /// 衝突は status_changed を出して戻る（呼び手は source_deleted_at を書き、結果を捨てる）。ほかの例外は投げる（ID と結果が残る）
    private func advanceToCompleted(_ part: RecordingRow) throws {
        let pk = part.partkey
        do {
            switch part.status {
            case .sourceDeleting:
                try deps.store.recordPartTransition(partkey: pk, from: .sourceDeleting, to: .completed)
            case .rawSaved, .sourceDeletePending:
                try deps.store.recordPartTransition(partkey: pk, from: part.status, to: .sourceDeleting)
                try deps.store.recordPartTransition(partkey: pk, from: .sourceDeleting, to: .completed)
            default:
                return
            }
        } catch is TransitionConflict {
            deps.logStatusChanged(recordingKey: pk)
        }
    }

    /// 失敗・期限切れの後始末。状態を動かす／ID を外す。衝突したら status_changed を出して偽
    func pend(_ part: RecordingRow, code: ErrorCode, reason: String) throws -> Bool {
        let pk = part.partkey
        if part.status == .sourceDeleting {
            do {
                try deps.store.recordPartTransition(
                    partkey: pk, from: .sourceDeleting, to: .sourceDeletePending, errorCode: code, detail: reason)
            } catch is TransitionConflict {
                deps.logStatusChanged(recordingKey: pk)
                return false
            }
            try deps.store.updateRecording(pk, [.deleteRequestID(nil)])
        } else {
            // SKIPPED・RAW_SAVED・SOURCE_DELETE_PENDING・COMPLETED は状態を動かさない（SM-20・F-74）
            guard try deps.store.updateRecordingIfStatus(pk, status: part.status, [.deleteRequestID(nil)]) else {
                deps.logStatusChanged(recordingKey: pk)
                return false
            }
        }
        deps.log.warning(.sourceDeletePending, [(.recordingKey, .string(pk)), (.reason, .string(reason))])
        deps.pended.insert(pk)
        return true
    }

    /// 決着した（最後の遷移が detail not_deletable の COMPLETED）Part を後追いで要求した試行か（F-78。PLAN §8.9.6）:
    /// events の最後が COMPLETED→SOURCE_DELETING（detail 無し。後追いの ③）で、その前が →COMPLETED（detail not_deletable）
    static func retriesASettledPart(_ events: [EventRow]) -> Bool {
        guard events.count >= 2 else { return false }
        let request = events[events.count - 1]
        let settled = events[events.count - 2]
        return request.fromStatus == PartStatus.completed.rawValue
            && request.toStatus == PartStatus.sourceDeleting.rawValue && request.detail == nil
            && settled.toStatus == PartStatus.completed.rawValue && settled.detail == DeletionReason.notDeletable
    }

    /// 決着した Part の後追いの要求を reaper がまた拒否した（F-78。PLAN §8.9.6）。pend すると COMPLETED の Session に
    /// ID の無い SOURCE_DELETE_PENDING が残り、自動では評価されず「消せなかった録音」からも外れるので、既存の
    /// SOURCE_DELETING→COMPLETED（detail not_deletable、error_message = 理由語）で消さずに決着し直し、ID を外す（遷移が先）。
    /// source_delete_skipped recording_key=… reason=not_deletable detail=<理由語>。source_deleted_at は入れない。
    /// 衝突は status_changed を出して偽（結果を残す）
    func resettle(_ part: RecordingRow, reason: String) throws -> Bool {
        let pk = part.partkey
        do {
            try deps.store.recordPartTransition(
                partkey: pk, from: .sourceDeleting, to: .completed, errorMessage: reason,
                detail: DeletionReason.notDeletable)
        } catch is TransitionConflict {
            deps.logStatusChanged(recordingKey: pk)
            return false
        }
        try deps.store.updateRecording(pk, [.deleteRequestID(nil)])
        deps.log.info(
            .sourceDeleteSkipped,
            [
                (.recordingKey, .string(pk)), (.reason, .string(DeletionReason.notDeletable)),
                (.detail, .string(reason)),
            ])
        return true
    }

    /// snapshot が新鮮な tick だけ呼ぶ（呼び手が確かめる）。戻り値は新しい reaperScanGeneration（起動しなければ引数のまま）
    func runReaperIfNeeded(reaperScanGeneration: UInt64) async -> UInt64 {
        // 確かめる順は 要求 → writable → readiness（安いものから。無駄に --version の子プロセスを起動しない）。
        // 見るのは要求の宛先のデバイス（F-79。別のデバイスが書き込み可能なだけでは、reaper はその要求を残して終わる）
        let requested = DeleteQueue.requestedDeviceIDs(layout: deps.layout)
        guard !requested.isEmpty, let snapshot = await deps.ingest.latestSnapshot(),
            Self.anyWritable(requested, in: snapshot)
        else { return reaperScanGeneration }
        // 起動の直前はキャッシュを使わない（キャッシュの鍵に ctime が無い。§8.9.2・§8.9.6）
        guard await deps.locks.readiness(config: deps.config, useCache: false) == .configured else {
            return reaperScanGeneration
        }
        let before = DeleteQueue.listing(layout: deps.layout)
        switch await deps.reaper.run() {
        case .notLaunched(let reason):
            deps.log.warning(.reaperFailed, [(.reason, .string(reason))])
            return reaperScanGeneration
        case .finished(let result):
            logRun(result)
        }
        let next: UInt64
        if DeleteQueue.listing(layout: deps.layout) == before {
            // 何も処理されなかった（要求を残した・busy）→ 走査しない。走査の公開は Worker をすぐに起こし、
            // 起動 → 走査 → tick が期限まで間を置かずに続く（F-79）。DELETED は次に完了する走査まで残す（見送りと同じ）
            next = ((await deps.ingest.latestSnapshot())?.generation ?? 0) + 1
        } else if let g = await deps.ingest.scanNow() {
            // 呼び出しの後に始まり完了した走査
            next = g
        } else {
            // 見送り → 次に完了する走査を待つ（DELETED はそれまで残る）
            next = ((await deps.ingest.latestSnapshot())?.generation ?? 0) + 1
        }
        await collectDeleteResults(reaperScanGeneration: next)
        return next
    }

    /// 要求の device_id のどれかが snapshot で `.writable` か（F-79。PLAN §8.9.6）。device_id はスカラー単位で照合する
    static func anyWritable(_ deviceIDs: [String], in snapshot: DeviceSnapshot) -> Bool {
        snapshot.devices.keys.contains { key in
            deviceIDs.contains { DeletionPolicy.sameKey($0, key) }
                && DeviceWritability.observe(deviceID: key, snapshot: snapshot) == .writable
        }
    }

    /// reaper_run exit=<n> は起動したら常に出す（PLAN 付録 A.4）。0 以外は reaper_failed（4 は busy）
    func logRun(_ result: ProcessResult) {
        let exit: LogValue
        let failure: String?
        switch result.termination {
        case .exited(let code):
            exit = .int(Int64(code))
            failure = code == 0 ? nil : (code == Self.busyExitCode ? DeletionReason.busy : DeletionReason.exit(code))
        case .signaled(let signal):
            exit = .int(Int64(128 + signal))
            failure = DeletionReason.exit(128 + signal)
        case .spawnFailed:
            exit = .int(Int64(Self.spawnFailedExitCode))
            failure = DeletionReason.exit(Self.spawnFailedExitCode)
        case .timedOut:
            exit = .null
            failure = DeletionReason.timeout
        }
        deps.log.info(.reaperRun, [(.exit, exit)])
        if let failure {
            deps.log.warning(.reaperFailed, [(.reason, .string(failure))])
        }
    }

    /// reaper が reaper.lock を取れなかったときの終了コード（PLAN §8.9.4 reaper_busy）
    static let busyExitCode: Int32 = 4
    /// 起動に失敗したときに reaper_run へ書く終了コード（PLAN 付録 A.4）
    static let spawnFailedExitCode: Int32 = 127
}
