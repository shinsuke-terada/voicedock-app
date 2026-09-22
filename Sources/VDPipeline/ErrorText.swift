// 例外を error_message とログ用の 1 行にする（PLAN §8.3「<型名>: <説明>」）。Duration を秒の Double にする。

/// 例外を error_message とログ用の 1 行にする（PLAN §8.3「<型名>: <説明>」）。
enum ErrorText {
    static func describe(_ error: any Error) -> String { "\(type(of: error)): \(error)" }
}

/// Duration を秒の Double にする。
enum DurationSeconds {
    /// Duration を秒の Double に（`Double(c.seconds) + Double(c.attoseconds) / 1e18`）。
    static func of(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
