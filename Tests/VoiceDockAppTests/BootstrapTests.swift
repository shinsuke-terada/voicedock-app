// Bootstrap の起動の順（PLAN §8.15）のテスト。本番の部品は組まず、順序の関数に偽物を渡す。
import Synchronization
import Testing

@testable import VoiceDockApp

@Suite("Bootstrap")
struct BootstrapTests {
    @Test("起動は復旧（Worker.start）を待ってから走査（IngestService.start）を始める")
    func startServicesAwaitsRecoveryBeforeScan() async {
        let order = Mutex<[String]>([])
        let task = await Bootstrap.startServices(
            workerStart: {
                // 復旧に時間が掛かっても、走査はその後
                try? await Task.sleep(for: .milliseconds(50))
                order.withLock { $0.append("start") }
            },
            workerRun: { order.withLock { $0.append("run") } },
            ingestStart: { order.withLock { $0.append("ingest") } })
        await task.value
        let recorded = order.withLock { $0 }
        #expect(recorded.first == "start")
        #expect(recorded.count == 3)
        #expect(Set(recorded) == ["start", "run", "ingest"])
    }
}
