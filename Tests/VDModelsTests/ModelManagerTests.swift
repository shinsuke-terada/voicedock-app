// ModelManager のテスト（T-23 §5.4）。ネットワークには出ない（BlockingSessionFactory）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore
@testable import VDModels

/// テスト 1 本分の準備。
private struct World {
    let tmp: TempDirectory
    let layout: HomeLayout
    let cache: ModelVerificationCache
    let manager: ModelManager

    /// TestCatalogs.minimal の whisper の項目（bytes 1、sha256 は "a" × 64）。
    var whisper: ModelEntry {
        get throws { try #require(TestCatalogs.minimal.entry(kind: .whisper, id: "large-v3-turbo-q5_0")) }
    }

    func url(_ e: ModelEntry, kind: ModelKind) -> URL {
        layout.modelFile(kind: kind.rawValue, file: e.file)
    }
}

/// sha256 と bytes を差し替えたカタログ（whisper 1 件）。
private func catalog(whisperSHA sha: String, bytes: Int) throws -> ModelCatalog {
    let commit = String(repeating: "0", count: 40)
    let json = """
        {"schema": 1,
         "whisper": [{"id": "w", "displayName": "w", "file": "w.bin", \
        "url": "https://huggingface.co/x/y/resolve/\(commit)/w.bin", \
        "sha256": "\(sha)", "bytes": \(bytes), "license": "MIT"}],
         "vad": [], "llm": []}
        """
    guard case .success(let c) = ModelCatalog.load(Data(json.utf8)) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return c
}

@Suite("ModelManager")
struct ModelManagerTests {
    private func world(
        catalog: ModelCatalog = TestCatalogs.minimal, factory: any DownloadSessionFactory = BlockingSessionFactory()
    ) throws -> World {
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url)
        try layout.createDirectories()
        let log = AppLog(
            sink: CapturingLogSink(), level: .debug, unsafeContent: false,
            zone: ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo"))),
            clock: FixedClock(epochMillis: 1_756_000_000_000))
        let downloader = ModelDownloader(
            layout: layout, factory: factory, log: log, hashChunkBytes: 1_048_576)
        let cache = ModelVerificationCache()
        let manager = ModelManager(
            layout: layout, catalog: catalog, downloader: downloader, cache: cache, log: log,
            hashChunkBytes: 1_048_576)
        return World(tmp: tmp, layout: layout, cache: cache, manager: manager)
    }

    /// custom:<sha> の置き場所（models/llm/custom-<sha の先頭 16>.gguf）。
    private func customURL(_ w: World, sha: String) -> URL {
        w.tmp.url.appendingPathComponent("models/llm/custom-\(sha.prefix(16)).gguf")
    }

    @Test("ファイルが無ければ absent")
    func absentWhenMissing() async throws {
        let w = try world()
        #expect(await w.manager.state(kind: .whisper, id: "large-v3-turbo-q5_0") == .absent)
    }

    @Test("在って size が一致すれば present")
    func presentWhenSizeMatches() async throws {
        let w = try world()
        try Data(count: 1).write(to: w.url(try w.whisper, kind: .whisper))
        #expect(await w.manager.state(kind: .whisper, id: "large-v3-turbo-q5_0") == .present)
    }

    @Test("size が違えば absent（速い判定）")
    func wrongSizeIsAbsent() async throws {
        let w = try world()
        try Data().write(to: w.url(try w.whisper, kind: .whisper))
        #expect(await w.manager.state(kind: .whisper, id: "large-v3-turbo-q5_0") == .absent)
    }

    @Test("知らない ID は absent")
    func unknownIDIsAbsent() async throws {
        let w = try world()
        #expect(await w.manager.state(kind: .whisper, id: "nope") == .absent)
        #expect(await w.manager.url(kind: .whisper, id: "nope") == nil)
    }

    @Test("custom:<sha> は models/llm/custom-<16>.gguf を指す")
    func customIDResolves() async throws {
        let w = try world()
        let sha = String(repeating: "c", count: 64)
        let file = customURL(w, sha: sha)
        try Data([1, 2, 3]).write(to: file)
        #expect(await w.manager.url(kind: .llm, id: "custom:" + sha) == file)
        #expect(await w.manager.state(kind: .llm, id: "custom:" + sha) == .present)
    }

    @Test("SHA が一致すれば真")
    func verifySHAMatches() async throws {
        let body = Data("model".utf8)
        let w = try world(catalog: try catalog(whisperSHA: FileHasher.sha256(body), bytes: body.count))
        try body.write(to: w.layout.modelFile(kind: "whisper", file: "w.bin"))
        #expect(await w.manager.verifySHA(kind: .whisper, id: "w"))
    }

    @Test("中身が違えば偽")
    func verifySHADetectsChange() async throws {
        let body = Data("model".utf8)
        let w = try world(catalog: try catalog(whisperSHA: FileHasher.sha256(body), bytes: body.count))
        try Data("other".utf8).write(to: w.layout.modelFile(kind: "whisper", file: "w.bin"))
        #expect(await w.manager.verifySHA(kind: .whisper, id: "w") == false)
    }

    @Test("同じ (inode,size,mtime) なら 2 回目は読み直さない")
    func verifySHAUsesTheCache() async throws {
        let body = Data("model".utf8)
        let w = try world(catalog: try catalog(whisperSHA: FileHasher.sha256(body), bytes: body.count))
        let file = w.layout.modelFile(kind: "whisper", file: "w.bin")
        try body.write(to: file)
        #expect(await w.manager.verifySHA(kind: .whisper, id: "w"))
        #expect(chmod(file.path(percentEncoded: false), 0o000) == 0)
        defer { _ = chmod(file.path(percentEncoded: false), 0o644) }
        #expect(await w.manager.verifySHA(kind: .whisper, id: "w"))
    }

