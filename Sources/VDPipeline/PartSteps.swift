// Part の工程（PLAN §5.5。voicedock pipeline.py:266-282, 1537-1605）。skip / fail / 再オープンの呼び出し。
import VDContract
import VDCore
import VDStore

/// Part の 1 件の処理の結果。
enum PartStepResult: Equatable, Sendable { case stopped, readyForSession }

/// Part の工程（PLAN §5.5）。すべての ensure* は冪等。偽を返したら以降の工程を実行しない。
struct PartSteps {
    let ctx: TickContext
    let sessions: SessionSteps

    init(ctx: TickContext) {
        self.ctx = ctx
        self.sessions = SessionSteps(ctx: ctx)
    }

    var store: Store { ctx.deps.store }
    var layout: HomeLayout { ctx.deps.layout }
    var clock: any AppClock { ctx.deps.clock }
    var log: AppLog { ctx.deps.log }
    var cfg: AppConfig { ctx.config }

    /// ensureNormalized → ensureTranscribed → ensureRawNote → Raw の直後の削除評価（PLAN §5.5）。
    /// 削除評価は RAW_SAVED 以降の Part でも呼ぶ（voicedock pipeline.py:281 と同じ）。
    func process(partkey: String) async -> PartStepResult {
        guard let r0 = (try? store.recording(partkey)) ?? nil else { return .stopped }
        guard await ensureNormalized(r0) else { return .stopped }
        guard let r1 = reload(partkey), await ensureTranscribed(r1) else { return .stopped }
        guard let r2 = reload(partkey), await ensureRawNote(r2) else { return .stopped }
        if let key = reload(partkey)?.sessionKey { _ = await requestDeletionsAfterRawNote(sessionKey: key) }
        return .readyForSession
    }

    func reload(_ pk: String) -> RecordingRow? { (try? store.recording(pk)) ?? nil }

    /// → SKIPPED（error_code・error_message）→ part_skipped → その Part の Session の再オープン。
    func skip(_ row: RecordingRow, from: PartStatus, code: ErrorCode, message: String) throws {
        try store.recordPartTransition(
            partkey: row.partkey, from: from, to: .skipped, errorCode: code, errorMessage: message)
        log.info(
            .partSkipped,
            [(.recordingKey, .string(row.partkey)), (.reason, .string(code.skipReasonWord ?? code.rawValue))])
        if let key = row.sessionKey { _ = sessions.reopenSession(key) }
    }

    /// → FAILED → <event>（ERROR）→ その Part の Session の再オープン。
    func fail(
        _ row: RecordingRow, from: PartStatus, code: ErrorCode, message: String, event: LogEvent,
        reason: String? = nil
    ) throws {
        try store.recordPartTransition(
            partkey: row.partkey, from: from, to: .failed, errorCode: code, errorMessage: message)
        var fields: [(LogKey, LogValue)] = [
            (.recordingKey, .string(row.partkey)), (.errorCode, .string(code.rawValue)),
        ]
        if let reason { fields.append((.reason, .string(reason))) }
        log.error(event, fields)
        if let key = row.sessionKey { _ = sessions.reopenSession(key) }
    }

    /// TransitionConflict は偽（何も書かずに次へ。PLAN §5.4）、ほかの例外は ctx.warnStore(e) を出して偽。
    func guarded(_ body: () async throws -> Bool) async -> Bool {
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
