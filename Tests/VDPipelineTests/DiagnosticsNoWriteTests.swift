// 診断と状態の詳細が何も書かないことのテスト（T-32 §5.3。OPS-14・NOTE-16・PT-17）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice

@testable import VDPipeline
@testable import VDStore

@Suite("診断は何も書かない")
struct DiagnosticsNoWriteTests {
    /// config・DB・inbox・staging・models・Vault を用意した世界（DB の Store は閉じてから返す）
    static func populated(vault: Bool = true) async throws -> (DiagnosticsWorld, String) {
        var vaultPath = ""
        let w = try await DiagnosticsWorld.make(
            results: [DiagnosticsWorld.help(DiagnosticsWorld.whisperHelpAll)],
            snapshot: DiagnosticsWorld.snapshot(devices: ["DJIMIC3": false]))
        if vault {
            vaultPath = try w.makeVault()
            let path = vaultPath
            let r = await w.configStore.update { $0.vault.path = path }
            guard case .success = r else { throw PipelineFixtureError.invalidConfig("\(r)") }
        }
        do {
            let store = try w.openStore()
            try w.addInboxPart(
                store: store, relpath: "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
                status: .rawSaved)
            try w.addInboxPart(
                store: store, relpath: "TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav",
                status: .discovered)
        }
        try FileManager.default.createDirectory(
            at: w.layout.staging.appendingPathComponent("x", isDirectory: true), withIntermediateDirectories: true)
        try Data(count: 8).write(to: w.layout.staging.appendingPathComponent("x/a.wav"))
        try w.placeModel(kind: .whisper, file: "ggml-large-v3-turbo-q8_0.bin")
        try w.placeModel(kind: .vad, file: "ggml-silero-v5.1.2.bin")
        try w.placeHelper(w.paths.whisperCLI)
        return (w, vaultPath)
    }

    @Test("OPS-14 <HOME> を書き換えない（-shm の索引を除く）")
    func diagnosticsChangeNothingInHome() async throws {
        let (w, _) = try await Self.populated()
        let before = try FileTree.listing(w.layout.root)
        let results = await Diagnostics(deps: w.deps).run(loginItemStatus: .enabled)
        #expect(results.count == 16)
        let after = try FileTree.listing(w.layout.root)
        #expect(after == before)
        #expect(before.contains { $0.hasPrefix("voicedock.sqlite ") })
    }

    @Test("Vault にファイルもフォルダも作らない")
    func diagnosticsChangeNothingInVault() async throws {
        let (w, vaultPath) = try await Self.populated()
        let vault = URL(fileURLWithPath: vaultPath, isDirectory: true)
        let before = try FileTree.listing(vault)
        _ = await Diagnostics(deps: w.deps).run(loginItemStatus: .enabled)
        let after = try FileTree.listing(vault)
        #expect(after == before)
        #expect(before == [".obsidian/"])
    }

    @Test("DB を作らない")
    func diagnosticsDoNotCreateTheDatabase() async throws {
        let w = try await DiagnosticsWorld.make()
        _ = await Diagnostics(deps: w.deps).run(loginItemStatus: .enabled)
        #expect(!PipelineFixtures.exists(w.layout.database))
    }

    @Test("テンプレートのフォルダを作らない")
    func diagnosticsDoNotCreateNoteFolders() async throws {
        let (w, vaultPath) = try await Self.populated()
        let template = await w.configStore.current()?.obsidian.raw.folderTemplate
        #expect(template == "Daily/Voice/Raw/{yyyymmdd}")
        _ = await Diagnostics(deps: w.deps).run(loginItemStatus: .enabled)
        #expect(!FileManager.default.fileExists(atPath: vaultPath + "/Daily"))
    }

    @Test("状態の詳細も書かない")
    func statusReportChangesNothing() async throws {
        let (w, _) = try await Self.populated()
        let before = try FileTree.listing(w.layout.root)
        let config = await w.configStore.current()
        let report = StatusReporter.build(
            layout: w.layout, config: config, snapshot: await w.ingest.latestSnapshot(), now: w.clock.now(),
            zone: PipelineFixtures.zone)
        #expect(report.inbox.leftoverCount == 1)
        let after = try FileTree.listing(w.layout.root)
        #expect(after == before)
    }
}
