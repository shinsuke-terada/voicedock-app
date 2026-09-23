// LLM の HTTP がリダイレクトに従わないこと（PLAN §8.5。F-79・issue #118 の E3）。
// 既定の URLSession は 3xx の Location へ本文と Authorization を付けたまま送り直す（外部の https でも）。
// 写し方は差し替えの応答（LoopbackStub）で、リダイレクトに従わないことは 127.0.0.1 の本物の HTTP サーバ（このファイルの
// LoopbackHTTPServer。転送先もループバック）で確かめる。ループバック以外への要求は OffLoopbackBlocker が失敗させる（TEST-12）。
import Darwin
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDLLM

/// ループバック以外への要求だけを引き受けて失敗させる URLProtocol（127.0.0.1 は本物の HTTP の経路に任せる。TEST-12）。
private final class OffLoopbackBlocker: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host(percentEncoded: false) != LoopbackEndpoint.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// 本番の設定（EphemeralSessionFactory）の先頭に OffLoopbackBlocker を置いたファクトリ。
private struct LoopbackOnlySessionFactory: LoopbackSessionFactory {
    func configuration() -> URLSessionConfiguration {
        let configuration = EphemeralSessionFactory().configuration()
        configuration.protocolClasses = [OffLoopbackBlocker.self] + (configuration.protocolClasses ?? [])
        return configuration
    }
}

/// 127.0.0.1 の本物の HTTP/1.1 サーバ（1 接続に 1 応答して閉じる）。受けた要求の行と本文を記録する。
private final class LoopbackHTTPServer: Sendable {
    struct Received: Sendable {
        let requestLine: String
        let headerLines: [String]
        let body: Data
    }

    struct Reply: Sendable {
        let status: Int
        let headerLines: [String]
        let body: Data
    }

    let port: UInt16
    private let listener: Int32
    private let stopped = Mutex(false)
    private let finished = DispatchSemaphore(value: 0)
    private let log = Mutex<[Received]>([])
    private let reply: @Sendable (Received) -> Reply

    /// bind と listen に失敗したら nil
    init?(reply: @escaping @Sendable (Received) -> Reply) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in getsockname(fd, raw, &length) }
        }
        guard bound == 0, named == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        listener = fd
        port = UInt16(bigEndian: assigned.sin_port)
        self.reply = reply
        Thread.detachNewThread { [self] in serve() }
    }

    var received: [Received] { log.withLock { $0 } }

    /// 受け付けを止め、受け付けの糸が終わるのを待ってから閉じる
    func stop() {
        stopped.withLock { $0 = true }
        finished.wait()
        close(listener)
    }

    /// poll で 50 ms ごとに止める印を見る（accept に閉じたソケットを渡さない）
    private func serve() {
        defer { finished.signal() }
        while !stopped.withLock({ $0 }) {
            var entry = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&entry, 1, 50) > 0 else { continue }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { continue }
            handle(connection)
            close(connection)
        }
    }

    private func handle(_ connection: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = recv(connection, &chunk, chunk.count, 0)
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
            headerEnd = buffer.range(of: separator)
        }
        guard let end = headerEnd else { return }
        let lines = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let headerLines = Array(lines.dropFirst())
        let length =
            headerLines.compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }.first ?? 0
        var body = Data(buffer[end.upperBound...])
        while body.count < length {
            let n = recv(connection, &chunk, chunk.count, 0)
            guard n > 0 else { break }
            body.append(contentsOf: chunk[0..<n])
        }
        let request = Received(requestLine: lines.first ?? "", headerLines: headerLines, body: body)
        log.withLock { $0.append(request) }
        let answer = reply(request)
        var head = "HTTP/1.1 \(answer.status) X\r\n"
        for line in answer.headerLines + ["Content-Length: \(answer.body.count)", "Connection: close"] {
            head += line + "\r\n"
        }
        let bytes = [UInt8](Data((head + "\r\n").utf8) + answer.body)
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { return }
            sent += n
        }
    }
}

@Suite("LoopbackRedirect", .serialized, .timeLimit(.minutes(1)))
struct LoopbackRedirectTests {
    static let apiKey = String(repeating: "k", count: 32)
    static let okBody = #"{"choices":[{"message":{"content":"{}"}}]}"#

    static func transport(port: UInt16, factory: any LoopbackSessionFactory) throws -> LoopbackChatTransport {
        LoopbackChatTransport(
            endpoint: try #require(LoopbackEndpoint(port: port)), apiKey: apiKey, modelID: "m-id",
            config: AppConfig.defaults(timeZone: "Asia/Tokyo").llm, factory: factory)
    }

