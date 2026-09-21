// 削除結果（reaper が書き、アプリが読む。PLAN §4.4）。
import Foundation

public struct DeleteResult: Equatable, Sendable {
    /// Contract.resultSchema
    public let schema: Int
    /// "request_id"
    public let requestID: String
    /// "completed_at"
    public let completedAt: String
    /// "reaper_version"
    public let reaperVersion: String
    /// "device_id"
    public let deviceID: String
    /// "partkey"
    public let partkey: String
    public let status: DeleteResultStatus
    /// DELETED なら relpath、SOURCE_IDENTITY_MISMATCH なら理由語（どちらか一方。連結しない）
    public let detail: String

    public init(
        schema: Int = Contract.resultSchema, requestID: String, completedAt: String, reaperVersion: String,
        deviceID: String, partkey: String, status: DeleteResultStatus, detail: String
    ) {
        self.schema = schema
        self.requestID = requestID
        self.completedAt = completedAt
        self.reaperVersion = reaperVersion
        self.deviceID = deviceID
        self.partkey = partkey
        self.status = status
        self.detail = detail
    }
}

public enum DeleteResultStatus: String, Sendable, CaseIterable {
    case deleted = "DELETED"
    /// PT-06 の例外として許可されている唯一の場所
    case sourceIdentityMismatch = "SOURCE_IDENTITY_MISMATCH"
}
