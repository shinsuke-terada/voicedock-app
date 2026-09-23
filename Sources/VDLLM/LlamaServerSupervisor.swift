// llama-server の起動と停止（PLAN §8.5・§2.1）。Worker と DR-09 が単一のインスタンスを共有する。
import Foundation
import VDContract
import VDCore
import VDProcess

/// 起動済みの llama-server への接続に要るもの。
public struct LlamaServerHandle: Equatable, Sendable {
    public let endpoint: LoopbackEndpoint
    /// 小文字 16 進 32 文字
    public let apiKey: String
    /// 要求本文の "model" に入れる（カタログの ID か custom:<sha256>）
    public let modelID: String

    public init(endpoint: LoopbackEndpoint, apiKey: String, modelID: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.modelID = modelID
    }
}

/// llama-server を解析の間だけ起動する（PLAN §8.5・§2.1）。メモリの確認はここではしない（PLAN §5.4 のガード）。
public actor LlamaServerSupervisor {
    public static let maxAttempts = 3
    public static let startupTimeoutSeconds = 300
    public static let stopGraceSeconds = 10

    private let runner: any ProcessRunning
    private let paths: AppPaths
    private let layout: HomeLayout
    private let clock: any AppClock
    private let sleeper: any Sleeper
    private let log: AppLog
    private let factory: any LoopbackSessionFactory
    private let portPicker: @Sendable () -> UInt16?

    private var current: (process: RunningProcess, handle: LlamaServerHandle, model: URL, contextSize: Int)?
    private var starting: Task<Result<LlamaServerHandle, StageFailure>, Never>?
    private var stopping: Task<Void, Never>?
    /// 起動の途中（/health が 200 になる前）のプロセス。stop() が直ちに止める（F-76）
    private var launching: RunningProcess?
    /// 起動の途中に stop() が来た印。startServer は次の試行・次の待ちに進まずに抜ける（F-76）。停止が終われば下ろす
    private var abortStart = false

    public init(
        runner: any ProcessRunning, paths: AppPaths, layout: HomeLayout, clock: AppClock, sleeper: Sleeper, log: AppLog,
        factory: any LoopbackSessionFactory, portPicker: @escaping @Sendable () -> UInt16? = FreePort.pick
    ) {
        self.runner = runner
        self.paths = paths
        self.layout = layout
        self.clock = clock
        self.sleeper = sleeper
        self.log = log
        self.factory = factory
        self.portPicker = portPicker
    }

    /// 起動済みで同じモデル・同じ contextSize・生きていればそれを返す。違えば止めてから起動し直す。
    public func ensureRunning(model: URL, modelID: String, config: LLMConfig) async -> Result<
        LlamaServerHandle, StageFailure
    > {
        while true {
            // 起動・停止の途中なら終わりを待ち、自分の条件で比べ直す（actor の再入。2 つ起動しない）
            if let starting {
                _ = await starting.value
                continue
            }
            if let stopping {
                await stopping.value
                continue
            }
            if let c = current, c.model == model, c.contextSize == config.contextSize, c.handle.modelID == modelID,
                await c.process.isRunning
            {
                // isRunning の await の間に起動・停止が始まっていたり current が替わっていたら、先頭から比べ直す
                if starting == nil && stopping == nil && current?.handle == c.handle {
                    return .success(c.handle)
                }
                continue
            }
            // 上の await の間に別の呼び手が起動・停止を始めていれば、もう一度待つ
            if starting == nil && stopping == nil { break }
        }
        // 止めることと起動することを 1 つの Task にまとめ、await の前に starting を立てる
        let contextSize = config.contextSize
        // starting を空にするのは Task の中（終わる前）。待っていた呼び手が終わった Task を見て回り続けないため
        let task = Task {
            await self.stopCurrent()
            let result = await self.startServer(model: model, modelID: modelID, contextSize: contextSize)
            self.starting = nil
            return result
        }
        starting = task
        return await task.value
    }

    /// 起動していなければ何もしない。起動の途中なら、中止の印を立てて起動中のプロセスを直ちに止め、
    /// 起動を次の試行・次の待ちに進ませずに `server_start_failed: cancelled` で終わらせる（F-76。読み込みの完了を待たない）。
    /// 停止も 1 つの Task（stopping）にして、その間に来た ensureRunning を待たせる（停止の途中は起動しない。
    /// 新しい鍵ファイルを消さない）。停止が終われば、その後の ensureRunning は起動してよい。
    public func stop() async {
        while let stopping {
            await stopping.value
        }
        // stopping を立てるまでに await を挟まない（この後に来た ensureRunning は、この停止の終わりを待つ）
        let task = Task {
            await self.abortStarting()
            await self.stopCurrent()
            self.stopping = nil
        }
        stopping = task
        await task.value
    }

    /// 起動の途中なら中止させ、その終わりを待つ。起動中のプロセスは待たずに止める（F-76）。
    private func abortStarting() async {
        while let starting {
            abortStart = true
            if let process = launching {
                launching = nil
                _ = await process.terminate(grace: .seconds(Self.stopGraceSeconds))
            }
            _ = await starting.value
        }
        abortStart = false
    }

    /// SIGTERM → stopGraceSeconds → SIGKILL（プロセスグループごと）。API キーファイルを消す（PLAN §8.5）。
    private func stopCurrent() async {
        guard let c = current else { return }
        current = nil
        _ = await c.process.terminate(grace: .seconds(Self.stopGraceSeconds))
        log.info(.llmServerStopped, [(.port, .int(Int64(c.handle.endpoint.port)))])
        removeKeyFile()
    }

    /// maxAttempts 回まで、1 回ごとに別のポートで起動する。1 回ごとの失敗はログに出さない。
    /// await の後ごとに中止の印（abortStart）を見て、立っていれば次の試行・次の待ちに進まずに抜ける（F-76）。
    private func startServer(model: URL, modelID: String, contextSize: Int) async -> Result<
        LlamaServerHandle, StageFailure
    > {
        var lastReason = "no_port"
        var lastStderr = ""
        for _ in 1...Self.maxAttempts {
            if abortStart { return await abandon(nil) }
            guard let port = portPicker(), let endpoint = LoopbackEndpoint(port: port) else {
                lastReason = "no_port"
                lastStderr = ""
                continue
            }
            let key = Self.makeKey()
            do {
                try AtomicFile.write(Data(key.utf8), to: layout.llamaAPIKeyFile, permissions: 0o600)
            } catch {
                removeKeyFile()
                return .failure(StageFailure(.llmUnavailable, "server_start_failed: api_key_file"))
            }
            let spec = ProcessSpec(
                executable: paths.llamaServer,
                arguments: LlamaArgs.build(
                    model: model, port: port, apiKeyFile: layout.llamaAPIKeyFile, contextSize: contextSize),
                environment: ProcessEnvironment.standard)
            let process: RunningProcess
            do {
                process = try await runner.spawn(spec)
            } catch {
                lastReason = "spawn_failed"
                lastStderr = ""
                continue
            }
            launching = process
            if abortStart { return await abandon(process) }
            let started = clock.uptime()
            while true {
                // 200 の後に子の生存を確かめる（F-79。子が bind に失敗して終わっても、ポートを取った別のプロセスが
                // 200 を返しうる。死んでいれば下の「途中で終了した」と同じく exited(<n>) などで次の試行へ）
                if await LoopbackHealth.check(endpoint, factory: factory) == 200, await process.isRunning {
                    if abortStart { return await abandon(process) }
                    launching = nil
                    let handle = LlamaServerHandle(endpoint: endpoint, apiKey: key, modelID: modelID)
                    current = (process, handle, model, contextSize)
                    let elapsed = PyRound.round(Self.seconds(clock.uptime() - started), digits: 1)
                    log.info(.llmServerStarted, [(.port, .int(Int64(port))), (.elapsedS, .double(elapsed))])
                    return .success(handle)
                }
                if abortStart { return await abandon(process) }
                let running = await process.isRunning
                if abortStart { return await abandon(process) }
                if !running {
                    launching = nil
                    // 既に終わっているので終了の状態を得るだけ
                    let termination = await process.terminate(grace: .zero)
                    lastReason = Self.reason(termination)
                    lastStderr = String(decoding: await process.stderrTail(), as: UTF8.self)
                    break
                }
                if clock.uptime() - started >= .seconds(Self.startupTimeoutSeconds) {
                    launching = nil
                    _ = await process.terminate(grace: .seconds(Self.stopGraceSeconds))
                    lastReason = "timeout"
                    lastStderr = String(decoding: await process.stderrTail(), as: UTF8.self)
                    break
                }
                do {
                    try await sleeper.sleep(seconds: 1)
                } catch {
                    return await abandon(process)
                }
                if abortStart { return await abandon(process) }
            }
        }
        removeKeyFile()
        return .failure(StageFailure(.llmUnavailable, Self.message(lastReason, lastStderr)))
    }

    /// 起動をやめる（呼び手の取り消し・stop() の中止の印。F-76）。起動中のプロセスを止め、鍵ファイルを消す。
    /// stop() が先に止め始めていても、同じプロセスの terminate は同じ終わり方を返す（二重に待っても害が無い）。
    private func abandon(_ process: RunningProcess?) async -> Result<LlamaServerHandle, StageFailure> {
        launching = nil
        if let process { _ = await process.terminate(grace: .seconds(Self.stopGraceSeconds)) }
        removeKeyFile()
        return .failure(StageFailure(.llmUnavailable, "server_start_failed: cancelled"))
    }

    /// API キーファイルを消す（失敗は無視。PLAN §8.5）。
    private func removeKeyFile() {
        try? SafeUnlink.remove(layout.llamaAPIKeyFile, under: .run, layout: layout, missingOK: true)
    }

    /// SystemRandomNumberGenerator の 16 バイトを小文字 16 進 2 桁ずつつないだ 32 文字。
    private static func makeKey() -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        var key = ""
        for _ in 0..<16 {
            let byte = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
            key.append(digits[Int(byte >> 4)])
            key.append(digits[Int(byte & 0x0f)])
        }
        return key
    }

    private static func reason(_ termination: ProcessResult.Termination) -> String {
        switch termination {
        case .exited(let n): return "exited(\(n))"
        case .signaled(let n): return "signaled(\(n))"
        case .timedOut: return "timeout"
        case .spawnFailed: return "spawn_failed"
        }
    }

    /// `server_start_failed: <理由>: <stderr の末尾 150 スカラー>`。stderr が空なら `: ` 以降を付けない（PLAN §8.5）。
    private static func message(_ reason: String, _ stderr: String) -> String {
        let text = PyText.strip(stderr)
        if text.isEmpty {
            return "server_start_failed: \(reason)"
        }
        let scalars = text.unicodeScalars
        var tail = String.UnicodeScalarView()
        tail.append(contentsOf: scalars.suffix(150))
        return "server_start_failed: \(reason): \(String(tail))"
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
