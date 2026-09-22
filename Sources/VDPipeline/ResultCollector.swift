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

    /// 回収を待つ Part の状態（PLAN §8.9.6）= awaitingDeletion ∪ {SKIPPED}
    static let collectableStatuses: Set<PartStatus> = PartStates.awaitingDeletion.union([.skipped])

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
                    if try pend(part, code: .sourceIdentityMismatch, reason: result.detail) {
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
                        try deps.store.updateRecording(
                            pk, [.sourceDeletedAt(deps.zone.iso(deps.clock.now())), .deleteRequestID(nil)])
                        try advanceToCompleted(part)
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

    /// SKIPPED 以外を COMPLETED まで進める（付録 A.2）。衝突は status_changed（source_deleted_at は既に書いた。結果は捨てる）
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
            // SKIPPED・RAW_SAVED・SOURCE_DELETE_PENDING は状態を動かさない（SM-20）
            guard try deps.store.updateRecordingIfStatus(pk, status: part.status, [.deleteRequestID(nil)]) else {
                deps.logStatusChanged(recordingKey: pk)
                return false
            }
        }
        deps.log.warning(.sourceDeletePending, [(.recordingKey, .string(pk)), (.reason, .string(reason))])
        deps.pended.insert(pk)
        return true
    }

    /// snapshot が新鮮な tick だけ呼ぶ（呼び手が確かめる）。戻り値は新しい reaperScanGeneration（起動しなければ引数のまま）
    func runReaperIfNeeded(reaperScanGeneration: UInt64) async -> UInt64 {
        // 確かめる順は 要求 → writable → readiness（安いものから。無駄に --version の子プロセスを起動しない）
        guard DeleteQueue.hasPendingRequests(layout: deps.layout) else { return reaperScanGeneration }
        guard let snapshot = await deps.ingest.latestSnapshot(),
            snapshot.devices.keys.contains(where: {
                DeviceWritability.observe(deviceID: $0, snapshot: snapshot) == .writable
            })
        else { return reaperScanGeneration }
        // 起動の直前はキャッシュを使わない（キャッシュの鍵に ctime が無い。§8.9.2・§8.9.6）
        guard await deps.locks.readiness(config: deps.config, useCache: false) == .configured else {
            return reaperScanGeneration
        }
        switch await deps.reaper.run() {
        case .notLaunched(let reason):
            deps.log.warning(.reaperFailed, [(.reason, .string(reason))])
            return reaperScanGeneration
        case .finished(let result):
            logRun(result)
        }
        let next: UInt64
        if let g = await deps.ingest.scanNow() {
            // 呼び出しの後に始まり完了した走査
            next = g
        } else {
            // 見送り → 次に完了する走査を待つ（DELETED はそれまで残る）
            next = ((await deps.ingest.latestSnapshot())?.generation ?? 0) + 1
        }
        await collectDeleteResults(reaperScanGeneration: next)
        return next
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
