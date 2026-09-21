// VDProcess の内部（WaitStatus・OutputTail・Spawn の指定の検査）のテスト（T-12 §5.3）。
import Darwin
import Foundation
import Testing

@testable import VDProcess

@Suite("Spawn", .serialized, .timeLimit(.minutes(1)))
struct SpawnTests {
    @Test("waitpid の status を終了コードとシグナルに写す")
    func waitStatusDecoding() {
        #expect(WaitStatus.termination(0x0700) == .exited(7))
        #expect(WaitStatus.termination(0x0009) == .signaled(9))
        #expect(WaitStatus.termination(nil) == .exited(-1))
    }

    @Test("OutputTail は末尾だけを持つ")
    func outputTailKeepsSuffix() {
        let tail = OutputTail(limit: 4)
        Array("abc".utf8).withUnsafeBytes { tail.append($0) }
        Array("defg".utf8).withUnsafeBytes { tail.append($0) }
        #expect(tail.snapshot == Data("defg".utf8))
    }

    /// 子を 1 本起動して ExitWaiter で待つ。3 秒以内に返らなければ取りこぼしとして pid を返す（後始末に waitpid で回収する）
    private static func waitOne(_ path: String, _ arguments: [String], killAtOnce: Bool) async -> pid_t? {
        let spec = ProcessSpec(executable: URL(filePath: path), arguments: arguments, environment: [:])
        guard case .success(let child) = Spawn.start(spec) else { return -1 }
        close(child.stdoutFD)
        close(child.stderrFD)
        let exit = Task { await ExitWaiter.wait(pid: child.pid) }
        if killAtOnce { kill(child.pid, SIGKILL) }
        if await ProcessRunner.finishes(exit, within: .seconds(3)) { return nil }
        kill(child.pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(child.pid, &status, 0)
        return child.pid
    }

    @Test("並行に起動してすぐ終わる子の終了も取りこぼさない")
    func exitWaiterConcurrentEarlyExits() async {
        var lost: [pid_t] = []
        for _ in 0..<20 {
            lost += await withTaskGroup(of: pid_t?.self) { group in
                for i in 0..<20 {
                    group.addTask {
                        i.isMultiple(of: 2)
                            ? await Self.waitOne("/usr/bin/true", [], killAtOnce: false)
                            : await Self.waitOne("/bin/sleep", ["30"], killAtOnce: true)
                    }
                }
                var found: [pid_t] = []
                for await pid in group { if let pid { found.append(pid) } }
                return found
            }
        }
        #expect(lost == [])
    }

    @Test("= を含む環境変数名は EINVAL")
    func environmentKeyWithEqualsIsRejected() {
        let spec = ProcessSpec(executable: URL(filePath: "/usr/bin/true"), arguments: [], environment: ["A=B": "1"])
        switch Spawn.start(spec) {
        case .success(let child):
            Issue.record("起動してしまった: pid \(child.pid)")
        case .failure(let error):
            #expect(error == .spawnFailed(errno: EINVAL))
        }
    }
}
