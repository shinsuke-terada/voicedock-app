// 診断が触る口（すべて読むだけ）。Worker とは別に組み立てる（書ける Store を渡さない。PT-17）。
import Foundation
import Security
import VDContract
import VDCore
import VDDevice
import VDProcess

/// 診断が触る口（すべて読むだけ。PLAN §8.11・PT-17）。
public struct DiagnosticsDependencies: Sendable {
    public let layout: HomeLayout
    public let paths: AppPaths
    public let catalog: ModelCatalog
    public let config: ConfigStore
    public let ingest: any IngestPort
    /// Phase 7 は DisabledLockObserver、T-36 が LockEvaluator に差し替える（T-32 §4.11）
    public let locks: any LockObserving
    public let runner: any ProcessRunning
    public let verificationCache: ModelVerificationCache
    public let signature: any AppSignatureReading
    public let bundleURL: URL
    public let physicalMemoryBytes: UInt64
    public let clock: any AppClock
    public let log: AppLog

    public init(
        layout: HomeLayout, paths: AppPaths, catalog: ModelCatalog, config: ConfigStore, ingest: any IngestPort,
        locks: any LockObserving, runner: any ProcessRunning, verificationCache: ModelVerificationCache,
        signature: any AppSignatureReading, bundleURL: URL, physicalMemoryBytes: UInt64, clock: any AppClock,
        log: AppLog
    ) {
        self.layout = layout
        self.paths = paths
        self.catalog = catalog
        self.config = config
        self.ingest = ingest
        self.locks = locks
        self.runner = runner
        self.verificationCache = verificationCache
        self.signature = signature
        self.bundleURL = bundleURL
        self.physicalMemoryBytes = physicalMemoryBytes
        self.clock = clock
        self.log = log
    }
}

/// アプリ自身の署名（DR-17）。
public struct AppSignatureInfo: Equatable, Sendable {
    public let valid: Bool
    /// ad-hoc 署名では nil
    public let teamID: String?
    /// 検査自体が失敗した理由
    public let message: String?

    public init(valid: Bool, teamID: String?, message: String?) {
        self.valid = valid
        self.teamID = teamID
        self.message = message
    }
}

/// アプリ自身の署名を読む口（DR-17。テストは偽物に差し替える）。
public protocol AppSignatureReading: Sendable {
    func read(bundle: URL) -> AppSignatureInfo
}

/// 本番の実装（Security.framework）。
public struct SecAppSignatureReader: AppSignatureReading {
    public init() {}

    public func read(bundle: URL) -> AppSignatureInfo {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else {
            return AppSignatureInfo(valid: false, teamID: nil, message: DiagnosticTexts.signatureUnreadable)
        }
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return AppSignatureInfo(valid: false, teamID: nil, message: nil)
        }
        var info: CFDictionary?
        _ = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        let teamID = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        return AppSignatureInfo(valid: true, teamID: teamID, message: nil)
    }
}
