// Session の工程（PLAN §5.6・§8.5。voicedock session.py / pipeline.py:551-666, 1103-1227）。
import Foundation
import VDContract
import VDCore
import VDLLM
import VDStore

/// Session の 1 件の処理の結果。
enum SessionStepResult: Equatable, Sendable { case stopped, empty, analyzed, saved }

/// Session の工程（PLAN §5.6）。すべての ensure* は冪等。偽を返したら以降の工程を実行しない。
struct SessionSteps {
    /// 生成は `SessionSteps(ctx:)`（合成された init）。
    let ctx: TickContext

    /// 無通信で閉じたときの events の detail（PLAN §5.6）。
    static let idleDetail = "idle"

    var store: Store { ctx.deps.store }
    var cfg: AppConfig { ctx.config }
    var zone: ZonedTime { ctx.zone }
    var log: AppLog { ctx.deps.log }
    var layout: HomeLayout { ctx.deps.layout }

    /// session_key が NULL の Part を Session に入れる（PLAN §5.6。voicedock session.py:136-270）。
    /// 閉じた Session（OPEN 以外）への追加は events を書かず、再オープンもしない（SM-11 / SM-12）。
    func groupNewParts() throws {
        for part in try store.ungroupedRecordings() {
            // 自分で書いた ISO なので起きない。起きたら未分組のまま
            guard let started = zone.parseISO(part.startedAt) else { continue }
            // 設定のタイムゾーンへ変換してから日付（TIME-02）
            let day = zone.localDate(started)
            // KeyError（device_id が不正）は分組しない
            guard let key = try? targetKey(part, day) else { continue }
            let status: SessionStatus
            if let s = try store.session(key) {
                status = s.status
            } else {
                try store.insertSession(NewSession(sessionKey: key, dayDate: day.dashed, deviceID: part.deviceID))
                status = .open
            }
            try store.updateRecording(part.partkey, [.sessionKey(key)])
            try store.refreshSessionAggregates(key)
            if status == .open {
                // 新規作成の直後も書く（SM-02）
                try store.recordSessionTransition(sessionKey: key, from: .open, to: .open, detail: part.partkey)
            }
        }
    }

    /// 入れる鍵。1 本目は接尾辞なし。空きのある最も小さい n（#2, #3, …）か、まだ無い鍵。
    func targetKey(_ part: RecordingRow, _ day: LocalDate) throws -> String {
        var key = try SessionKey.make(deviceID: part.deviceID, dayStamp: day.stamp)
        while true {
            guard let s = try store.session(key) else { return key }
            if hasRoom(s, part) { return key }
            key = try SessionKey.nextOverflow(key)
        }
    }

    /// Part の数と録音の長さの上限（長さ不明は 0 として数える）。
    func hasRoom(_ s: SessionRow, _ part: RecordingRow) -> Bool {
        s.partCount < cfg.session.maxParts
            && (s.recordedSeconds ?? 0) + (part.durationSeconds ?? 0) <= Double(cfg.session.maxDurationSeconds)
    }

    /// idle が経った OPEN を READY にする（voicedock session.py:276-313 の idle の枝。日付が過去の OPEN も同じ規則）。
    /// F-66: 日付が変わっただけでは閉じない（voicedock の stale_day の枝は廃止）。閉じる契機は idle と今すぐ要約だけ。
    func closeIdleSessions() throws {
        let now = ctx.deps.clock.now()
        let idleBefore = now.adding(seconds: -cfg.session.idleCloseSeconds)
        for s in try store.sessions(status: .open) {
            // 読めない updated_at は「古い」側。ちょうど idleCloseSeconds 経ったものは閉じる
            guard zone.parseISO(s.updatedAt).map({ $0 <= idleBefore }) ?? true else { continue }
            do {
                try store.recordSessionTransition(
                    sessionKey: s.sessionKey, from: .open, to: .ready, detail: Self.idleDetail)
            } catch is TransitionConflict {
                continue
            }
        }
    }

    /// 再オープン。行えたら true。TransitionConflict は false（PLAN §5.6。voicedock pipeline.py:551-590 ＋ ★3 辺）。
    /// 削除待ちの Part の状態は動かさない（結果は §8.9.6 の全件回収が拾う）。
    func reopenSession(_ sessionKey: String) -> Bool {
        guard cfg.session.allowReopen else { return false }
        return guarded {
            guard let s = try store.session(sessionKey), SessionStates.reopenable.contains(s.status) else {
                return false
            }
            try store.recordSessionTransition(sessionKey: sessionKey, from: s.status, to: .merging, detail: "reopen")
            try store.updateSession(sessionKey, [.regeneratedCount(s.regeneratedCount + 1)])
            log.info(
                .sessionReopened,
                [(.sessionKey, .string(sessionKey)), (.regeneratedCount, .of(s.regeneratedCount + 1))])
            return true
        }
    }

    /// 統合 → 解析 → Daily（T-29）→ 削除段（T-38）（voicedock pipeline.py:637-666）。
    func process(sessionKey key: String) async -> SessionStepResult {
        guard let row = (try? store.session(key)) ?? nil else { return .stopped }
        if SessionStates.savedOrBeyond.contains(row.status) {
            await deleteSourcesIfSafe(key)
            return .saved
        }
        ctx.activity.set(.merging(sessionKey: key))
        let t: SessionTranscript?
        do {
            t = try buildSessionTranscript(key)
        } catch {
            ctx.warnStore(error)
            return .stopped
        }
        guard ensureMerged(row, t) else {
            return ((try? store.session(key)) ?? nil)?.status == .completed ? .empty : .stopped
        }
        // MERGED 以降なのに有効な segment が無い（transcript が後から読めなくなった）。進めず、黙って止まらずに失敗にする（F-74）
        guard let t else {
            _ = failUnreadableAfterMerge(key)
            return .stopped
        }
        guard await ensureAnalysis(key, t) else { return .stopped }
        // T-29 まで常に偽
        guard await ensureDailyNote(key, t) else { return .analyzed }
        // SAVED の直後に backoff を見ずに 1 回（T-38）
        await deleteSourcesIfSafe(key)
        return .saved
    }

    /// → FAILED → <event>（ERROR）。Session の失敗では再オープンしない。
    func failSession(
        _ key: String, from: SessionStatus, code: ErrorCode, message: String, event: LogEvent,
        reason: String? = nil
    ) throws {
        try store.recordSessionTransition(
            sessionKey: key, from: from, to: .failed, errorCode: code, errorMessage: message)
        var fields: [(LogKey, LogValue)] = [(.sessionKey, .string(key)), (.errorCode, .string(code.rawValue))]
        if let reason { fields.append((.reason, .string(reason))) }
        // 付録 A.4: session_merge_failed は error_code まで
        if event != .sessionMergeFailed && !message.isEmpty { fields.append((.detail, .string(message))) }
        log.error(event, fields)
    }

    /// TransitionConflict は偽（何も書かずに次へ。PLAN §5.4）、ほかの例外は ctx.warnStore(e) を出して偽。
    func guarded(_ body: () throws -> Bool) -> Bool {
        do {
            return try body()
        } catch is TransitionConflict {
            return false
        } catch {
            ctx.warnStore(error)
            return false
        }
    }

    /// guarded の async 版（trailing closure で曖昧にならないよう名前を分ける）。
    func guardedAsync(_ body: () async throws -> Bool) async -> Bool {
        do {
            return try await body()
        } catch is TransitionConflict {
            return false
        } catch {
            ctx.warnStore(error)
            return false
        }
    }
}
