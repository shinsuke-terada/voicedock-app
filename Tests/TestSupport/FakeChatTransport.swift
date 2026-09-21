// LLM への要求を記録し、決めておいた応答を返す ChatTransport（T-19。T-20・T-22・T-29 も使う）。
import Foundation
import VDCore
import VDLLM

public actor FakeChatTransport: ChatTransport {
    public struct Call: Equatable, Sendable {
        public let system: String
        public let user: String
    }

    private var responses: [ChatResult]
    private let handler: (@Sendable (Call) -> ChatResult)?
    private var recorded: [Call] = []

    /// 応答を順に返す。尽きたら .failure(StageFailure(.llmUnavailable, "FakeChatTransport: 応答がありません"))。
    public init(responses: [ChatResult]) {
        self.responses = responses
        self.handler = nil
    }

    /// 呼び出しごとに handler で応答を決める（T-20 の Map / Reduce の振り分け用）。
    public init(handler: @escaping @Sendable (Call) -> ChatResult) {
        self.responses = []
        self.handler = handler
    }

    public func complete(system: String, user: String) async -> ChatResult {
        let call = Call(system: system, user: user)
        recorded.append(call)
        if let handler {
            return handler(call)
        }
        guard !responses.isEmpty else {
            return .failure(StageFailure(.llmUnavailable, "FakeChatTransport: 応答がありません"))
        }
        return responses.removeFirst()
    }

    public var calls: [Call] { recorded }
}
