// ZonedTime・LocalDate・ISOWallClock の検査（PLAN §5.7。T-10）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("ZonedTime")
struct ZonedTimeTests {
    func zone(_ identifier: String) throws -> ZonedTime {
        ZonedTime(timeZone: try #require(TimeZone(identifier: identifier)))
    }

    @Test("ISO は秒まで・オフセット付き")
    func isoTokyo() throws {
        // 2026-08-30 07:00:12.999 JST = 2026-08-29T22:00:12.999Z
        #expect(try zone("Asia/Tokyo").iso(Instant(epochMillis: 1_788_040_812_999)) == "2026-08-30T07:00:12+09:00")
    }

    @Test("UTC は +00:00（Z にしない）")
    func isoUTCHasPlusZero() throws {
        #expect(try zone("UTC").iso(Instant(epochMillis: 0)) == "1970-01-01T00:00:00+00:00")
        #expect(ZonedTime(timeZone: .gmt).iso(Instant(epochMillis: 1_788_040_812_999)) == "2026-08-29T22:00:12+00:00")
    }

    @Test("負のオフセット")
    func isoNegativeOffset() throws {
        // 2026-07-01T12:00:00Z は New York の夏（EDT）
        #expect(
            try zone("America/New_York").iso(Instant(epochMillis: 1_782_907_200_000)) == "2026-07-01T08:00:00-04:00")
    }

    @Test("紀元前の秒の切り捨ては −∞ 方向")
    func isoNegativeEpochFloors() throws {
        #expect(try zone("UTC").iso(Instant(epochMillis: -1)) == "1969-12-31T23:59:59+00:00")
        #expect(try zone("UTC").iso(Instant(epochMillis: -1000)) == "1969-12-31T23:59:59+00:00")
        #expect(try zone("UTC").iso(Instant(epochMillis: -1001)) == "1969-12-31T23:59:58+00:00")
    }

    @Test(
        "iso → parseISO は秒単位で一致",
        arguments: [
            (Int64(1_788_040_812_999), Int64(1_788_040_812_000)),
            (0, 0),
            (-14_182_940_500, -14_182_941_000),
            (951_836_399_001, 951_836_399_000),
            (2_147_483_648_000, 2_147_483_648_000),
        ])
    func parseRoundTrip(millis: Int64, floored: Int64) throws {
        for identifier in ["Asia/Tokyo", "UTC", "America/New_York"] {
            let z = try zone(identifier)
            #expect(z.parseISO(z.iso(Instant(epochMillis: millis))) == Instant(epochMillis: floored))
        }
    }

    @Test("iso が作らない形は読まない")
    func parseRejectsOtherForms() throws {
        let z = try zone("Asia/Tokyo")
        for text in [
            "2026-08-30T07:00:12Z", "2026-08-30 07:00:12+09:00", "2026-08-30T07:00:12.5+09:00",
            "2026-02-30T00:00:00+09:00", "2026-08-30T07:00:12+0900", "", "2026-08-30T07:00:12+24:00",
            "2026-08-30T07:00:12+09:60", "２026-08-30T07:00:12+09:00",
        ] {
            #expect(z.parseISO(text) == nil, "\(text)")
        }
        #expect(z.parseISO("2026-08-29T07:12:04+09:00") == Instant(epochMillis: 1_787_955_124_000))
        #expect(z.parseISO("2026-08-28T22:12:04-00:00") == Instant(epochMillis: 1_787_955_124_000))
    }

