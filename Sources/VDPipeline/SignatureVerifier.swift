// reaper の署名検証（PLAN §8.9.3 の 4）。テストは FakeSignatureVerifier を注入する（本番のコードに「テストなら」分岐を作らない。CR-25）。
import Foundation
import Security
import VDCore

public protocol SignatureVerifier: Sendable {
    /// url のコードの署名が要件を満たすか。検証できない（無い・署名が無い・要件が壊れている）ものは偽。
    func verify(url: URL) -> Bool
}

public struct CodeSignatureVerifier: SignatureVerifier {
    public let requirement: String
    public init(requirement: String) { self.requirement = requirement }
    public func verify(url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else {
            return false
        }
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &compiled) == errSecSuccess,
            let compiled
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), compiled)
            == errSecSuccess
    }
}

public enum ReaperSignature {
    /// `anchor apple generic and identifier "<bundleID>.reaper" and certificate leaf[subject.OU] = "<teamID>"`（PLAN §8.9.3。定数はこの 1 つ）
    public static func requirement(bundleID: String, teamID: String) -> String {
        "anchor apple generic and identifier \"" + bundleID + ".reaper\" and certificate leaf[subject.OU] = \""
            + teamID + "\""
    }
    /// 本番の要件（AppIdentity から）。Bootstrap が CodeSignatureVerifier に渡す
    public static var production: String { requirement(bundleID: AppIdentity.bundleID, teamID: AppIdentity.teamID) }
}
