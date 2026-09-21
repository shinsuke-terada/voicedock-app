// モデルのダウンロード元の差し替え（PLAN §10.1・TEST-12。00-api-map §15。T-23）。ネットワークには決して出ない。
import Foundation
import Synchronization
import VDModels

public enum ModelHostReply: Sendable {
    /// 200 で全部返す
    case body(Data)
    case http(status: Int, body: Data)
    case failure(URLError.Code)
    /// 途中まで返してから失敗する
    case truncated(Data, URLError.Code)
}

/// 絶対 URL ごとに応答を決める（**ネットワークには決して出ない**）。テストごとに register / unregister する。
public enum ModelHostStub {
    fileprivate struct Table {
        var replies: [String: @Sendable () -> ModelHostReply] = [:]
        var counts: [String: Int] = [:]
    }

    fileprivate static let table = Mutex(Table())

    public static func register(url: String, _ reply: @escaping @Sendable () -> ModelHostReply) {
        table.withLock { $0.replies[url] = reply }
    }

    public static func unregister(url: String) {
        table.withLock { t in
            t.replies[url] = nil
            t.counts[url] = nil
        }
    }

    /// その URL に来た要求の数。
    public static func requests(url: String) -> Int {
        table.withLock { $0.counts[url] ?? 0 }
    }

    public static func reset() {
        table.withLock { $0 = Table() }
    }

    /// 要求を数えて応答の作り手を返す（無ければ nil）。
    fileprivate static func record(url: String) -> (@Sendable () -> ModelHostReply)? {
        table.withLock { t in
            t.counts[url, default: 0] += 1
            return t.replies[url]
        }
    }
}

public final class ModelHostURLProtocol: URLProtocol {
    /// .body を流す単位。
    static let chunkBytes = 65_536

    override public class func canInit(with request: URLRequest) -> Bool { true }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        guard let url = request.url, let reply = ModelHostStub.record(url: url.absoluteString) else {
            fail(.notConnectedToInternet)
            return
        }
        switch reply() {
        case .body(let d):
            guard respond(url, status: 200, headers: ["Content-Length": "\(d.count)"]) else { return }
            var offset = 0
            while offset < d.count {
                let end = min(offset + Self.chunkBytes, d.count)
                client?.urlProtocol(self, didLoad: d.subdata(in: offset..<end))
                offset = end
            }
            client?.urlProtocolDidFinishLoading(self)
        case .http(let status, let d):
            guard respond(url, status: status, headers: [:]) else { return }
            client?.urlProtocol(self, didLoad: d)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            fail(code)
        case .truncated(let d, let code):
            guard respond(url, status: 200, headers: [:]) else { return }
            client?.urlProtocol(self, didLoad: d)
            fail(code)
        }
    }

    override public func stopLoading() {}

    /// 応答の頭を返す。作れなければ失敗させて false。
    private func respond(_ url: URL, status: Int, headers: [String: String]) -> Bool {
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else {
            fail(.badServerResponse)
            return false
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        return true
    }

    private func fail(_ code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }
}

public struct ModelHostSessionFactory: DownloadSessionFactory {
    public init() {}

    /// .ephemeral に protocolClasses = [ModelHostURLProtocol.self]
    public func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelHostURLProtocol.self]
        return configuration
    }
}

/// T-21 の BlockingSessionFactory をダウンロードにも使えるようにする（中身は空。configuration() は既に在る）。
extension BlockingSessionFactory: DownloadSessionFactory {}
