// 時計と待ち（本物と差し替え）の検査（CR-08。T-10）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("Clock")
struct ClockTests {
    @Test("SystemClock の uptime は減らない")
    func systemClockUptimeIsMonotonic() {
        let clock = SystemClock()
        let first = clock.uptime()
        let second = clock.uptime()
        #expect(second >= first)
        #expect(first >= .zero)
    }

    @Test("0 秒の待ちはすぐ返る")
    func taskSleeperZeroReturnsImmediately() async throws {
        try await TaskSleeper().sleep(seconds: 0)
        try await TaskSleeper().sleep(seconds: -1)
    }

    @Test("FixedClock は now と uptime を同じだけ進める")
    func fixedClockAdvances() {
        let clock = FixedClock(now: Instant(epochMillis: 10_000))
        #expect(clock.now() == Instant(epochMillis: 10_000))
        #expect(clock.uptime() == .zero)
        clock.advance(seconds: 3)
        #expect(clock.now() == Instant(epochMillis: 13_000))
        #expect(clock.uptime() == .seconds(3))
        clock.advance(milliseconds: 250)
        #expect(clock.now() == Instant(epochMillis: 13_250))
        #expect(clock.uptime() == .milliseconds(3_250))
        clock.set(Instant(epochMillis: 1))
        #expect(clock.now() == Instant(epochMillis: 1))
        #expect(clock.uptime() == .milliseconds(3_250))
        #expect(FixedClock(epochMillis: 42).now() == Instant(epochMillis: 42))
    }

    @Test("SteppingClock は now と uptime を呼ぶたびに別々に進める")
    func steppingClockAdvancesBoth() {
        let clock = SteppingClock(start: Instant(epochMillis: 1000), stepMilliseconds: 500)
        #expect(clock.now() == Instant(epochMillis: 1000))
        #expect(clock.now() == Instant(epochMillis: 1500))
        #expect(clock.uptime() == .zero)
        #expect(clock.uptime() == .milliseconds(500))
        #expect(clock.now() == Instant(epochMillis: 2000))
    }

    @Test("RecordingSleeper は待たずに記録する")
    func recordingSleeperRecords() async throws {
        let empty = RecordingSleeper()
        #expect(empty.recorded == [])
        let sleeper = RecordingSleeper()
        try await sleeper.sleep(seconds: 3)
        try await sleeper.sleep(seconds: 10)
        #expect(sleeper.recorded == [3, 10])

        let clock = FixedClock(now: Instant(epochMillis: 0))
        let advancing = RecordingSleeper(clock: clock)
        try await advancing.sleep(seconds: 3)
        try await advancing.sleep(seconds: 10)
        #expect(advancing.recorded == [3, 10])
        #expect(clock.now() == Instant(epochMillis: 13_000))
        #expect(clock.uptime() == .seconds(13))
    }
}
