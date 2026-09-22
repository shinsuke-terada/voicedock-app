// 今すぐ要約（パネルの手動の要約。PLAN §5.4・F-66）。今日の OPEN の Session を閉じ、要約は同じ tick の processReadySessions が進める。
import VDCore
import VDStore

/// 今すぐ要約を行わなかった理由（日本語の 1 行。PLAN §5.4・F-66）。
public struct SummarizeNowFailure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// 今すぐ要約（PLAN §5.4・F-66）。LLM のガード（§8.5）を通るときだけ、今日の OPEN の Session を `OPEN→READY`（detail `summarize_now`）にする。
struct SummarizeNow {
    /// events の detail（PLAN §5.6・付録 A.2 の注記）。
    static let detail = "summarize_now"

    let ctx: TickContext

    /// 閉じた Session の数（対象が無ければ 0）。LLM のガードに当たれば何も閉じずに失敗（理由の語は §5.4 のガードと同じ）。
    func run() -> Result<Int, SummarizeNowFailure> {
        let r = LLMGuard(ctx: ctx).inspect()
        if r.target == nil {
            // 理由が空で target も無いのは到達しない（LLMGuard の 5.）。そのときも「モデルが無い」で断る
            let reasons = r.reasons.isEmpty ? [PauseReason.llmModelMissing] : r.reasons
            return .failure(SummarizeNowFailure(message: reasons.map(StatusTexts.pauseWord).joined(separator: "、")))
        }
        do {
            return .success(try closeTodaySessions())
        } catch {
            ctx.warnStore(error)
            return .failure(SummarizeNowFailure(message: ErrorText.describe(error)))
        }
    }

    /// 今日（設定のタイムゾーン）の OPEN を session_key 順に READY にする。TransitionConflict は数えずに次へ。
    /// 日付が過去の OPEN は同じ段の closeIdleSessions が先に閉じている（stale_day）。
    func closeTodaySessions() throws -> Int {
        let store = ctx.deps.store
        let today = ctx.zone.today(ctx.deps.clock.now()).dashed
        var closed = 0
        for s in try store.sessions(status: .open) where s.dayDate == today {
            do {
                try store.recordSessionTransition(
                    sessionKey: s.sessionKey, from: .open, to: .ready, detail: Self.detail)
                closed += 1
            } catch is TransitionConflict {
                continue
            }
        }
        return closed
    }
}
