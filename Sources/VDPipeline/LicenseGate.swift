// 課金の差し込み口（PLAN §8.14）。v1 は常に許可。認証サーバと通信しない。

/// 課金の差し込み口（PLAN §8.14）。
public protocol LicenseGate: Sendable { func allowsProcessing() -> Bool }

/// v1 の実装（常に許可）。
public struct AlwaysAllowLicenseGate: LicenseGate {
    public init() {}
    public func allowsProcessing() -> Bool { true }
}
