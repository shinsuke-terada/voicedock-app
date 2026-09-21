// 工程内リトライと削除評価の待ち秒の式（PLAN §5.4・§8.9.5。T-08）。
import Testing

@testable import VDCore

@Suite("RetryDelay")
struct RetryDelayTests {
    @Test("既定 3 回・[3,10,30] は 3 秒・10 秒で終わる")
    func inProcessDefault() {
        #expect(RetryDelay.inProcess(retryCount: 1, maxAttempts: 3, backoff: [3, 10, 30]) == 3)
        #expect(RetryDelay.inProcess(retryCount: 2, maxAttempts: 3, backoff: [3, 10, 30]) == 10)
        #expect(RetryDelay.inProcess(retryCount: 3, maxAttempts: 3, backoff: [3, 10, 30]) == nil)
        #expect(RetryDelay.inProcess(retryCount: 0, maxAttempts: 3, backoff: [3, 10, 30]) == nil)
    }

    @Test("backoff が足りなければ nil")
    func inProcessShortBackoff() {
        #expect(RetryDelay.inProcess(retryCount: 2, maxAttempts: 5, backoff: [3]) == nil)
    }

    @Test("削除評価の attempts 0 と 1 は先頭の値（voicedock test_retry.py:517）")
    func deleteEvaluationZeroAndOneAreFirst() {
        let backoff = [60, 300, 900, 3600]
        #expect(RetryDelay.deleteEvaluation(attempts: 0, backoff: backoff) == 60)
        #expect(RetryDelay.deleteEvaluation(attempts: 1, backoff: backoff) == 60)
        #expect(RetryDelay.deleteEvaluation(attempts: 2, backoff: backoff) == 300)
        #expect(RetryDelay.deleteEvaluation(attempts: 4, backoff: backoff) == 3600)
        #expect(RetryDelay.deleteEvaluation(attempts: 9, backoff: backoff) == 3600)
    }

    @Test("削除評価の backoff が空なら 0")
    func deleteEvaluationEmpty() {
        #expect(RetryDelay.deleteEvaluation(attempts: 3, backoff: []) == 0)
    }
}
