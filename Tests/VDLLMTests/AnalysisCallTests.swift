// AnalysisCall の送信・取り出し・検証・修復の流れが voicedock analyze と同じであること（PLAN §8.5、T-19）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

@Suite("AnalysisCall")
struct AnalysisCallTests {
    static let good = #"{"title":"t","summary":"s"}"#
    static let body = "文字起こしの本文です"
    static let missingSummary = #"{"title":"t"}"#
    static let unavailable = StageFailure(.llmUnavailable, "URLError -1004")

    static func call(
        _ transport: FakeChatTransport, repairAttempts: Int = 1, custom: String = ""
    ) throws -> AnalysisCall {
        AnalysisCall(
            transport: transport, prompts: try LLMFixtures.prompts(), customInstructions: custom,
            repairAttempts: repairAttempts)
    }

    static func success(_ result: Result<AnalysisCall.Success, StageFailure>) -> AnalysisCall.Success? {
        try? result.get()
    }

    static func failure(_ result: Result<AnalysisCall.Success, StageFailure>) -> StageFailure? {
        if case .failure(let failure) = result {
            return failure
        }
        return nil
    }

    @Test("1 回目で通る")
    func validFirstResponse() async throws {
        let transport = FakeChatTransport(responses: [.content(Self.good)])
        let final = LLMFixtures.schema(.final)
        let result = try await Self.call(transport).run(kind: .analyze, schema: final, body: Self.body)
        let success = try #require(Self.success(result))
        #expect(success.repairs == 0)
        #expect(success.trimmed == [])
        #expect(success.result.title == "t")
        #expect(success.result.summary == "s")
        let calls = await transport.calls
        #expect(calls.count == 1)
        #expect(calls.first?.system == (try LLMFixtures.prompts()).analyze(schema: final, custom: ""))
        #expect(calls.first?.user == Self.body)
    }

    @Test("1 回で直る")
    func invalidThenRepaired() async throws {
        let transport = FakeChatTransport(responses: [.content(Self.missingSummary), .content(Self.good)])
        let final = LLMFixtures.schema(.final)
        let result = try await Self.call(transport).run(kind: .analyze, schema: final, body: Self.body)
        #expect(Self.success(result)?.repairs == 1)
        let calls = await transport.calls
        #expect(calls.count == 2)
        let expectedSystem = (try LLMFixtures.prompts()).repair(
            schema: final, errors: "- summary: Field required", previousOutput: Self.missingSummary)
        #expect(calls.last?.system == expectedSystem)
        #expect(calls.last?.user == "")
    }

    @Test("直らなければ LLM_INVALID_JSON")
    func twoFailuresAreInvalidJSON() async throws {
        let transport = FakeChatTransport(responses: [.content(Self.missingSummary), .content(Self.missingSummary)])
        let result = try await Self.call(transport).run(
            kind: .analyze, schema: LLMFixtures.schema(.final), body: Self.body)
        #expect(Self.failure(result) == StageFailure(.llmInvalidJSON, "- summary: Field required"))
        #expect(await transport.calls.count == 2)
    }

    @Test("CE llm.repairAttempts 0 は修復しない")
    func repairAttemptsZero() async throws {
        let zero = FakeChatTransport(responses: [.content(Self.missingSummary), .content(Self.good)])
        let result = try await Self.call(zero, repairAttempts: 0).run(
            kind: .analyze, schema: LLMFixtures.schema(.final), body: Self.body)
        #expect(await zero.calls.count == 1)
        #expect(Self.failure(result)?.code == .llmInvalidJSON)

        let one = FakeChatTransport(responses: [.content(Self.missingSummary), .content(Self.good)])
        let repaired = try await Self.call(one, repairAttempts: 1).run(
            kind: .analyze, schema: LLMFixtures.schema(.final), body: Self.body)
        #expect(await one.calls.count == 2)
        #expect(Self.success(repaired)?.repairs == 1)
    }

    @Test("CE llm.analysis.customInstructions が system に差し込まれる")
    func ceCustomInstructions() async throws {
        let withCustom = FakeChatTransport(responses: [.content(Self.good)])
        _ = try await Self.call(withCustom, custom: "箇条書きは短く。").run(
            kind: .analyze, schema: LLMFixtures.schema(.final), body: Self.body)
        let withoutCustom = FakeChatTransport(responses: [.content(Self.good)])
        _ = try await Self.call(withoutCustom, custom: "").run(
            kind: .analyze, schema: LLMFixtures.schema(.final), body: Self.body)
        let first = try #require(await withCustom.calls.first?.system)
        let second = try #require(await withoutCustom.calls.first?.system)
        #expect(first.contains("箇条書きは短く。"))
        #expect(!second.contains("箇条書きは短く。"))
        #expect(!first.contains("{custom_instructions}"))
        #expect(!second.contains("{custom_instructions}"))
    }

