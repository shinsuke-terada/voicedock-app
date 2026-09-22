// 乗り換えの走査の契機とガード（T-33 §5.2。PLAN §8.13・§8.15）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDNotes

@testable import VDPipeline
@testable import VDStore

@Suite("ImportedKeysService")
struct ImportedKeysServiceTests {
    static let rawNote = "Daily/Voice/Raw/20260829/2026-08-29 raw.md"

    static func writeKeyNote(_ w: PipelineWorld) throws {
        try w.writeVaultNote(Self.rawNote, w.voicedockRawNote(keys: [PipelineFixtures.foreignKeyA]))
    }

    @Test("Vault が使えれば走る")
    func scansWhenTheVaultIsAvailable() async throws {
        let w = try await PipelineWorld.make()
        try await w.installVault()
        try Self.writeKeyNote(w)
        #expect(await w.importedKeys.scanIfAvailable(.startup) == 1)
        #expect(try w.store.importedKeys() == [PipelineFixtures.foreignKeyA])
    }

    @Test("Vault 未設定なら何もしない")
    func noVaultPathDoesNothing() async throws {
        let w = try await PipelineWorld.make { $0.vault.path = nil }
        try FileManager.default.createDirectory(
            at: w.vaultURL.appendingPathComponent(".obsidian", isDirectory: true), withIntermediateDirectories: true)
        try Self.writeKeyNote(w)
        let before = w.sink.lines.count
        #expect(await w.importedKeys.scanIfAvailable(.vaultSelected) == 0)
        #expect(w.sink.lines.count == before)
        #expect(try w.store.importedKeys().isEmpty)
    }

    @Test("目印が無ければ走らない（幻の Vault を読まない）")
    func missingMarkerDoesNothing() async throws {
        let w = try await PipelineWorld.make()
        try await w.installVault(marker: false)
        try Self.writeKeyNote(w)
        #expect(await w.importedKeys.scanIfAvailable(.startup) == 0)
        #expect(try w.store.importedKeys().isEmpty)
    }

    @Test("DB の例外はログにして続ける")
    func storeErrorIsLoggedNotThrown() async throws {
        let w = try await PipelineWorld.make()
        try await w.installVault()
        try Self.writeKeyNote(w)
        try w.store.pool.close()
        #expect(await w.importedKeys.scanIfAvailable(.startup) == 0)
        let lines = w.lines("config_warning").filter { $0.contains("rule=store") }
        #expect(lines.count == 1)
        // message は例外の型名（PLAN §A の config_warning。文言ではない）
        #expect(lines.first?.contains("message=DatabaseError") == true)
        #expect(w.lines("imported_keys_added").isEmpty)
    }

    @Test("起動で 1 回だけ走る")
    func startupScanRunsOnce() async throws {
        let w = try await PipelineWorld.make()
        try await w.installVault()
        try Self.writeKeyNote(w)
        let worker = w.worker()
        await worker.start()
        await worker.tick()
        // 起動の後に置いたノートは、次の起動まで取り込まれない（tick では走らない）
        try w.writeVaultNote(
            "Daily/Voice/Raw/20260830/2026-08-30 raw.md", w.voicedockRawNote(keys: [PipelineFixtures.foreignKeyB]))
        await worker.tick()
        #expect(w.lines("imported_keys_added").count == 1)
        #expect(try w.store.importedKeys() == [PipelineFixtures.foreignKeyA])
    }

    @Test("起動の走査は最初の tick より前")
    func startupScanRunsBeforeTheFirstTick() async throws {
        let w = try await PipelineWorld.make()
        try await w.installVault()
        try Self.writeKeyNote(w)
        let worker = w.worker()
        await worker.start()
        #expect(try w.store.importedKeys() == [PipelineFixtures.foreignKeyA])
    }

    @Test("遅れた start でも走る")
    func delayedStartAlsoScans() async throws {
        let w = try await PipelineWorld.make()
        try await w.installVault()
        try Self.writeKeyNote(w)
        try Data("{".utf8).write(to: w.layout.configFile)
        _ = await w.configStore.load()
        let worker = w.worker()
        await worker.start()
        #expect(try w.store.importedKeys().isEmpty)
        var fixed = PipelineFixtures.baseConfig()
        fixed.vault.path = w.vaultPath
        try AtomicFile.write(ConfigLoader.encode(fixed), to: w.layout.configFile)
        _ = await w.configStore.load()
        await worker.tick()
        #expect(try w.store.importedKeys() == [PipelineFixtures.foreignKeyA])
    }
}
