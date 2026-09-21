// LlamaServerSupervisor のテスト（T-21 §5.3）。本物の ProcessRunner と偽の llama-server（FakeLlamaServer）で行う。
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
private final class PortSequence: Sendable {
    private let remaining: Mutex<[UInt16]>

    init(_ ports: [UInt16]) {
        remaining = Mutex(ports)
    }

    func next() -> UInt16? {
        remaining.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

/// 本物の ProcessRunner に委ね、spawn した子を覚える（pid の生死を確かめるため）。
private actor SpawnRecordingRunner: ProcessRunning {
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

/// 偽の llama-server の invocation 回目が API キーファイルを読み終えるまで（最大 4 秒）応答を止める。読み終えたら true。
/// 本物の llama-server は起動してから /health に応答するので、偽物の /health もそれに合わせる（スクリプトが走る前に 200 を返さない）。
/// 上限は LoopbackHealth.timeoutSeconds（5 秒）より短くする（URLSession の時間切れより先に、原因の見える失敗を返すため）。
private func waitUntilStarted(_ fake: FakeLlamaServer, invocation: Int) -> Bool {
    for _ in 0..<400 {
        if let key = try? fake.apiKey(ofInvocation: invocation), key.unicodeScalars.count == 32 { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return false
}

private typealias HealthHandler = @Sendable (StubRequest) -> StubReply

/// invocation 回目の起動を待ってから、503 を failures 回返し、その後は 200 を返す /health（failures が nil なら常に 503）。
private func healthReply(_ fake: FakeLlamaServer, invocation: Int, failures: Int?) -> HealthHandler {
    let seen = Mutex(0)
    return { _ in
        // 偽物が起動しなかったら黙って 200 を返さず、時間切れの失敗にする（原因が見えるように）
        guard waitUntilStarted(fake, invocation: invocation) else { return .failure(.timedOut) }
        guard let failures else { return .http(status: 503, body: Data()) }
        let n = seen.withLock { value in
            value += 1
            return value
        }
        return n > failures
            ? .http(status: 200, body: Data(#"{"status":"ok"}"#.utf8)) : .http(status: 503, body: Data())
    }
}

private struct Rig {
    let tmp: TempDirectory
    let layout: HomeLayout
    let fake: FakeLlamaServer
    let model: URL
    let runner: SpawnRecordingRunner
    let sleeper: RecordingSleeper
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

@Suite("LlamaServerSupervisor", .serialized, .timeLimit(.minutes(1)))
struct LlamaServerSupervisorTests {
    /// ports は FreePort.pick() で先に取った列（重なりを除く）。picker が nil を返すなら ports は空。
    private static func withRig(
        mode: FakeLlamaServer.Mode, ports portCount: Int, pickerReturnsNil: Bool = false,
        clock: any AppClock = FixedClock(epochMillis: 0), _ body: (Rig) async throws -> Void
    ) async throws {
        var ports: [UInt16] = []
        while ports.count < portCount {
            let port = try #require(FreePort.pick())
            if !ports.contains(port) { ports.append(port) }
        }
        let sequence = PortSequence(ports)
        let picker: @Sendable () -> UInt16? = { pickerReturnsNil ? nil : sequence.next() }
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        let fake = try FakeLlamaServer(directory: tmp.url.appendingPathComponent("fake", isDirectory: true), mode: mode)
        let paths = AppPaths(
            resources: PackageRoot.url.appendingPathComponent("Resources"), helpers: fake.helpersDirectory)
        let model = tmp.url.appendingPathComponent("m.gguf", isDirectory: false)
        try Data().write(to: model)
        let runner = SpawnRecordingRunner()
        let sleeper = RecordingSleeper()
        let sink = CapturingLogSink()
        let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        let log = AppLog(
            sink: sink, level: .debug, unsafeContent: false, zone: zone, clock: FixedClock(epochMillis: 0))
        let supervisor = LlamaServerSupervisor(
            runner: runner, paths: paths, layout: layout, clock: clock, sleeper: sleeper, log: log,
            factory: BlockingSessionFactory(), portPicker: picker)
        let rig = Rig(
            tmp: tmp, layout: layout, fake: fake, model: model, runner: runner, sleeper: sleeper, sink: sink,
            supervisor: supervisor, config: AppConfig.defaults(timeZone: "Asia/Tokyo").llm, ports: ports)
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

    private static func isLowerHex32(_ key: String) -> Bool {
        key.unicodeScalars.count == 32
            && key.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    @Test("起動して /health が 200 になるまで待つ")
    func startsAndWaitsForHealth() async throws {
        try await Self.withRig(mode: .stayAlive, ports: 1) { rig in
            let port = rig.ports[0]
            LoopbackStub.register(port: port, healthReply(rig.fake, invocation: 1, failures: 2))
            let handle = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
                .get()
            #expect(handle.endpoint.port == port)
            #expect(handle.modelID == "m-id")
            #expect(rig.fake.invocationCount() == 1)
            #expect(
                try rig.fake.arguments(ofInvocation: 1) == [
                    "--model", rig.model.path(percentEncoded: false), "--host", "127.0.0.1", "--port", "\(port)",
                    "--api-key-file", rig.keyPath, "--ctx-size", "32768", "--n-gpu-layers", "999", "--jinja",
                    "--parallel", "1", "--no-webui", "--offline",
                ])
            let attributes = try FileManager.default.attributesOfItem(atPath: rig.keyPath)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let stored = try String(contentsOfFile: rig.keyPath, encoding: .utf8)
            #expect(Self.isLowerHex32(stored))
            #expect(stored == handle.apiKey)
            #expect(try rig.fake.apiKey(ofInvocation: 1) == handle.apiKey)
            #expect(rig.sleeper.recorded == [1, 1])
            let lines = rig.sink.lines
            #expect(lines.contains { $0.hasSuffix(" llm_server_started port=\(port) elapsed_s=0.0") }, "\(lines)")
        }
    }

    @Test("同じ条件なら起動し直さない")
    func reusesARunningServer() async throws {
        try await Self.withRig(mode: .stayAlive, ports: 2) { rig in
            for (index, port) in rig.ports.enumerated() {
                LoopbackStub.register(port: port, healthReply(rig.fake, invocation: index + 1, failures: 0))
            }
            let first = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
                .get()
            let second = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
                .get()
            #expect(first == second)
            #expect(rig.fake.invocationCount() == 1)
            #expect(await rig.runner.spawned.count == 1)
        }
    }

    @Test("モデルが変わったら止めて起動し直す")
    func restartsWhenTheModelChanges() async throws {
        try await Self.withRig(mode: .stayAlive, ports: 2) { rig in
            for (index, port) in rig.ports.enumerated() {
                LoopbackStub.register(port: port, healthReply(rig.fake, invocation: index + 1, failures: 0))
            }
            let other = rig.tmp.url.appendingPathComponent("other.gguf", isDirectory: false)
            try Data().write(to: other)
            let first = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
                .get()
            let second = try await rig.supervisor.ensureRunning(model: other, modelID: "m-id", config: rig.config)
                .get()
            #expect(first.endpoint.port == rig.ports[0])
            #expect(second.endpoint.port == rig.ports[1])
            #expect(rig.fake.invocationCount() == 2)
            let spawned = await rig.runner.spawned
            try #require(spawned.count == 2)
            #expect(Self.isGone(spawned[0].pid))
            let lines = rig.sink.lines
            #expect(lines.contains { $0.hasSuffix(" llm_server_stopped port=\(rig.ports[0])") }, "\(lines)")
        }
    }

    @Test("同時に呼ばれても 2 つを同時に生かさない（actor の再入）")
    func concurrentCallsKeepOnlyOneAlive() async throws {
        try await Self.withRig(mode: .stayAlive, ports: 3) { rig in
            for (index, port) in rig.ports.enumerated() {
                LoopbackStub.register(port: port, healthReply(rig.fake, invocation: index + 1, failures: 0))
            }
            let b = rig.tmp.url.appendingPathComponent("b.gguf", isDirectory: false)
            let c = rig.tmp.url.appendingPathComponent("c.gguf", isDirectory: false)
            try Data().write(to: b)
            try Data().write(to: c)
            _ = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config).get()
            async let first = rig.supervisor.ensureRunning(model: b, modelID: "m-id", config: rig.config)
            async let second = rig.supervisor.ensureRunning(model: c, modelID: "m-id", config: rig.config)
            let (forB, forC) = await (first, second)
            let handleB = try forB.get()
            let handleC = try forC.get()
            // 起動中に来た呼び手は、終わりを待ってから自分の条件で比べ直す（別のモデルの handle を受け取らない）
            #expect(handleB.endpoint != handleC.endpoint)
            let spawned = await rig.runner.spawned
            #expect(spawned.count == 3)
            // 同時に生きている llama-server は 1 つだけ
            var alive = 0
            for process in spawned where await process.isRunning { alive += 1 }
            #expect(alive == 1)
            await rig.supervisor.stop()
            for process in spawned {
                #expect(Self.isGone(process.pid))
            }
            #expect(!FileManager.default.fileExists(atPath: rig.keyPath))
        }
    }

    @Test("起動に失敗したら別のポートで")
    func retriesOnAnotherPort() async throws {
        try await Self.withRig(mode: .exitBeforeAttempt(3, code: 1), ports: 3) { rig in
            LoopbackStub.register(port: rig.ports[2], healthReply(rig.fake, invocation: 3, failures: 0))
            let handle = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
                .get()
            #expect(handle.endpoint.port == rig.ports[2])
            #expect(rig.fake.invocationCount() == 3)
            for n in 1...3 {
                let arguments = try rig.fake.arguments(ofInvocation: n)
                let index = try #require(arguments.firstIndex(of: "--port"))
                #expect(arguments[index + 1] == "\(rig.ports[n - 1])")
            }
        }
    }

    @Test("3 回失敗したら LLM_UNAVAILABLE")
    func failsAfterThreeAttempts() async throws {
        try await Self.withRig(mode: .exitImmediately(code: 1), ports: 3) { rig in
            let result = await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
            #expect(
                result
                    == .failure(
                        StageFailure(.llmUnavailable, "server_start_failed: exited(1): fake llama-server attempt 3")))
            #expect(rig.fake.invocationCount() == 3)
            #expect(!FileManager.default.fileExists(atPath: rig.keyPath))
        }
    }

    @Test("300 秒で諦める")
    func timesOutAfter300Seconds() async throws {
        try await Self.withRig(
            mode: .stayAlive, ports: 3, clock: SteppingClock(start: Instant(epochMillis: 0), stepMilliseconds: 1000)
        ) { rig in
            for (index, port) in rig.ports.enumerated() {
                LoopbackStub.register(port: port, healthReply(rig.fake, invocation: index + 1, failures: nil))
            }
            let result = await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
            #expect(
                result
                    == .failure(
                        StageFailure(.llmUnavailable, "server_start_failed: timeout: fake llama-server attempt 3")))
            #expect(rig.fake.invocationCount() == 3)
            let spawned = await rig.runner.spawned
            #expect(spawned.count == 3)
            for process in spawned {
                #expect(await !process.isRunning)
                #expect(Self.isGone(process.pid))
            }
            #expect(!FileManager.default.fileExists(atPath: rig.keyPath))
        }
    }

    @Test("空きポートが取れなければ起動しない")
    func noPortFails() async throws {
        try await Self.withRig(mode: .stayAlive, ports: 0, pickerReturnsNil: true) { rig in
            let result = await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
            #expect(result == .failure(StageFailure(.llmUnavailable, "server_start_failed: no_port")))
            #expect(rig.fake.invocationCount() == 0)
            #expect(await rig.runner.spawned.isEmpty)
        }
    }

    @Test("停止でプロセスと鍵ファイルを消す")
    func stopTerminatesAndRemovesTheKey() async throws {
        try await Self.withRig(mode: .stayAlive, ports: 1) { rig in
            LoopbackStub.register(port: rig.ports[0], healthReply(rig.fake, invocation: 1, failures: 0))
            _ = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config).get()
            #expect(FileManager.default.fileExists(atPath: rig.keyPath))
            await rig.supervisor.stop()
            let spawned = await rig.runner.spawned
            try #require(spawned.count == 1)
            #expect(Self.isGone(spawned[0].pid))
            #expect(!FileManager.default.fileExists(atPath: rig.keyPath))
            let lines = rig.sink.lines
            #expect(lines.last?.hasSuffix(" llm_server_stopped port=\(rig.ports[0])") == true, "\(lines)")
        }
    }

    @Test("起動していなければ停止は何もしない")
    func stopWithoutServerDoesNothing() async throws {
        try await Self.withRig(mode: .stayAlive, ports: 0, pickerReturnsNil: true) { rig in
            await rig.supervisor.stop()
            #expect(rig.sink.lines.isEmpty)
            #expect(await rig.runner.spawned.isEmpty)
        }
    }

    @Test("API キーを引数に置かない")
    func keyIsNotInTheArguments() async throws {
        try await Self.withRig(mode: .stayAlive, ports: 1) { rig in
            LoopbackStub.register(port: rig.ports[0], healthReply(rig.fake, invocation: 1, failures: 0))
            let handle = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
                .get()
            let arguments = try rig.fake.arguments(ofInvocation: 1)
            #expect(!arguments.isEmpty)
            #expect(!arguments.contains { $0.contains(handle.apiKey) })
        }
    }
}
