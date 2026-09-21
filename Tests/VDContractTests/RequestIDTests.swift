// RequestID の検査（T-06 §5.9）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("RequestID")
struct RequestIDTests {
    static let partkey = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"

    @Test("UTC・Z 付きの ID")
    func makesUTCRequestID() {
        let id = RequestID.make(partkey: Self.partkey, utcEpochSeconds: 1_789_203_600, randomHex6: "a1b2c3")
        #expect(id == "20260912T090000Z-a5d046dce76cfedc-a1b2c3")
    }

    @Test("形式の検査")
    func validatesPattern() {
        #expect(RequestID.isValid("20260912T090000Z-a5d046dce76cfedc-a1b2c3"))
        #expect(!RequestID.isValid("20260912T090000-a5d046dce76cfedc-a1b2c3"))
        #expect(!RequestID.isValid("20260912T090000Z-A5D046DCE76CFEDC-a1b2c3"))
        #expect(!RequestID.isValid("20260912T090000Z-a5d0/6dce76cfedc-a1b2c3"))
        #expect(!RequestID.isValid("../x"))
        #expect(!RequestID.isValid("20260912T090000Z-a5d046dce76cfedc-a1b2c3\n"))
        #expect(!RequestID.isValid(""))
    }

    @Test("乱数は 6 桁の小文字 16 進")
    func randomHexIsSixLowerHex() {
        var seen = Set<String>()
        for _ in 0..<100 {
            let hex = RequestID.randomHex6()
            #expect(PatternMatch.wholeMatch("^[0-9a-f]{6}$", hex) != nil)
            seen.insert(hex)
        }
        #expect(seen.count >= 2)
    }
}
