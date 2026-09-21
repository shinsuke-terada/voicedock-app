// reaper の時刻（PLAN §8.9.4。config.json を読まないのでシステムのローカル時刻を使う）。PT-09 の許可場所。
import Foundation

struct ReaperClock: Sendable {
    /// PLAN §4.4・§8.9.4。例 `2026-09-12T18:00:05+09:00`
    static let isoFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"

    /// システムのローカルタイムゾーンで今を書式化する
    /// （DateFormatter は Sendable でないので保持せず、呼ばれるたびに作る）
    func nowISO() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = Self.isoFormat
        return f.string(from: Date())
    }
}
