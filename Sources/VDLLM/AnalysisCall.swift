// 1 回の解析要求: 送信 → 取り出し → 切り詰め → 検証 → 修復（voicedock llm.py:460-544）。
import Foundation
import VDCore

public struct AnalysisCall: Sendable {
    public let transport: any ChatTransport
    public let prompts: Prompts
    public let customInstructions: String
    public let repairAttempts: Int

    public init(transport: any ChatTransport, prompts: Prompts, customInstructions: String, repairAttempts: Int) {
        self.transport = transport
        self.prompts = prompts
        self.customInstructions = customInstructions
        self.repairAttempts = repairAttempts
    }

    public struct Success: Equatable, Sendable {
        public let result: AnalysisResult
        public let trimmed: [String]
        public let repairs: Int
    }

    /// kind に応じて system を作り、body を user として送る。例外を投げない。
    /// スキーマは呼び手が渡す（analyze / reduce は最終形、map は中間形）。修復プロンプトにも同じスキーマを使う。
    public func run(kind: PromptKind, schema: AnalysisSchema, body: String) async -> Result<Success, StageFailure> {
        let system = prompts.system(kind, schema: schema, custom: customInstructions)
        var raw: String
        switch await transport.complete(system: system, user: body) {
        case .failure(let failure): return .failure(failure)
        case .content(let content): raw = content
        }
        var attempt = 0
        while true {
            let evaluated = Self.evaluate(raw, schema: schema)
            if let result = evaluated.result {
                return .success(Success(result: result, trimmed: evaluated.trimmed, repairs: attempt))
            }
            if attempt >= repairAttempts {
                return .failure(StageFailure(.llmInvalidJSON, evaluated.failure))
            }
            // 修復要求に transcript を再送しない。
            let repairSystem = prompts.repair(schema: schema, errors: evaluated.failure, previousOutput: raw)
            switch await transport.complete(system: repairSystem, user: "") {
            // 修復の途中で落ちたら LLM_UNAVAILABLE のまま（LLM_INVALID_JSON にしない）。
            case .failure(let failure): return .failure(failure)
            case .content(let content): raw = content
            }
            attempt += 1
        }
    }

    /// 1 つの生の応答を評価する（取り出し → 切り詰め → 検証）。
    static func evaluate(_ raw: String, schema: AnalysisSchema) -> (
        result: AnalysisResult?, failure: String, trimmed: [String]
    ) {
        guard let obj = JSONExtractor.extractObject(raw) else {
            return (nil, LLMValidationMessages.notExtracted, [])
        }
        let (trimmedObj, trimmed) = AnalysisValidator.trim(obj, schema: schema)
        switch AnalysisValidator.validate(trimmedObj, schema: schema) {
        case .success(let result): return (result, "", trimmed)
        case .failure(let errors): return (nil, errors.rendered, trimmed)
        }
    }
}
