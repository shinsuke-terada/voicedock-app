// AppIdentity と identity.env の一致（PLAN §3.1。T-36 §6.8）。
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("AppIdentity")
struct AppIdentityTests {
    /// identity.env を行ごとに KEY=VALUE で読む（# で始まる行と空行は飛ばす）
    static func identityEnv() throws -> [String: String] {
        let text = try String(contentsOf: PackageRoot.file("identity.env"), encoding: .utf8)
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            guard let equal = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equal])] = String(line[line.index(after: equal)...])
        }
        return values
    }

    @Test("AppIdentity は identity.env と同じ")
    func matchesIdentityEnv() throws {
        let env = try Self.identityEnv()
        #expect(env["BUNDLE_ID"] == AppIdentity.bundleID)
        #expect(env["TEAM_ID"] == AppIdentity.teamID)
        let team = try #require(env["TEAM_ID"])
        // ^[A-Z0-9]{10}$（プレースホルダのままなら落ちる）
        #expect(team.unicodeScalars.count == 10)
        #expect(team.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) })
    }

    @Test("reaper の識別子は <BUNDLE_ID>.reaper")
    func reaperIdentifierAppendsSuffix() {
        #expect(AppIdentity.reaperIdentifier == AppIdentity.bundleID + ".reaper")
    }
}
