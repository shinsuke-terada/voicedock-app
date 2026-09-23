// ConfigStore.update が書く前に今の config.json を読み直し、その値に変更を当てて検証して書くことのテスト
// （F-83。PLAN §6.1。issue #119 の H4・H7）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDPipeline

@Suite("ConfigStore（F-83）", .timeLimit(.minutes(1)))
struct ConfigStoreConflictTests {
    typealias Scene = ConfigStoreTests.Scene

    /// reloadGuidance の固定の文言（TEST-01）
    static let guidance = ConfigViolation(
        rule: "CV-39", code: .configInvalidValue, keyPath: "<file>",
        message: "config.json は最後に読み込んだ後に変更されています（手の編集を含めて検証しました）。「設定を読み直す」で内容を確かめてください")

    static func isSuccess(_ result: ConfigUpdateResult) -> Bool {
        if case .success = result { return true }
        return false
    }

    static func violations(_ result: ConfigUpdateResult) -> [ConfigViolation] {
        if case .failure(let v) = result { return v }
        return []
    }

    /// 削除が有効（両方 true・rw）の設定を書いて読み込んだ ConfigStore（reaper.conf の観測も有効）
    static func loadedWithDeletionOn(_ s: Scene) async throws -> (ConfigStore, AppConfig) {
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        config.cleanup.deleteSourceAudio = true
        config.cleanup.deleteSkippedSource = true
        config.device.mountMode = "rw"
        try s.write(config)
        let store = s.store { ConfigStoreTests.deleteOn }
        guard case .valid = await store.load() else { throw CocoaError(.fileReadCorruptFile) }
        return (store, config)
    }

    @Test("F-83 読んだ後の手編集は残り、パネルの変更も当たる（手で false にした deleteSkippedSource が true に戻らない）")
    func handEditIsKeptAndTheChangeApplies() async throws {
        let s = try Scene()
        let (store, config) = try await Self.loadedWithDeletionOn(s)
        var edited = config
        edited.cleanup.deleteSkippedSource = false
        try s.write(edited)
        let result = await store.update { $0.vault.path = "/Users/example/Vault" }
        #expect(Self.isSuccess(result))
        var expected = edited
        expected.vault.path = "/Users/example/Vault"
        #expect(try s.fileConfig() == expected)
        #expect(await store.current() == expected)
        #expect(await store.violations() == [])
    }

    @Test("F-83 無効化の途中（reaper.conf は false、ファイルは true）でも偽の CV-30 を出さずに書ける")
    func disablingDoesNotTripOverTheOldFile() async throws {
        let s = try Scene()
        let (store, config) = try await Self.loadedWithDeletionOn(s)
        let result = await store.update(
            { ConfigStore.turnDeletionOff(&$0) }, reaperConfObservation: ConfigStoreTests.deleteOff)
        #expect(Self.isSuccess(result))
        var expected = config
        expected.cleanup.deleteSourceAudio = false
        expected.cleanup.deleteSkippedSource = false
        expected.device.mountMode = "ro"
        #expect(try s.fileConfig() == expected)
    }

    @Test("F-83 手で deleteSourceAudio を true にしたファイルは、組み合わせた値の CV-30 で書かず、案内を添える")
    func handEnabledDeletionIsRefused() async throws {
        let s = try Scene()
        let store = s.store { ConfigStoreTests.deleteOff }
        #expect(ConfigStoreTests.isValid(await store.load()))
        var edited = try s.fileConfig()
        edited.cleanup.deleteSourceAudio = true
        edited.device.mountMode = "rw"
        try s.write(edited)
        let before = try s.fileBytes()
        let v = Self.violations(await store.update { $0.vault.path = "/a" })
        #expect(v.map(\.rule) == ["CV-30", "CV-39"])
        #expect(v.last == Self.guidance)
        #expect(try s.fileBytes() == before)
        #expect(await store.current()?.cleanup.deleteSourceAudio == false)
    }

