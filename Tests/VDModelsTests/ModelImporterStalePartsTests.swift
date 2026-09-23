// 取り込みの途中で残った `.custom-import-*.gguf.part` の掃除・取り込みの書き出しとメモリの式のテスト
// （F-83。PLAN §8.10。issue #119 の F7・F10・F11・H8）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore
@testable import VDModels

@Suite("ModelImporter（F-83）")
struct ModelImporterStalePartsTests {
    /// "a" × 1,000,000 の SHA-256（FIPS 180-2 の検査値）
    static let millionASHA = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

    func world() throws -> (TempDirectory, HomeLayout) {
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url)
        try layout.createDirectories()
        return (tmp, layout)
    }

    func manager(_ layout: HomeLayout) throws -> ModelManager {
        let log = AppLog(
            sink: CapturingLogSink(), level: .debug, unsafeContent: false,
            zone: ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo"))),
            clock: FixedClock(epochMillis: 1_756_000_000_000))
        let downloader = ModelDownloader(
            layout: layout, factory: BlockingSessionFactory(), log: log, hashChunkBytes: 4096)
        return ModelManager(
            layout: layout, catalog: TestCatalogs.minimal, downloader: downloader, cache: ModelVerificationCache(),
            log: log, hashChunkBytes: 4096)
    }

    func llm(_ layout: HomeLayout) -> URL { layout.models(kind: "llm") }

    func names(_ layout: HomeLayout) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: llm(layout).path(percentEncoded: false)).sorted()
    }

    func put(_ layout: HomeLayout, _ name: String) throws {
        try Data("partial".utf8).write(to: llm(layout).appendingPathComponent(name, isDirectory: false))
    }

    @Test("F-83 取り込みを始める前に、前回の途中の .custom-import-<16 hex>.gguf.part を消す")
    func importRemovesStaleParts() async throws {
        let (tmp, layout) = try world()
        defer { tmp.remove() }
        try put(layout, ".custom-import-0123456789abcdef.gguf.part")
        try put(layout, ".custom-import-fedcba9876543210.gguf.part")
        let source = tmp.url.appendingPathComponent("in.gguf", isDirectory: false)
        try Data(repeating: UInt8(ascii: "a"), count: 1_000_000).write(to: source)
        let m = try manager(layout)
        let r = await m.importCustomLLM(from: source)
        let imported = try r.get()
        #expect(imported.id == "custom:" + Self.millionASHA)
        #expect(try names(layout) == ["custom-cdc76e5c9914fb92.gguf"])
    }

    @Test("F-83 名前の形が完全に一致する通常のファイルだけを消す（symlink・大文字・桁違い・別の名前は残す）")
    func onlyExactNamesAreRemoved() throws {
        let (tmp, layout) = try world()
        defer { tmp.remove() }
        let kept = [
            // APFS は大文字小文字を区別しないので、小文字の対と重ならない 16 進にする
            ".custom-import-ABCDEF0123456789.gguf.part",
            ".custom-import-0123456789abcde.gguf.part",
            ".custom-import-0123456789abcdef0.gguf.part",
            "custom-import-0123456789abcdef.gguf.part",
            ".custom-import-0123456789abcdef.gguf.part.bak",
            ".custom-import-0123456789abcdef.gguf",
            ".Qwen3-4B-Instruct-2507-Q4_K_M.gguf.part",
            "custom-3605803b982cb64a.gguf",
        ]
        for name in kept { try put(layout, name) }
        try put(layout, ".custom-import-0123456789abcdef.gguf.part")
        let outside = tmp.url.appendingPathComponent("outside.gguf", isDirectory: false)
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: llm(layout).appendingPathComponent(".custom-import-fedcba9876543210.gguf.part"),
            withDestinationURL: outside)
        #expect(ModelImporter.discardStaleParts(layout: layout) == 1)
        #expect(try names(layout) == (kept + [".custom-import-fedcba9876543210.gguf.part"]).sorted())
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
    }

    @Test("F-83 llm のフォルダが空なら何も消さない（TEST-28）")
    func emptyFolder() throws {
        let (tmp, layout) = try world()
        defer { tmp.remove() }
        #expect(ModelImporter.discardStaleParts(layout: layout) == 0)
        #expect(try names(layout) == [])
    }

    @Test("F-83 何回にも分けて読んでも（autoreleasepool の中）SHA-256 は同じ")
    func chunkedImportHashesTheWholeFile() throws {
        let (tmp, layout) = try world()
        defer { tmp.remove() }
        let source = tmp.url.appendingPathComponent("in.gguf", isDirectory: false)
        try Data(repeating: UInt8(ascii: "a"), count: 1_000_000).write(to: source)
        let r = ModelImporter.importGGUF(from: source, layout: layout, chunkBytes: 4096)
        #expect(try r.get().id == "custom:" + Self.millionASHA)
        #expect(try Data(contentsOf: try r.get().url) == Data(repeating: UInt8(ascii: "a"), count: 1_000_000))
    }

    @Test("F-83 meetsMemory は ModelMemory と同じ式（負の値・掛け算のあふれで落ちない。CR-06・CR-16）")
    func meetsMemoryUsesTheSharedFormula() {
        func entry(_ gb: Int) -> ModelEntry {
            ModelEntry(
                id: "m", displayName: "m", file: "m.gguf",
                url: "https://huggingface.co/x/y/resolve/\(String(repeating: "0", count: 40))/m.gguf",
                sha256: String(repeating: "a", count: 64), bytes: 1, license: "MIT", minMemoryGB: gb, verified: true)
        }
        #expect(ModelManager.meetsMemory(entry(-1), physicalMemoryBytes: 0) == true)
        #expect(ModelManager.meetsMemory(entry(0), physicalMemoryBytes: 0) == true)
        #expect(ModelManager.meetsMemory(entry(Int.max), physicalMemoryBytes: UInt64.max) == false)
        #expect(ModelManager.meetsMemory(entry(16), physicalMemoryBytes: 17_179_869_184) == true)
        #expect(ModelManager.meetsMemory(entry(16), physicalMemoryBytes: 17_179_869_183) == false)
    }
}