    @Test("秒付きのオフセットを読む")
    func parseSecondsOffset() throws {
        let z = try zone("Asia/Tokyo")
        #expect(z.parseISO("1900-01-01T00:00:00+09:18:59") == Instant(epochMillis: -2_209_022_339_000))
        #expect(
            ZonedTime(fixedOffsetSeconds: 33_539).iso(Instant(epochMillis: -2_209_022_339_000))
                == "1900-01-01T00:00:00+09:18:59")
    }

    @Test("ファイル名の時刻にはタイムゾーンを付与するだけ（TIME-03）")
    func fileNameTimeIsAttachedNotConverted() throws {
        let local = try #require(LocalDateTime(year: 2026, month: 8, day: 29, hour: 7, minute: 12, second: 4))
        let tokyo = try zone("Asia/Tokyo")
        let utc = try zone("UTC")
        #expect(tokyo.iso(tokyo.instant(of: local)) == "2026-08-29T07:12:04+09:00")
        #expect(utc.iso(utc.instant(of: local)) == "2026-08-29T07:12:04+00:00")
        #expect(tokyo.instant(of: local) == Instant(epochMillis: 1_787_955_124_000))
        #expect(utc.instant(of: local) - tokyo.instant(of: local) == 32_400_000)
        #expect(tokyo.localDateTime(tokyo.instant(of: local)) == local)
    }

    @Test("23:50 の Part の日付は設定のタイムゾーンで決まる（TIME-02）")
    func localDateAt2350() throws {
        let tokyo = try zone("Asia/Tokyo")
        let utc = try zone("UTC")
        let lateNight = Instant(epochMillis: 1_788_015_000_000)  // 2026-08-29T14:50:00+00:00
        #expect(
            tokyo.localDateTime(lateNight)
                == LocalDateTime(year: 2026, month: 8, day: 29, hour: 23, minute: 50, second: 0))
        #expect(tokyo.localDate(lateNight).stamp == "20260829")
        #expect(utc.localDate(lateNight).stamp == "20260829")
        let afterMidnight = Instant(epochMillis: 1_788_016_200_000)  // 2026-08-29T15:10:00+00:00
        #expect(tokyo.localDate(afterMidnight).stamp == "20260830")
        #expect(tokyo.today(afterMidnight).stamp == "20260830")
        #expect(utc.localDate(afterMidnight).stamp == "20260829")
    }

    @Test("日付の足し算は月末・閏年をまたぐ")
    func localDateArithmetic() throws {
        func date(_ text: String) throws -> LocalDate { try #require(LocalDate(dashed: text)) }
        #expect(try date("2024-02-28").adding(days: 1).dashed == "2024-02-29")
        #expect(try date("2023-02-28").adding(days: 1).dashed == "2023-03-01")
        #expect(try date("2026-12-31").adding(days: 1).dashed == "2027-01-01")
        #expect(try date("2026-01-01").adding(days: -1).dashed == "2025-12-31")
        #expect(try date("2026-08-29").adding(days: 0).dashed == "2026-08-29")
        #expect(try date("2026-08-29") < date("2026-08-30"))
        #expect(try date("2026-08-30") < date("2026-09-01"))
        #expect(try !(date("2026-08-30") < date("2026-08-30")))
    }

    @Test("LocalDate は dashed と stamp を読み書きする")
    func localDateParse() throws {
        let dashed = try #require(LocalDate(dashed: "2026-08-29"))
        #expect(dashed.stamp == "20260829")
        #expect(dashed == LocalDate(year: 2026, month: 8, day: 29))
        let stamp = try #require(LocalDate(stamp: "20260829"))
        #expect(stamp.dashed == "2026-08-29")
        #expect(LocalDate(dashed: "2026-8-29") == nil)
        #expect(LocalDate(stamp: "20260230") == nil)
        #expect(LocalDate(dashed: "") == nil)
        #expect(LocalDate(stamp: "") == nil)
        #expect(LocalDate(year: 2026, month: 2, day: 29) == nil)
    }

    @Test("固定オフセットのゾーンは夏時間をまたいでも同じオフセットで描く")
    func fixedOffsetZone() throws {
        let noon = Instant(epochMillis: 1_772_971_200_000)  // 2026-03-08T12:00:00Z
        #expect(ZonedTime(fixedOffsetSeconds: -18_000).iso(noon) == "2026-03-08T07:00:00-05:00")
        #expect(try zone("America/New_York").iso(noon) == "2026-03-08T08:00:00-04:00")
        #expect(ZonedTime(fixedOffsetSeconds: 999_999).iso(noon) == "2026-03-08T12:00:00+00:00")
    }

    @Test("壁時計は保存文字列の数字をそのまま")
    func wallClockFromString() {
        #expect(ISOWallClock.hhmm("2026-08-29T07:12:04+09:00") == "07:12")
        #expect(ISOWallClock.hhmmss("2026-08-29T07:12:04+09:00") == "07:12:04")
        #expect(ISOWallClock.hhmmss("2026-08-29T07:12:04-05:00") == "07:12:04")
        #expect(ISOWallClock.hhmm("garbage") == nil)
        #expect(ISOWallClock.hhmmss("garbage") == nil)
        #expect(ISOWallClock.hhmm("") == nil)
    }
}
