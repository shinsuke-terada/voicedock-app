// ダウンロードの再開データを結末まで残すこと・止めて再開データを保存する口・照合したファイルの書き出しのテスト
// （F-83。PLAN §8.10。issue #119 の F6・F10）。ネットワークには出ない（ResumableHostURLProtocol は URL ごとに応答を決め、それ以外は失敗させる）。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract

@testable import VDCore
@testable import VDModels

/// 最初の要求には途中まで返して止まり（ETag・Accept-Ranges・Last-Modified を付けるので URLSession が再開データを作る）、
/// 再開の要求（Range 付き）には残りを 206 で返す（rangeStatus を決めればその状態の誤り）。2 本目以降の要求には全部を 200 で返す。
/// **ネットワークには決して出ない**（登録の無い URL・URL の無い要求は失敗させる）。
final class ResumableHostURLProtocol: URLProtocol {
    struct Host {
        let payload: Data
        let half: Int
        /// 再開の要求が届いた時点で在るかを見るファイル（`.resume`）
        let watched: URL
        /// 最初の（Range の無い）要求を途中で止めるか
        let stallFirst: Bool
        /// Range の要求に返す誤りの状態（nil なら 206 で残り）
        let rangeStatus: Int?
        /// 届いた再開の要求（Range の値と、その時点で watched が在ったか）
        var resumed: [String] = []
        var watchedExisted: [Bool] = []
        /// 届いた Range の無い要求の数
        var fresh = 0
    }

    static let hosts = Mutex<[String: Host]>([:])
    static let etag = "\"f83\""
    static let lastModified = "Wed, 23 Sep 2026 00:00:00 GMT"

    static func register(
        _ url: String, payload: Data, watched: URL, stallFirst: Bool = true, rangeStatus: Int? = nil
    ) {
        hosts.withLock {
            $0[url] = Host(
                payload: payload, half: payload.count / 2, watched: watched, stallFirst: stallFirst,
                rangeStatus: rangeStatus)
        }
    }

    static func unregister(_ url: String) {
        hosts.withLock { $0[url] = nil }
    }