    @Test("F-83 構造が壊れた config.json には書かない（違反と案内を返す）")
    func brokenFileIsNotWritten() async throws {
        let s = try Scene()
        let store = s.store()
        #expect(ConfigStoreTests.isValid(await store.load()))
        try s.writeText("{")
        let v = Self.violations(await store.update { $0.vault.path = "/a" })
        #expect(
            v == [
                ConfigViolation(
                    rule: "CV-39", code: .configInvalidValue, keyPath: "<file>", message: "JSON として読めません"),
                Self.guidance,
            ])
        #expect(try s.fileBytes() == Array("{".utf8))
        #expect(await store.current()?.vault.path == nil)
    }

    @Test("F-83 中身を空にされた config.json にも書かない（TEST-28）")
    func emptiedFileIsNotWritten() async throws {
        let s = try Scene()
        let store = s.store()
        #expect(ConfigStoreTests.isValid(await store.load()))
        try s.writeText("")
        #expect(Self.violations(await store.update { $0.vault.path = "/a" }).map(\.rule) == ["CV-39", "CV-39"])
        #expect(try s.fileBytes() == [])
    }

    @Test("F-83 未知のキーを足したファイルは load と同じ厳密な経路で断る（CV-01）")
    func unknownKeyIsRefusedLikeLoad() async throws {
        let s = try Scene()
        let store = s.store()
        #expect(ConfigStoreTests.isValid(await store.load()))
        var object = try #require(
            try JSONSerialization.jsonObject(with: try ConfigLoader.encode(try s.fileConfig())) as? [String: Any])
        object["extra"] = 1
        try JSONSerialization.data(withJSONObject: object).write(to: s.layout.configFile)
        let v = Self.violations(await store.update { $0.vault.path = "/a" })
        #expect(
            v.first == ConfigViolation(rule: "CV-01", code: .configUnknownKey, keyPath: "extra", message: "未知のキーです"))
    }

    @Test("F-83 config.json が消えていれば、メモリの値に変更を当てて作り直す（Vault・モデルの選択を失わない）")
    func missingFileIsRecreatedFromMemory() async throws {
        let s = try Scene()
        let store = s.store()
        #expect(ConfigStoreTests.isValid(await store.load()))
        #expect(Self.isSuccess(await store.update { $0.vault.path = "/Users/example/Vault" }))
        try FileManager.default.removeItem(at: s.layout.configFile)
        #expect(Self.isSuccess(await store.update { $0.llm.temperature = 1.5 }))
        let written = try s.fileConfig()
        #expect(written.vault.path == "/Users/example/Vault")
        #expect(written.llm.temperature == 1.5)
    }

    @Test("F-83 読み直してから書く直前までにまた変わったら書かない")
    func changeWhileWritingIsRefused() async throws {
        let s = try Scene()
        let store = s.store()
        #expect(ConfigStoreTests.isValid(await store.load()))
        let url = s.layout.configFile
        let result = await store.update { c in
            // mutate の中（読み直しの後・書く直前の照合の前）でファイルを変える
            try? Data("{}".utf8).write(to: url)
            c.vault.path = "/a"
        }
        #expect(
            Self.violations(result) == [
                ConfigViolation(
                    rule: "CV-39", code: .configInvalidValue, keyPath: "<file>",
                    message: "書き込む直前に config.json が変更されました。もう一度操作してください")
            ])
        #expect(try s.fileBytes() == Array("{}".utf8))
    }

    @Test("F-83 自分が書いた後は続けて書ける")
    func consecutiveUpdates() async throws {
        let s = try Scene()
        let store = s.store()
        #expect(ConfigStoreTests.isValid(await store.load()))
        #expect(Self.isSuccess(await store.update { $0.vault.path = "/a" }))
        #expect(Self.isSuccess(await store.update { $0.vault.path = "/b" }))
        #expect(try s.fileConfig().vault.path == "/b")
    }

    @Test("F-83 符号化できない値は書かずに違反を返す（config.json は変わらない）")
    func unencodableValueIsNotWritten() async throws {
        let s = try Scene()
        let store = s.store()
        #expect(ConfigStoreTests.isValid(await store.load()))
        let before = try s.fileBytes()
        let v = Self.violations(await store.update { $0.audio.freeSpaceMultiplier = .infinity })
        #expect(v.map(\.rule) == ["CV-39"])
        #expect(v.map(\.keyPath) == ["<file>"])
        #expect(v.first?.message.hasPrefix("符号化できません: ") == true)
        #expect(try s.fileBytes() == before)
        #expect(await store.current()?.audio.freeSpaceMultiplier.isFinite == true)
    }

    @Test("F-83 メモリだけ無効側に倒す（ファイルは書かない）")
    func disableDeletionInMemory() async throws {
        let s = try Scene()
        let (store, _) = try await Self.loadedWithDeletionOn(s)
        let before = try s.fileBytes()
        await store.disableDeletionInMemory()
        let c = try #require(await store.current())
        #expect(c.cleanup.deleteSourceAudio == false)
        #expect(c.cleanup.deleteSkippedSource == false)
        #expect(c.device.mountMode == "ro")
        #expect(try s.fileBytes() == before)
    }
}
