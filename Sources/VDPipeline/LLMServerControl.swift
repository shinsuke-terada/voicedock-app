// Worker が llama-server に求めるもの（テストで FakeLLMServer に差し替える）。本番は LlamaServerSupervisor（T-21）。
import Foundation
import VDCore
import VDLLM

/// llama-server の起動と停止（00-api-map §11）。本番は LlamaServerSupervisor、テストは FakeLLMServer。
public protocol LLMServerControl: Sendable {
    func ensureRunning(model: URL, modelID: String, config: LLMConfig) async -> Result<LlamaServerHandle, StageFailure>
    func stop() async
}

extension LlamaServerSupervisor: LLMServerControl {}

/// 起動した llama-server への ChatTransport を作る。本番は
/// `{ h, c in LoopbackChatTransport(endpoint: h.endpoint, apiKey: h.apiKey, modelID: h.modelID, config: c, factory: EphemeralSessionFactory()) }`（Bootstrap が渡す）。
public typealias ChatTransportFactory = @Sendable (LlamaServerHandle, LLMConfig) -> any ChatTransport
