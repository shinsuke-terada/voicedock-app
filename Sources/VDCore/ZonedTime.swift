// 設定のタイムゾーンでの時刻の書式と暦・日付・保存文字列の壁時計（PLAN §5.7）。
import Foundation
import VDContract

/// 設定のタイムゾーンでの時刻の書式と暦（PLAN §5.7）。ISO 文字列を作るのは `iso(_:)` だけ。
public struct ZonedTime: Sendable {
    public let timeZone: TimeZone
    private let calendar: Calendar

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    /// 固定オフセットで描く（Raw の見出しなど、保存文字列のオフセットのまま描く所。PLAN §5.7・X-32）。
    /// `TimeZone(secondsFromGMT:)` が nil（±18 時間を超える）なら `.gmt`。
    public init(fixedOffsetSeconds: Int) {
        self.init(timeZone: TimeZone(secondsFromGMT: fixedOffsetSeconds) ?? .gmt)
    }

    /// ISO 8601、秒まで（秒未満は切り捨て）、オフセット付き（例 "2026-08-30T07:00:12+09:00"。UTC は "+00:00"）。
    public func iso(_ i: Instant) -> String {
        let date = Self.flooredDate(i)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        var text = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0,
            c.minute ?? 0, c.second ?? 0)
        let magnitude = abs(offset)
        text += offset >= 0 ? "+" : "-"
        text += String(format: "%02d:%02d", magnitude / 3600, (magnitude % 3600) / 60)
        if magnitude % 60 != 0 {
            text += String(format: ":%02d", magnitude % 60)
        }
        return text
    }

    /// `iso(_:)` が作る形だけを読む（例外を投げず nil）。
    public func parseISO(_ s: String) -> Instant? {
        let chars = Array(s.unicodeScalars)
        guard chars.count == 25 || chars.count == 28 else { return nil }
        var separators: [Int: Set<Character>] = [4: ["-"], 7: ["-"], 10: ["T"], 13: [":"], 16: [":"], 19: ["+", "-"]]
        separators[22] = [":"]
        if chars.count == 28 {
            separators[25] = [":"]
        }
        for (index, scalar) in chars.enumerated() {
            if let allowed = separators[index] {
                guard allowed.contains(Character(scalar)) else { return nil }
            } else {
                guard ("0"..."9").contains(scalar) else { return nil }
            }
        }
        func number(_ start: Int, _ length: Int) -> Int {
            chars[start..<(start + length)].reduce(0) { $0 * 10 + Int($1.value - 48) }
        }
        guard
            let local = LocalDateTime(
                year: number(0, 4), month: number(5, 2), day: number(8, 2), hour: number(11, 2),
                minute: number(14, 2), second: number(17, 2))
        else { return nil }
        let offsetHour = number(20, 2)
        let offsetMinute = number(23, 2)
        let offsetSecond = chars.count == 28 ? number(26, 2) : 0
        guard (0...23).contains(offsetHour), (0...59).contains(offsetMinute), (0...59).contains(offsetSecond) else {
            return nil
        }
        let sign = chars[19] == "+" ? 1 : -1
        let offsetSeconds = offsetHour * 3600 + offsetMinute * 60 + offsetSecond
        let days = CivilDays.fromCivil(local.year, local.month, local.day)
        let utc = days * 86_400 + local.hour * 3600 + local.minute * 60 + local.second - sign * offsetSeconds
        return Instant(epochMillis: Int64(utc) * 1000)
    }

    public func localDateTime(_ i: Instant) -> LocalDateTime {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Self.flooredDate(i))
        guard
            let local = LocalDateTime(
                year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0, hour: c.hour ?? 0, minute: c.minute ?? 0,
                second: c.second ?? 0)
        else {
            // 年が 1〜9999 の外（到達しない）。紀元の時刻は必ず範囲内なので再帰は 1 段で止まる。
            return localDateTime(Instant(epochMillis: 0))
        }
        return local
    }

    public func localDate(_ i: Instant) -> LocalDate {
        let local = localDateTime(i)
        return LocalDate(validYear: local.year, month: local.month, day: local.day)
    }

    /// ファイル名の時刻にタイムゾーンを「付与」する（変換しない。TIME-03）。
    public func instant(of local: LocalDateTime) -> Instant {
        let components = DateComponents(
            year: local.year, month: local.month, day: local.day, hour: local.hour, minute: local.minute,
            second: local.second)
        if let date = calendar.date(from: components) {
            return Instant(date: date)
        }
        let days = CivilDays.fromCivil(local.year, local.month, local.day)
        let utc = days * 86_400 + local.hour * 3600 + local.minute * 60 + local.second
        return Instant(epochMillis: Int64(utc - timeZone.secondsFromGMT()) * 1000)
    }

    public func today(_ now: Instant) -> LocalDate { localDate(now) }

    /// 秒へ切り捨てた Date（負の値は −∞ 方向）。
    private static func flooredDate(_ i: Instant) -> Date {
        let m = i.epochMillis
        let secs = m >= 0 ? m / 1000 : -((-m + 999) / 1000)
        return Date(timeIntervalSince1970: Double(secs))
    }
}

