// LoopbackHTTP のテスト（T-21 §5.1）。ネットワークには出ない（BlockingSessionFactory）。
import Darwin
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess

@testable import VDLLM

/// configuration() が呼ばれた回数を数えるファクトリ。
private final class CountingSessionFactory: LoopbackSessionFactory {
    private let calls = Mutex(0)

    func configuration() -> URLSessionConfiguration {
        calls.withLock { $0 += 1 }
        return BlockingSessionFactory().configuration()
    }

    var count: Int { calls.withLock { $0 } }
}

@Suite("LoopbackHTTP")
struct LoopbackHTTPTests {
    static let modelID = "qwen3-30b-a3b-instruct-2507-q4_k_m"
    static let apiKey = String(repeating: "k", count: 32)

    static func defaultConfig() -> LLMConfig {
        AppConfig.defaults(timeZone: "Asia/Tokyo").llm
    }

    static func transport(port: UInt16, config: LLMConfig = defaultConfig()) throws -> LoopbackChatTransport {
        LoopbackChatTransport(
            endpoint: try #require(LoopbackEndpoint(port: port)), apiKey: apiKey, modelID: modelID, config: config,
            factory: BlockingSessionFactory())
    }

    static func reply(_ status: Int, _ body: String) -> @Sendable (StubRequest) -> StubReply {
        { _ in .http(status: status, body: Data(body.utf8)) }
    }

    static let okBody = #"{"choices":[{"message":{"content":"{}"}}]}"#

    /// 1 回 complete して、受けた要求の本文を辞書で返す。
    static func sentBody(config: LLMConfig) async throws -> [String: Any] {
        let port = try #require(FreePort.pick())
        LoopbackStub.register(port: port, reply(200, okBody))
        defer { LoopbackStub.unregister(port: port) }
        _ = try await transport(port: port, config: config).complete(system: "s", user: "u")
        let requests = LoopbackStub.requests(port: port)
        try #require(requests.count == 1)
        return try #require(try JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any])
    }

    @Test("URL は 127.0.0.1 固定")
    func endpointURLs() throws {
        let endpoint = try #require(LoopbackEndpoint(port: 8080))
        #expect(endpoint.chatCompletionsURL.absoluteString == "http://127.0.0.1:8080/v1/chat/completions")
        #expect(endpoint.healthURL.absoluteString == "http://127.0.0.1:8080/health")
        #expect(endpoint.port == 8080)
        #expect(LoopbackEndpoint.host == "127.0.0.1")
        #expect(LoopbackEndpoint(port: 0) == nil)
    }