    @Test("repairAttempts 2 は 2 回修復する")
    func repairAttemptsTwo() async throws {
        let transport = FakeChatTransport(responses: Array(repeating: .content(Self.missingSummary), count: 3))
        let result = try await Self.call(transport, repairAttempts: 2).run(
            kind: .analyze, schema: LLMFixtures.schema(.final), body: Self.body)
        #expect(await transport.calls.count == 3)
        #expect(Self.failure(result) == StageFailure(.llmInvalidJSON, "- summary: Field required"))
    }

    @Test("接続失敗はそのまま返す")
    func transportFailureIsReturned() async throws {
        let transport = FakeChatTransport(responses: [.failure(Self.unavailable)])
        let result = try await Self.call(transport).run(
            kind: .analyze, schema: LLMFixtures.schema(.final), body: Self.body)
        #expect(Self.failure(result) == Self.unavailable)
        #expect(await transport.calls.count == 1)
    }

    @Test("修復の途中の接続失敗は LLM_UNAVAILABLE")
    func repairThatCannotConnectStops() async throws {
        let transport = FakeChatTransport(responses: [.content("x"), .failure(Self.unavailable)])
        let result = try await Self.call(transport).run(
            kind: .analyze, schema: LLMFixtures.schema(.final), body: Self.body)
        #expect(Self.failure(result) == Self.unavailable)
        #expect(await transport.calls.count == 2)
    }

    @Test("外形が壊れた応答（空文字）は修復へ回る")
    func malformedEnvelopeGoesToRepair() async throws {
        let transport = FakeChatTransport(responses: [.content(""), .content("")])
        let final = LLMFixtures.schema(.final)
        let result = try await Self.call(transport).run(kind: .analyze, schema: final, body: Self.body)
        #expect(Self.failure(result) == StageFailure(.llmInvalidJSON, "応答から JSON を抽出できませんでした"))
        let calls = await transport.calls
        #expect(calls.count == 2)
        let expectedSystem = (try LLMFixtures.prompts()).repair(
            schema: final, errors: "応答から JSON を抽出できませんでした", previousOutput: "")
        #expect(calls.last?.system == expectedSystem)
    }

    @Test("修復要求に本文を入れない")
    func repairNeverResendsTheTranscript() async throws {
        let transport = FakeChatTransport(responses: [.content(Self.missingSummary), .content(Self.good)])
        _ = try await Self.call(transport).run(kind: .analyze, schema: LLMFixtures.schema(.final), body: Self.body)
        let calls = await transport.calls
        let second = try #require(calls.count == 2 ? calls[1] : nil)
        #expect(!second.system.contains(Self.body))
        #expect(!second.user.contains(Self.body))
    }

    @Test("map は中間形で検証する")
    func mapUsesThePartialSchema() async throws {
        let transport = FakeChatTransport(responses: [.content(Self.good), .content(#"{"summary":"s"}"#)])
        let partial = LLMFixtures.schema(.partial)
        let result = try await Self.call(transport).run(kind: .map, schema: partial, body: Self.body)
        #expect(Self.success(result)?.repairs == 1)
        let calls = await transport.calls
        #expect(calls.count == 2)
        #expect(calls.first?.system == (try LLMFixtures.prompts()).map(schema: partial, custom: ""))
        let expectedTail =
            String(decoding: try Golden.expectedBytes("llm_schema_block", "partial_default"), as: UTF8.self) + "\n"
        #expect(calls.last?.system.hasSuffix(expectedTail) == true)
        #expect(calls.last?.system.contains("- title: Extra inputs are not permitted") == true)
    }

    @Test("切り詰めの記録を返す")
    func trimmedNotesPropagate() async throws {
        let tags = (0..<20).map { "\"t\($0)\"" }.joined(separator: ",")
        let transport = FakeChatTransport(responses: [.content(#"{"title":"t","summary":"s","tags":["# + tags + "]}")])
        let result = try await Self.call(transport).run(
            kind: .analyze, schema: LLMFixtures.schema(.final), body: Self.body)
        let success = try #require(Self.success(result))
        #expect(success.trimmed == ["tags: 20 -> 15"])
        #expect(success.result.tags?.count == 15)
    }
}
