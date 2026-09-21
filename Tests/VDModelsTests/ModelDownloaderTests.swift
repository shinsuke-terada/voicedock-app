// ModelDownloader のテスト（T-23 §5.1）。ネットワークには出ない（ModelHostSessionFactory / BlockingSessionFactory）。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract

@testable import VDCore
@testable import VDModels

/// テスト 1 本分の準備。
private struct World {
    let tmp: TempDirectory
    let layout: HomeLayout
    let sink: CapturingLogSink
    let log: AppLog
    let entry: ModelEntry

    var final: URL { layout.modelFile(kind: "whisper", file: entry.file) }
    var part: URL { layout.modelPart(kind: "whisper", file: entry.file) }
    var resume: URL { layout.modelResume(file: entry.file) }

    func downloader(
        _ factory: any DownloadSessionFactory = ModelHostSessionFactory(), hashChunkBytes: Int = 1_048_576
    ) -> ModelDownloader {
        ModelDownloader(layout: layout, factory: factory, log: log, hashChunkBytes: hashChunkBytes)
    }

    /// 同じ ID・同じファイル名で url・file・sha256・bytes を差し替えた項目。
    func with(url: String? = nil, file: String? = nil, sha256: String? = nil, bytes: Int64? = nil) -> ModelEntry {
        ModelEntry(
            id: entry.id, displayName: entry.displayName, file: file ?? entry.file, url: url ?? entry.url,
            sha256: sha256 ?? entry.sha256, bytes: bytes ?? entry.bytes, license: entry.license, minMemoryGB: nil,
            verified: nil)
    }

    func lines(containing text: String) -> [String] {
        sink.lines.filter { $0.contains(text) }
    }
}

/// 待ち合わせ（URLProtocol の読み込みのスレッドを止めておく）。open() で待っている者を全部放す。
/// open() は何度呼んでもよい（leave は 1 回だけ）。テストは `defer { gate.open() }` を置いて止まったままにしない。
final class Gate: Sendable {
    private let group = DispatchGroup()
    private let opened = Mutex(false)
    init() { group.enter() }
    func wait() { group.wait() }
    func open() {
        let first = opened.withLock { o in
            defer { o = true }
            return !o
        }
        if first { group.leave() }
    }
}