    /// 転送先（B）と、B へのリダイレクトを返すサーバ（A）を立てて body を行い、終わったら止める
    private static func withRedirect(
        status: Int, redirectBody: String, targetPath: String,
        _ body: (_ source: LoopbackHTTPServer, _ target: LoopbackHTTPServer) async throws -> Void
    ) async throws {
        let target = try #require(
            LoopbackHTTPServer { _ in .init(status: 200, headerLines: [], body: Data(Self.okBody.utf8)) })
        defer { target.stop() }
        let location = "http://127.0.0.1:\(target.port)" + targetPath
        let source = try #require(
            LoopbackHTTPServer { _ in
                .init(status: status, headerLines: ["Location: " + location], body: Data(redirectBody.utf8))
            })
        defer { source.stop() }
        try await body(source, target)
    }

    @Test(
        "F-79 3xx は LLM_UNAVAILABLE「HTTP <code>: <本文>」（差し替えの応答。パラメータ化: 301・302・303・307・308）",
        arguments: [301, 302, 303, 307, 308])
    func redirectStatusIsUnavailable(status: Int) async throws {
        let port = try #require(FreePort.pick())
        LoopbackStub.register(port: port) { _ in .http(status: status, body: Data("moved".utf8)) }
        defer { LoopbackStub.unregister(port: port) }
        #expect(
            try await Self.transport(port: port, factory: BlockingSessionFactory()).complete(system: "s", user: "u")
                == .failure(StageFailure(.llmUnavailable, "HTTP \(status): moved")))
    }

    @Test("F-79 2xx だけが成功（境界: 0・199・200・299・300・399・400）")
    func onlyTwoHundredsSucceed() {
        #expect(LoopbackChatTransport.succeeded(0) == false)
        #expect(LoopbackChatTransport.succeeded(199) == false)
        #expect(LoopbackChatTransport.succeeded(200) == true)
        #expect(LoopbackChatTransport.succeeded(299) == true)
        #expect(LoopbackChatTransport.succeeded(300) == false)
        #expect(LoopbackChatTransport.succeeded(399) == false)
        #expect(LoopbackChatTransport.succeeded(400) == false)
    }

    @Test("F-79 本物の HTTP でも 2xx は従来どおり content を取り出す（対照）")
    func realServerSuccessIsParsed() async throws {
        let server = try #require(
            LoopbackHTTPServer { _ in .init(status: 200, headerLines: [], body: Data(Self.okBody.utf8)) })
        defer { server.stop() }
        let result = try await Self.transport(port: server.port, factory: LoopbackOnlySessionFactory())
            .complete(system: "s", user: "u")
        #expect(result == .content("{}"))
        #expect(server.received.count == 1)
        #expect(server.received.first?.requestLine == "POST /v1/chat/completions HTTP/1.1")
    }

    @Test(
        "F-79 リダイレクトに従わず、本文と API キーを転送先に送らない（本物の HTTP。パラメータ化: 302・307・308）",
        arguments: [302, 307, 308])
    func redirectIsNotFollowed(status: Int) async throws {
        try await Self.withRedirect(status: status, redirectBody: "moved", targetPath: "/v1/chat/completions") {
            source, target in
            let result = try await Self.transport(port: source.port, factory: LoopbackOnlySessionFactory())
                .complete(system: "s", user: "本文")
            #expect(result == .failure(StageFailure(.llmUnavailable, "HTTP \(status): moved")))
            #expect(source.received.count == 1)
            #expect(source.received.first?.headerLines.contains("Authorization: Bearer " + Self.apiKey) == true)
            #expect(target.received.count == 0)
        }
    }

    @Test("F-79 本文の無い 3xx も失敗（「HTTP 307: 」）")
    func emptyRedirectBodyIsUnavailable() async throws {
        try await Self.withRedirect(status: 307, redirectBody: "", targetPath: "/v1/chat/completions") {
            source, target in
            let result = try await Self.transport(port: source.port, factory: LoopbackOnlySessionFactory())
                .complete(system: "s", user: "u")
            #expect(result == .failure(StageFailure(.llmUnavailable, "HTTP 307: ")))
            #expect(target.received.count == 0)
        }
    }

    @Test("F-79 /health の 3xx に従わず、そのステータスを返す（転送先の 200 を起動済みと見ない）")
    func healthRedirectIsNotFollowed() async throws {
        try await Self.withRedirect(status: 307, redirectBody: "", targetPath: "/health") { source, target in
            let endpoint = try #require(LoopbackEndpoint(port: source.port))
            #expect(await LoopbackHealth.check(endpoint, factory: LoopbackOnlySessionFactory()) == 307)
            #expect(source.received.first?.requestLine == "GET /health HTTP/1.1")
            #expect(target.received.count == 0)
        }
    }
}
