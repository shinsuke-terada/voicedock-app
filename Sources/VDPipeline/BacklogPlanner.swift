// 後追い（PLAN §8.9.9。voicedock backlog.py）。判定は DeletionPolicy.canDeleteSource をそのまま使う（式を 2 本にしない）。
// 2 つの操作をまとめない: 「過去分」は「消してよい」、「手動で消した分」は「もう無い」を言う（不在のファイルは同定できない）。
import VDContract
import VDCore
import VDDevice
import VDStore

public enum BacklogKind: String, Sendable, Equatable {
    /// 過去分を削除対象にする
    case backlog
    /// 手動で消した分を完了にする
    case resolveAbsent
}

public struct BacklogSkip: Equatable, Sendable {
    public let partkey: String
    /// DeletionReason.alreadyDeleted / notDeletable / deviceAbsent / stillPresent
    public let reason: String

    public init(partkey: String, reason: String) {
        self.partkey = partkey
        self.reason = reason
    }
}

public struct BacklogPlan: Equatable, Sendable {
    public let eligible: [String]
    public let skipped: [BacklogSkip]

    public init(eligible: [String], skipped: [BacklogSkip]) {
        self.eligible = eligible
        self.skipped = skipped
    }
}

public struct BacklogExecution: Equatable, Sendable {
    /// 実行の直前に立て直した計画
    public let plan: BacklogPlan
    public let done: Int

    public init(plan: BacklogPlan, done: Int) {
        self.plan = plan
        self.done = done
    }
}

public struct BacklogFailure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// パネルからの 1 件の仕事（Worker の直列ループで実行する）。reply は Worker の文脈で 1 回だけ呼ばれる。
public enum BacklogAction: Sendable {
    case preview(reply: @Sendable (Result<BacklogPlan, BacklogFailure>) -> Void)
    case execute(reply: @Sendable (Result<BacklogExecution, BacklogFailure>) -> Void)
}

/// 後追いの計画と実行。プレビューは何も書かない（DB・queue・ログ。`--dry-run` と同じ）。
struct BacklogPlanner {
    let deps: DeletionDependencies

    /// 過去分（voicedock backlog.py:48-73 ＋ 本計画の差分）
    func planBacklog() async throws -> BacklogPlan {
        // 新鮮でなければ nil（→ 式が偽 = not_deletable）
        let snapshot = await deps.freshSnapshot()
        let ctx = await deps.context(snapshot: snapshot)
        var eligible: [String] = []
        var skipped: [BacklogSkip] = []
        // session_key 順
        for session in try deps.store.sessions(status: .completed) {
            let parts = try deps.store.recordings(inSession: session.sessionKey)
            for part in parts where part.status == .completed || part.status == .sourceDeletePending {
                if part.sourceDeletedAt != nil {
                    skipped.append(BacklogSkip(partkey: part.partkey, reason: DeletionReason.alreadyDeleted))
                } else if part.deleteRequestID != nil {
                    // 結果待ち（復旧の PENDING は ID を持ったまま。二重に要求しない）
                    skipped.append(BacklogSkip(partkey: part.partkey, reason: DeletionReason.notDeletable))
                } else if DeletionPolicy.canDeleteSource(
                    DeletionCandidate(part: part, session: session, parts: parts, twin: nil), ctx)
                {
                    eligible.append(part.partkey)
                } else {
                    skipped.append(BacklogSkip(partkey: part.partkey, reason: DeletionReason.notDeletable))
                }
            }
        }
        return BacklogPlan(eligible: eligible, skipped: skipped)
    }

    /// 手動で消した分（voicedock backlog.py:74-91 ＋ 本計画の差分: 未接続を「無い」と判定しない）
    func planResolveAbsent() async throws -> BacklogPlan {
        let snapshot = await deps.freshSnapshot()
        var eligible: [String] = []
        var skipped: [BacklogSkip] = []
        // started_at, partkey 順
        for part in try deps.store.recordings(status: .sourceDeletePending) {
            // デバイスが無い・snapshot が古い
            guard let s = snapshot, let obs = s.devices[part.deviceID] else {
                skipped.append(BacklogSkip(partkey: part.partkey, reason: DeletionReason.deviceAbsent))
                continue
            }
            // 在る（source_path が無いものも「無い」と確かめられない）
            guard let rel = part.sourcePath, !obs.relpaths.contains(where: { DeletionPolicy.sameKey($0, rel) }) else {
                skipped.append(BacklogSkip(partkey: part.partkey, reason: DeletionReason.stillPresent))
                continue
            }
            eligible.append(part.partkey)
        }
        return BacklogPlan(eligible: eligible, skipped: skipped)
    }

