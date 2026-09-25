// 子プロセスの実行（PLAN §8.2）。起動・出力の末尾・タイムアウト・プロセスグループごとの停止。
import Darwin
import Foundation
import Synchronization
import VDCore

public protocol ProcessRunning: Sendable {
    func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult
    func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess
}

public actor ProcessRunner: ProcessRunning {
    public static let killGrace: Duration = .seconds(5)  // SIGTERM から SIGKILL まで（PLAN §8.2）
    static let readerDrainGrace: Duration = .seconds(2)  // 子の終了後に出力の EOF を待つ上限
    /// terminateAll の後の run / spawn が返す errno（起動しなかった。F-76）。呼び手が「観測できなかった」と見分けるのに使う
    public static let closedErrno: Int32 = ECANCELED
    /// terminateAll が子の終わりを見直す間隔（全部が終われば grace を待たずに戻る。F-76）
    static let terminatePollInterval: Duration = .milliseconds(50)

    private var active: Set<pid_t> = []  // run 中と spawn 中の子（= プロセスグループ）
    /// terminateAll が SIGTERM を送った子（run が結果の `stoppedByTerminateAll` に写す。F-82）
    private var stoppedByTerminateAll: Set<pid_t> = []
    /// terminateAll の後は真。以後は子を起動しない（開き直さない。アプリの終了の後に子を残さない。F-76）
    private var closed = false

    public init() {}

    /// 完了まで待つ。起動の失敗は投げずに .spawnFailed で返す。タイムアウトと呼び手の取り消しは .timedOut。
    /// terminateAll の後は起動せずに .spawnFailed(errno: ECANCELED)（F-76）。
    /// 実行中に terminateAll が止めた子の結果は `stoppedByTerminateAll` が真（呼び手が失敗として記録しないため。F-82）
    public func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult {
        if closed {
            return ProcessResult(
                termination: .spawnFailed(errno: Self.closedErrno), stdoutTail: Data(), stderrTail: Data())
        }
        let child: SpawnedChild
        switch Spawn.start(spec) {
        case .success(let c):
            child = c
        case .failure(.spawnFailed(let e)), .failure(.pipeFailed(let e)):
            return ProcessResult(termination: .spawnFailed(errno: e), stdoutTail: Data(), stderrTail: Data())
        }
        let stdout = OutputTail(limit: ProcessResult.stdoutTailLimit)
        let stderr = OutputTail(limit: ProcessResult.stderrTailLimit)
        let readers = Task {
            async let a: Void = PipeReader.drain(fd: child.stdoutFD, into: stdout)
            async let b: Void = PipeReader.drain(fd: child.stderrFD, into: stderr)
            _ = await (a, b)
        }
        let exit = Task { await ExitWaiter.wait(pid: child.pid) }
        active.insert(child.pid)

        var timedOut = false
        if await !Self.race(exit: exit, timeout: timeout) {
            timedOut = true
            Self.signalGroup(child.pid, SIGTERM)
            if await !Self.race(exit: exit, timeout: Self.killGrace) { Self.signalGroup(child.pid, SIGKILL) }
        }
        let raw = await exit.value
        Self.signalGroup(child.pid, SIGKILL)  // 子の終了後に同じグループに残った孫を消す（ASR-07）
        await Self.finishReaders(readers, [stdout, stderr])
        active.remove(child.pid)
        let stopped = stoppedByTerminateAll.remove(child.pid) != nil
        return ProcessResult(
            termination: timedOut ? .timedOut : WaitStatus.termination(raw), stdoutTail: stdout.snapshot,
            stderrTail: stderr.snapshot, stoppedByTerminateAll: stopped)
    }

    /// 起動して手放す（llama-server）。止めるのは RunningProcess.terminate。
    /// terminateAll の後は起動せずに SpawnError.spawnFailed(errno: ECANCELED) を投げる（F-76）
    public func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess {
        if closed { throw .spawnFailed(errno: Self.closedErrno) }
        let child = try Spawn.start(spec).get()
        let stdout = OutputTail(limit: ProcessResult.stdoutTailLimit)
        let stderr = OutputTail(limit: ProcessResult.stderrTailLimit)
        let readers = Task {
            async let a: Void = PipeReader.drain(fd: child.stdoutFD, into: stdout)
            async let b: Void = PipeReader.drain(fd: child.stderrFD, into: stderr)
            _ = await (a, b)
        }
        let record = ExitRecord()
        let exit = Task {
            let raw = await ExitWaiter.wait(pid: child.pid)
            record.set(raw)
            return raw
        }
        active.insert(child.pid)
        let process = RunningProcess(
            pid: child.pid, exit: exit, record: record, readers: readers, stdout: stdout, stderr: stderr)
        Task {
            _ = await exit.value
            self.unregister(child.pid)
        }
        return process
    }

    /// アプリの終了（PLAN §8.15）。まず閉じる（以後の run / spawn は起動しない。F-76）→ 全グループに SIGTERM →
    /// 全部が終わるか grace が過ぎるまで待つ（呼び手の取り消しでも待つのをやめる）→ 残りに SIGKILL。
    /// 閉じることと写しを取ることの間に await を挟まない（actor の中で続けて行い、その間に起動された子を取りこぼさない）
    public func terminateAll(grace: Duration) async {
        closed = true
        let pids = active
        if pids.isEmpty { return }
        stoppedByTerminateAll.formUnion(pids)
        for pid in pids { Self.signalGroup(pid, SIGTERM) }
        var waited: Duration = .zero
        while waited < grace, !pids.isDisjoint(with: active) {
            do { try await Task.sleep(for: Self.terminatePollInterval) } catch { break }
            waited += Self.terminatePollInterval
        }
        for pid in pids.intersection(active) { Self.signalGroup(pid, SIGKILL) }
    }

    /// spawn の子の終わり（spawn の子は結果を返さないので、止めた印もここで捨てる）
    func unregister(_ pid: pid_t) {
        active.remove(pid)
        stoppedByTerminateAll.remove(pid)
    }

    /// プロセスグループへシグナルを送る（ESRCH は無視）
    static func signalGroup(_ pgid: pid_t, _ signal: Int32) { _ = kill(-pgid, signal) }

    /// exit が timeout 以内に終われば true。呼び手のタスクが取り消されていれば false（= 止める側に倒す）
    static func race(exit: Task<Int32?, Never>, timeout: Duration) async -> Bool {
        await finishes(exit, within: timeout)
    }

    /// 出力の EOF を readerDrainGrace だけ待ち、過ぎたら読み取りに停止を要求して終わりを待つ
    static func finishReaders(_ readers: Task<Void, Never>, _ tails: [OutputTail]) async {
        let done = await finishes(readers, within: readerDrainGrace)
        if !done {
            for tail in tails { tail.requestStop() }
            await readers.value
        }
    }

    /// task が timeout 以内に終われば true。時間切れと呼び手のタスクの取り消しは false（止める側へ倒す）。
    /// withTaskGroup は抜ける前に残った子タスクを待つので使わない（Task.value の待ちは取り消しで中断されない）
    static func finishes<T: Sendable>(_ task: Task<T, Never>, within timeout: Duration) async -> Bool {
        let outcome = FirstOutcome()
        Task {  // task が終われば自然に終わる
            _ = await task.value
            outcome.settle(true)
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            outcome.settle(false)
        }
        let first = await withTaskCancellationHandler {
            await outcome.value()
        } onCancel: {
            outcome.settle(false)  // 取り消し（呼び手の取り消し）は「時間切れ」と同じに扱い、止める側へ倒す
        }
        timer.cancel()
        return first
    }
}

/// 最初に決まった Bool を 1 回だけ返す（finishes の時間切れと終了の早い方）。
final class FirstOutcome: Sendable {
    private let state: Mutex<State>
    struct State {
        var settled: Bool? = nil
        var continuation: CheckedContinuation<Bool, Never>? = nil
    }
    init() { state = Mutex(State()) }

    /// 最初の 1 回だけが効く。待っている value() があれば起こす
    func settle(_ result: Bool) {
        let waiting: CheckedContinuation<Bool, Never>? = state.withLock { st in
            if st.settled != nil { return nil }
            st.settled = result
            let c = st.continuation
            st.continuation = nil
            return c
        }
        waiting?.resume(returning: result)
    }

    /// 決まるまで待つ（既に決まっていればすぐ返す）
    func value() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let ready: Bool? = state.withLock { st in
                if let settled = st.settled { return settled }
                st.continuation = c
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }
}
