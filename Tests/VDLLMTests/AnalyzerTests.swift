// Session の解析（単一パス・Map → Reduce・多段 Reduce）が voicedock analyze_session と同じ流れであること（PLAN §8.5、T-20）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

/// 要求の種類を system で判定し、テストごとの応答を返す（T-20 §5.4）。
struct AnalyzerHarness: Sendable {
    enum Kind: Equatable, Sendable { case analyze, map, reduce, repair }

    let prompts: Prompts
    let analyzeSystem: String
    let mapSystem: String
    let reduceSystem: String

    init() throws {
        prompts = try LLMFixtures.prompts()
        let final = LLMFixtures.schema(.final)
        let partial = LLMFixtures.schema(.partial)
        analyzeSystem = prompts.analyze(schema: final, custom: "")
        mapSystem = prompts.map(schema: partial, custom: "")
        reduceSystem = prompts.reduce(schema: final, custom: "")
    }

    /// analyze / map / reduce のどれとも一致しなければ修復（`prompts.repair(…)`）。
    func kind(_ system: String) -> Kind {
        switch system {
        case analyzeSystem: return .analyze
        case mapSystem: return .map
        case reduceSystem: return .reduce
        default: return .repair
        }
    }

    static let unavailable = StageFailure(.llmUnavailable, "URLError -1004")
    static let unexpected = ChatResult.failure(StageFailure(.llmUnavailable, "想定外の要求"))

    static func config(_ edit: (inout LLMConfig) -> Void = { _ in }) -> LLMConfig {
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo").llm
        edit(&config)
        return config
    }

    static func transcript(_ segments: [AbsoluteSegment]) -> SessionTranscript {
        SessionTranscript(
            dayDate: LocalDate(year: 2026, month: 8, day: 29)!, segments: segments, blocks: [], excludedPartkeys: [])
    }

    /// `{"summary": s, "key_points": kp}` の JSON 文字列。
    static func partial(_ s: String, kp: [String] = []) -> ChatResult {
        .content(
            PyJSON.dumpsCompact(.object([("summary", .string(s)), ("key_points", .array(kp.map { .string($0) }))])))
    }

    /// `{"title": "題", "summary": "まとめ", …}` の JSON 文字列。extra は `,"tags":[…]` のような続き。
    static func final(_ extra: String = "") -> ChatResult {
        .content(#"{"title":"題","summary":"まとめ""# + extra + "}")
    }

    static func tags(_ count: Int) -> String {
        #","tags":["# + (1...count).map { "\"t\($0)\"" }.joined(separator: ",") + "]"
    }

    /// Analyzer を作って analyze を 1 回走らせる。
    func run(
        _ segments: [AbsoluteSegment], config: LLMConfig = AnalyzerHarness.config(),
        respond: @escaping @Sendable (Kind, String) -> ChatResult
    ) async -> (outcome: AnalyzeOutcome, calls: [FakeChatTransport.Call]) {
        let transport = transport(respond)
        let analyzer = Analyzer(transport: transport, prompts: prompts, config: config)
        let outcome = await analyzer.analyze(Self.transcript(segments))
        return (outcome, await transport.calls)
    }

    func transport(_ respond: @escaping @Sendable (Kind, String) -> ChatResult) -> FakeChatTransport {
        let harness = self
        return FakeChatTransport { call in respond(harness.kind(call.system), call.user) }
    }

    func kinds(_ calls: [FakeChatTransport.Call]) -> [Kind] {
        calls.map { kind($0.system) }
    }

    static func success(_ outcome: AnalyzeOutcome) -> (
        result: AnalysisResult, partials: [AnalysisResult], chunks: [Chunk], trimmed: [String]
    )? {
        if case .success(let result, let partials, let chunks, let trimmed) = outcome {
            return (result, partials, chunks, trimmed)
        }
        return nil
    }
}

@Suite("Analyzer")
struct AnalyzerTests {
    /// 「朝の話」@0 と「夜の話」@5000（時間で 2 チャンク）。
    static let twoChunks = [ChunkFixtures.seg("朝の話", 0), ChunkFixtures.seg("夜の話", 5000)]
    static let emptyPartialsJSON =
        #"[{"summary":"朝","key_points":[],"tasks":[],"decisions":[],"ideas":[]},"#
        + #"{"summary":"夜","key_points":[],"tasks":[],"decisions":[],"ideas":[]}]"#

