// 終了の後始末を全体で打ち切ること・段の順・終了の直前に子を残さないこと（F-76・issue #116。PLAN §8.15）。
// 段は偽物のクロージャ。子プロセスは無害なコマンドだけ。
import Darwin
import Foundation
import Synchronization
import TestSupport
import Testing
import VDProcess

@testable import VoiceDockApp

/// 呼ばれた段の名前を順に覚える。
private final class StepLog: Sendable {
    private let names = Mutex<[String]>([])

    func add(_ name: String) { names.withLock { $0.append(name) } }

    var all: [String] { names.withLock { $0 } }
}

@Suite("AppDelegate（終了の後始末）", .serialized, .timeLimit(.minutes(1)))
struct AppDelegateShutdownTests {
    /// 段の名前を順に記録する ShutdownParts
    private static func recordingParts(_ log: StepLog) -> AppDelegate.ShutdownParts {
        AppDelegate.ShutdownParts(
            requestStop: { log.add("requestStop") },
            terminateChildren: { log.add("terminateChildren") },
            stopIngest: { log.add("stopIngest") },
            stopLLM: { log.add("stopLLM") },
            awaitWorker: { log.add("awaitWorker") })
    }

    @Test("F-76 段が 0 個なら直ちに終わる")
    func noStepsFinishImmediately() async {
        let clock = ContinuousClock()
        var finished = false
        let elapsed = await clock.measure {
            finished = await AppDelegate.shutDown(within: .seconds(10), [])
        }
        #expect(finished)
        #expect(elapsed < .seconds(1))
    }

    @Test("F-76 段を順に行い、最後まで終われば真")
    func stepsRunInOrder() async {
        let order = Mutex<[String]>([])
        let finished = await AppDelegate.shutDown(
            within: .seconds(10),
            [
                { order.withLock { $0.append("requestStop") } },
                { order.withLock { $0.append("terminateAll") } },
                { order.withLock { $0.append("llama") } },
                { order.withLock { $0.append("worker") } },
            ])
        #expect(finished)
        #expect(order.withLock { $0 } == ["requestStop", "terminateAll", "llama", "worker"])
    }

    @Test("F-76 本番の段の順: 停止要求 → 子を閉じて止める → 取り込み → llama → Worker の待ち（子を止める段が先）")
    func productionStepsKillChildrenFirst() async {
        let log = StepLog()
        let finished = await AppDelegate.shutDown(
            within: .seconds(10), AppDelegate.shutdownSteps(Self.recordingParts(log)))
        #expect(finished)
        #expect(log.all == ["requestStop", "terminateChildren", "stopIngest", "stopLLM", "awaitWorker"])
    }

    @Test("F-76 終了の直前に残った子を止め、以後の起動を拒む（後始末を飛ばして終わるときの備え）")
    @MainActor
    func killChildrenBeforeExitStopsLeftovers() async throws {
        let dir = try TempDirectory()
        let marker = dir.url.appending(path: "ran")
        let runner = ProcessRunner()
        let child = try await runner.spawn(
            ProcessSpec(executable: URL(filePath: "/bin/sleep"), arguments: ["30"], environment: [:]))
        #expect(AppDelegate.killChildrenBeforeExit(runner, within: .seconds(5)))
        let termination = await child.waitForExit()
        #expect(termination == .signaled(SIGTERM) || termination == .signaled(SIGKILL))
        let result = await runner.run(
            ProcessSpec(
                executable: URL(filePath: "/usr/bin/touch"), arguments: [marker.path(percentEncoded: false)],
                environment: [:]), timeout: .seconds(10))
        #expect(result.termination == .spawnFailed(errno: ECANCELED))
        #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
    }

    @Test("F-76 終わらない段があっても全体を timeout で打ち切り、後の段を待たない")
    func hangingStepIsCutOff() async {
        let order = Mutex<[String]>([])
        let clock = ContinuousClock()
        var finished = true
        let elapsed = await clock.measure {
            finished = await AppDelegate.shutDown(
                within: .milliseconds(300),
                [
                    { order.withLock { $0.append("terminateAll") } },
                    {
                        order.withLock { $0.append("llama") }
                        // 取り消しに応じない待ち（llama-server の読み込みの終わりを待つ `Task.value` の代わり）
                        await Task.detached { try? await Task.sleep(for: .seconds(5)) }.value
                    },
                    { order.withLock { $0.append("worker") } },
                ])
        }
        #expect(!finished)
        #expect(elapsed < .seconds(3))
        #expect(order.withLock { $0 } == ["terminateAll", "llama"])
    }
}