public struct LocalDate: Comparable, Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// LocalDateTime(year:month:day:hour: 0, minute: 0, second: 0) が作れるときだけ。
    public init?(year: Int, month: Int, day: Int) {
        guard LocalDateTime(year: year, month: month, day: day, hour: 0, minute: 0, second: 0) != nil else {
            return nil
        }
        self.init(validYear: year, month: month, day: day)
    }

    /// "yyyy-MM-dd" 丁度 10 文字（ASCII 数字）だけ。
    public init?(dashed: String) {
        let chars = Array(dashed.unicodeScalars)
        guard chars.count == 10, chars[4] == "-", chars[7] == "-",
            let year = Self.digits(chars[0..<4]), let month = Self.digits(chars[5..<7]),
            let day = Self.digits(chars[8..<10])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// "yyyyMMdd" 丁度 8 文字だけ。
    public init?(stamp: String) {
        let chars = Array(stamp.unicodeScalars)
        guard chars.count == 8, let year = Self.digits(chars[0..<4]), let month = Self.digits(chars[4..<6]),
            let day = Self.digits(chars[6..<8])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// 検査済みの値から（暦の計算の結果など）。
    init(validYear: Int, month: Int, day: Int) {
        self.year = validYear
        self.month = month
        self.day = day
    }

    public var dashed: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var stamp: String { String(format: "%04d%02d%02d", year, month, day) }

    /// CivilDays で計算する。
    public func adding(days: Int) -> LocalDate {
        let civil = CivilDays.toCivil(CivilDays.fromCivil(year, month, day) + days)
        return LocalDate(validYear: civil.year, month: civil.month, day: civil.day)
    }

    /// (year, month, day) の辞書順。
    public static func < (a: LocalDate, b: LocalDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// ASCII の数字だけの並びなら整数。
    private static func digits(_ scalars: ArraySlice<Unicode.Scalar>) -> Int? {
        var value = 0
        for scalar in scalars {
            guard ("0"..."9").contains(scalar) else { return nil }
            value = value * 10 + Int(scalar.value - 48)
        }
        return value
    }
}

/// 保存された ISO 文字列（設定のタイムゾーンのオフセット付き）の壁時計を、文字列の数字そのままで取り出す（PLAN §5.7。変換しない）。
public enum ISOWallClock {
    /// 位置 10 が "T"、13・16 が ":" で長さが 19 以上なら文字 11..<16（"HH:MM"）。そうでなければ nil。
    public static func hhmm(_ iso: String) -> String? {
        slice(iso, 11..<16)
    }

    /// 同じ条件で 11..<19（"HH:MM:SS"）。
    public static func hhmmss(_ iso: String) -> String? {
        slice(iso, 11..<19)
    }

    private static func slice(_ iso: String, _ range: Range<Int>) -> String? {
        let chars = Array(iso.unicodeScalars)
        guard chars.count >= 19, chars[10] == "T", chars[13] == ":", chars[16] == ":" else { return nil }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: chars[range])
        return String(text)
    }
}

/// Howard Hinnant の days_from_civil / civil_from_days を整数で（Foundation の暦に頼らない）。
enum CivilDays {
    /// 1970-01-01 からの日数。
    static func fromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// 1970-01-01 からの日数から (年, 月, 日)。
    static func toCivil(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (y + (m <= 2 ? 1 : 0), m, d)
    }
}
