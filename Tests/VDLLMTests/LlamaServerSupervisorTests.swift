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
final class PortSequence: Sendable {
    private let remaining: Mutex<[UInt16]>

    init(_ ports: [UInt16]) {
        remaining = Mutex(ports)
    }

    func next() -> UInt16? {
        remaining.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}

/// 本物の ProcessRunner に委ね、spawn した子を覚える（pid の生死を確かめるため）。
actor SpawnRecordingRunner: ProcessRunning {
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

/// 偽の llama-server の invocation 回目が API キーファイルを読み終えるまで（最大 10 秒）応答を止める。
/// 本物の llama-server は起動してから /health に応答するので、偽物の /health もそれに合わせる（スクリプトが走る前に 200 を返さない）。
func waitUntilStarted(_ fake: FakeLlamaServer, invocation: Int) {
    for _ in 0..<1000 {
        if let key = try? fake.apiKey(ofInvocation: invocation), key.unicodeScalars.count == 32 { return }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

/// invocation 回目の起動を待ってから、503 を failures 回返し、その後は 200 を返す /health（failures が nil なら常に 503）。
func healthReply(_ fake: FakeLlamaServer, invocation: Int, failures: Int?) -> @Sendable (StubRequest) -> StubReply {
    let seen = Mutex(0)
    return { _ in
        waitUntilStarted(fake, invocation: invocation)
        guard let failures else { return .http(status: 503, body: Data()) }
        let n = seen.withLock { value in
            value += 1
            return value
        }
        return n > failures
            ? .http(status: 200, body: Data(#"{"status":"ok"}"#.utf8)) : .http(status: 503, body: Data())
    }
}

@Suite("LlamaServerSupervisor", .serialized)
struct LlamaServerSupervisorTests {
    struct Rig {
        let tmp: TempDirectory
        let layout: HomeLayout
        let fake: FakeLlamaServer
        let model: URL
        let runner: SpawnRecordingRunner
        let sleeper: RecordingSleeper
        let sink: CapturingLogSink
        let supervisor: LlamaServerSupervisor
        let config: LLMConfig
    }

    static func makeRig(
        mode: FakeLlamaServer.Mode, picker: @escaping @Sendable () -> UInt16?,
        clock: any AppClock = FixedClock(epochMillis: 0)
    ) throws -> Rig {
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
        return Rig(
            tmp: tmp, layout: layout, fake: fake, model: model, runner: runner, sleeper: sleeper, sink: sink,
            supervisor: supervisor, config: AppConfig.defaults(timeZone: "Asia/Tokyo").llm)
    }

    static func pickPorts(_ n: Int) throws -> [UInt16] {
        var ports: [UInt16] = []
        while ports.count < n {
            let port = try #require(FreePort.pick())
            if !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    static func isGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    static func expectedArguments(model: URL, port: UInt16, layout: HomeLayout) -> [String] {
        [
            "--model", model.path(percentEncoded: false), "--host", "127.0.0.1", "--port", "\(port)",
            "--api-key-file", layout.llamaAPIKeyFile.path(percentEncoded: false), "--ctx-size", "32768",
            "--n-gpu-layers", "999", "--jinja", "--parallel", "1", "--no-webui", "--offline",
        ]
    }

    static func isLowerHex32(_ key: String) -> Bool {
        key.unicodeScalars.count == 32
            && key.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    @Test("起動して /health が 200 になるまで待つ")
    func startsAndWaitsForHealth() async throws {
        let ports = try Self.pickPorts(1)
        let sequence = PortSequence(ports)
        let rig = try Self.makeRig(mode: .stayAlive, picker: { sequence.next() })
        LoopbackStub.register(port: ports[0], healthReply(rig.fake, invocation: 1, failures: 2))
        defer { LoopbackStub.unregister(port: ports[0]) }
        let result = await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
        let handle = try result.get()
        #expect(handle.endpoint.port == ports[0])
        #expect(handle.modelID == "m-id")
        #expect(rig.fake.invocationCount() == 1)
        #expect(
            try rig.fake.arguments(ofInvocation: 1)
                == Self.expectedArguments(model: rig.model, port: ports[0], layout: rig.layout))
        let keyPath = rig.layout.llamaAPIKeyFile.path(percentEncoded: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: keyPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let stored = try String(contentsOfFile: keyPath, encoding: .utf8)
        #expect(Self.isLowerHex32(stored))
        #expect(stored == handle.apiKey)
        #expect(try rig.fake.apiKey(ofInvocation: 1) == handle.apiKey)
        #expect(rig.sleeper.recorded == [1, 1])
        let lines = rig.sink.lines
        #expect(lines.contains { $0.hasSuffix(" llm_server_started port=\(ports[0]) elapsed_s=0.0") }, "\(lines)")
        await rig.supervisor.stop()
    }

    @Test("同じ条件なら起動し直さない")
    func reusesARunningServer() async throws {
        let ports = try Self.pickPorts(2)
        let sequence = PortSequence(ports)
        let rig = try Self.makeRig(mode: .stayAlive, picker: { sequence.next() })
        for (index, port) in ports.enumerated() {
            LoopbackStub.register(port: port, healthReply(rig.fake, invocation: index + 1, failures: 0))
        }
        defer { for port in ports { LoopbackStub.unregister(port: port) } }
        let first = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config).get()
        let second = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config).get()
        #expect(first == second)
        #expect(rig.fake.invocationCount() == 1)
        #expect(await rig.runner.spawned.count == 1)
        await rig.supervisor.stop()
    }

    @Test("モデルが変わったら止めて起動し直す")
    func restartsWhenTheModelChanges() async throws {
        let ports = try Self.pickPorts(2)
        let sequence = PortSequence(ports)
        let rig = try Self.makeRig(mode: .stayAlive, picker: { sequence.next() })
        for (index, port) in ports.enumerated() {
            LoopbackStub.register(port: port, healthReply(rig.fake, invocation: index + 1, failures: 0))
        }
        defer { for port in ports { LoopbackStub.unregister(port: port) } }
        let other = rig.tmp.url.appendingPathComponent("other.gguf", isDirectory: false)
        try Data().write(to: other)
        let first = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config).get()
        let second = try await rig.supervisor.ensureRunning(model: other, modelID: "m-id", config: rig.config).get()
        #expect(first.endpoint.port == ports[0])
        #expect(second.endpoint.port == ports[1])
        #expect(rig.fake.invocationCount() == 2)
        let spawned = await rig.runner.spawned
        try #require(spawned.count == 2)
        #expect(Self.isGone(spawned[0].pid))
        let lines = rig.sink.lines
        #expect(lines.contains { $0.hasSuffix(" llm_server_stopped port=\(ports[0])") }, "\(lines)")
        await rig.supervisor.stop()
    }

    @Test("起動に失敗したら別のポートで")
    func retriesOnAnotherPort() async throws {
        let ports = try Self.pickPorts(3)
        let sequence = PortSequence(ports)
        let rig = try Self.makeRig(mode: .exitBeforeAttempt(3, code: 1), picker: { sequence.next() })
        LoopbackStub.register(port: ports[2], healthReply(rig.fake, invocation: 3, failures: 0))
        defer { LoopbackStub.unregister(port: ports[2]) }
        let handle = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config).get()
        #expect(handle.endpoint.port == ports[2])
        #expect(rig.fake.invocationCount() == 3)
        for n in 1...3 {
            let arguments = try rig.fake.arguments(ofInvocation: n)
            let index = try #require(arguments.firstIndex(of: "--port"))
            #expect(arguments[index + 1] == "\(ports[n - 1])")
        }
        await rig.supervisor.stop()
    }

    @Test("3 回失敗したら LLM_UNAVAILABLE")
    func failsAfterThreeAttempts() async throws {
        let ports = try Self.pickPorts(3)
        let sequence = PortSequence(ports)
        let rig = try Self.makeRig(mode: .exitImmediately(code: 1), picker: { sequence.next() })
        let result = await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
        #expect(
            result
                == .failure(
                    StageFailure(.llmUnavailable, "server_start_failed: exited(1): fake llama-server attempt 3")))
        #expect(rig.fake.invocationCount() == 3)
        #expect(!FileManager.default.fileExists(atPath: rig.layout.llamaAPIKeyFile.path(percentEncoded: false)))
    }

    @Test("300 秒で諦める")
    func timesOutAfter300Seconds() async throws {
        let ports = try Self.pickPorts(3)
        let sequence = PortSequence(ports)
        let rig = try Self.makeRig(
            mode: .stayAlive, picker: { sequence.next() },
            clock: SteppingClock(start: Instant(epochMillis: 0), stepMilliseconds: 1000))
        for (index, port) in ports.enumerated() {
            LoopbackStub.register(port: port, healthReply(rig.fake, invocation: index + 1, failures: nil))
        }
        defer { for port in ports { LoopbackStub.unregister(port: port) } }
        let result = await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
        #expect(
            result
                == .failure(StageFailure(.llmUnavailable, "server_start_failed: timeout: fake llama-server attempt 3")))
        #expect(rig.fake.invocationCount() == 3)
        let spawned = await rig.runner.spawned
        #expect(spawned.count == 3)
        for process in spawned {
            #expect(await !process.isRunning)
            #expect(Self.isGone(process.pid))
        }
        #expect(!FileManager.default.fileExists(atPath: rig.layout.llamaAPIKeyFile.path(percentEncoded: false)))
    }

    @Test("空きポートが取れなければ起動しない")
    func noPortFails() async throws {
        let rig = try Self.makeRig(mode: .stayAlive, picker: { nil })
        let result = await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config)
        #expect(result == .failure(StageFailure(.llmUnavailable, "server_start_failed: no_port")))
        #expect(rig.fake.invocationCount() == 0)
        #expect(await rig.runner.spawned.isEmpty)
    }

    @Test("停止でプロセスと鍵ファイルを消す")
    func stopTerminatesAndRemovesTheKey() async throws {
        let ports = try Self.pickPorts(1)
        let sequence = PortSequence(ports)
        let rig = try Self.makeRig(mode: .stayAlive, picker: { sequence.next() })
        LoopbackStub.register(port: ports[0], healthReply(rig.fake, invocation: 1, failures: 0))
        defer { LoopbackStub.unregister(port: ports[0]) }
        _ = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config).get()
        let keyPath = rig.layout.llamaAPIKeyFile.path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: keyPath))
        await rig.supervisor.stop()
        let spawned = await rig.runner.spawned
        try #require(spawned.count == 1)
        #expect(Self.isGone(spawned[0].pid))
        #expect(!FileManager.default.fileExists(atPath: keyPath))
        let lines = rig.sink.lines
        #expect(lines.last?.hasSuffix(" llm_server_stopped port=\(ports[0])") == true, "\(lines)")
    }

    @Test("起動していなければ停止は何もしない")
    func stopWithoutServerDoesNothing() async throws {
        let rig = try Self.makeRig(mode: .stayAlive, picker: { nil })
        await rig.supervisor.stop()
        #expect(rig.sink.lines.isEmpty)
        #expect(await rig.runner.spawned.isEmpty)
    }

    @Test("API キーを引数に置かない")
    func keyIsNotInTheArguments() async throws {
        let ports = try Self.pickPorts(1)
        let sequence = PortSequence(ports)
        let rig = try Self.makeRig(mode: .stayAlive, picker: { sequence.next() })
        LoopbackStub.register(port: ports[0], healthReply(rig.fake, invocation: 1, failures: 0))
        defer { LoopbackStub.unregister(port: ports[0]) }
        let handle = try await rig.supervisor.ensureRunning(model: rig.model, modelID: "m-id", config: rig.config).get()
        let arguments = try rig.fake.arguments(ofInvocation: 1)
        #expect(!arguments.isEmpty)
        #expect(!arguments.contains { $0.contains(handle.apiKey) })
        await rig.supervisor.stop()
    }
}
