// 削除要求（アプリが書き、reaper が読む。PLAN §4.4）。絶対パスを持たない。
import Foundation

public struct DeleteRequest: Equatable, Sendable {
    /// Contract.requestSchema
    public let schema: Int
    /// JSON "request_id"
    public let requestID: String
    /// JSON "created_at"（ZonedTime.iso の文字列。VDContract は書式を作らない）
    public let createdAt: String
    /// JSON "device_id"
    public let deviceID: String
    /// JSON "partkey"
    public let partkey: String
    /// JSON "session_key"
    public let sessionKey: String
    /// JSON "targets" の 1 要素配列
    public let target: DeleteTarget

    public init(
        schema: Int = Contract.requestSchema, requestID: String, createdAt: String, deviceID: String,
        partkey: String, sessionKey: String, target: DeleteTarget
    ) {
        self.schema = schema
        self.requestID = requestID
        self.createdAt = createdAt
        self.deviceID = deviceID
        self.partkey = partkey
        self.sessionKey = sessionKey
        self.target = target
    }
}

public struct DeleteTarget: Equatable, Sendable {
    public let relpath: String
    /// DB の source_size（デバイス上の原本の値。DEL-12）
    public let size: Int64
    /// DB の source_mtime（デバイス上の原本の値。DEL-12）
    public let mtime: Double

    public init(relpath: String, size: Int64, mtime: Double) {
        self.relpath = relpath
        self.size = size
        self.mtime = mtime
    }
}
