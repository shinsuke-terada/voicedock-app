// /health が 200 でも、自分の子が死んでいれば起動済みにしない（PLAN §8.5。F-79・issue #118 の E3）。
// FreePort.pick() がポートを閉じてから llama-server が bind するまでの間に別のプロセスがそのポートを取ると、
// llama-server は bind に失敗して終わり、別のプロセスの 200 で起動済みと扱われ、以後の本文と API キーがそこへ送られた。
// 本物の ProcessRunner と偽の llama-server（FakeLlamaServer）で行う。/health の偽物は子が終わるのを待ってから 200 を返す。
import Darwin
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess

@testable import VDLLM

/// 決めておいたポートを順に返す（尽きたら nil）。
private final class ResponderTestPorts: Sendable {
    private let remaining: Mutex<[UInt16]>

    init(_ ports: [UInt16]) {
        remaining = Mutex(ports)
    }

    func next() -> UInt16? {
        remaining.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

/// 本物の ProcessRunner に委ね、spawn した子を順に覚える（/health の偽物が同期的に引けるよう Mutex で持つ）。
private final class SpawnLedger: ProcessRunning, Sendable {
    private let inner = ProcessRunner()
    private let spawned = Mutex<[RunningProcess]>([])

    func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult {
        await inner.run(spec, timeout: timeout)
    }

    func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess {
        let process = try await inner.spawn(spec)
        spawned.withLock { $0.append(process) }
        return process
    }

    /// index 番目（0 始まり）に起動した子。まだ無ければ nil
    func process(_ index: Int) -> RunningProcess? {
        spawned.withLock { index < $0.count ? $0[index] : nil }
    }

    var all: [RunningProcess] { spawned.withLock { $0 } }
}

private typealias HealthHandler = @Sendable (StubRequest) -> StubReply

private let healthOK = StubReply.http(status: 200, body: Data(#"{"status":"ok"}"#.utf8))

/// index 番目に起動した子が終わるのを待ってから 200 を返す（子の後にそのポートを取った別のプロセスの 200 の姿）。
/// 子は /health を呼ぶ前に spawn 済み（supervisor は spawn の後に /health を呼ぶ）。待ちの上限は LoopbackHealth.timeoutSeconds より短い 4 秒
private func answerAfterExit(_ ledger: SpawnLedger, index: Int) -> HealthHandler {
    { _ in
        guard let process = ledger.process(index) else { return .failure(.cannotConnectToHost) }
        let exited = DispatchSemaphore(value: 0)
        Task {
            _ = await process.waitForExit()
            exited.signal()
        }
        guard exited.wait(timeout: .now() + 4) == .success else { return .failure(.timedOut) }
        return healthOK
    }
}

/// 偽の llama-server の invocation 回目が API キーファイルを読み終える（印のファイル）のを待ってから 200 を返す（最大 4 秒）。
private func answerAfterStart(_ fake: FakeLlamaServer, invocation: Int) -> HealthHandler {
    { _ in
        for _ in 0..<400 {
            if let key = try? fake.apiKey(ofInvocation: invocation), key.unicodeScalars.count == 32 { return healthOK }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return .failure(.timedOut)
    }
}

@Suite("LlamaServerHealthResponder", .serialized, .timeLimit(.minutes(1)))
struct LlamaServerHealthResponderTests {
    private struct Rig {
        let layout: HomeLayout
        let fake: FakeLlamaServer
        let model: URL
        let ledger: SpawnLedger
        let sleeper: RecordingSleeper
        let sink: CapturingLogSink
        let supervisor: LlamaServerSupervisor
        let config: LLMConfig
        let ports: [UInt16]
    }

    /// ports は FreePort.pick() で先に取った列（重なりを除く）。終わったら（途中で失敗しても）子を止めて登録を外す
    private static func withRig(
        mode: FakeLlamaServer.Mode, ports portCount: Int, _ body: (Rig) async throws -> Void
    ) async throws {
        var ports: [UInt16] = []
        while ports.count < portCount {
            let port = try #require(FreePort.pick())
            if !ports.contains(port) { ports.append(port) }
        }
        let sequence = ResponderTestPorts(ports)
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        let fake = try FakeLlamaServer(directory: tmp.url.appendingPathComponent("fake", isDirectory: true), mode: mode)
        let paths = AppPaths(
            resources: PackageRoot.url.appendingPathComponent("Resources"), helpers: fake.helpersDirectory)
        let model = tmp.url.appendingPathComponent("m.gguf", isDirectory: false)
        try Data().write(to: model)
        let ledger = SpawnLedger()
        let sleeper = RecordingSleeper()
        let sink = CapturingLogSink()
        let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        let log = AppLog(sink: sink, level: .debug, unsafeContent: false, zone: zone, clock: FixedClock(epochMillis: 0))
        let supervisor = LlamaServerSupervisor(
            runner: ledger, paths: paths, layout: layout, clock: FixedClock(epochMillis: 0), sleeper: sleeper,
            log: log, factory: BlockingSessionFactory(), portPicker: { sequence.next() })
        let rig = Rig(
            layout: layout, fake: fake, model: model, ledger: ledger, sleeper: sleeper, sink: sink,
            supervisor: supervisor, config: AppConfig.defaults(timeZone: "Asia/Tokyo").llm, ports: ports)
        defer {
            for port in ports { LoopbackStub.unregister(port: port) }
        }
        do {
            try await body(rig)
        } catch {
            await Self.cleanUp(rig)
            throw error
        }
        await Self.cleanUp(rig)
    }

    private static func cleanUp(_ rig: Rig) async {
        await rig.supervisor.stop()
        for process in rig.ledger.all {
            _ = await process.terminate(grace: .zero)
        }
    }

    private static func started(_ rig: Rig) -> [String] {
        rig.sink.lines.filter { $0.contains(" llm_server_started ") }
    }

    @Test("F-79 /health が 200 でも子が死んでいれば起動済みにせず、次のポートで起動し直す")
    func deadChildIsNotStarted() async throws {
        try await Self.withRig(mode: .exitBeforeAttempt(2, code: 1), ports: 2) { rig in
            LoopbackStub.register(port: rig.ports[0], answerAfterExit(rig.ledger, index: 0))
            LoopbackStub.register(port: rig.ports[1], answerAfterStart(rig.fake, invocation: 2))
            let handle = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
                .get()
            #expect(handle.endpoint.port == rig.ports[1])
            #expect(rig.fake.invocationCount() == 2)
            #expect(LoopbackStub.requests(port: rig.ports[0]).count == 1)
            #expect(rig.sleeper.recorded == [])
            let lines = Self.started(rig)
            #expect(lines.count == 1)
            #expect(lines.first?.hasSuffix(" llm_server_started port=\(rig.ports[1]) elapsed_s=0.0") == true)
        }
    }

    @Test("F-79 /health が 200 でも子が 3 回とも死んでいれば server_start_failed: exited(<n>)（鍵ファイルを消す）")
    func deadChildrenFailWithExistingReason() async throws {
        try await Self.withRig(mode: .exitImmediately(code: 3), ports: 3) { rig in
            for (index, port) in rig.ports.enumerated() {
                LoopbackStub.register(port: port, answerAfterExit(rig.ledger, index: index))
            }
            let result = await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
            #expect(
                result
                    == .failure(
                        StageFailure(.llmUnavailable, "server_start_failed: exited(3): fake llama-server attempt 3")))
            #expect(rig.fake.invocationCount() == 3)
            #expect(Self.started(rig) == [])
            #expect(!FileManager.default.fileExists(atPath: rig.layout.llamaAPIKeyFile.path(percentEncoded: false)))
        }
    }
}
