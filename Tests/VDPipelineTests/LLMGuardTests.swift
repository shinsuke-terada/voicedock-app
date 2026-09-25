// 解析の前のガードのテスト（T-22 §6.6。PLAN §5.4・§8.5「解析の前のガード」）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDPipeline

@Suite("LLMGuard")
struct LLMGuardTests {
    static func modelURL(_ w: PipelineWorld) throws -> URL {
        let entry = try #require(TestCatalogs.minimal.entry(kind: .llm, id: "test-llm"))
        return ModelFiles.url(kind: .llm, entry: entry, layout: w.layout)
    }

    /// ガードを評価し、結果と停止中の理由を返す。
    static func evaluate(_ w: PipelineWorld) async throws -> (LLMTarget?, [PauseReason]) {
        let ctx = try await w.context()
        let target = LLMGuard(ctx: ctx).evaluate()
        return (target, ctx.pauses.paused)
    }

    static func installed(physicalMemoryBytes: UInt64 = 1 << 40) async throws -> PipelineWorld {
        let w = try await PipelineWorld.make(physicalMemoryBytes: physicalMemoryBytes)
        try await w.installLLM()
        return w
    }

    static let customID = "custom:" + String(repeating: "0", count: 64)

    /// llm.modelID = customID（設定の検証を通らなければテストを落とす）。
    static func selectCustom(_ w: PipelineWorld) async throws {
        let result = await w.configStore.update { $0.llm.modelID = Self.customID }
        guard case .success = result else { throw PipelineFixtureError.invalidConfig("\(result)") }
    }

    @Test("CE llm.modelID 未選択なら llm_not_selected、選べば通る")
    func ceLlmModelID() async throws {
        let none = try await PipelineWorld.make()
        let (t0, p0) = try await Self.evaluate(none)
        #expect(t0 == nil)
        #expect(p0 == [.llmNotSelected])
        let w = try await Self.installed()
        let (t1, p1) = try await Self.evaluate(w)
        #expect(t1 == LLMTarget(model: try Self.modelURL(w), modelID: "test-llm"))
        #expect(p1.isEmpty)
    }

    @Test("ファイルが無ければ llm_model_missing")
    func missingModel() async throws {
        let w = try await Self.installed()
        try FileManager.default.removeItem(at: try Self.modelURL(w))
        let (t, p) = try await Self.evaluate(w)
        #expect(t == nil)
        #expect(p == [.llmModelMissing])
    }

    @Test("大きさが違えば無いのと同じ")
    func wrongSizeIsMissing() async throws {
        let w = try await Self.installed()
        let entry = try #require(TestCatalogs.minimal.entry(kind: .llm, id: "test-llm"))
        try Data(count: Int(entry.bytes) + 1).write(to: try Self.modelURL(w))
        let (t, p) = try await Self.evaluate(w)
        #expect(t == nil)
        #expect(p == [.llmModelMissing])
    }

    @Test("メモリが足りなければ llm_insufficient_memory")
    func insufficientMemory() async throws {
        let w = try await Self.installed(physicalMemoryBytes: 0)
        let (t, p) = try await Self.evaluate(w)
        #expect(t == nil)
        #expect(p == [.llmInsufficientMemory])
    }

    @Test("llama-server が無い・実行できなければ llama_server_missing", arguments: [true, false])
    func missingServer(remove: Bool) async throws {
        let w = try await Self.installed()
        let path = w.paths.llamaServer.path(percentEncoded: false)
        if remove {
            try FileManager.default.removeItem(atPath: path)
        } else {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        }
        let (t, p) = try await Self.evaluate(w)
        #expect(t == nil)
        #expect(p == [.llamaServerMissing])
    }

    @Test("独立した理由は全部出す")
    func allIndependentReasonsAreReported() async throws {
        let w = try await Self.installed(physicalMemoryBytes: 0)
        try FileManager.default.removeItem(at: try Self.modelURL(w))
        try FileManager.default.removeItem(at: w.paths.llamaServer)
        let (t, p) = try await Self.evaluate(w)
        #expect(t == nil)
        #expect(p == [.llmModelMissing, .llmInsufficientMemory, .llamaServerMissing])
    }

    @Test("custom はメモリを見ない")
    func customModelSkipsMemory() async throws {
        let w = try await Self.installed(physicalMemoryBytes: 0)
        let file = w.layout.root.appendingPathComponent("models/llm/custom-0000000000000000.gguf")
        try Data([0]).write(to: file)
        try await Self.selectCustom(w)
        let (t, p) = try await Self.evaluate(w)
        #expect(t?.model.path(percentEncoded: false) == file.path(percentEncoded: false))
        #expect(t?.modelID == Self.customID)
        #expect(p.isEmpty)
    }

    @Test("custom のファイルが無ければ llm_model_missing")
    func customModelMissing() async throws {
        let w = try await Self.installed()
        try await Self.selectCustom(w)
        let (t, p) = try await Self.evaluate(w)
        #expect(t == nil)
        #expect(p == [.llmModelMissing])
    }
}
