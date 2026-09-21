// エラーを error_message 用の 1 行にする（PLAN §8.3「<型名>: <説明>」）。
enum ErrorText {
    /// `"<型名>: <説明>"`。型名は `String(describing: type(of: error))`、説明は `String(describing: error)`。
    static func describe(_ error: any Error) -> String {
        "\(String(describing: type(of: error))): \(String(describing: error))"
    }
}
