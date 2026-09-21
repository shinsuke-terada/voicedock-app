// オフセットを持たない壁時計の日時（ファイル名の時刻。PLAN §4.1）。
import Foundation

public struct LocalDateTime: Equatable, Hashable, Sendable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int

    /// 整数範囲で検査する（Calendar に任せない）。範囲外は nil。
    public init?(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        guard (1...9999).contains(year),
            (1...12).contains(month),
            day >= 1, day <= Self.daysInMonth(year: year, month: month),
            (0...23).contains(hour),
            (0...59).contains(minute),
            (0...59).contains(second)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// "yyyyMMdd"（4 桁・2 桁・2 桁のゼロ埋め）。
    public var dayStamp: String {
        String(format: "%04d%02d%02d", year, month, day)
    }

    /// (year, month, day, hour, minute, second) の辞書順。
    public static func < (lhs: LocalDateTime, rhs: LocalDateTime) -> Bool {
        (lhs.year, lhs.month, lhs.day, lhs.hour, lhs.minute, lhs.second)
            < (rhs.year, rhs.month, rhs.day, rhs.hour, rhs.minute, rhs.second)
    }

    /// グレゴリオ暦の月の日数。month が 1〜12 以外なら 0。
    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            return 31
        case 4, 6, 9, 11:
            return 30
        case 2:
            let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return isLeap ? 29 : 28
        default:
            return 0
        }
    }
}
