// 工程内リトライ（PLAN §5.4。voicedock worker.py:240-262 / pipeline.py:1750-1796）。
import VDCore
import VDStore

/// 工程内リトライ。既定（3 回・[3, 10, 30]）で「失敗 → 3 秒 → 失敗 → 10 秒 → 失敗 → 終了」。戻すときは retry_count を据え置く。
struct InProcessRetry {
    let ctx: TickContext

    /// step を 1 回実行 → 行が FAILED で工程内リトライの対象なら backoff を待って戻し、もう一度。
    func run(entity: EntityType, key: String, _ step: () async -> Void) async {
        while true {
            await step()
            guard let d = delay(entity: entity, key: key) else { return }
            if ctx.stop.isSet { return }
            do { try await ctx.deps.sleeper.sleep(seconds: d) } catch { return }
            if ctx.stop.isSet { return }
            guard
                (try? Requeue(ctx: ctx).resumeFailed(entity: entity, key: key, resetRetry: false, detail: "retry"))
                    == true
            else { return }
        }
    }

    /// 待つ秒。対象でなければ nil（DB の例外も nil）。
    func delay(entity: EntityType, key: String) -> Int? {
        let store = ctx.deps.store
        let retryCount: Int
        switch entity {
        case .recording:
            guard let row = (try? store.recording(key)) ?? nil, row.status == .failed, let code = row.errorCode,
                code.retryPolicy == .attempts, let from = (try? store.failedFromPart(key)) ?? nil,
                PartStates.retryableFromFailed.contains(from)
            else { return nil }
            retryCount = row.retryCount
        case .session:
            guard let row = (try? store.session(key)) ?? nil, row.status == .failed, let code = row.errorCode,
                code.retryPolicy == .attempts, let from = (try? store.failedFromSession(key)) ?? nil,
                SessionStates.retryableFromFailed.contains(from)
            else { return nil }
            retryCount = row.retryCount
        }
        return RetryDelay.inProcess(
            retryCount: retryCount, maxAttempts: ctx.config.retry.maxAttempts, backoff: ctx.config.retry.backoffSeconds)
    }
}