    /// 2 チャンクの既定の応答（Map は朝・夜、Reduce は FINAL）。
    static func morningEvening(_ kind: AnalyzerHarness.Kind, _ user: String) -> ChatResult {
        switch kind {
        case .map where user == "朝の話": return AnalyzerHarness.partial("朝")
        case .map where user == "夜の話": return AnalyzerHarness.partial("夜")
        case .reduce: return AnalyzerHarness.final()
        default: return AnalyzerHarness.unexpected
        }
    }

    static func repeated(_ c: Character, _ n: Int) -> String {
        String(repeating: c, count: n)
    }

    @Test("チャンク 0 個は SESSION_MERGE_FAILED")
    func emptyTranscriptIsMergeFailure() async throws {
        let harness = try AnalyzerHarness()
        let (outcome, calls) = await harness.run([]) { _, _ in AnalyzerHarness.final() }
        #expect(outcome == .failure(StageFailure(.sessionMergeFailed, "チャンクが 0 個です（統合結果が空）")))
        #expect(calls.isEmpty)
    }

    @Test("1 チャンクなら analyze 1 回")
    func singleChunkUsesTheAnalyzePrompt() async throws {
        let harness = try AnalyzerHarness()
        let segs = [ChunkFixtures.seg("短い一", 0), ChunkFixtures.seg("短い二", 10)]
        let (outcome, calls) = await harness.run(segs) { kind, _ in
            kind == .analyze ? AnalyzerHarness.final() : AnalyzerHarness.unexpected
        }
        #expect(calls.count == 1)
        #expect(calls.first?.system == harness.analyzeSystem)
        #expect(calls.first?.user == "短い一\n短い二")
        let success = try #require(AnalyzerHarness.success(outcome))
        #expect(success.partials == [])
        #expect(success.chunks.count == 1)
        #expect(success.chunks.first?.text == "短い一\n短い二")
    }

