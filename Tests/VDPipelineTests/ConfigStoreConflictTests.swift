// ConfigStore.update が、最後に読んでから変わった config.json を上書きしないこと・符号化できない値を書かないことのテスト
// （F-83。PLAN §6.1。issue #119 の H4・H7）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDPipeline

@Suite("ConfigStore（F-83）")
struct ConfigStoreConflictTests {
    typealias Scene = ConfigStoreTests.Scene

    /// changedOnDiskMessage の固定の文言（TEST-01）
    static let changed =
        "最後に読み込んだ後に config.json が変更されています。" + "「設定を読み直す」で読み直してから、もう一度操作してください"

    static func cv39(_ message: String) -> ConfigUpdateResult {
        .failure([ConfigViolation(rule: "CV-39", code: .configInvalidValue, keyPath: "<file>", message: message)])
    }

    static func isSuccess(_ result: ConfigUpdateResult) -> Bool {
        if case .success = result { return true }
        return false
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

    @Test("F-83 読んだ後に手で編集された config.json は上書きしない（手で false にした deleteSkippedSource が true に戻らない）")
    func handEditIsNotOverwritten() async throws {
        let s = try Scene()
        let (store, config) = try await Self.loadedWithDeletionOn(s)
        var edited = config
        edited.cleanup.deleteSkippedSource = false
        try s.write(edited)
        let before = try s.fileBytes()
        let result = await store.update { $0.vault.path = "/Users/example/Vault" }
        #expect(result == Self.cv39(Self.changed))
        #expect(try s.fileBytes() == before)
        #expect(try s.fileConfig().cleanup.deleteSkippedSource == false)
        #expect(await store.current() == config)
    }

    @Test("F-83 読み直せば、手編集の上に書ける")
    func reloadThenUpdate() async throws {
        let s = try Scene()
        let (store, config) = try await Self.loadedWithDeletionOn(s)
        var edited = config
        edited.cleanup.deleteSkippedSource = false
        try s.write(edited)
        #expect(await store.update { $0.vault.path = "/Users/example/Vault" } == Self.cv39(Self.changed))
        guard case .valid = await store.load() else { throw CocoaError(.fileReadCorruptFile) }
        #expect(Self.isSuccess(await store.update { $0.vault.path = "/Users/example/Vault" }))
        let written = try s.fileConfig()
        #expect(written.cleanup.deleteSkippedSource == false)
        #expect(written.vault.path == "/Users/example/Vault")
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

    @Test("F-83 config.json が消えていれば書かない（作り直さない）")
    func missingFileIsNotRecreated() async throws {
        let s = try Scene()
        let store = s.store()
        #expect(ConfigStoreTests.isValid(await store.load()))
        try FileManager.default.removeItem(at: s.layout.configFile)
        #expect(await store.update { $0.vault.path = "/a" } == Self.cv39(Self.changed))
        #expect(!FileManager.default.fileExists(atPath: s.layout.configFile.path(percentEncoded: false)))
    }

    @Test("F-83 中身を空にされた config.json は上書きしない（TEST-28）")
    func emptiedFileIsNotOverwritten() async throws {
        let s = try Scene()
        let store = s.store()
        #expect(ConfigStoreTests.isValid(await store.load()))
        try s.writeText("")
        #expect(await store.update { $0.vault.path = "/a" } == Self.cv39(Self.changed))
        #expect(try s.fileBytes() == [])
    }

    @Test("F-83 符号化できない値は書かずに違反を返す（config.json は変わらない）")
    func unencodableValueIsNotWritten() async throws {
        let s = try Scene()
        let store = s.store()
        #expect(ConfigStoreTests.isValid(await store.load()))
        let before = try s.fileBytes()
        let result = await store.update { $0.audio.freeSpaceMultiplier = .infinity }
        guard case .failure(let v) = result else {
            Issue.record("成功してしまった")
            return
        }
        #expect(v.map(\.rule) == ["CV-39"])
        #expect(v.map(\.keyPath) == ["<file>"])
        #expect(v.first?.message.hasPrefix("符号化できません: ") == true)
        #expect(try s.fileBytes() == before)
        #expect(await store.current()?.audio.freeSpaceMultiplier.isFinite == true)
    }
}
