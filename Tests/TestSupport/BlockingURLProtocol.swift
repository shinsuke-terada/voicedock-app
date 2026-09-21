// ループバック以外への要求を失敗させ、127.0.0.1 への要求に差し替えの応答を返す URLProtocol（PLAN §10.1・TEST-12。00-api-map §15。T-21）。
import Foundation
import Synchronization
import VDLLM

/// 受けた要求。
public struct StubRequest: Sendable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data
}

/// 差し替えの応答。
public enum StubReply: Sendable {
    case http(status: Int, body: Data)
    case failure(URLError.Code)
}

/// 127.0.0.1:<port> ごとの応答の登録と、受けた要求の記録。
public enum LoopbackStub {
    fileprivate struct Entry {
        var handler: (@Sendable (StubRequest) -> StubReply)?
        var requests: [StubRequest] = []
    }

    fileprivate static let table = Mutex<[UInt16: Entry]>([:])

    /// 127.0.0.1:<port> への要求に handler で応答する（テストごとに別のポートを使えば並行に走らせても混ざらない）。
    public static func register(port: UInt16, _ handler: @escaping @Sendable (StubRequest) -> StubReply) {
        table.withLock { $0[port] = Entry(handler: handler) }
    }

    public static func unregister(port: UInt16) {
        _ = table.withLock { $0.removeValue(forKey: port) }
    }

    /// 受けた要求（順に）。
    public static func requests(port: UInt16) -> [StubRequest] {
        table.withLock { $0[port]?.requests ?? [] }
    }

    /// 要求を記録して handler を返す。handler が無ければ nil（記録もしない）。
    fileprivate static func record(port: UInt16, _ request: StubRequest) -> (@Sendable (StubRequest) -> StubReply)? {
        table.withLock { table in
            guard let handler = table[port]?.handler else { return nil }
            table[port]?.requests.append(request)
            return handler
        }
    }
}

/// ネットワークへ出さない URLProtocol。
public final class BlockingURLProtocol: URLProtocol {
    override public class func canInit(with request: URLRequest) -> Bool { true }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        guard let url = request.url, url.host(percentEncoded: false) == LoopbackEndpoint.host else {
            fail(.notConnectedToInternet)
            return
        }
        let port = url.port.flatMap { UInt16(exactly: $0) } ?? 0
        let stub = StubRequest(
            method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request))
        guard let handler = LoopbackStub.record(port: port, stub) else {
            fail(.cannotConnectToHost)
            return
        }
        switch handler(stub) {
        case .http(let status, let body):
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])
            else {
                fail(.badServerResponse)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            fail(code)
        }
    }

    override public func stopLoading() {}

    private func fail(_ code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }

    /// httpBody か httpBodyStream を全部読んだもの。
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return data
    }
}

/// protocolClasses に BlockingURLProtocol だけを置いたファクトリ。
public struct BlockingSessionFactory: LoopbackSessionFactory {
    public init() {}

    /// .ephemeral に protocolClasses = [BlockingURLProtocol.self]
    public func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockingURLProtocol.self]
        return configuration
    }
}
