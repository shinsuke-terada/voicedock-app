// ループバック（127.0.0.1）への HTTP だけを行う唯一のファイル（PLAN §8.5、PT-02）。URL(string:) を使わない。
import Darwin
import Foundation
import VDCore

/// llama-server の宛先。ホストは 127.0.0.1 に固定（PT-02）。
public struct LoopbackEndpoint: Equatable, Sendable {
    public static let host = "127.0.0.1"
    public let port: UInt16
    /// http://127.0.0.1:<port>/v1/chat/completions
    public let chatCompletionsURL: URL
    /// http://127.0.0.1:<port>/health
    public let healthURL: URL

    /// port が 0 なら nil。URL は URLComponents（scheme "http"・host 127.0.0.1・port・path）で作り、url が nil なら nil。
    public init?(port: UInt16) {
        guard port != 0,
            let chat = Self.url(port: port, path: "/v1/chat/completions"),
            let health = Self.url(port: port, path: "/health")
        else { return nil }
        self.port = port
        self.chatCompletionsURL = chat
        self.healthURL = health
    }

    private static func url(port: UInt16, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(port)
        components.path = path
        return components.url
    }
}

/// URLSessionConfiguration の作り手（PLAN §10.1。テストで差し替える）。
public protocol LoopbackSessionFactory: Sendable {
    /// 呼ぶたびに新しい設定を返す（呼び手が timeout を書き込む）。
    func configuration() -> URLSessionConfiguration
}

/// 本番のファクトリ。プロキシ・キャッシュ・クッキーを使わない。
public struct EphemeralSessionFactory: LoopbackSessionFactory {
    public init() {}

    /// .ephemeral に connectionProxyDictionary = [:]（プロキシを通さない）、requestCachePolicy = .reloadIgnoringLocalCacheData、
    /// urlCache = nil、httpCookieStorage = nil、httpShouldSetCookies = false、waitsForConnectivity = false を設定したもの。
    public func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        return configuration
    }
}

/// llama-server の chat/completions を呼ぶ ChatTransport（voicedock llm.py の complete）。ログは出さない（PR-08）。
public struct LoopbackChatTransport: ChatTransport {
    private let endpoint: LoopbackEndpoint
    private let apiKey: String
    private let modelID: String
    private let config: LLMConfig
    private let factory: any LoopbackSessionFactory

    public init(
        endpoint: LoopbackEndpoint, apiKey: String, modelID: String, config: LLMConfig,
        factory: any LoopbackSessionFactory
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.modelID = modelID
        self.config = config
        self.factory = factory
    }

    /// LLM-10: 要求ごとに新しい URLSession を作り、使い回さない。
    public func complete(system: String, user: String) async -> ChatResult {
        guard let request = makeRequest(system: system, user: user) else {
            return .failure(StageFailure(.llmUnavailable, "request_encoding_failed"))
        }
        let session = URLSession(configuration: makeConfiguration())
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            // リダイレクトに従わない（F-79。3xx の応答そのものを受け取り、下で失敗にする）
            (data, response) = try await session.data(for: request, delegate: RedirectRefusal())
        } catch let error as URLError {
            return .failure(StageFailure(.llmUnavailable, "URLError \(error.code.rawValue)"))
        } catch {
            return .failure(StageFailure(.llmUnavailable, String(describing: type(of: error))))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !Self.succeeded(status) {
            let body = TextLimit.prefix(String(decoding: data, as: UTF8.self), scalars: 200)
            return .failure(StageFailure(.llmUnavailable, "HTTP \(status): \(body)"))
        }
        return .content(Self.content(of: data))
    }

    /// 2xx だけを成功とする（F-79。3xx はリダイレクトに従わずに受け取った応答、0 は HTTP でない応答）。
    static func succeeded(_ status: Int) -> Bool {
        (200...299).contains(status)
    }

    /// factory の設定に requestTimeoutSeconds を request / resource の両方の timeout として入れたもの。
    func makeConfiguration() -> URLSessionConfiguration {
        let configuration = factory.configuration()
        configuration.timeoutIntervalForRequest = Double(config.requestTimeoutSeconds)
        configuration.timeoutIntervalForResource = Double(config.requestTimeoutSeconds)
        return configuration
    }

    /// POST chat/completions の要求。本文を作れなければ nil。
    func makeRequest(system: String, user: String) -> URLRequest? {
        let body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": config.temperature,
            "top_p": config.topP,
            "max_tokens": config.maxOutputTokens,
            "response_format": ["type": "json_object"],
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        var request = URLRequest(url: endpoint.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Double(config.requestTimeoutSeconds)
        request.httpBody = data
        return request
    }

    /// voicedock `_content_of`: choices[0].message.content の文字列。どこかで外れたら ""（修復へ回す）。
    /// content の先頭の U+FEFF を落とさないため PyJSON.decode で読む（PLAN §5.7・F-45）。
    static func content(of data: Data) -> String {
        guard case .object(let top)? = PyJSON.decode(data),
            case .array(let items)? = member(top, "choices"),
            let first = items.first,
            case .object(let choice) = first,
            case .object(let message)? = member(choice, "message"),
            case .string(let text)? = member(message, "content")
        else { return "" }
        return text
    }

    /// キーをスカラー列で比べる。同じキーが複数あれば Python の dict と同じく最後のもの。
    private static func member(_ pairs: [(String, PyJSONValue)], _ key: String) -> PyJSONValue? {
        pairs.last { $0.0.unicodeScalars.elementsEqual(key.unicodeScalars) }?.1
    }
}

/// 空きポートを得る（PLAN §8.5）。
public enum FreePort {
    /// 127.0.0.1:0 に bind して割り当てられたポートを返し、ソケットは閉じる。取れなければ nil。
    public static func pick() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
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
        guard bound == 0 else { return nil }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(fd, raw, &length)
            }
        }
        guard named == 0 else { return nil }
        let port = UInt16(bigEndian: assigned.sin_port)
        return port == 0 ? nil : port
    }
}

/// llama-server の /health（API キー不要。読み込み中は 503、準備ができると 200）。
public enum LoopbackHealth {
    public static let timeoutSeconds: Double = 5

    /// GET healthURL の HTTP ステータス。接続できない・HTTP でない応答なら nil。
    public static func check(_ endpoint: LoopbackEndpoint, factory: any LoopbackSessionFactory) async -> Int? {
        var request = URLRequest(url: endpoint.healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        let configuration = factory.configuration()
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        // リダイレクトに従わない（F-79。3xx はそのステータスを返し、200 ではないので起動済みにしない）
        guard let (_, response) = try? await session.data(for: request, delegate: RedirectRefusal()) else {
            return nil
        }
        return (response as? HTTPURLResponse)?.statusCode
    }
}

/// HTTP のリダイレクトに従わない（F-79。PLAN §8.5）。既定の URLSession は 3xx の Location へ本文と Authorization を
/// 付けたまま送り直す（外部の https でも）ので、要求ごとにこの delegate を渡し、3xx の応答そのものを受け取る。
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
