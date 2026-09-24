// schemaVersion 1 → 2 の移行の検査（PLAN §6.1。F-89。T-47）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("ConfigMigratorV2")
struct ConfigMigratorV2Tests {
    /// 既定値（timeZone は Asia/Tokyo）を符号化した JSON の辞書。
    static func defaults() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: ConfigLoader.encode(AppConfig.defaults(timeZone: "Asia/Tokyo")))
        return try #require(object as? [String: Any])
    }

    /// F-89 の前の既定値: schemaVersion を 1 にし、transcription.diarization を消した辞書。
    static func v1() throws -> [String: Any] {
        var object = try defaults()
        object["schemaVersion"] = 1
        var transcription = try #require(object["transcription"] as? [String: Any])
        transcription["diarization"] = nil
        object["transcription"] = transcription
        return object
    }

    static func migrated(_ object: [String: Any]) throws -> [String: Any] {
        switch ConfigMigrator.migrate(object) {
        case .success(let result): return result
        case .failure(let violation):
            Issue.record("移行に失敗: \(violation)")
            throw violation
        }
    }

    static func violation(_ object: [String: Any]) -> ConfigViolation? {
        if case .failure(let violation) = ConfigMigrator.migrate(object) { return violation }
        return nil
    }

    static func schemaVersion(_ object: [String: Any]) -> Int? {
        (object["schemaVersion"] as? NSNumber)?.intValue
    }

    static func diarizationEnabled(_ object: [String: Any]) -> Bool? {
        let transcription = object["transcription"] as? [String: Any]
        let diarization = transcription?["diarization"] as? [String: Any]
        return diarization?["enabled"] as? Bool
    }

    static func cv39(_ message: String) -> ConfigViolation {
        ConfigViolation(rule: "CV-39", code: .configInvalidValue, keyPath: "schemaVersion", message: message)
    }

    @Test("1 の設定は diarization.enabled=false を足して 2 にする")
    func v1GetsDiarizationOff() throws {
        let result = try Self.migrated(try Self.v1())
        #expect(Self.schemaVersion(result) == 2)
        #expect(Self.diarizationEnabled(result) == false)
    }

    @Test("1 でも diarization が在れば触らない")
    func v1KeepsExistingDiarization() throws {
        var object = try Self.v1()
        var transcription = try #require(object["transcription"] as? [String: Any])
        transcription["diarization"] = ["enabled": true]
        object["transcription"] = transcription
        let result = try Self.migrated(object)
        #expect(Self.schemaVersion(result) == 2)
        #expect(Self.diarizationEnabled(result) == true)
    }

    @Test("transcription が辞書でなければ版だけ上げる")
    func v1NonDictTranscriptionIsLeftToCV39() throws {
        var object = try Self.v1()
        object["transcription"] = 3
        let result = try Self.migrated(object)
        #expect(Self.schemaVersion(result) == 2)
        #expect((result["transcription"] as? NSNumber)?.intValue == 3)
        let data = try JSONSerialization.data(withJSONObject: object)
        guard case .invalid(let violations) = ConfigLoader.decodeStructure(data: data) else {
            Issue.record("transcription が 3 なのに読めた")
            return
        }
        #expect(
            violations == [
                ConfigViolation(
                    rule: "CV-39", code: .configInvalidValue, keyPath: "transcription", message: "オブジェクトであること")
            ])
    }

    @Test("2 はそのまま")
    func v2PassesThrough() throws {
        let object = try Self.defaults()
        let result = try Self.migrated(object)
        #expect(NSDictionary(dictionary: result).isEqual(to: object))
        #expect(Self.schemaVersion(result) == 2)
        #expect(Self.diarizationEnabled(result) == false)
    }

    @Test("3 は新しすぎる")
    func v3IsTooNew() throws {
        var object = try Self.defaults()
        object["schemaVersion"] = 3
        #expect(Self.violation(object) == Self.cv39("この版のアプリより新しい設定です（schemaVersion 3）。アプリを更新してください"))
    }

    @Test("1 の config.json（F-89 の前の既定値）が ConfigLoader で読める")
    func v1FileLoadsThroughLoader() throws {
        let data = try JSONSerialization.data(withJSONObject: try Self.v1())
        let result = ConfigLoader.load(data: data, catalog: TestCatalogs.minimal, reaperConfObservation: .missing)
        guard case .valid(let config) = result else {
            Issue.record("読めない: \(result)")
            return
        }
        #expect(config.schemaVersion == 2)
        #expect(config.transcription.diarization.enabled == false)
        #expect(config == AppConfig.defaults(timeZone: "Asia/Tokyo"))
    }

    @Test("空の辞書（TEST-28）")
    func emptyObjectIsRejected() {
        #expect(Self.violation([:]) == Self.cv39("キーがありません"))
    }
}
