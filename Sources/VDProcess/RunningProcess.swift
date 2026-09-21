// spawn した子（llama-server）。止めるのは terminate（PLAN §8.5）。
import Darwin
import Foundation
import Synchronization

public final class RunningProcess: Sendable {
    public let pid: pid_t
    let exit: Task<Int32?, Never>
    let record: ExitRecord
    let readers: Task<Void, Never>
    let stdout: OutputTail
    let stderr: OutputTail

    init(
        pid: pid_t, exit: Task<Int32?, Never>, record: ExitRecord, readers: Task<Void, Never>, stdout: OutputTail,
        stderr: OutputTail
    ) {
        self.pid = pid
        self.exit = exit
        self.record = record
        self.readers = readers
        self.stdout = stdout
        self.stderr = stderr
    }

    public var isRunning: Bool { get async { !record.isSet } }
    public func stderrTail() async -> Data { stderr.snapshot }
    public func stdoutTail() async -> Data { stdout.snapshot }

    /// SIGTERM（グループ）→ grace 待つ → SIGKILL（グループ）。既に終わっていれば、その終わり方を返す
    public func terminate(grace: Duration) async -> ProcessResult.Termination {
        if record.isSet { return WaitStatus.termination(record.raw) }
        ProcessRunner.signalGroup(pid, SIGTERM)
        if await !ProcessRunner.race(exit: exit, timeout: grace) { ProcessRunner.signalGroup(pid, SIGKILL) }
        let raw = await exit.value
        ProcessRunner.signalGroup(pid, SIGKILL)  // 残った孫
        await ProcessRunner.finishReaders(readers, [stdout, stderr])
        return WaitStatus.termination(raw)
    }

    /// 終了を待つ（llama-server が勝手に落ちたことの検出に使う）
    public func waitForExit() async -> ProcessResult.Termination {
        WaitStatus.termination(await exit.value)
    }
}

final class ExitRecord: Sendable {
    private let state: Mutex<(set: Bool, raw: Int32?)>
    init() { state = Mutex((set: false, raw: nil)) }
    func set(_ raw: Int32?) { state.withLock { $0 = (true, raw) } }
    var isSet: Bool { state.withLock { $0.set } }
    var raw: Int32? { state.withLock { $0.raw } }
}