    @Test("単一パスは重複除去しない")
    func singleChunkIsNotDeduped() async throws {
        let harness = try AnalyzerHarness()
        let (outcome, _) = await harness.run([ChunkFixtures.seg("話", 0)]) { kind, _ in
            kind == .analyze ? AnalyzerHarness.final(#","key_points":["A","a"]"#) : AnalyzerHarness.unexpected
        }
        #expect(AnalyzerHarness.success(outcome)?.result.keyPoints == ["A", "a"])
    }

    @Test("単一パスの切り詰めの記録は前置き無し")
    func singleChunkTrimmedHasNoPrefix() async throws {
        let harness = try AnalyzerHarness()
        let (outcome, _) = await harness.run([ChunkFixtures.seg("話", 0)]) { kind, _ in
            kind == .analyze ? AnalyzerHarness.final(AnalyzerHarness.tags(20)) : AnalyzerHarness.unexpected
        }
        #expect(AnalyzerHarness.success(outcome)?.trimmed == ["tags: 20 -> 15"])
    }

    @Test("2 チャンク以上は Map → Reduce")
    func multipleChunksRunMapThenReduce() async throws {
        let harness = try AnalyzerHarness()
        let (outcome, calls) = await harness.run(Self.twoChunks, respond: Self.morningEvening)
        #expect(harness.kinds(calls) == [.map, .map, .reduce])
        #expect(calls.map(\.user).prefix(2) == ["朝の話", "夜の話"])
        #expect(calls.last?.user == Self.emptyPartialsJSON)
        let success = try #require(AnalyzerHarness.success(outcome))
        #expect(success.partials.map(\.summary) == ["朝", "夜"])
        #expect(success.chunks.count == 2)
    }

    @Test("Reduce に原文を再送しない")
    func reduceNeverResendsTheTranscript() async throws {
        let harness = try AnalyzerHarness()
        let (_, calls) = await harness.run(Self.twoChunks, respond: Self.morningEvening)
        let reduceUser = try #require(calls.first { harness.kind($0.system) == .reduce }?.user)
        #expect(!reduceUser.contains("朝の話"))
        #expect(!reduceUser.contains("夜の話"))
    }

    @Test("Reduce の結果は重複除去する")
    func reduceResultIsDeduped() async throws {
        let harness = try AnalyzerHarness()
        let (outcome, _) = await harness.run(Self.twoChunks) { kind, user in
            kind == .reduce ? .content(DedupeTests.applyInput) : Self.morningEvening(kind, user)
        }
        let success = try #require(AnalyzerHarness.success(outcome))
        DedupeTests.expectApplied(success.result)
    }

    @Test("切り詰めの記録に段を前置する")
    func trimmedNotesArePrefixed() async throws {
        let harness = try AnalyzerHarness()
        let (outcome, _) = await harness.run(Self.twoChunks) { kind, user in
            switch kind {
            case .map where user == "朝の話": return AnalyzerHarness.partial("朝", kp: (1...25).map { "k\($0)" })
            case .reduce: return AnalyzerHarness.final(AnalyzerHarness.tags(20))
            default: return Self.morningEvening(kind, user)
            }
        }
        #expect(AnalyzerHarness.success(outcome)?.trimmed == ["map: key_points: 25 -> 20", "reduce: tags: 20 -> 15"])
    }

    @Test("Map が落ちたら Reduce へ進まない")
    func mapFailureStopsBeforeReduce() async throws {
        let harness = try AnalyzerHarness()
        let (outcome, calls) = await harness.run(Self.twoChunks) { kind, user in
            kind == .map && user == "夜の話" ? .failure(AnalyzerHarness.unavailable) : Self.morningEvening(kind, user)
        }
        #expect(outcome == .failure(AnalyzerHarness.unavailable))
        #expect(calls.count == 2)
    }

    @Test("Map の応答の title は未知キー")
    func mapUsesThePartialSchema() async throws {
        let harness = try AnalyzerHarness()
        let (outcome, calls) = await harness.run(Self.twoChunks) { kind, user in
            switch kind {
            case .map where user == "朝の話": return AnalyzerHarness.final()
            case .repair: return AnalyzerHarness.partial("朝")
            default: return Self.morningEvening(kind, user)
            }
        }
        let repairs = calls.filter { harness.kind($0.system) == .repair }
        #expect(repairs.count == 1)
        #expect(repairs.first?.system.contains("- title: Extra inputs are not permitted") == true)
        #expect(AnalyzerHarness.success(outcome)?.partials.map(\.summary) == ["朝", "夜"])
    }

    @Test("中間結果が 1 個なら束ねない")
    func singlePartialSkipsBundling() async throws {
        let harness = try AnalyzerHarness()
        let transport = harness.transport { kind, _ in
            kind == .reduce ? AnalyzerHarness.final() : AnalyzerHarness.unexpected
        }
        let analyzer = Analyzer(
            transport: transport, prompts: harness.prompts,
            config: AnalyzerHarness.config { $0.maxCharsPerRequest = 10 })
        let big = AnalysisResult(
            title: nil, summary: Self.repeated("s", 100), keyPoints: [], tasks: [], decisions: [], ideas: [], tags: nil)
        let result = await analyzer.reduce([big], depth: 1)
        #expect((try? result.get())?.0.title == "題")
        let calls = await transport.calls
        #expect(harness.kinds(calls) == [.reduce])
    }

    @Test("大きすぎる Reduce の入力は先に束ねる")
    func oversizedReduceInputFoldsFirst() async throws {
        let harness = try AnalyzerHarness()
        let config = AnalyzerHarness.config {
            $0.maxCharsPerRequest = 150
            $0.chunkOverlapChars = 0
        }
        let segs = [
            ChunkFixtures.seg(Self.repeated("a", 100), 0), ChunkFixtures.seg(Self.repeated("b", 100), 10),
            ChunkFixtures.seg(Self.repeated("c", 100), 20),
        ]
        let (outcome, calls) = await harness.run(segs, config: config) { kind, user in
            switch kind {
            case .map where user.hasPrefix("["):
                return user.contains("\"s1\"") ? AnalyzerHarness.partial("f1") : AnalyzerHarness.partial("f2")
            case .map where user.hasPrefix("a"): return AnalyzerHarness.partial("s1")
            case .map where user.hasPrefix("b"): return AnalyzerHarness.partial("s2")
            case .map where user.hasPrefix("c"): return AnalyzerHarness.partial("s3")
            case .reduce: return AnalyzerHarness.final()
            default: return AnalyzerHarness.unexpected
            }
        }
        #expect(harness.kinds(calls) == [.map, .map, .map, .map, .map, .reduce])
        let empty = #""key_points":[],"tasks":[],"decisions":[],"ideas":[]}"#
        try #require(calls.count == 6)
        #expect(calls[3].system == harness.mapSystem)
        #expect(calls[3].user == #"[{"summary":"s1","# + empty + #",{"summary":"s2","# + empty + "]")
        #expect(calls[4].user == #"[{"summary":"s3","# + empty + "]")
        #expect(calls[5].user == #"[{"summary":"f1","# + empty + #",{"summary":"f2","# + empty + "]")
        #expect(AnalyzerHarness.success(outcome)?.partials.map(\.summary) == ["s1", "s2", "s3"])
    }

    @Test("束の Map の切り詰めは reduce1: を前置する")
    func foldTrimmedNotesArePrefixed() async throws {
        let harness = try AnalyzerHarness()
        let config = AnalyzerHarness.config {
            $0.maxCharsPerRequest = 400
            $0.chunkOverlapChars = 0
        }
        let segs = [
            ChunkFixtures.seg(Self.repeated("a", 300), 0), ChunkFixtures.seg(Self.repeated("b", 300), 10),
            ChunkFixtures.seg(Self.repeated("c", 300), 20),
        ]
        let (outcome, calls) = await harness.run(segs, config: config) { kind, user in
            switch kind {
            case .map where user.hasPrefix("["):
                if user.contains(Self.repeated("A", 150)) {
                    return AnalyzerHarness.partial("f1", kp: Array(repeating: "k", count: 25))
                }
                return user.contains(Self.repeated("B", 150))
                    ? AnalyzerHarness.partial("f2") : AnalyzerHarness.partial("f3")
            case .map where user.hasPrefix("a"): return AnalyzerHarness.partial(Self.repeated("A", 150))
            case .map where user.hasPrefix("b"): return AnalyzerHarness.partial(Self.repeated("B", 150))
            case .map where user.hasPrefix("c"): return AnalyzerHarness.partial(Self.repeated("C", 150))
            case .reduce: return AnalyzerHarness.final()
            default: return AnalyzerHarness.unexpected
            }
        }
        #expect(calls.count == 7)
        #expect(AnalyzerHarness.success(outcome)?.trimmed == ["reduce1: key_points: 25 -> 20"])
    }

    @Test("段数の上限で LLM_INVALID_JSON")
    func depthLimitStopsRecursion() async throws {
        let harness = try AnalyzerHarness()
        let config = AnalyzerHarness.config {
            $0.maxCharsPerRequest = 50
            $0.chunkOverlapChars = 0
        }
        let segs = [
            ChunkFixtures.seg(Self.repeated("x", 40), 0), ChunkFixtures.seg(Self.repeated("y", 40), 10),
            ChunkFixtures.seg(Self.repeated("z", 40), 20),
        ]
        let (outcome, calls) = await harness.run(segs, config: config) { kind, _ in
            kind == .map ? AnalyzerHarness.partial(Self.repeated("S", 60)) : AnalyzerHarness.final()
        }
        #expect(outcome == .failure(StageFailure(.llmInvalidJSON, "多段 Reduce が上限 3 段に達しました")))
        #expect(calls.count == 9)
        #expect(!harness.kinds(calls).contains(.reduce))
    }

    @Test("reduceMaxItems（4）を超える件数は本文が小さくても束ねる（X-43）")
    func manyItemsFoldEvenWhenBodyIsSmall() async throws {
        let harness = try AnalyzerHarness()
        let segs = (0..<5).map { ChunkFixtures.seg("m\($0)", $0 * 5000) }
        let (outcome, calls) = await harness.run(segs) { kind, user in
            switch kind {
            case .map where user.hasPrefix("["):
                return user.contains("\"s0\"") ? AnalyzerHarness.partial("f1") : AnalyzerHarness.partial("f2")
            case .map:
                guard let n = ["m0", "m1", "m2", "m3", "m4"].firstIndex(where: { user.hasPrefix($0) }) else {
                    return AnalyzerHarness.unexpected
                }
                return AnalyzerHarness.partial("s\(n)")
            case .reduce: return AnalyzerHarness.final()
            default: return AnalyzerHarness.unexpected
            }
        }
        #expect(harness.kinds(calls) == Array(repeating: AnalyzerHarness.Kind.map, count: 7) + [.reduce])
        try #require(calls.count == 8)
        let empty = #""key_points":[],"tasks":[],"decisions":[],"ideas":[]}"#
        #expect(calls[7].user == #"[{"summary":"f1","# + empty + #",{"summary":"f2","# + empty + "]")
        #expect(AnalyzerHarness.success(outcome)?.partials.map(\.summary) == ["s0", "s1", "s2", "s3", "s4"])
    }

    @Test("Reduce の接続失敗はそのまま")
    func transportFailureInReduceIsReturned() async throws {
        let harness = try AnalyzerHarness()
        let (outcome, _) = await harness.run(Self.twoChunks) { kind, user in
            kind == .reduce ? .failure(AnalyzerHarness.unavailable) : Self.morningEvening(kind, user)
        }
        #expect(outcome == .failure(AnalyzerHarness.unavailable))
    }

    @Test("CE llm.maxCharsPerRequest を小さくすると Map → Reduce になる")
    func ceMaxCharsPerRequest() async throws {
        let harness = try AnalyzerHarness()
        let segs = [ChunkFixtures.seg(Self.repeated("a", 100), 0), ChunkFixtures.seg(Self.repeated("b", 100), 10)]
        let respond: @Sendable (AnalyzerHarness.Kind, String) -> ChatResult = { kind, user in
            switch kind {
            case .analyze, .reduce: return AnalyzerHarness.final()
            case .map where user.hasPrefix("a"): return AnalyzerHarness.partial("朝")
            case .map where user.hasPrefix("b"): return AnalyzerHarness.partial("夜")
            default: return AnalyzerHarness.unexpected
            }
        }
        let (_, defaultCalls) = await harness.run(segs, respond: respond)
        #expect(harness.kinds(defaultCalls) == [.analyze])
        let (outcome, smallCalls) = await harness.run(
            segs, config: AnalyzerHarness.config { $0.maxCharsPerRequest = 150 }, respond: respond)
        // 2 チャンク（200 > 150）。Reduce の入力は 139 スカラー（≤ 150）なので束ねずに reduce 1 回。
        #expect(harness.kinds(smallCalls) == [.map, .map, .reduce])
        #expect(smallCalls.last?.user == Self.emptyPartialsJSON)
        #expect(TextLimit.scalarCount(Self.emptyPartialsJSON) == 139)
        #expect(AnalyzerHarness.success(outcome)?.chunks.count == 2)
    }

    @Test("CE llm.maxSecondsPerRequest を小さくすると時間で割れる")
    func ceMaxSecondsPerRequest() async throws {
        let harness = try AnalyzerHarness()
        let segs = [ChunkFixtures.seg("朝", 0), ChunkFixtures.seg("昼", 1800)]
        let respond: @Sendable (AnalyzerHarness.Kind, String) -> ChatResult = { kind, user in
            switch kind {
            case .analyze, .reduce: return AnalyzerHarness.final()
            case .map: return AnalyzerHarness.partial(user)
            case .repair: return AnalyzerHarness.unexpected
            }
        }
        let (_, defaultCalls) = await harness.run(segs, respond: respond)
        #expect(harness.kinds(defaultCalls) == [.analyze])
        let (_, smallCalls) = await harness.run(
            segs, config: AnalyzerHarness.config { $0.maxSecondsPerRequest = 600 }, respond: respond)
        #expect(harness.kinds(smallCalls) == [.map, .map, .reduce])
    }

    @Test("CE llm.chunkOverlapChars が次のチャンクの重なりを決める")
    func ceChunkOverlapChars() async throws {
        let harness = try AnalyzerHarness()
        let segs = [ChunkFixtures.seg("aaaa", 0), ChunkFixtures.seg("bb", 10), ChunkFixtures.seg("cccccc", 20)]
        let respond: @Sendable (AnalyzerHarness.Kind, String) -> ChatResult = { kind, _ in
            kind == .map ? AnalyzerHarness.partial("p") : AnalyzerHarness.final()
        }
        let (_, three) = await harness.run(
            segs,
            config: AnalyzerHarness.config {
                $0.maxCharsPerRequest = 10
                $0.chunkOverlapChars = 3
            }, respond: respond)
        let (_, zero) = await harness.run(
            segs,
            config: AnalyzerHarness.config {
                $0.maxCharsPerRequest = 10
                $0.chunkOverlapChars = 0
            }, respond: respond)
        #expect(three.count > 1 && harness.kind(three[1].system) == .map)
        #expect(three.count > 1 && three[1].user == "bb\ncccccc")
        #expect(zero.count > 1 && harness.kind(zero[1].system) == .map)
        #expect(zero.count > 1 && zero[1].user == "cccccc")
    }
}
