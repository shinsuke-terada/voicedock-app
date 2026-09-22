// LLMServerControl の偽物。プロセスを起動しない（00-api-map §15。T-22）。
import Foundation
import VDCore
import VDLLM
import VDPipeline

/// LLMServerControl の偽物。ensureRunning と stop の呼び出しを記録する。
public actor FakeLLMServer: LLMServerControl {
    /// 成功のときに返す port
    private static let port: UInt16 = 40_000
    /// 成功のときに返す API キー（"0" × 32）
    private static let apiKey = String(repeating: "0", count: 32)

    private let failure: StageFailure?
    private var calls: [(model: URL, modelID: String)] = []
    private var stops = 0

    /// failure を渡すと ensureRunning は常にそれを返す。nil なら成功（port 40000、apiKey "0"×32、modelID は渡された値）。
    public init(failure: StageFailure? = nil) {
        self.failure = failure
    }

    public func ensureRunning(model: URL, modelID: String, config: LLMConfig) async -> Result<
        LlamaServerHandle, StageFailure
    > {
        calls.append((model: model, modelID: modelID))
        if let failure { return .failure(failure) }
        guard let endpoint = LoopbackEndpoint(port: Self.port) else {
            return .failure(StageFailure(.llmUnavailable, "FakeLLMServer: endpoint"))
        }
        return .success(LlamaServerHandle(endpoint: endpoint, apiKey: Self.apiKey, modelID: modelID))
    }

    public func stop() async {
        stops += 1
    }

    public var ensureCalls: [(model: URL, modelID: String)] { calls }
    public var stopCount: Int { stops }
}