    static func host(_ url: String) -> Host? {
        hosts.withLock { $0[url] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = Self.host(url.absoluteString) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let total = host.payload.count
        if let range = request.value(forHTTPHeaderField: "Range") {
            let existed = FileManager.default.fileExists(atPath: host.watched.path(percentEncoded: false))
            Self.hosts.withLock { hosts in
                hosts[url.absoluteString]?.resumed.append(range)
                hosts[url.absoluteString]?.watchedExisted.append(existed)
            }
            if let status = host.rangeStatus {
                respond(url, status: status, headers: ["Content-Length": "2"])
                client?.urlProtocol(self, didLoad: Data("no".utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let rest = host.payload.subdata(in: host.half..<total)
            respond(
                url, status: 206,
                headers: [
                    "Content-Length": "\(rest.count)", "Content-Range": "bytes \(host.half)-\(total - 1)/\(total)",
                ])
            client?.urlProtocol(self, didLoad: rest)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let count = Self.hosts.withLock { hosts -> Int in
            hosts[url.absoluteString]?.fresh += 1
            return hosts[url.absoluteString]?.fresh ?? 0
        }
        respond(url, status: 200, headers: ["Content-Length": "\(total)"])
        if host.stallFirst && count == 1 {
            // 前半だけ返して止まる（止めるのはテストの stopAllKeepingResumeData・cancel）
            client?.urlProtocol(self, didLoad: host.payload.subdata(in: 0..<host.half))
        } else {
            client?.urlProtocol(self, didLoad: host.payload)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private func respond(_ url: URL, status: Int, headers: [String: String]) {
        var fields = headers
        fields["ETag"] = Self.etag
        fields["Accept-Ranges"] = "bytes"
        fields["Last-Modified"] = Self.lastModified
        guard
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
}

struct ResumableHostSessionFactory: DownloadSessionFactory {
    func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResumableHostURLProtocol.self]
        return configuration
    }
}

@Suite("ModelDownloader（F-83）", .serialized, .timeLimit(.minutes(1)))
struct ModelDownloaderResumeTests {
    static let payload = Data((0..<200_000).map { UInt8($0 % 251) })
    static let commit = String(repeating: "0", count: 40)

    struct World {
        let tmp: TempDirectory
        let layout: HomeLayout
        let sink: CapturingLogSink
        let downloader: ModelDownloader
        let entry: ModelEntry

        var final: URL { layout.modelFile(kind: "whisper", file: entry.file) }
        var part: URL { layout.modelPart(kind: "whisper", file: entry.file) }
        var resume: URL { layout.modelResume(file: entry.file) }
    }

    func world(_ repo: String, factory: any DownloadSessionFactory = ResumableHostSessionFactory()) throws -> World {
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
        let downloader = ModelDownloader(layout: layout, factory: factory, log: log, hashChunkBytes: 4096)
        return World(tmp: tmp, layout: layout, sink: sink, downloader: downloader, entry: entry)
    }

    func size(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.size] as? Int
    }

    /// 条件が真になるまで短く待つ（上限 10 秒）。
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test("F-83 止めると再開データを .resume に書き終えてから戻り、次の起動のダウンロードはそこから再開する")
    func stopKeepsResumeDataAndTheNextDownloadResumes() async throws {
        let w = try world("f83-stop-and-resume")
        ResumableHostURLProtocol.register(w.entry.url, payload: Self.payload, watched: w.resume)
        defer { ResumableHostURLProtocol.unregister(w.entry.url) }
        let written = Mutex<Int64>(0)
        let downloader = w.downloader
        let entry = w.entry
        let first = Task {
            await downloader.download(entry, kind: .whisper, progress: { done, _ in written.withLock { $0 = done } })
        }
        try await waitUntil { written.withLock { $0 } >= 100_000 }
        await downloader.stopAllKeepingResumeData()
        // 戻った時点で書き終えている
        #expect((size(w.resume) ?? 0) >= 16)
        #expect(await first.value == .failure(.cancelled))
        #expect((size(w.resume) ?? 0) >= 16)
        #expect(w.sink.lines.filter { $0.contains("model_download_failed") }.isEmpty)

        // 次のダウンロード: 再開の要求の時点でも .resume は残っていて、残りの半分だけを受け取って完成する
        let second = await downloader.download(entry, kind: .whisper, progress: { _, _ in })
        #expect(second == .success(w.final))
        let host = try #require(ResumableHostURLProtocol.host(w.entry.url))
        #expect(host.resumed == ["bytes=100000-"])
        #expect(host.watchedExisted == [true])
        #expect(try Data(contentsOf: w.final) == Self.payload)
        #expect(size(w.resume) == nil)
        #expect(size(w.part) == nil)
        #expect(w.sink.lines.filter { $0.contains(" model_downloaded id=test-whisper") }.count == 1)
    }

    @Test("F-83 使える .resume は、再開の要求が届いた時点でも消さない（終了・クラッシュで途中経過を失わない）")
    func usableResumeSurvivesUntilTheOutcome() async throws {
        let w = try world("f83-resume-survives")
        ResumableHostURLProtocol.register(w.entry.url, payload: Self.payload, watched: w.resume)
        defer { ResumableHostURLProtocol.unregister(w.entry.url) }
        let written = Mutex<Int64>(0)
        let downloader = w.downloader
        let entry = w.entry
        let first = Task {
            await downloader.download(entry, kind: .whisper, progress: { done, _ in written.withLock { $0 = done } })
        }
        try await waitUntil { written.withLock { $0 } >= 100_000 }
        // 利用者の「中止」（cancel(id:)）でも再開データは .resume に残る
        await downloader.cancel(id: entry.id)
        #expect(await first.value == .failure(.cancelled))
        #expect((size(w.resume) ?? 0) >= 16)
        // 別の ModelDownloader（次の起動）で再開する
        let next = ModelDownloader(
            layout: w.layout, factory: ResumableHostSessionFactory(),
            log: AppLog(
                sink: w.sink, level: .debug, unsafeContent: false,
                zone: ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo"))),
                clock: FixedClock(epochMillis: 1_756_000_000_000)),
            hashChunkBytes: 4096)
        #expect(await next.download(entry, kind: .whisper, progress: { _, _ in }) == .success(w.final))
        #expect(ResumableHostURLProtocol.host(w.entry.url)?.watchedExisted == [true])
        #expect(size(w.resume) == nil)
    }

    /// 最初の要求を途中で止め、stopAllKeepingResumeData で .resume を残す
    func leaveResumeData(_ w: World) async throws {
        let written = Mutex<Int64>(0)
        let downloader = w.downloader
        let entry = w.entry
        let first = Task {
            await downloader.download(entry, kind: .whisper, progress: { done, _ in written.withLock { $0 = done } })
        }
        try await waitUntil { written.withLock { $0 } >= 100_000 }
        await downloader.stopAllKeepingResumeData()
        #expect(await first.value == .failure(.cancelled))
        #expect((size(w.resume) ?? 0) >= 16)
    }

    @Test("F-83 再開データの URL が今の URL と違えば、捨てて最初から落とす（別の URL へ Range の要求を出さない）")
    func resumeDataForAnotherURLIsDiscarded() async throws {
        let w = try world("f83-url-a")
        ResumableHostURLProtocol.register(w.entry.url, payload: Self.payload, watched: w.resume)
        defer { ResumableHostURLProtocol.unregister(w.entry.url) }
        try await leaveResumeData(w)
        let other = ModelEntry(
            id: w.entry.id, displayName: w.entry.displayName, file: w.entry.file,
            url: "https://huggingface.co/a/f83-url-b/resolve/\(Self.commit)/ggml-t.bin", sha256: w.entry.sha256,
            bytes: w.entry.bytes, license: w.entry.license, minMemoryGB: nil, verified: nil)
        ResumableHostURLProtocol.register(other.url, payload: Self.payload, watched: w.resume, stallFirst: false)
        defer { ResumableHostURLProtocol.unregister(other.url) }
        #expect(await w.downloader.download(other, kind: .whisper, progress: { _, _ in }) == .success(w.final))
        #expect(ResumableHostURLProtocol.host(w.entry.url)?.resumed == [])
        #expect(ResumableHostURLProtocol.host(other.url)?.resumed == [])
        #expect(ResumableHostURLProtocol.host(other.url)?.fresh == 1)
        #expect(size(w.resume) == nil)
    }

    @Test("F-83 読めない .resume（16 バイト以上の壊れた再開データ）は捨てて最初から落とす")
    func garbageResumeStartsFresh() async throws {
        let w = try world("f83-garbage")
        ResumableHostURLProtocol.register(w.entry.url, payload: Self.payload, watched: w.resume, stallFirst: false)
        defer { ResumableHostURLProtocol.unregister(w.entry.url) }
        try Data(repeating: 7, count: 64).write(to: w.resume)
        #expect(await w.downloader.download(w.entry, kind: .whisper, progress: { _, _ in }) == .success(w.final))
        #expect(ResumableHostURLProtocol.host(w.entry.url)?.fresh == 1)
        #expect(size(w.resume) == nil)
    }

    @Test("F-83 再開の要求が HTTP の誤り（403）で終わったら、最初から 1 回だけやり直す")
    func expiredResumeRestartsOnce() async throws {
        let w = try world("f83-expired")
        ResumableHostURLProtocol.register(w.entry.url, payload: Self.payload, watched: w.resume, rangeStatus: 403)
        defer { ResumableHostURLProtocol.unregister(w.entry.url) }
        try await leaveResumeData(w)
        #expect(await w.downloader.download(w.entry, kind: .whisper, progress: { _, _ in }) == .success(w.final))
        let host = try #require(ResumableHostURLProtocol.host(w.entry.url))
        #expect(host.resumed == ["bytes=100000-"])
        #expect(host.fresh == 2)
        #expect(try Data(contentsOf: w.final) == Self.payload)
        #expect(w.sink.lines.filter { $0.contains("model_download_failed") }.isEmpty)
        #expect(w.sink.lines.filter { $0.contains(" model_downloaded id=test-whisper") }.count == 1)
    }

    @Test("F-83 走っていなければ止めても何も書かない（TEST-28）")
    func stopWithoutDownloadsDoesNothing() async throws {
        let w = try world("f83-idle", factory: BlockingSessionFactory())
        await w.downloader.stopAllKeepingResumeData()
        let names = try FileManager.default.contentsOfDirectory(
            atPath: w.layout.modelsDirectory.path(percentEncoded: false))
        #expect(names.filter { $0.hasSuffix(".resume") }.isEmpty)
    }

    // MARK: - ModelFileSync（F10）

    @Test("F-83 照合したファイルは書き出せる（通常のファイル）")
    func syncFileSucceeds() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent(".w.bin.part")
        try Data("x".utf8).write(to: url)
        #expect(ModelFileSync.syncFile(url) == nil)
    }

    @Test("F-83 無いファイルは ENOENT、symlink は辿らずに ELOOP")
    func syncFileReportsErrno() throws {
        let tmp = try TempDirectory()
        let missing = tmp.url.appendingPathComponent("missing")
        #expect(ModelFileSync.syncFile(missing) == ENOENT)
        let target = tmp.url.appendingPathComponent("target")
        try Data("x".utf8).write(to: target)
        let link = tmp.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(ModelFileSync.syncFile(link) == ELOOP)
    }
}
