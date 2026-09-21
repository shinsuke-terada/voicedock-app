// LocalDateTime の検査（T-06 §5.2）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("LocalDateTime")
struct LocalDateTimeTests {
    struct Fields: Sendable, CustomTestStringConvertible {
        let y: Int
        let mo: Int
        let d: Int
        let h: Int
        let mi: Int
        let s: Int
        init(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) {
            self.y = y
            self.mo = mo
            self.d = d
            self.h = h
            self.mi = mi
            self.s = s
        }
        var make: LocalDateTime? { LocalDateTime(year: y, month: mo, day: d, hour: h, minute: mi, second: s) }
        var testDescription: String { "(\(y),\(mo),\(d),\(h),\(mi),\(s))" }
    }

    @Test(
        "実在する日時は作れる",
        arguments: [
            Fields(2026, 8, 29, 7, 12, 4), Fields(2024, 2, 29, 0, 0, 0), Fields(2000, 2, 29, 23, 59, 59),
            Fields(9999, 12, 31, 0, 0, 0), Fields(1, 1, 1, 0, 0, 0),
        ])
    func acceptsValidDates(_ f: Fields) {
        #expect(f.make != nil)
    }

    @Test(
        "存在しない日時は nil",
        arguments: [
            Fields(2026, 2, 29, 0, 0, 0), Fields(1900, 2, 29, 0, 0, 0), Fields(2026, 2, 30, 0, 0, 0),
            Fields(2026, 13, 1, 0, 0, 0), Fields(2026, 0, 1, 0, 0, 0), Fields(2026, 4, 31, 0, 0, 0),
            Fields(0, 1, 1, 0, 0, 0), Fields(10000, 1, 1, 0, 0, 0), Fields(2026, 1, 1, 24, 0, 0),
            Fields(2026, 1, 1, 0, 60, 0), Fields(2026, 1, 1, 0, 0, 60), Fields(2026, 1, 1, 0, 0, -1),
        ])
    func rejectsInvalidDates(_ f: Fields) {
        #expect(f.make == nil)
    }

    @Test("dayStamp は yyyyMMdd")
    func dayStampIsZeroPadded() throws {
        #expect(try #require(Fields(2026, 8, 9, 0, 0, 0).make).dayStamp == "20260809")
        #expect(try #require(Fields(1, 1, 1, 0, 0, 0).make).dayStamp == "00010101")
    }

    @Test("年月日時分秒の辞書順")
    func ordersLexicographically() throws {
        let a = try #require(Fields(2026, 8, 29, 7, 12, 4).make)
        let b = try #require(Fields(2026, 8, 29, 7, 12, 5).make)
        let c = try #require(Fields(2025, 12, 31, 23, 59, 59).make)
        let d = try #require(Fields(2026, 1, 1, 0, 0, 0).make)
        #expect(a < b)
        #expect(!(b < a))
        #expect(c < d)
        #expect(!(d < c))
    }
}
