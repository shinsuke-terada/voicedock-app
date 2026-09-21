// ConfigLoader の 4 段の読み込み（CV-01・CV-39）のテスト（T-09）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("ConfigLoader")
struct ConfigLoaderTests {
    /// 既定値（timeZone は Asia/Tokyo）を符号化した JSON の辞書。
    static func valid() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: ConfigLoader.encode(AppConfig.defaults(timeZone: "Asia/Tokyo")))
        return try #require(object as? [String: Any])
    }

    /// キーパスの位置に値を置く（nil なら消す）。途中はオブジェクトでなければならない。
    static func setting(_ root: [String: Any], _ path: String, _ value: Any?) -> [String: Any] {
        var parts = path.split(separator: ".").map(String.init)
        let last = parts.removeLast()
        func apply(_ object: [String: Any], _ rest: ArraySlice<String>) -> [String: Any] {
            var copy = object
            if let head = rest.first {
                copy[head] = apply(object[head] as? [String: Any] ?? [:], rest.dropFirst())
            } else {
                copy[last] = value
            }
            return copy
        }
        return apply(root, parts[...])
    }

    static func load(_ root: [String: Any]) throws -> ConfigLoadResult {
        let data = try JSONSerialization.data(withJSONObject: root)
        return load(data)
    }

    static func load(_ data: Data) -> ConfigLoadResult {
        ConfigLoader.load(data: data, catalog: TestCatalogs.minimal, reaperConfObservation: .missing)
    }

    static func violations(_ result: ConfigLoadResult) -> [ConfigViolation] {
        if case .invalid(let violations) = result { return violations }
        return []
    }

    static func cv39(_ keyPath: String, _ message: String) -> ConfigViolation {
        ConfigViolation(rule: "CV-39", code: .configInvalidValue, keyPath: keyPath, message: message)
    }

    static func cv01(_ keyPath: String) -> ConfigViolation {
        ConfigViolation(rule: "CV-01", code: .configUnknownKey, keyPath: keyPath, message: "未知のキーです")
    }

    @Test("CV-39 JSON でなければ読めない")
    func cv39NotJSON() {
        #expect(Self.load(Data("{".utf8)) == .invalid([Self.cv39("<file>", "JSON として読めません")]))
    }

    @Test("CV-39 空のデータは JSON として読めない")
    func cv39EmptyData() {
        #expect(Self.load(Data()) == .invalid([Self.cv39("<file>", "JSON として読めません")]))
    }

    @Test("CV-39 トップが配列なら読めない")
    func cv39NotObject() {
        #expect(Self.load(Data("[]".utf8)) == .invalid([Self.cv39("<file>", "JSON のオブジェクトではありません")]))
    }

    @Test("CV-39 schemaVersion が無い")
    func cv39SchemaVersionMissing() throws {
        let result = try Self.load(Self.setting(Self.valid(), "schemaVersion", nil))
        #expect(result == .invalid([Self.cv39("schemaVersion", "キーがありません")]))
    }

    @Test("CV-39 schemaVersion が 1.5 や true")
    func cv39SchemaVersionNotInteger() throws {
        for value: Any in [1.5, true] {
            let result = try Self.load(Self.setting(Self.valid(), "schemaVersion", value))
            #expect(result == .invalid([Self.cv39("schemaVersion", "整数であること")]))
        }
    }

    @Test("CV-39 schemaVersion 0")
    func cv39SchemaVersionZero() throws {
        let result = try Self.load(Self.setting(Self.valid(), "schemaVersion", 0))
        #expect(result == .invalid([Self.cv39("schemaVersion", "不正な schemaVersion（0）")]))
    }

    @Test("CV-01 トップの未知のキー")
    func cv01UnknownTopLevelKey() throws {
        let result = try Self.load(Self.setting(Self.valid(), "extra", 1))
        #expect(result == .invalid([Self.cv01("extra")]))
    }

    @Test("CV-01 入れ子の未知のキー")
    func cv01UnknownNestedKey() throws {
        let root = Self.setting(try Self.valid(), "llm.analysis.sections.summary2", ["enabled": true])
        #expect(Self.violations(try Self.load(root)).map(\.keyPath) == ["llm.analysis.sections.summary2"])
        #expect(Self.violations(try Self.load(root)).map(\.rule) == ["CV-01"])
    }

    @Test("CV-01 複数の未知キーは昇順")
    func cv01UnknownKeysAreSorted() throws {
        let root = Self.setting(Self.setting(try Self.valid(), "device.zz", 1), "device.aa", 1)
        #expect(try Self.load(root) == .invalid([Self.cv01("device.aa"), Self.cv01("device.zz")]))
    }

    @Test("CV-01 summary と timeline の maxItems は未知のキー（F-54）")
    func cv01SummaryMaxItemsIsUnknown() throws {
        for name in ["summary", "timeline"] {
            let path = "llm.analysis.sections.\(name).maxItems"
            #expect(try Self.load(Self.setting(Self.valid(), path, 10)) == .invalid([Self.cv01(path)]))
        }
        let keyPoints = Self.setting(try Self.valid(), "llm.analysis.sections.key_points.maxItems", 10)
        guard case .valid(let config) = try Self.load(keyPoints) else {
            Issue.record("key_points.maxItems = 10 は通るはず")
            return
        }
        #expect(config.llm.analysis.sections.keyPoints.maxItems == 10)
    }

    @Test("CV-39 欠けたキー")
    func cv39MissingKey() throws {
        let result = try Self.load(Self.setting(Self.valid(), "device.stabilityChecks", nil))
        #expect(result == .invalid([Self.cv39("device.stabilityChecks", "キーがありません")]))
        // 欠けたキーは型に写す前に全部出す（JSONDecoder は最初の 1 つしか言わない）。
        let two = Self.setting(
            Self.setting(try Self.valid(), "device.stabilityChecks", nil), "device.maxScanDepth", nil)
        #expect(
            try Self.load(two)
                == .invalid([
                    Self.cv39("device.maxScanDepth", "キーがありません"),
                    Self.cv39("device.stabilityChecks", "キーがありません"),
                ]))
    }

    @Test("CV-39 null を許すキーでも欠けたら違反")
    func cv39MissingOptionalKeyStillMissing() throws {
        let result = try Self.load(Self.setting(Self.valid(), "vault.path", nil))
        #expect(result == .invalid([Self.cv39("vault.path", "キーがありません")]))
    }

    @Test("null を許すキーは null でよい")
    func nullForOptionalIsValid() throws {
        let root = try Self.valid()
        #expect((root["vault"] as? [String: Any])?["path"] is NSNull)
        #expect(try Self.load(root) == .valid(AppConfig.defaults(timeZone: "Asia/Tokyo")))
    }

    @Test("CV-39 オブジェクトの位置に数値")
    func cv39ObjectExpected() throws {
        let result = try Self.load(Self.setting(Self.valid(), "vault", 1))
        #expect(result == .invalid([Self.cv39("vault", "オブジェクトであること")]))
    }

    @Test("CV-39 型違いはキーのパス付き")
    func cv39TypeMismatch() throws {
        let result = try Self.load(Self.setting(Self.valid(), "device.stabilityChecks", "2"))
        #expect(result == .invalid([Self.cv39("device.stabilityChecks", "型が違います")]))
    }

    @Test("CV-39 配列の要素の型違い")
    func cv39TypeMismatchInArray() throws {
        let root = Self.setting(try Self.valid(), "cleanup.deleteEvaluationBackoffSeconds", [60, "x"] as [Any])
        let violations = Self.violations(try Self.load(root))
        #expect(violations.map(\.keyPath) == ["cleanup.deleteEvaluationBackoffSeconds.1"])
        #expect(violations.map(\.rule) == ["CV-39"])
    }

    @Test("CV-39 null にできないキー")
    func cv39NullForNonOptional() throws {
        let result = try Self.load(Self.setting(Self.valid(), "device.mountMode", NSNull()))
        #expect(result == .invalid([Self.cv39("device.mountMode", "null にできません")]))
    }

    @Test("CV-39 整数のキーに 1.5")
    func cv39FloatForInt() throws {
        let violations = Self.violations(try Self.load(Self.setting(Self.valid(), "session.maxParts", 1.5)))
        #expect(violations == [Self.cv39("session.maxParts", "値が不正です")])
    }

    @Test("キーの段で違反があれば意味の検証をしない")
    func stopsBeforeValidationWhenKeysWrong() throws {
        let root = Self.setting(Self.setting(try Self.valid(), "extra", 1), "session.blockGapSeconds", -1)
        #expect(try Self.load(root) == .invalid([Self.cv01("extra")]))
    }

    @Test("意味の検証は 1 つ目で止めない")
    func validationCollectsAll() throws {
        let root = Self.setting(
            Self.setting(try Self.valid(), "session.blockGapSeconds", -1), "obsidian.maxTitleBytes", 0)
        #expect(Self.violations(try Self.load(root)).map(\.rule) == ["CV-08", "CV-16"])
    }

    @Test("違反の 1 行表記は空白 2 つ区切り")
    func renderedFormat() {
        let violation = ConfigViolation(
            rule: "CV-08", code: .configInvalidValue, keyPath: "session.blockGapSeconds", message: "0 以上であること（-1）")
        #expect(violation.rendered == "CV-08  CONFIG_INVALID_VALUE  session.blockGapSeconds: 0 以上であること（-1）")
    }
}
