// 安定性判定（T-14 §5.3）。stat は台本の閉包、待ちは RecordingSleeper（実際には待たない）。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDCore

@testable import VDDevice

@Suite("StabilityChecker")
struct StabilityCheckerTests {
    /// 2026-09-21T13:33:20Z
    static let nowSeconds: Double = 1_790_000_000
    static let clock = FixedClock(epochMillis: 1_790_000_000_000)

    static func deviceConfig() -> DeviceConfig { AppConfig.defaults(timeZone: "Asia/Tokyo").device }

    /// relpath ごとに呼ばれた回（0 始まり）を数え、台本の値を返す
    final class ScriptedStat: Sendable {
        private let calls = Mutex<[String: Int]>([:])
        private let script: @Sendable (String, Int) -> FileStat?

        init(_ script: @escaping @Sendable (String, Int) -> FileStat?) {
            self.script = script
        }

        var closure: @Sendable (String) -> FileStat? {
            { [self] rel in
                let index = calls.withLock { counts -> Int in
                    let n = counts[rel, default: 0]
                    counts[rel] = n + 1
                    return n
                }
                return script(rel, index)
            }
        }
    }

    struct CancellingSleeper: Sleeper {
        func sleep(seconds: Int) async throws { throw CancellationError() }
    }

    static func check(
        _ candidates: [String], config: DeviceConfig = deviceConfig(), sleeper: any Sleeper,
        _ script: @escaping @Sendable (String, Int) -> FileStat?
    ) async -> [String: FileStat] {
        await StabilityChecker(config: config, clock: clock, sleeper: sleeper)
            .stableCandidates(candidates, stat: ScriptedStat(script).closure)
    }

    @Test("候補 0 件は待たない（空の状態）")
    func emptyCandidatesDoNotWait() async {
        let sleeper = RecordingSleeper()
        let result = await Self.check([], sleeper: sleeper) { _, _ in FileStat(size: 1, mtime: Self.nowSeconds) }
        #expect(result.isEmpty)
        #expect(sleeper.recorded == [])
    }

    @Test("mtime が 60 秒以上前なら即安定（fast path）")
    func oldFilesAreStableWithoutWaiting() async {
        let sleeper = RecordingSleeper()
        let old = FileStat(size: 10, mtime: Self.nowSeconds - 3600)
        let result = await Self.check(["a", "b"], sleeper: sleeper) { _, _ in old }
        #expect(result == ["a": old, "b": old])
        #expect(sleeper.recorded == [])
    }

    @Test("ちょうど 60 秒前は fast path")
    func fastPathBoundaryIsInclusive() async {
        let sleeper = RecordingSleeper()
        let boundary = FileStat(size: 10, mtime: Self.nowSeconds - 60)
        let result = await Self.check(["a"], sleeper: sleeper) { _, _ in boundary }
        #expect(result == ["a": boundary])
        #expect(sleeper.recorded == [])
    }

    @Test("新しいファイルはちょうど checks 回（2 回）一致して安定")
    func newFileNeedsExactlyChecksRounds() async {
        let sleeper = RecordingSleeper()
        let fresh = FileStat(size: 10, mtime: Self.nowSeconds)
        let result = await Self.check(["a"], sleeper: sleeper) { _, _ in fresh }
        #expect(result == ["a": fresh])
        #expect(sleeper.recorded == [3, 3])
    }

    @Test("1 回目で変われば見送り")
    func changeInFirstRoundDefers() async {
        let result = await Self.check(["a"], sleeper: RecordingSleeper()) { _, index in
            FileStat(size: index >= 1 ? 11 : 10, mtime: Self.nowSeconds)
        }
        #expect(result.isEmpty)
    }

    @Test("最後の回で変われば見送り")
    func changeInLastRoundDefers() async {
        let result = await Self.check(["a"], sleeper: RecordingSleeper()) { _, index in
            FileStat(size: 10, mtime: Self.nowSeconds + (index >= 2 ? 1 : 0))
        }
        #expect(result.isEmpty)
    }

    @Test("stat が取れないものは見送り")
    func statFailureDefers() async {
        let result = await Self.check(["a"], sleeper: RecordingSleeper()) { _, _ in nil }
        #expect(result.isEmpty)
    }

