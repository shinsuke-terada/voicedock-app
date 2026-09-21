// GoldenConfig.make（golden の設定の上書きから AppConfig を作る）のテスト（T-09）。
import Foundation
import Testing
import VDCore

@testable import TestSupport

@Suite("GoldenConfig")
struct GoldenConfigTests {
    static func allCases() throws -> [GoldenCase] {
        try Golden.groupNames().flatMap { try Golden.cases($0) }
    }

    /// キーパスで辞書を辿る。
    static func value(_ root: [String: Any], _ path: String) -> Any? {
        var current: Any = root
        for key in path.split(separator: ".").map(String.init) {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current
    }

    @Test("golden の上書きは設定の同じキーパスに入る")
    func overridesLandOnKeyPaths() throws {
        for item in try Self.allCases() where !(try item.overrides()).isEmpty {
            let config = try GoldenConfig.make(item)
            let object = try JSONSerialization.jsonObject(with: ConfigLoader.encode(config))
            let root = try #require(object as? [String: Any])
            for (key, expected) in try item.overrides() {
                #expect(GoldenJSON(any: Self.value(root, key)) == expected, "\(item.testDescription) \(key)")
            }
        }
    }

    @Test("上書きの無いケースは既定値と同じ")
    func noOverridesEqualsDefaults() throws {
        let item = try #require(try Golden.cases("sanitize").first)
        #expect(try item.overrides().isEmpty)
        #expect(try GoldenConfig.make(item) == AppConfig.defaults(timeZone: "Asia/Tokyo"))
    }

    @Test("上書きのあるケースが在る（空で緑にしない）")
    func someCasesHaveOverrides() throws {
        #expect(try Self.allCases().contains { !(try $0.overrides()).isEmpty })
    }

    @Test("途中のキーが無ければ missingPath")
    func missingPathThrows() {
        var object: [String: Any] = ["obsidian": ["maxTitleBytes": 180]]
        #expect(throws: GoldenConfig.Failure.missingPath("nope.x")) {
            try GoldenConfig.set(&object, path: ["obsidian", "nope", "x"][...], value: 1)
        }
    }

    @Test("空のパスは missingPath（空文字）")
    func emptyPathThrows() {
        var object: [String: Any] = [:]
        #expect(throws: GoldenConfig.Failure.missingPath("")) {
            try GoldenConfig.set(&object, path: [][...], value: 1)
        }
    }
}
