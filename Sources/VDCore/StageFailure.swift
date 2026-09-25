// 工程の運用上の失敗（ErrorCode と文言の組。00-api-map §0）。
/// 工程の運用上の失敗（ErrorCode を持つ）。error_message に入る文言は `message`（200 文字への切り詰めは VDStore が行う）。
public struct StageFailure: Error, Equatable, Sendable {
    public let code: ErrorCode
    public let message: String
    public init(_ code: ErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}
