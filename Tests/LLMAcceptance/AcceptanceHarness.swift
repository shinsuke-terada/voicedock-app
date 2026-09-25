// LLM 受け入れ試験の実行: llama-server の起動・Analyzer の実行・呼び出しの数え方（PLAN §10.6。T-24 §4.4）。
import Foundation
import Synchronization
import TestSupport
import VDContract
import VDCore
import VDLLM
import VDProcess

/// fixture 1 本の解析の結果。
struct AcceptanceRun: Sendable {
    let fixtureID: String
    let scalarCount: Int
    /// fixture の expected.maxTasksWithDue（判定 J3 が使う）。
    let maxTasksWithDue: Int
    let outcome: AnalyzeOutcome
    /// 本体の要求（user が空でないもの）。
    let calls: Int
    /// 修復が 1 回以上入った本体の要求。
    let repairedCalls: Int
    /// 修復の要求の総数。
    let repairs: Int
    let elapsed: Duration
}

/// 要求を数えながら本物の transport へ流す（T-19 §4.8: 修復の要求は user が空）。
final class CountingChatTransport: ChatTransport, Sendable {
    private let inner: any ChatTransport
    private let sent = Mutex<[Bool]>([])

    init(_ inner: any ChatTransport) {
        self.inner = inner
    }

    func complete(system: String, user: String) async -> ChatResult {
        sent.withLock { $0.append(user.isEmpty) }
        return await inner.complete(system: system, user: user)
    }

    /// 送った順の記録（true = 修復の要求）。
    func record() -> [Bool] {
        sent.withLock { $0 }
    }

    /// 記録から (本体の要求, 修復の入った本体の要求, 修復の要求) を数える。
    static func count(_ record: [Bool]) -> (calls: Int, repairedCalls: Int, repairs: Int) {
        var calls = 0
        var repairedCalls = 0
        var repairs = 0
        var previous: Bool?
        for isRepair in record {
            if isRepair {
                repairs += 1
                // 本体の要求の直後の最初の修復だけを数える（修復が続いても 1 回）
                if previous == false { repairedCalls += 1 }
            } else {
                calls += 1
            }
            previous = isRepair
        }
        return (calls, repairedCalls, repairs)
    }
}

struct AcceptanceHarness {
    /// モデルのファイルの場所（本番の `<HOME>` を読むだけ）。カタログに在ればその置き場所、無ければ custom:<sha256> の置き場所。
    static func modelURL(modelID: String, paths: AppPaths) -> Result<URL, AcceptanceError> {
        let prod = HomeLayout.production()
        let notFound: AcceptanceError = "モデル \(modelID) が見つかりません"
        guard let data = try? Data(contentsOf: paths.modelCatalog),
            case .success(let catalog) = ModelCatalog.load(data)
        else { return .failure(notFound) }
        let url: URL
        if let entry = catalog.entry(kind: .llm, id: modelID) {
            url = ModelFiles.url(kind: .llm, entry: entry, layout: prod)
        } else if let custom = ModelFiles.customLLMURL(id: modelID, layout: prod) {
            url = custom
        } else {
            return .failure(notFound)
        }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return .failure(notFound)
        }
        return .success(url)
    }

    /// 試験に使う AppPaths（リポジトリの Resources と Vendor/build/bin）。
    static var paths: AppPaths {
        let root = PackageRoot.url
        return AppPaths(
            resources: root.appendingPathComponent("Resources", isDirectory: true),
            helpers: root.appendingPathComponent("Vendor/build/bin", isDirectory: true))
    }

    /// llama-server を 1 回だけ起動し、10 本を順に流す。終わったら必ず stop する。
    static func run(modelID: String, fixtures: [AcceptanceFixture]) async -> Result<[AcceptanceRun], AcceptanceError> {
        let paths = Self.paths
        // 本番の <HOME> に書かない（llama-server の API キーは tmp/run/llama-api-key に出る）
        let tmp: TempDirectory
        do {
            tmp = try TempDirectory()
        } catch {
            return .failure("一時ディレクトリを作れません: \(error)")
        }
        defer { tmp.remove() }
        let layout = HomeLayout(root: tmp.url)
        do {
            try layout.createDirectories()
        } catch {
            return .failure("一時の HomeLayout を作れません: \(error)")
        }
        let modelURL: URL
        switch Self.modelURL(modelID: modelID, paths: paths) {
        case .failure(let message): return .failure(message)
        case .success(let url): modelURL = url
        }
        // 既定値で走らせる（利用者の config.json を読まない）
        let config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        let zone = ZonedTime(timeZone: TimeZone(identifier: config.timeZone) ?? .gmt)
        let clock = SystemClock()
        let supervisor = LlamaServerSupervisor(
            runner: ProcessRunner(), paths: paths, layout: layout, clock: clock, sleeper: TaskSleeper(),
            log: AppLog(sink: CapturingLogSink(), level: .info, unsafeContent: false, zone: zone, clock: clock),
            factory: EphemeralSessionFactory())
        let result = await runAll(
            supervisor: supervisor, modelURL: modelURL, modelID: modelID, config: config, paths: paths,
            fixtures: fixtures)
        await supervisor.stop()
        return result
    }

    /// 起動から fixture を順に流すまで（呼び手が必ず stop する）。
    private static func runAll(
        supervisor: LlamaServerSupervisor, modelURL: URL, modelID: String, config: AppConfig, paths: AppPaths,
        fixtures: [AcceptanceFixture]
    ) async -> Result<[AcceptanceRun], AcceptanceError> {
        let handle: LlamaServerHandle
        switch await supervisor.ensureRunning(model: modelURL, modelID: modelID, config: config.llm) {
        case .failure(let failure): return .failure(AcceptanceError(stringLiteral: failure.message))
        case .success(let h): handle = h
        }
        let prompts: Prompts
        do {
            prompts = try Prompts.load(directory: paths.promptsDirectory)
        } catch {
            return .failure("プロンプトを読めません: \(error)")
        }
        var runs: [AcceptanceRun] = []
        // 順に 1 本ずつ（並行に投げない）
        for fixture in fixtures {
            let counting = CountingChatTransport(
                LoopbackChatTransport(
                    endpoint: handle.endpoint, apiKey: handle.apiKey, modelID: handle.modelID, config: config.llm,
                    factory: EphemeralSessionFactory()))
            let analyzer = Analyzer(transport: counting, prompts: prompts, config: config.llm)
            let clock = ContinuousClock()
            let start = clock.now
            let outcome = await analyzer.analyze(fixture.transcript(gapSeconds: config.session.blockGapSeconds))
            let elapsed = clock.now - start
            let counted = CountingChatTransport.count(counting.record())
            runs.append(
                AcceptanceRun(
                    fixtureID: fixture.id, scalarCount: fixture.scalarCount, maxTasksWithDue: fixture.maxTasksWithDue,
                    outcome: outcome, calls: counted.calls, repairedCalls: counted.repairedCalls,
                    repairs: counted.repairs, elapsed: elapsed))
        }
        return .success(runs)
    }
}
