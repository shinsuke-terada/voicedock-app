// events.entity_type の値と、表・主キー列の対応（PLAN §5.2）。
public enum EntityType: String, Sendable, CaseIterable {
    case recording
    case session

    /// SQL へ埋め込んでよい唯一の可変部分（2 値の enum から来る固定文字列）
    var table: String { self == .recording ? "recordings" : "sessions" }
    var keyColumn: String { self == .recording ? "partkey" : "session_key" }
}
