// tick の段 refreshVaultIndex のテスト（T-29 §6.4。PLAN §8.6 WikiLink・NOTE-11。voicedock test_worker_loop :962-1015）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDNotes

@testable import VDPipeline

@Suite("VaultIndexStage", .serialized, .timeLimit(.minutes(1)))
struct VaultIndexStageTests {
    /// Vault に Topics/VoiceDock.md と Raw のノートを置いた世界と、その Worker。
    static func world(configure: (inout AppConfig) -> Void = { _ in }) async throws -> (PipelineWorld, Worker) {
        let w = try await PipelineWorld.make(configure: configure)
        let vault = try await w.installVault()
        try touch(vault, "Topics/VoiceDock.md")
        try touch(vault, "Daily/Voice/Raw/20260829/2026-08-29 raw.md")
        let worker = w.worker()
        await worker.start()
        return (w, worker)
    }

    static func touch(_ vault: URL, _ rel: String) throws {
        let url = vault.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(Data("# note\n".utf8), to: url)
    }

    static func update(_ w: PipelineWorld, _ mutate: @escaping @Sendable (inout AppConfig) -> Void) async throws {
        let result = await w.configStore.update(mutate)
        guard case .success = result else { throw PipelineFixtureError.invalidConfig("\(result)") }
    }

    @Test("索引を作り Raw のフォルダを除く")
    func indexIsBuiltAndExcludesRaw() async throws {
        let (w, worker) = try await Self.world()
        await worker.tick()
        let index = try #require(await worker.vaultIndex)
        #expect(index.contains("VoiceDock"))
        #expect(!index.contains("2026-08-29 raw"))
        // 一時ディレクトリ（Vault）を tick の後まで残す
        withExtendedLifetime(w) {}
    }

    @Test("TTL の間は作り直さない")
    func indexIsKeptAcrossTicks() async throws {
        let (w, worker) = try await Self.world()
        await worker.tick()
        let first = try #require(await worker.vaultIndex)
        w.clock.advance(seconds: 299)
        await worker.tick()
        let second = try #require(await worker.vaultIndex)
        #expect(second.builtAt == first.builtAt)
    }

    @Test("TTL が過ぎたら作り直す（等号で古い）")
    func staleIndexIsRebuilt() async throws {
        let (w, worker) = try await Self.world()
        await worker.tick()
        let first = try #require(await worker.vaultIndex)
        w.clock.advance(seconds: 300)
        await worker.tick()
        let second = try #require(await worker.vaultIndex)
        #expect(second.builtAt == first.builtAt + .seconds(300))
    }

    @Test("CE obsidian.wiki.vaultIndexCacheSeconds 0 なら毎回作る")
    func ceVaultIndexCacheSeconds() async throws {
        let (w, worker) = try await Self.world(configure: { $0.obsidian.wiki.vaultIndexCacheSeconds = 0 })
        await worker.tick()
        #expect(try #require(await worker.vaultIndex).contains("New") == false)
        try Self.touch(w.vaultURL, "Topics/New.md")
        await worker.tick()
        #expect(try #require(await worker.vaultIndex).contains("New"))
    }

    @Test("linkTags が偽なら索引を持たない")
    func linkTagsOffDropsIndex() async throws {
        let (w, worker) = try await Self.world()
        await worker.tick()
        #expect(await worker.vaultIndex != nil)
        try await Self.update(w) { $0.obsidian.wiki.linkTags = false }
        await worker.tick()
        #expect(await worker.vaultIndex == nil)
        #expect(await worker.vaultIndexPath == nil)
    }

    @Test("使えない Vault では前の索引を保つ")
    func unavailableVaultKeepsIndex() async throws {
        let (w, worker) = try await Self.world()
        await worker.tick()
        let first = try #require(await worker.vaultIndex)
        try FileManager.default.removeItem(at: w.vaultURL.appendingPathComponent(".obsidian", isDirectory: true))
        w.clock.advance(seconds: 300)
        await worker.tick()
        let second = try #require(await worker.vaultIndex)
        #expect(second.builtAt == first.builtAt)
        #expect(second.contains("VoiceDock"))
    }

    @Test("Vault の場所が変われば作り直す")
    func vaultChangeRebuilds() async throws {
        let (w, worker) = try await Self.world()
        await worker.tick()
        let other = w.tmp.url.appendingPathComponent("vault2", isDirectory: true)
        try FileManager.default.createDirectory(
            at: other.appendingPathComponent(".obsidian", isDirectory: true), withIntermediateDirectories: true)
        try Self.touch(other, "Other.md")
        let path = w.tmp.url.appendingPathComponent("vault2").path(percentEncoded: false)
        try await Self.update(w) { $0.vault.path = path }
        await worker.tick()
        let index = try #require(await worker.vaultIndex)
        #expect(index.contains("Other"))
        #expect(!index.contains("VoiceDock"))
        #expect(await worker.vaultIndexPath == path)
    }
}
