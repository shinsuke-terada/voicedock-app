// 工程内リトライと削除評価の待ち秒の式（PLAN §5.4・§8.9.5）。
public enum RetryDelay {
    /// 工程内リトライの待ち秒（PLAN §5.4。voicedock pipeline.py:1750-1760）。
    /// retryCount < 1 か retryCount >= maxAttempts なら nil（終わり）。backoff[retryCount - 1] が無ければ nil。
    public static func inProcess(retryCount: Int, maxAttempts: Int, backoff: [Int]) -> Int? {
        guard retryCount >= 1, retryCount < maxAttempts else { return nil }
        let index = retryCount - 1
        guard index < backoff.count else { return nil }
        return backoff[index]
    }

    /// 削除評価の待ち秒（PLAN §8.9.5。voicedock pipeline.py:1855-1868）。attempts 0 と 1 はどちらも先頭の値。
    /// backoff が空なら 0（CV-52 で空は設定エラーだが、ここでは落ちない）。
    public static func deleteEvaluation(attempts: Int, backoff: [Int]) -> Int {
        guard !backoff.isEmpty else { return 0 }
        let index = min(max(attempts, 1), backoff.count) - 1
        return backoff[index]
    }
}
