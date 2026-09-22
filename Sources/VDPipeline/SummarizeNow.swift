// 今すぐ要約（パネルの手動の要約。PLAN §5.4・F-66）。OPEN の Session を閉じ、要約は同じ tick の processReadySessions が進める。
import VDCore
import VDStore

/// 今すぐ要約を行わなかった理由（日本語の 1 行。PLAN §5.4・F-66）。
public struct SummarizeNowFailure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// 今すぐ要約（PLAN §5.4・F-66）。LLM のガード（§8.5）を通るときだけ、OPEN の Session を日付を問わず全部
/// `OPEN→READY`（detail `summarize_now`）にする（取り残しを無くすため）。
struct SummarizeNow {
    /// events の detail（PLAN §5.6・付録 A.2 の注記）。
    static let detail = "summarize_now"

    let ctx: TickContext

    /// 閉じた Session の数（対象が無ければ 0）。LLM のガードに当たれば何も閉じずに失敗（理由の語は §5.4 のガードと同じ）。
    func run() -> Result<Int, SummarizeNowFailure> {
        if case .blocked(let reasons) = LLMGuard(ctx: ctx).inspect() {
            return .failure(SummarizeNowFailure(message: reasons.map(StatusTexts.pauseWord).joined(separator: "、")))
        }
        do {
            return .success(try closeOpenSessions())
        } catch {
            ctx.warnStore(error)
            return .failure(SummarizeNowFailure(message: ErrorText.describe(error)))
        }
    }

    /// OPEN を session_key 順に（日付を問わず）READY にする。TransitionConflict は数えずに次へ。
    func closeOpenSessions() throws -> Int {
        let store = ctx.deps.store
        var closed = 0
        for s in try store.sessions(status: .open) {
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