    @Test("25 件でも待ちは checks 回だけ（DEV-14）")
    func waitingDoesNotScaleWithFileCount() async {
        let sleeper = RecordingSleeper()
        let names = (0..<25).map { "f\($0)" }
        let fresh = FileStat(size: 10, mtime: Self.nowSeconds)
        let result = await Self.check(names, sleeper: sleeper) { _, _ in fresh }
        #expect(Set(result.keys) == Set(names))
        #expect(sleeper.recorded == [3, 3])
    }

    @Test("返す FileStat は最後の観測")
    func returnsLatestObservation() async {
        let a = FileStat(size: 10, mtime: Self.nowSeconds - 3600)
        let b = FileStat(size: 15, mtime: Self.nowSeconds - 3000)
        let fresh = FileStat(size: 20, mtime: Self.nowSeconds)
        let result = await Self.check(["old", "new"], sleeper: RecordingSleeper()) { rel, index in
            rel == "old" ? (index == 0 ? a : b) : fresh
        }
        #expect(result["old"] == b)
        #expect(result["new"] == fresh)
    }

    @Test("fast path でも取り直しで消えていれば返さない")
    func vanishedFastPathFileIsNotReturned() async {
        let old = FileStat(size: 10, mtime: Self.nowSeconds - 3600)
        let fresh = FileStat(size: 20, mtime: Self.nowSeconds)
        let result = await Self.check(["old", "new"], sleeper: RecordingSleeper()) { rel, index in
            rel == "old" ? (index == 0 ? old : nil) : fresh
        }
        #expect(result == ["new": fresh])
    }

    @Test("待ちが止められたらこの回は見送り")
    func cancelledSleepReturnsNothing() async {
        let fresh = FileStat(size: 20, mtime: Self.nowSeconds)
        let result = await Self.check(["a"], sleeper: CancellingSleeper()) { _, _ in fresh }
        #expect(result.isEmpty)
    }

    @Test("CE device.stabilityChecks = 1 なら 1 回だけ待つ")
    func checksOfOneNeedsOneRound() async {
        var config = Self.deviceConfig()
        config.stabilityChecks = 1
        let sleeper = RecordingSleeper()
        let defaultSleeper = RecordingSleeper()
        let fresh = FileStat(size: 20, mtime: Self.nowSeconds)
        let result = await Self.check(["a"], config: config, sleeper: sleeper) { _, _ in fresh }
        _ = await Self.check(["a"], sleeper: defaultSleeper) { _, _ in fresh }
        #expect(result == ["a": fresh])
        #expect(sleeper.recorded == [3])
        #expect(defaultSleeper.recorded == [3, 3])
    }

    @Test("CE device.stabilityIntervalSeconds 5 にすると 5 秒ずつ待つ")
    func ceStabilityIntervalSeconds() async {
        var config = Self.deviceConfig()
        config.stabilityIntervalSeconds = 5
        let sleeper = RecordingSleeper()
        let defaultSleeper = RecordingSleeper()
        let fresh = FileStat(size: 20, mtime: Self.nowSeconds)
        let result = await Self.check(["a"], config: config, sleeper: sleeper) { _, _ in fresh }
        _ = await Self.check(["a"], sleeper: defaultSleeper) { _, _ in fresh }
        #expect(result == ["a": fresh])
        #expect(sleeper.recorded == [5, 5])
        #expect(defaultSleeper.recorded == [3, 3])
    }

    @Test("CE device.stabilityFastPathSeconds 10 にすると 10 秒前でも即安定")
    func ceStabilityFastPathSeconds() async {
        var config = Self.deviceConfig()
        config.stabilityFastPathSeconds = 10
        let sleeper = RecordingSleeper()
        let defaultSleeper = RecordingSleeper()
        let recent = FileStat(size: 20, mtime: Self.nowSeconds - 10)
        let result = await Self.check(["a"], config: config, sleeper: sleeper) { _, _ in recent }
        _ = await Self.check(["a"], sleeper: defaultSleeper) { _, _ in recent }
        #expect(result == ["a": recent])
        #expect(sleeper.recorded == [])
        #expect(defaultSleeper.recorded == [3, 3])
    }
}