    /// 計画の eligible を 1 件ずつ実行する。実行した数（voicedock backlog.py:135-187）。
    /// DEL-19: 1 件ごとに捕捉して残りを続ける（DeletionRequester と同じ形。途中まで書いた数を失わない）
    func executeBacklog(_ plan: BacklogPlan) async throws -> Int {
        let snapshot = await deps.freshSnapshot()
        let ctx = await deps.context(snapshot: snapshot)
        var done = 0
        for pk in plan.eligible {
            do {
                // 計画の後に状態が変わった（DEL-19）
                guard let part = try deps.store.recording(pk),
                    part.status == .completed || part.status == .sourceDeletePending,
                    part.deleteRequestID == nil, part.sourceDeletedAt == nil,
                    let key = part.sessionKey, let session = try deps.store.session(key)
                else {
                    deps.logStatusChanged(recordingKey: pk)
                    continue
                }
                let parts = try deps.store.recordings(inSession: key)
                // 式が偽になった（ログなし。voicedock と同じ）
                guard
                    DeletionPolicy.canDeleteSource(
                        DeletionCandidate(part: part, session: session, parts: parts, twin: nil), ctx)
                else { continue }
                // ①ID → ②要求ファイル
                guard let id = try RequestWriter(deps: deps).write(part: part, sessionKey: key) else { continue }
                // ③ COMPLETED か SOURCE_DELETE_PENDING から
                try deps.store.recordPartTransition(partkey: pk, from: part.status, to: .sourceDeleting)
                deps.log.info(
                    .deleteRequested,
                    [(.requestID, .string(id)), (.recordingKey, .string(pk)), (.sessionKey, .string(key))])
                done += 1
            } catch is TransitionConflict {
                deps.logStatusChanged(recordingKey: pk)
                continue
            } catch {
                deps.warn(error)
                continue
            }
        }
        return done
    }

    /// 手動で消した分を完了にする。実行した数（voicedock backlog.py:188-238）。
    /// source_deleted_at を入れない（VoiceDock が消したのではない。PLAN §8.9.9）。直通の辺を足さない（付録 A.2 の 2 遷移）。
    /// DEL-19: 1 件ごとに捕捉して残りを続ける
    func executeResolveAbsent(_ plan: BacklogPlan) async throws -> Int {
        let snapshot = await deps.freshSnapshot()
        var done = 0
        for pk in plan.eligible {
            do {
                // DEL-19
                guard let part = try deps.store.recording(pk), part.status == .sourceDeletePending else {
                    deps.logStatusChanged(recordingKey: pk)
                    continue
                }
                // 実行の時点で「無い」を確かめ直す（在れば完了にしない）
                guard let s = snapshot, let obs = s.devices[part.deviceID], let rel = part.sourcePath,
                    !obs.relpaths.contains(where: { DeletionPolicy.sameKey($0, rel) })
                else { continue }
                try deps.store.recordPartTransition(
                    partkey: pk, from: .sourceDeletePending, to: .sourceDeleting,
                    detail: DeletionReason.resolveAbsentDetail)
                try deps.store.recordPartTransition(
                    partkey: pk, from: .sourceDeleting, to: .completed, detail: DeletionReason.alreadyAbsent)
                // 対応する試行の無い要求・結果を残さない（#160）
                _ = DeleteQueue.withdrawRequests(partkey: pk, layout: deps.layout)
                _ = DeleteQueue.withdrawResults(partkey: pk, layout: deps.layout)
                try deps.store.updateRecording(pk, [.deleteRequestID(nil)])
                deps.log.info(
                    .sourceDeleteSkipped,
                    [(.recordingKey, .string(pk)), (.reason, .string(DeletionReason.alreadyAbsent))])
                done += 1
            } catch is TransitionConflict {
                deps.logStatusChanged(recordingKey: pk)
                continue
            } catch {
                deps.warn(error)
                continue
            }
        }
        return done
    }

    /// 仕事を実行して reply を 1 回呼ぶ。実行は計画を立て直してから（プレビューの後に状態が変わりうる）
    func handle(_ action: BacklogAction, kind: BacklogKind) async {
        switch action {
        case .preview(let reply):
            do {
                reply(.success(kind == .backlog ? try await planBacklog() : try await planResolveAbsent()))
            } catch {
                reply(.failure(BacklogFailure(message: ErrorText.describe(error))))
            }
        case .execute(let reply):
            do {
                let plan = kind == .backlog ? try await planBacklog() : try await planResolveAbsent()
                let done =
                    plan.eligible.isEmpty
                    ? 0 : (kind == .backlog ? try await executeBacklog(plan) : try await executeResolveAbsent(plan))
                reply(.success(BacklogExecution(plan: plan, done: done)))
            } catch {
                reply(.failure(BacklogFailure(message: ErrorText.describe(error))))
            }
        }
    }
}
