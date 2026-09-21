// AppVersion の検査（T-06 §5.1）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("AppVersion")
struct VersionTests {
    @Test("VERSION ファイルと AppVersion.string が一致する")
    func stringMatchesVersionFile() throws {
        let text = try String(contentsOf: PackageRoot.url.appendingPathComponent("VERSION"), encoding: .utf8)
        #expect(AppVersion.string == text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("X.Y.Z を数値の組にする")
    func componentsParsesThreeNumbers() throws {
        let parsed = try #require(AppVersion.components("1.10.0"))
        #expect(parsed.major == 1)
        #expect(parsed.minor == 10)
        #expect(parsed.patch == 0)
    }

    @Test("形式外は nil", arguments: ["", "1.0", "1.0.0.0", "1..0", "v1.0.0", "1.0.-1", "１.0.0"])
    func componentsRejectsMalformed(_ input: String) {
        #expect(AppVersion.components(input) == nil)
    }

    @Test("版を数値の組で比べる")
    func isSameComparesNumerically() {
        #expect(AppVersion.isSame("1.10.0", "1.10.0"))
        #expect(!AppVersion.isSame("1.10.0", "1.9.0"))
        #expect(!AppVersion.isSame("1.0.0", "1.0.x"))
    }
}
