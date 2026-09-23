// 終了の後始末を全体で打ち切ること（F-76・issue #116。PLAN §8.15「最大 10 秒待って終了」）。段は偽物のクロージャ。
import Foundation
import Synchronization
import Testing

@testable import VoiceDockApp

@Suite("AppDelegate（終了の後始末）", .timeLimit(.minutes(1)))
struct AppDelegateShutdownTests {
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
