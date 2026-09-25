// schemaVersion 2 → 3 の移行の検査（PLAN §6.1。F-92）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("ConfigMigratorV3")
struct ConfigMigratorV3Tests {
    /// 既定値（timeZone は Asia/Tokyo）を符号化した JSON の辞書（3）。
    static func defaults() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: ConfigLoader.encode(AppConfig.defaults(timeZone: "Asia/Tokyo")))
        return try #require(object as? [String: Any])
    }

    /// F-92 の前の既定値: schemaVersion を 2 にし、llm.analysis.prompts を消した辞書。
    static func v2() throws -> [String: Any] {
        var object = try defaults()
        object["schemaVersion"] = 2
        var llm = try #require(object["llm"] as? [String: Any])
        var analysis = try #require(llm["analysis"] as? [String: Any])
        analysis["prompts"] = nil
        llm["analysis"] = analysis
        object["llm"] = llm
        return object
    }

    static func prompts(_ object: [String: Any]) -> [String: Any]? {
        let llm = object["llm"] as? [String: Any]
        let analysis = llm?["analysis"] as? [String: Any]
        return analysis?["prompts"] as? [String: Any]
    }

    /// llm.analysis.prompts が 3 つとも null（NSNull）で、ほかのキーが無いか
    static func promptsAreNull(_ object: [String: Any]) -> Bool {
        guard let p = prompts(object) else { return false }
        return Set(p.keys) == ["analyze", "map", "reduce"] && p.values.allSatisfy { $0 is NSNull }
    }

    static func migrated(_ object: [String: Any]) throws -> [String: Any] {
        switch ConfigMigrator.migrate(object) {
        case .success(let result): return result
        case .failure(let violation):
            Issue.record("移行に失敗: \(violation)")
            throw violation
        }
    }

    static func cv39(_ message: String) -> ConfigViolation {
        ConfigViolation(rule: "CV-39", code: .configInvalidValue, keyPath: "schemaVersion", message: message)
    }

    @Test("2 の設定は llm.analysis.prompts（3 つとも null）を足して 3 にする")
    func v2GetsNullPrompts() throws {
        let result = try Self.migrated(try Self.v2())
        #expect((result["schemaVersion"] as? NSNumber)?.intValue == 3)
        #expect(Self.promptsAreNull(result))
    }

    @Test("2 でも prompts が在れば触らない")
    func v2KeepsExistingPrompts() throws {
        var object = try Self.v2()
        var llm = try #require(object["llm"] as? [String: Any])
        var analysis = try #require(llm["analysis"] as? [String: Any])
        analysis["prompts"] = [
            "analyze": "A {schema_block} {custom_instructions}", "map": NSNull(), "reduce": NSNull(),
        ]
        llm["analysis"] = analysis
        object["llm"] = llm
        let result = try Self.migrated(object)
        #expect((result["schemaVersion"] as? NSNumber)?.intValue == 3)
        #expect(Self.prompts(result)?["analyze"] as? String == "A {schema_block} {custom_instructions}")
    }

    @Test("llm.analysis が辞書でなければ版だけ上げる（CV-39 に任せる）")
    func v2NonDictAnalysisIsLeftToCV39() throws {
        var object = try Self.v2()
        var llm = try #require(object["llm"] as? [String: Any])
        llm["analysis"] = "x"
        object["llm"] = llm
        let result = try Self.migrated(object)
        #expect((result["schemaVersion"] as? NSNumber)?.intValue == 3)
        #expect((result["llm"] as? [String: Any])?["analysis"] as? String == "x")
        let data = try JSONSerialization.data(withJSONObject: object)
        guard case .invalid(let violations) = ConfigLoader.decodeStructure(data: data) else {
            Issue.record("llm.analysis が文字列なのに読めた")
            return
        }
        #expect(
            violations == [
                ConfigViolation(
                    rule: "CV-39", code: .configInvalidValue, keyPath: "llm.analysis", message: "オブジェクトであること")
            ])
    }

    @Test("3 はそのまま")
    func v3PassesThrough() throws {
        let object = try Self.defaults()
        let result = try Self.migrated(object)
        #expect(NSDictionary(dictionary: result).isEqual(to: object))
        #expect((result["schemaVersion"] as? NSNumber)?.intValue == 3)
    }

    @Test("4 は新しすぎる")
    func v4IsTooNew() throws {
        var object = try Self.defaults()
        object["schemaVersion"] = 4
        guard case .failure(let violation) = ConfigMigrator.migrate(object) else {
            Issue.record("4 が通った")
            return
        }
        #expect(violation == Self.cv39("この版のアプリより新しい設定です（schemaVersion 4）。アプリを更新してください"))
    }

    @Test("0 は不正")
    func v0IsInvalid() throws {
        var object = try Self.defaults()
        object["schemaVersion"] = 0
        guard case .failure(let violation) = ConfigMigrator.migrate(object) else {
            Issue.record("0 が通った")
            return
        }
        #expect(violation == Self.cv39("不正な schemaVersion（0）"))
    }

    @Test("2 の config.json（F-92 の前の既定値）が ConfigLoader で読め、既定値と等しい")
    func v2FileLoadsThroughLoader() throws {
        let data = try JSONSerialization.data(withJSONObject: try Self.v2())
        let result = ConfigLoader.load(data: data, catalog: TestCatalogs.minimal, reaperConfObservation: .missing)
        guard case .valid(let config) = result else {
            Issue.record("読めない: \(result)")
            return
        }
        #expect(config.schemaVersion == 3)
        #expect(config.llm.analysis.prompts == PromptOverrides(analyze: nil, map: nil, reduce: nil))
        #expect(config == AppConfig.defaults(timeZone: "Asia/Tokyo"))
    }

    @Test("空の辞書（TEST-28）")
    func emptyObjectIsRejected() {
        guard case .failure(let violation) = ConfigMigrator.migrate([:]) else {
            Issue.record("空の辞書が通った")
            return
        }
        #expect(violation == Self.cv39("キーがありません"))
    }
}