@Suite("ModelDownloader")
struct ModelDownloaderTests {
    static let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })
    static let commit = String(repeating: "0", count: 40)

    /// テストごとに別の URL（ModelHostStub は URL で引く）。
    private func world(_ repo: String) throws -> World {
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url)
        try layout.createDirectories()
        let sink = CapturingLogSink()
        let log = AppLog(
            sink: sink, level: .debug, unsafeContent: false,
            zone: ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo"))),
            clock: FixedClock(epochMillis: 1_756_000_000_000))
        let entry = ModelEntry(
            id: "test-whisper", displayName: "T", file: "ggml-t.bin",
            url: "https://huggingface.co/a/\(repo)/resolve/\(Self.commit)/ggml-t.bin",
            sha256: FileHasher.sha256(Self.payload), bytes: Int64(Self.payload.count),
            license: "MIT", minMemoryGB: nil, verified: nil)
        return World(tmp: tmp, layout: layout, sink: sink, log: log, entry: entry)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func contents(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).sorted()
    }

    /// 条件が真になるまで短く待つ（上限 10 秒）。
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test("落として SHA とサイズを照合して置く")
    func downloadsAndVerifies() async throws {
        let w = try world("downloads-and-verifies")
        ModelHostStub.register(url: w.entry.url) { .body(Self.payload) }
        defer { ModelHostStub.unregister(url: w.entry.url) }
        let r = await w.downloader().download(w.entry, kind: .whisper, progress: { _, _ in })
        #expect(r == .success(w.tmp.url.appendingPathComponent("models/whisper/ggml-t.bin")))
        #expect(try Data(contentsOf: w.final) == Self.payload)
        #expect(!exists(w.part))
        #expect(!exists(w.resume))
        #expect(w.lines(containing: " model_downloaded id=test-whisper").count == 1)
        #expect(w.sink.lines.count == 1)
    }

    @Test("進捗は最後に全体と一致する")
    func progressReachesTheTotal() async throws {
        let w = try world("progress-reaches-the-total")
        ModelHostStub.register(url: w.entry.url) { .body(Self.payload) }
        defer { ModelHostStub.unregister(url: w.entry.url) }
        let seen = Mutex<[(Int64, Int64)]>([])
        let r = await w.downloader().download(
            w.entry, kind: .whisper, progress: { written, total in seen.withLock { $0.append((written, total)) } })
        #expect(r == .success(w.final))
        let values = seen.withLock { $0 }
        let last = try #require(values.last)
        #expect(last.0 == 3_000_000)
        #expect(last.1 == 3_000_000)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.0 <= $1.0 })
    }

    @Test("SHA が違えば .part を消して失敗")
    func shaMismatchRemovesThePart() async throws {
        let w = try world("sha-mismatch-removes-the-part")
        let e = w.with(sha256: String(repeating: "b", count: 64))
        ModelHostStub.register(url: e.url) { .body(Self.payload) }
        defer { ModelHostStub.unregister(url: e.url) }
        let r = await w.downloader().download(e, kind: .whisper, progress: { _, _ in })
        #expect(r == .failure(.sha256Mismatch))
        #expect(try contents(w.layout.models(kind: "whisper")).isEmpty)
        #expect(w.lines(containing: " model_download_failed id=test-whisper reason=sha256_mismatch").count == 1)
    }

    @Test("サイズ違いは SHA より先に落とす")
    func sizeMismatchIsDetectedBeforeHashing() async throws {
        let w = try world("size-mismatch-before-hashing")
        let e = w.with(bytes: 3_000_001)
        ModelHostStub.register(url: e.url) { .body(Self.payload) }
        defer { ModelHostStub.unregister(url: e.url) }
        let r = await w.downloader().download(e, kind: .whisper, progress: { _, _ in })
        #expect(r == .failure(.sizeMismatch))
        #expect(w.lines(containing: " model_download_failed id=test-whisper reason=size_mismatch").count == 1)
        #expect(!exists(w.part))
    }

    @Test("2xx でなければ http_<code>")
    func httpErrorIsReported() async throws {
        let w = try world("http-error-is-reported")
        ModelHostStub.register(url: w.entry.url) { .http(status: 404, body: Data("no".utf8)) }
        defer { ModelHostStub.unregister(url: w.entry.url) }
        let r = await w.downloader().download(w.entry, kind: .whisper, progress: { _, _ in })
        #expect(r == .failure(.http(404)))
        #expect(w.lines(containing: " model_download_failed id=test-whisper reason=http_404").count == 1)
        #expect(!exists(w.part))
        #expect(!exists(w.final))
    }

    @Test("接続できなければ network")
    func networkFailureIsReported() async throws {
        let w = try world("network-failure-is-reported")
        ModelHostStub.register(url: w.entry.url) { .failure(.cannotConnectToHost) }
        defer { ModelHostStub.unregister(url: w.entry.url) }
        let r = await w.downloader().download(w.entry, kind: .whisper, progress: { _, _ in })
        #expect(r == .failure(.network))
        #expect(w.lines(containing: " model_download_failed id=test-whisper reason=network").count == 1)
    }

    @Test("BlockingURLProtocol では必ず失敗する（TEST-12）")
    func blockedFactoryNeverLeavesTheMachine() async throws {
        let w = try world("blocked")
        let e = w.with(
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(Self.commit)/ggml-t.bin")
        let r = await w.downloader(BlockingSessionFactory()).download(e, kind: .whisper, progress: { _, _ in })
        #expect(r == .failure(.network))
        #expect(!exists(w.part))
    }

    @Test("ホストが違えば要求を出さない")
    func badHostIsRejectedBeforeAnyRequest() async throws {
        let w = try world("bad-host")
        let e = w.with(url: "https://example.com/x/y/resolve/\(Self.commit)/ggml-t.bin")
        ModelHostStub.register(url: e.url) { .body(Self.payload) }
        defer { ModelHostStub.unregister(url: e.url) }
        let r = await w.downloader().download(e, kind: .whisper, progress: { _, _ in })
        #expect(r == .failure(.badHost))
        #expect(ModelHostStub.requests(url: e.url) == 0)
        #expect(w.lines(containing: " model_download_failed id=test-whisper reason=bad_url").count == 1)
    }

    @Test("resolve/main は受けない（PT-13 と同じ条件）")
    func mainInsteadOfCommitIsRejected() async throws {
        let w = try world("main-instead-of-commit")
        let e = w.with(url: "https://huggingface.co/a/main-instead-of-commit/resolve/main/ggml-t.bin")
        ModelHostStub.register(url: e.url) { .body(Self.payload) }
        defer { ModelHostStub.unregister(url: e.url) }
        let r = await w.downloader().download(e, kind: .whisper, progress: { _, _ in })
        #expect(r == .failure(.badHost))
        #expect(ModelHostStub.requests(url: e.url) == 0)
    }

    @Test("url の末尾がファイル名と違えば受けない")
    func fileNameMismatchIsRejected() async throws {
        let w = try world("file-name-mismatch")
        let e = w.with(url: "https://huggingface.co/a/file-name-mismatch/resolve/\(Self.commit)/other.bin")
        ModelHostStub.register(url: e.url) { .body(Self.payload) }
        defer { ModelHostStub.unregister(url: e.url) }
        let r = await w.downloader().download(e, kind: .whisper, progress: { _, _ in })
        #expect(r == .failure(.badHost))
        #expect(ModelHostStub.requests(url: e.url) == 0)
    }

    @Test("`..` を含むファイル名は受けない（OPS-19）")
    func unsafeFileNameIsRejected() async throws {
        let w = try world("unsafe-file-name")
        let e = w.with(
            url: "https://huggingface.co/a/unsafe-file-name/resolve/\(Self.commit)/../x.bin", file: "../x.bin")
        ModelHostStub.register(url: e.url) { .body(Self.payload) }
        defer { ModelHostStub.unregister(url: e.url) }
        let r = await w.downloader().download(e, kind: .whisper, progress: { _, _ in })
        #expect(r == .failure(.badFileName))
        #expect(ModelHostStub.requests(url: e.url) == 0)
        #expect(w.lines(containing: " model_download_failed id=test-whisper reason=bad_file_name").count == 1)
        // "." で始まらない `..` も受けない。
        let inner = w.with(
            url: "https://huggingface.co/a/unsafe-file-name/resolve/\(Self.commit)/ggml..t.bin", file: "ggml..t.bin")
        ModelHostStub.register(url: inner.url) { .body(Self.payload) }
        defer { ModelHostStub.unregister(url: inner.url) }
        let r2 = await w.downloader().download(inner, kind: .whisper, progress: { _, _ in })
        #expect(r2 == .failure(.badFileName))
        #expect(ModelHostStub.requests(url: inner.url) == 0)
    }

    @Test("在って size が一致すれば落とさない")
    func presentFileSkipsTheNetwork() async throws {
        let w = try world("present-file-skips")
        try Self.payload.write(to: w.final)
        ModelHostStub.register(url: w.entry.url) { .body(Self.payload) }
        defer { ModelHostStub.unregister(url: w.entry.url) }
        let r = await w.downloader().download(w.entry, kind: .whisper, progress: { _, _ in })
        #expect(r == .success(w.final))
        #expect(ModelHostStub.requests(url: w.entry.url) == 0)
        #expect(w.lines(containing: "model_downloaded").isEmpty)
    }

    @Test("使わない `.resume` は消える")
    func staleResumeIsRemovedWhenUnused() async throws {
        let w = try world("stale-resume")
        try Data(repeating: 7, count: 15).write(to: w.resume)
        // 要求が届いた時点（読んだ直後）で既に消えていること。
        let resume = w.resume
        let seen = Mutex<Bool?>(nil)
        ModelHostStub.register(url: w.entry.url) {
            seen.withLock { $0 = FileManager.default.fileExists(atPath: resume.path(percentEncoded: false)) }
            return .body(Self.payload)
        }
        defer { ModelHostStub.unregister(url: w.entry.url) }
        let r = await w.downloader().download(w.entry, kind: .whisper, progress: { _, _ in })
        #expect(r == .success(w.final))
        #expect(seen.withLock { $0 } == false)
        #expect(!exists(w.resume))
    }

    @Test("再開しないときは古い `.part` を捨てる")
    func stalePartIsRemovedBeforeStart() async throws {
        let w = try world("stale-part")
        try Data(repeating: 9, count: 10).write(to: w.part)
        // 要求が届いた時点（始める前）で既に消えていること。
        let part = w.part
        let seen = Mutex<Bool?>(nil)
        ModelHostStub.register(url: w.entry.url) {
            seen.withLock { $0 = FileManager.default.fileExists(atPath: part.path(percentEncoded: false)) }
            return .body(Self.payload)
        }
        defer { ModelHostStub.unregister(url: w.entry.url) }
        let r = await w.downloader().download(w.entry, kind: .whisper, progress: { _, _ in })
        #expect(r == .success(w.final))
        #expect(seen.withLock { $0 } == false)
        #expect(try Data(contentsOf: w.final) == Self.payload)
    }

    @Test("キャンセルは cancelled でログを出さない")
    func cancelStopsAndDoesNotLog() async throws {
        let w = try world("cancel-stops")
        let big = Data(count: 32 * 1_048_576)
        let e = w.with(sha256: FileHasher.sha256(big), bytes: Int64(big.count))
        let gate = Gate()
        defer { gate.open() }
        ModelHostStub.register(url: e.url) {
            gate.wait()
            return .body(big)
        }
        defer { ModelHostStub.unregister(url: e.url) }
        let downloader = w.downloader()
        let running = Task { await downloader.download(e, kind: .whisper, progress: { _, _ in }) }
        try await waitUntil { ModelHostStub.requests(url: e.url) == 1 }
        await downloader.cancel(id: e.id)
        gate.open()
        let r = await running.value
        #expect(r == .failure(.cancelled))
        #expect(w.lines(containing: "model_download_failed").isEmpty)
        #expect(!exists(w.final))
    }

    @Test("同じ ID の二重実行は断る")
    func twoDownloadsOfTheSameIDAreRefused() async throws {
        let w = try world("two-downloads")
        let gate = Gate()
        defer { gate.open() }
        ModelHostStub.register(url: w.entry.url) {
            gate.wait()
            return .body(Self.payload)
        }
        defer { ModelHostStub.unregister(url: w.entry.url) }
        let downloader = w.downloader()
        let first = Task { await downloader.download(w.entry, kind: .whisper, progress: { _, _ in }) }
        try await waitUntil { ModelHostStub.requests(url: w.entry.url) == 1 }
        // 2 本目が要求を出してしまっても止まらないよう、2 本目も Task で走らせてから門を開ける。
        let finished = Mutex(false)
        let second = Task {
            let r = await downloader.download(w.entry, kind: .whisper, progress: { _, _ in })
            finished.withLock { $0 = true }
            return r
        }
        try await waitUntil { finished.withLock { $0 } || ModelHostStub.requests(url: w.entry.url) >= 2 }
        gate.open()
        #expect(await second.value == .failure(.io("already_downloading")))
        #expect(await first.value == .success(w.final))
    }

    @Test("照合中の同じ ID は通さない（.part を消さず、要求も出さない）")
    func secondDownloadWaitsForVerification() async throws {
        let w = try world("second-waits-for-verification")
        let big = Data(count: 64 * 1_048_576)
        let e = w.with(sha256: FileHasher.sha256(big), bytes: Int64(big.count))
        ModelHostStub.register(url: e.url) { .body(big) }
        defer { ModelHostStub.unregister(url: e.url) }
        // 小さな単位で読ませて照合を長くする。
        let downloader = w.downloader(hashChunkBytes: 4096)
        let first = Task { await downloader.download(e, kind: .whisper, progress: { _, _ in }) }
        // .part に移された（= 照合に入る直前か照合中）ところで 2 本目。
        let part = w.part
        for _ in 0..<10_000 where !FileManager.default.fileExists(atPath: part.path(percentEncoded: false)) {
            try await Task.sleep(for: .milliseconds(1))
        }
        let second = await downloader.download(e, kind: .whisper, progress: { _, _ in })
        // 1 本目がまだなら断られ、終わっていれば「既に在る」。どちらでも要求は 1 件だけ。
        #expect(second == .failure(.io("already_downloading")) || second == .success(w.final))
        #expect(await first.value == .success(w.final))
        #expect(ModelHostStub.requests(url: e.url) == 1)
    }

    @Test("クエリ・フラグメント付きの URL は受けない")
    func queryOrFragmentIsRejected() async throws {
        let w = try world("query-or-fragment")
        let base = "https://huggingface.co/a/query-or-fragment/resolve/\(Self.commit)"
        for url in ["\(base)/ggml-t.bin?x=/ggml-t.bin", "\(base)/ggml-t.bin#/ggml-t.bin", "\(base)/x?a=/ggml-t.bin"] {
            let e = w.with(url: url)
            ModelHostStub.register(url: e.url) { .body(Self.payload) }
            defer { ModelHostStub.unregister(url: e.url) }
            let r = await w.downloader().download(e, kind: .whisper, progress: { _, _ in })
            #expect(r == .failure(.badHost), "\(url)")
            #expect(ModelHostStub.requests(url: e.url) == 0, "\(url)")
        }
    }

    @Test("空の応答はサイズ違い（TEST-28）")
    func emptyBodyIsASizeMismatch() async throws {
        let w = try world("empty-body")
        ModelHostStub.register(url: w.entry.url) { .body(Data()) }
        defer { ModelHostStub.unregister(url: w.entry.url) }
        let r = await w.downloader().download(w.entry, kind: .whisper, progress: { _, _ in })
        #expect(r == .failure(.sizeMismatch))
    }
}
