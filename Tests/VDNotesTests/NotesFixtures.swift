// VDNotes のテストの共通の準備（T-26 §5。T-27・T-28 も使う）。
import Foundation
import Testing
import VDCore

@testable import VDNotes

enum NotesFixtures {
    static let sessionKey = "DJIMIC3:20260829"
    static let keyA = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
    static let keyB = "DJIMIC3/TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav"

    static var jst: ZonedTime {
        get throws { ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo"))) }
    }

    static var day: LocalDate {
        get throws { try #require(LocalDate(year: 2026, month: 8, day: 29)) }
    }

    static func at(_ h: Int, _ m: Int, _ s: Int) throws -> Instant {
        try #require(try jst.parseISO(String(format: "2026-08-29T%02d:%02d:%02d+09:00", h, m, s)))
    }

    static func seg(_ at: Instant, _ text: String, secs: Int = 10) -> AbsoluteSegment {
        AbsoluteSegment(at: at, endAt: at.adding(seconds: secs), text: text)
    }

    static var partA: RawPart {
        get throws {
            RawPart(
                partkey: keyA, startedAt: "2026-08-29T07:12:04+09:00", endedAt: "2026-08-29T07:42:04+09:00",
                segments: [seg(try at(7, 12, 4), "おはようございます。"), seg(try at(7, 17, 4), "削除条件を整理します。")],
                zone: try jst)
        }
    }

    static var partB: RawPart {
        get throws {
            RawPart(
                partkey: keyB, startedAt: "2026-08-29T07:42:10+09:00", endedAt: "2026-08-29T08:12:10+09:00",
                segments: [seg(try at(7, 42, 10), "続きです。")], zone: try jst)
        }
    }

    static func config() -> ObsidianConfig {
        AppConfig.defaults(timeZone: "Asia/Tokyo").obsidian
    }
}
