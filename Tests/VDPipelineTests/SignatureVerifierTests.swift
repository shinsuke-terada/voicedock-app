// CodeSignatureVerifier（本物の Security.framework）と ReaperSignature の要件（PLAN §8.9.3。T-36 §6.6）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDPipeline

@Suite("CodeSignatureVerifier")
struct SignatureVerifierTests {
    static let ls = URL(fileURLWithPath: "/bin/ls", isDirectory: false)

    @Test("Apple の署名は anchor apple を満たす（検証が動いていることの対照）")
    func appleBinarySatisfiesAnchorApple() {
        #expect(CodeSignatureVerifier(requirement: "anchor apple").verify(url: Self.ls))
    }

    @Test("要件に合わなければ偽")
    func wrongRequirementFails() {
        let requirement = ReaperSignature.requirement(bundleID: "x", teamID: "ABCDE12345")
        #expect(CodeSignatureVerifier(requirement: requirement).verify(url: Self.ls) == false)
    }

    @Test("無いファイルは偽")
    func missingFileFails() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("none", isDirectory: false)
        #expect(CodeSignatureVerifier(requirement: "anchor apple").verify(url: url) == false)
    }

    @Test("署名の無いファイルは偽")
    func unsignedFileFails() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("s.sh", isDirectory: false)
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: url)
        #expect(CodeSignatureVerifier(requirement: "anchor apple").verify(url: url) == false)
    }

    @Test("壊れた要件は偽（例外にしない）")
    func brokenRequirementFails() {
        #expect(CodeSignatureVerifier(requirement: "not a requirement (((").verify(url: Self.ls) == false)
    }

    @Test("要件の文字列（逐語）")
    func requirementIsVerbatim() {
        #expect(
            ReaperSignature.requirement(bundleID: "io.github.shinsuke-terada.VoiceDock", teamID: "ABCDE12345")
                == #"anchor apple generic and identifier "io.github.shinsuke-terada.VoiceDock.reaper" and certificate leaf[subject.OU] = "ABCDE12345""#
        )
    }

    @Test("本番の要件は AppIdentity から作る")
    func productionUsesAppIdentity() {
        #expect(
            ReaperSignature.production
                == ReaperSignature.requirement(bundleID: AppIdentity.bundleID, teamID: AppIdentity.teamID))
        #expect(ReaperSignature.production.contains(AppIdentity.reaperIdentifier))
    }

    @Test("偽物は呼ばれた URL を記録し setValid に従う（TEST-05）")
    func fakeRecordsCalls() {
        let fake = FakeSignatureVerifier()
        #expect(fake.verify(url: Self.ls))
        fake.setValid(false)
        #expect(fake.verify(url: Self.ls) == false)
        #expect(fake.verifiedURLs.count == 2)
    }
}
