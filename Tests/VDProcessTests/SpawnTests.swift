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