    @Test("要求の形が voicedock と同じ")
    func requestMatchesTheSpec() async throws {
        let port = try #require(FreePort.pick())
        LoopbackStub.register(port: port, Self.reply(200, Self.okBody))
        defer { LoopbackStub.unregister(port: port) }
        let result = try await Self.transport(port: port).complete(system: "システム", user: "本文")
        #expect(result == .content("{}"))
        let requests = LoopbackStub.requests(port: port)
        try #require(requests.count == 1)
        let request = requests[0]
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://127.0.0.1:\(port)/v1/chat/completions")
        #expect(request.headers["Authorization"] == "Bearer kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk")
        #expect(request.headers["Content-Type"] == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(
            Set(body.keys) == ["model", "messages", "temperature", "top_p", "max_tokens", "response_format"])
        #expect(body["model"] as? String == "qwen3-30b-a3b-instruct-2507-q4_k_m")
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "システム"], ["role": "user", "content": "本文"]])
        #expect(body["temperature"] as? Double == 0.1)
        #expect(body["top_p"] as? Double == 0.9)
        #expect(body["max_tokens"] as? Int == 8192)
        #expect(body["response_format"] as? [String: String] == ["type": "json_object"])
    }

    @Test("CE llm.requestTimeoutSeconds がタイムアウトになる")
    func timeoutComesFromTheConfiguration() throws {
        let port = try #require(FreePort.pick())
        let standard = try Self.transport(port: port).makeConfiguration()
        #expect(standard.timeoutIntervalForRequest == 1800)
        #expect(standard.timeoutIntervalForResource == 1800)
        var config = Self.defaultConfig()
        config.requestTimeoutSeconds = 60
        let changed = try Self.transport(port: port, config: config)
        let configuration = changed.makeConfiguration()
        #expect(configuration.timeoutIntervalForRequest == 60)
        #expect(configuration.timeoutIntervalForResource == 60)
        #expect(changed.makeRequest(system: "s", user: "u")?.timeoutInterval == 60)
    }

    @Test("CE llm.temperature が本文に入る")
    func ceTemperature() async throws {
        var config = Self.defaultConfig()
        config.temperature = 0.7
        #expect(try await Self.sentBody(config: config)["temperature"] as? Double == 0.7)
        #expect(try await Self.sentBody(config: Self.defaultConfig())["temperature"] as? Double == 0.1)
    }

    @Test("CE llm.topP が本文の top_p に入る")
    func ceTopP() async throws {
        var config = Self.defaultConfig()
        config.topP = 0.5
        #expect(try await Self.sentBody(config: config)["top_p"] as? Double == 0.5)
        #expect(try await Self.sentBody(config: Self.defaultConfig())["top_p"] as? Double == 0.9)
    }

    @Test("CE llm.maxOutputTokens が本文の max_tokens に入る")
    func ceMaxOutputTokens() async throws {
        var config = Self.defaultConfig()
        config.maxOutputTokens = 256
        #expect(try await Self.sentBody(config: config)["max_tokens"] as? Int == 256)
        #expect(try await Self.sentBody(config: Self.defaultConfig())["max_tokens"] as? Int == 8192)
    }

    @Test("content を取り出す")
    func validResponseIsParsed() async throws {
        let port = try #require(FreePort.pick())
        LoopbackStub.register(
            port: port,
            Self.reply(200, #"{"choices":[{"message":{"content":"{\"a\":1}"}}],"usage":{"total_tokens":42}}"#))
        defer { LoopbackStub.unregister(port: port) }
        #expect(try await Self.transport(port: port).complete(system: "s", user: "u") == .content("{\"a\":1}"))
    }

    @Test("content の先頭の U+FEFF を落とさない（PyJSON.decode）")
    func contentKeepsLeadingBOM() async throws {
        let port = try #require(FreePort.pick())
        // JSON のエスケープ（バックスラッシュ 1 つ + ufeff）で U+FEFF を送る。
        let body = #"{"choices":[{"message":{"content":""# + "\\" + #"ufeff{}"}}]}"#
        LoopbackStub.register(port: port, Self.reply(200, body))
        defer { LoopbackStub.unregister(port: port) }
        let result = try await Self.transport(port: port).complete(system: "s", user: "u")
        guard case .content(let text) = result else {
            Issue.record("content ではない: \(result)")
            return
        }
        #expect(text.unicodeScalars.elementsEqual("\u{FEFF}{}".unicodeScalars))
    }

    @Test(
        "外形が壊れた応答は空文字（修復へ回す）",
        arguments: [
            #"{"choices":[]}"#, #"{"choices":[{}]}"#, #"{"choices":[{"message":{}}]}"#, #"{"choices":"nope"}"#, "{}",
            "[]", "<html>nope</html>", #"{"choices":[{"message":{"content":5}}]}"#, "",
        ])
    func malformedEnvelopeIsEmpty(body: String) async throws {
        let port = try #require(FreePort.pick())
        LoopbackStub.register(port: port, Self.reply(200, body))
        defer { LoopbackStub.unregister(port: port) }
        #expect(try await Self.transport(port: port).complete(system: "s", user: "u") == .content(""))
    }

    @Test("HTTP 400 以上は LLM_UNAVAILABLE", arguments: [400, 500, 503])
    func httpErrorIsUnavailable(status: Int) async throws {
        let port = try #require(FreePort.pick())
        LoopbackStub.register(port: port, Self.reply(status, "busy"))
        defer { LoopbackStub.unregister(port: port) }
        #expect(
            try await Self.transport(port: port).complete(system: "s", user: "u")
                == .failure(StageFailure(.llmUnavailable, "HTTP \(status): busy")))
    }

    @Test("本文は先頭 200 スカラーまで")
    func httpErrorBodyIsCutAt200Scalars() async throws {
        let port = try #require(FreePort.pick())
        LoopbackStub.register(port: port, Self.reply(500, String(repeating: "あ", count: 300)))
        defer { LoopbackStub.unregister(port: port) }
        #expect(
            try await Self.transport(port: port).complete(system: "s", user: "u")
                == .failure(StageFailure(.llmUnavailable, "HTTP 500: " + String(repeating: "あ", count: 200))))
    }

    @Test("接続できなければ URLError の番号")
    func connectionFailureIsUnavailable() async throws {
        let port = try #require(FreePort.pick())
        #expect(
            try await Self.transport(port: port).complete(system: "s", user: "u")
                == .failure(StageFailure(.llmUnavailable, "URLError -1004")))
    }

    @Test("要求ごとに新しい設定（使い回さない）")
    func newSessionPerRequest() async throws {
        let port = try #require(FreePort.pick())
        LoopbackStub.register(port: port, Self.reply(200, Self.okBody))
        defer { LoopbackStub.unregister(port: port) }
        let factory = CountingSessionFactory()
        let transport = LoopbackChatTransport(
            endpoint: try #require(LoopbackEndpoint(port: port)), apiKey: Self.apiKey, modelID: Self.modelID,
            config: Self.defaultConfig(), factory: factory)
        #expect(await transport.complete(system: "s", user: "u") == .content("{}"))
        #expect(await transport.complete(system: "s", user: "u") == .content("{}"))
        #expect(factory.count == 2)
        #expect(LoopbackStub.requests(port: port).count == 2)
    }

    @Test("/health のステータスを返す")
    func healthStatus() async throws {
        var ports: [UInt16] = []
        while ports.count < 3 {
            let port = try #require(FreePort.pick())
            if !ports.contains(port) { ports.append(port) }
        }
        let (ok, loading, missing) = (ports[0], ports[1], ports[2])
        LoopbackStub.register(port: ok, Self.reply(200, #"{"status":"ok"}"#))
        LoopbackStub.register(port: loading, Self.reply(503, "{}"))
        defer {
            LoopbackStub.unregister(port: ok)
            LoopbackStub.unregister(port: loading)
        }
        let factory = BlockingSessionFactory()
        #expect(await LoopbackHealth.check(try #require(LoopbackEndpoint(port: ok)), factory: factory) == 200)
        #expect(await LoopbackHealth.check(try #require(LoopbackEndpoint(port: loading)), factory: factory) == 503)
        #expect(await LoopbackHealth.check(try #require(LoopbackEndpoint(port: missing)), factory: factory) == nil)
        let requests = LoopbackStub.requests(port: ok) + LoopbackStub.requests(port: loading)
        #expect(requests.count == 2)
        for request in requests {
            #expect(request.method == "GET")
            #expect(request.url.path(percentEncoded: false) == "/health")
            #expect(request.headers["Authorization"] == nil)
        }
    }

    @Test("空きポートは再び bind できる")
    func freePortIsBindable() throws {
        let port = try #require(FreePort.pick())
        #expect(port != 0)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bound == 0)
    }
}
