// LlamaServerSupervisor の起動の途中の停止（F-76・issue #116）。本物の ProcessRunner と偽の llama-server（FakeLlamaServer）で行う。
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
private final class StopTestPorts: Sendable {
    private let remaining: Mutex<[UInt16]>

    init(_ ports: [UInt16]) {
        remaining = Mutex(ports)
    }

    func next() -> UInt16? {
        remaining.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

/// 本物の ProcessRunner に委ね、spawn した子を覚える（pid の生死を確かめるため）。
private actor StopTestRunner: ProcessRunning {
    private let inner = ProcessRunner()
    private(set) var spawned: [RunningProcess] = []

    func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult {
        await inner.run(spec, timeout: timeout)
    }

    func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess {
        let process = try await inner.spawn(spec)
        spawned.append(process)
        return process
    }
}

/// /health の要求が来るたびに知らせる（テストが「起動の途中」に入ったことを知るため）。
private final class HealthSignal: Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    func notify() { continuation.yield(()) }
}

private typealias StopTestHandler = @Sendable (StubRequest) -> StubReply

/// 偽の llama-server の invocation 回目が API キーファイルを読み終えるまで（最大 4 秒）応答を止める。読み終えたら true。
private func started(_ fake: FakeLlamaServer, invocation: Int) -> Bool {
    for _ in 0..<400 {
        if let key = try? fake.apiKey(ofInvocation: invocation), key.unicodeScalars.count == 32 { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return false
}

/// 読み込み中の /health（起動を待ってから、知らせて 50 ms 置いて 503）。
private func loading(_ fake: FakeLlamaServer, invocation: Int, _ signal: HealthSignal) -> StopTestHandler {
    { _ in
        guard started(fake, invocation: invocation) else { return .failure(.timedOut) }
        signal.notify()
        Thread.sleep(forTimeInterval: 0.05)
        return .http(status: 503, body: Data())
    }
}

/// 応答の遅い /health の遅れ（LoopbackHealth の 5 秒より短く、テストの期限（stopDeadline）より十分長く）
private let slowHealthSeconds: TimeInterval = 4

/// 応答の遅い読み込み中の /health（起動を待ってから知らせ、slowHealthSeconds 置いて 503）。
private func slowLoading(_ fake: FakeLlamaServer, invocation: Int, _ signal: HealthSignal) -> StopTestHandler {
    { _ in
        guard started(fake, invocation: invocation) else { return .failure(.timedOut) }
        signal.notify()
        Thread.sleep(forTimeInterval: slowHealthSeconds)
        return .http(status: 503, body: Data())
    }
}

/// 起動を待ってから 200 を返す /health。
private func healthy(_ fake: FakeLlamaServer, invocation: Int) -> StopTestHandler {
    { _ in
        guard started(fake, invocation: invocation) else { return .failure(.timedOut) }
        return .http(status: 200, body: Data(#"{"status":"ok"}"#.utf8))
    }
}

private struct StopRig {
    let tmp: TempDirectory
    let layout: HomeLayout
    let fake: FakeLlamaServer
    let model: URL
    let runner: StopTestRunner
    let sink: CapturingLogSink
    let supervisor: LlamaServerSupervisor
    let config: LLMConfig
    let ports: [UInt16]

    var keyPath: String { layout.llamaAPIKeyFile.path(percentEncoded: false) }

    /// 後片付け。途中で失敗しても `sleep 600` のプロセスグループを残さない。
    func cleanUp() async {
        await supervisor.stop()
        for process in await runner.spawned {
            _ = await process.terminate(grace: .zero)
        }
        for port in ports {
            LoopbackStub.unregister(port: port)
        }
    }
}

/// 時計は 1 回ごとに 10 秒進む（起動の待ちは 30 回で時間切れになる。止めなければ 2・3 回目を起動してしまう）。
@Suite("LlamaServerSupervisor（起動の途中の停止）", .serialized, .timeLimit(.minutes(1)))
struct LlamaServerSupervisorStopTests {
    private static func withRig(ports portCount: Int, _ body: (StopRig) async throws -> Void) async throws {
        var ports: [UInt16] = []
        while ports.count < portCount {
            let port = try #require(FreePort.pick())
            if !ports.contains(port) { ports.append(port) }
        }
        let sequence = StopTestPorts(ports)
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        let fake = try FakeLlamaServer(
            directory: tmp.url.appendingPathComponent("fake", isDirectory: true), mode: .stayAlive)
        let paths = AppPaths(
            resources: PackageRoot.url.appendingPathComponent("Resources"), helpers: fake.helpersDirectory)
        let model = tmp.url.appendingPathComponent("m.gguf", isDirectory: false)
        try Data().write(to: model)
        let runner = StopTestRunner()
        let sink = CapturingLogSink()
        let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        let log = AppLog(
            sink: sink, level: .debug, unsafeContent: false, zone: zone, clock: FixedClock(epochMillis: 0))
        let supervisor = LlamaServerSupervisor(
            runner: runner, paths: paths, layout: layout,
            clock: SteppingClock(start: Instant(epochMillis: 0), stepMilliseconds: 10_000),
            sleeper: RecordingSleeper(), log: log, factory: BlockingSessionFactory(),
            portPicker: { sequence.next() })
        let rig = StopRig(
            tmp: tmp, layout: layout, fake: fake, model: model, runner: runner, sink: sink, supervisor: supervisor,
            config: AppConfig.defaults(timeZone: "Asia/Tokyo").llm, ports: ports)
        do {
            try await body(rig)
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }

    private static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    private static let cancelled = StageFailure(.llmUnavailable, "server_start_failed: cancelled")

    /// stop の後、起動中のプロセスが消えるまでの期限（/health の遅れ slowHealthSeconds より短い）
    private static let stopDeadline: Duration = .seconds(3)

    /// pid が消えるまで 20 ms ごとに最大 stopDeadline 待つ。消えれば true
    private static func waitUntilGone(_ pid: pid_t) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: stopDeadline)
        while !isGone(pid), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return isGone(pid)
    }

    @Test("F-76 起動の途中の stop は起動中のプロセスを直ちに止め、次の試行に進まない")
    func stopDuringStartupAbortsImmediately() async throws {
        try await Self.withRig(ports: 3) { rig in
            let signal = HealthSignal()
            for (index, port) in rig.ports.enumerated() {
                LoopbackStub.register(port: port, loading(rig.fake, invocation: index + 1, signal))
            }
            let starting = Task {
                await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
            }
            var requests = signal.stream.makeAsyncIterator()
            _ = await requests.next()
            await rig.supervisor.stop()
            #expect(await starting.value == .failure(Self.cancelled))
            #expect(rig.fake.invocationCount() == 1)
            let spawned = await rig.runner.spawned
            try #require(spawned.count == 1)
            #expect(await !spawned[0].isRunning)
            #expect(Self.isGone(spawned[0].pid))
            #expect(!FileManager.default.fileExists(atPath: rig.keyPath))
            let lines = rig.sink.lines
            #expect(!lines.contains { $0.contains(" llm_server_started ") }, "\(lines)")
        }
    }

    @Test("F-76 起動の途中の stop は /health の応答を待たずに起動中のプロセスを止める")
    func stopKillsTheLaunchingProcessWithoutWaitingForHealth() async throws {
        try await Self.withRig(ports: 1) { rig in
            let signal = HealthSignal()
            LoopbackStub.register(port: rig.ports[0], slowLoading(rig.fake, invocation: 1, signal))
            let starting = Task {
                await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
            }
            var requests = signal.stream.makeAsyncIterator()
            _ = await requests.next()
            let spawned = await rig.runner.spawned
            try #require(spawned.count == 1)
            let pid = spawned[0].pid
            // /health の応答（4 秒後）より前に、起動中のプロセスが消える
            let stopping = Task { await rig.supervisor.stop() }
            #expect(try await Self.waitUntilGone(pid))
            await stopping.value
            #expect(await starting.value == .failure(Self.cancelled))
            #expect(rig.fake.invocationCount() == 1)
        }
    }

    @Test("F-76 停止が終われば、その後の ensureRunning は起動する")
    func ensureRunningAfterStopStarts() async throws {
        try await Self.withRig(ports: 2) { rig in
            let signal = HealthSignal()
            LoopbackStub.register(port: rig.ports[0], loading(rig.fake, invocation: 1, signal))
            LoopbackStub.register(port: rig.ports[1], healthy(rig.fake, invocation: 2))
            let starting = Task {
                await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
            }
            var requests = signal.stream.makeAsyncIterator()
            _ = await requests.next()
            await rig.supervisor.stop()
            #expect(await starting.value == .failure(Self.cancelled))
            let handle = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
                .get()
            #expect(handle.endpoint.port == rig.ports[1])
            #expect(rig.fake.invocationCount() == 2)
            let spawned = await rig.runner.spawned
            try #require(spawned.count == 2)
            #expect(await spawned[1].isRunning)
            #expect(try String(contentsOfFile: rig.keyPath, encoding: .utf8) == handle.apiKey)
        }
    }

    @Test("F-76 停止の途中に来た ensureRunning は停止が終わってから起動する（中止した起動の後で止められない）")
    func ensureRunningDuringStopWaitsForTheStop() async throws {
        try await Self.withRig(ports: 2) { rig in
            let signal = HealthSignal()
            LoopbackStub.register(port: rig.ports[0], slowLoading(rig.fake, invocation: 1, signal))
            LoopbackStub.register(port: rig.ports[1], healthy(rig.fake, invocation: 2))
            let first = Task {
                await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
            }
            var requests = signal.stream.makeAsyncIterator()
            _ = await requests.next()
            let launching = await rig.runner.spawned
            try #require(launching.count == 1)
            // 停止を始める。起動中のプロセスが消えたら、停止は確かに途中（1 回目の起動は /health の遅い応答を待っている）
            let stopDone = Mutex(false)
            let stopping = Task {
                await rig.supervisor.stop()
                stopDone.withLock { $0 = true }
            }
            try #require(try await Self.waitUntilGone(launching[0].pid))
            try #require(!stopDone.withLock { $0 })
            // 停止の途中に、同じ条件の 2 つ目の呼び手が来る
            let second = Task {
                await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
            }
            await stopping.value
            #expect(await first.value == .failure(Self.cancelled))
            let handle = try await second.value.get()
            #expect(handle.endpoint.port == rig.ports[1])
            let spawned = await rig.runner.spawned
            try #require(spawned.count == 2)
            #expect(Self.isGone(spawned[0].pid))
            // 2 つ目の呼び手の llama-server は停止の後に起動したので、生きている
            #expect(await spawned[1].isRunning)
            #expect(try String(contentsOfFile: rig.keyPath, encoding: .utf8) == handle.apiKey)
        }
    }
}
