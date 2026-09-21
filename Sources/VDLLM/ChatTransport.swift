// LLM への 1 回の要求の抽象（PLAN §8.5「HTTP」）。本番は LoopbackChatTransport（T-21）。
import Foundation
import VDCore

public enum ChatResult: Equatable, Sendable {
    /// choices[0].message.content。外形が壊れていれば ""（修復へ回す）。
    case content(String)
    /// LLM_UNAVAILABLE（接続失敗・HTTP 400 以上）。
    case failure(StageFailure)
}

public protocol ChatTransport: Sendable {
    func complete(system: String, user: String) async -> ChatResult
}
