// Instant と SecondsToMillis の検査（PLAN §5.7。T-10）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("Instant")
struct InstantTests {
    @Test("Date からの変換はミリ秒未満を切り捨てる")
    func dateRoundTripFloors() {
        #expect(Instant(date: Date(timeIntervalSince1970: 1.9999)).epochMillis == 1999)
        #expect(Instant(date: Date(timeIntervalSince1970: -0.0005)).epochMillis == -1)
        #expect(Instant(date: Date(timeIntervalSince1970: 0)).epochMillis == 0)
        #expect(Instant(epochMillis: 1500).date == Date(timeIntervalSince1970: 1.5))
    }

    @Test("足し算と差はミリ秒の整数")
    func addingAndDifference() {
        let base = Instant(epochMillis: 1_000)
        #expect(base.adding(seconds: 300).epochMillis == 301_000)
        #expect(base.adding(milliseconds: 1).epochMillis == 1_001)
        #expect(base.adding(seconds: 300) - base == 300_000)
        #expect(base - base.adding(milliseconds: 7) == -7)
        #expect(base < base.adding(milliseconds: 1))
    }

    @Test("whisper の秒はミリ秒に丸めて戻す")
    func whisperSecondsToMillis() {
        #expect(SecondsToMillis.fromWhisperSeconds(9.001) == 9001)
        #expect(SecondsToMillis.fromWhisperSeconds(12.999) == 12999)
        #expect(SecondsToMillis.fromWhisperSeconds(3.2) == 3200)
        #expect(SecondsToMillis.fromWhisperSeconds(0.0005) == 1)
        #expect(SecondsToMillis.fromWhisperSeconds(0.0004) == 0)
        #expect(SecondsToMillis.fromWhisperSeconds(0) == 0)
    }
}