    @Test("mtime が変われば読み直す")
    func verifySHARecomputesAfterTouch() async throws {
        let body = Data("model".utf8)
        let w = try world(catalog: try catalog(whisperSHA: FileHasher.sha256(body), bytes: body.count))
        let file = w.layout.modelFile(kind: "whisper", file: "w.bin")
        try body.write(to: file)
        #expect(await w.manager.verifySHA(kind: .whisper, id: "w"))
        // 同じ大きさ・同じ inode のまま中身を書き換え、mtime を確実に進める。
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("MODEL".utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)],
            ofItemAtPath: file.path(percentEncoded: false))
        #expect(await w.manager.verifySHA(kind: .whisper, id: "w") == false)
    }

    @Test("custom の期待値は ID の中の sha")
    func verifySHAOfCustomUsesTheID() async throws {
        let w = try world()
        let body = Data("custom model".utf8)
        let src = w.tmp.url.appendingPathComponent("in.gguf")
        try body.write(to: src)
        let imported = try await w.manager.importCustomLLM(from: src).get()
        #expect(await w.manager.verifySHA(kind: .llm, id: imported.id))
        // 先頭 16 桁（ファイル名）を保ったまま最後の 1 文字だけ変える。
        let last = imported.id.last == "0" ? "1" : "0"
        let changed = String(imported.id.dropLast()) + last
        #expect(await w.manager.verifySHA(kind: .llm, id: changed) == false)
    }

    @Test("無いファイルは偽（TEST-28）")
    func verifySHAOfMissingIsFalse() async throws {
        let body = Data("model".utf8)
        let w = try world(catalog: try catalog(whisperSHA: FileHasher.sha256(body), bytes: body.count))
        #expect(await w.manager.verifySHA(kind: .whisper, id: "w") == false)
        let path = w.layout.modelFile(kind: "whisper", file: "w.bin").path(percentEncoded: false)
        #expect(await w.cache.verifiedSHA256(path: path, inode: 0, size: 0, mtime: 0) == nil)
        try body.write(to: w.layout.modelFile(kind: "whisper", file: "w.bin"))
        var info = stat()
        #expect(stat(path, &info) == 0)
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        #expect(
            await w.cache.verifiedSHA256(
                path: path, inode: UInt64(info.st_ino), size: Int64(info.st_size), mtime: mtime) == nil)
    }

    @Test("失敗すると failed に日本語が出る")
    func failureIsShownAsAMessage() async throws {
        let w = try world()
        let r = await w.manager.download("large-v3-turbo-q5_0", kind: .whisper, progress: { _, _ in })
        #expect(r == .failure(.network))
        #expect(
            await w.manager.state(kind: .whisper, id: "large-v3-turbo-q5_0") == .failed("ネットワークに接続できませんでした"))
    }

    @Test("もう一度押すと失敗表示が消える")
    func downloadClearsThePreviousFailure() async throws {
        let w = try world()
        _ = await w.manager.download("large-v3-turbo-q5_0", kind: .whisper, progress: { _, _ in })
        let file = w.url(try w.whisper, kind: .whisper)
        try Data(count: 1).write(to: file)
        let r = await w.manager.download("large-v3-turbo-q5_0", kind: .whisper, progress: { _, _ in })
        #expect(r == .success(file))
        #expect(await w.manager.state(kind: .whisper, id: "large-v3-turbo-q5_0") == .present)
    }

    @Test("落としている最中にもう一度押しても状態を変えずに断る")
    func secondDownloadIsRefusedWithoutTouchingState() async throws {
        let w = try world(factory: ModelHostSessionFactory())
        let e = try w.whisper
        let gate = Gate()
        defer { gate.open() }
        ModelHostStub.register(url: e.url) {
            gate.wait()
            return .body(Data(count: 1))
        }
        defer { ModelHostStub.unregister(url: e.url) }
        let first = Task { await w.manager.download(e.id, kind: .whisper, progress: { _, _ in }) }
        for _ in 0..<1_000 where ModelHostStub.requests(url: e.url) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let second = await w.manager.download(e.id, kind: .whisper, progress: { _, _ in })
        #expect(second == .failure(.io("already_downloading")))
        #expect(await w.manager.state(kind: .whisper, id: e.id) == .downloading(0.0))
        gate.open()
        _ = await first.value
        #expect(ModelHostStub.requests(url: e.url) == 1)
    }

    @Test(
        "32 GB のモデルは 32 GiB 必要",
        arguments: [(UInt64(34_359_738_367), false), (UInt64(34_359_738_368), true)])
    func meetsMemoryUsesGiB(physicalMemoryBytes: UInt64, expected: Bool) {
        let e = ModelEntry(
            id: "big", displayName: "big", file: "big.gguf",
            url: "https://huggingface.co/x/y/resolve/\(String(repeating: "0", count: 40))/big.gguf",
            sha256: String(repeating: "a", count: 64), bytes: 1, license: "MIT", minMemoryGB: 32, verified: true)
        #expect(ModelManager.meetsMemory(e, physicalMemoryBytes: physicalMemoryBytes) == expected)
    }

    @Test("minMemoryGB が無ければ常に真")
    func meetsMemoryIsTrueWithoutLimit() throws {
        let e = try #require(TestCatalogs.minimal.entry(kind: .whisper, id: "large-v3-turbo-q5_0"))
        #expect(ModelManager.meetsMemory(e, physicalMemoryBytes: 0))
    }
}
