// 絶対時刻（Unix 紀元からのミリ秒の整数）と、whisper の秒からミリ秒への戻し（PLAN §5.7）。
import Foundation

/// 絶対時刻（Unix 紀元からのミリ秒）。Double の Date で加算しない（PLAN §5.7。等号の境界を Python と一致させる）。
public struct Instant: Comparable, Hashable, Sendable {
    public let epochMillis: Int64
    public init(epochMillis: Int64) { self.epochMillis = epochMillis }
    /// Date から。ミリ秒未満は切り捨て（負の値も −∞ 方向）。
    public init(date: Date) { self.epochMillis = Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
    /// Foundation の API に渡すときだけ使う。
    public var date: Date { Date(timeIntervalSince1970: Double(epochMillis) / 1000) }
    public func adding(milliseconds: Int64) -> Instant { Instant(epochMillis: epochMillis + milliseconds) }
    public func adding(seconds: Int) -> Instant { Instant(epochMillis: epochMillis + Int64(seconds) * 1000) }
    /// a − b のミリ秒。
    public static func - (a: Instant, b: Instant) -> Int64 { a.epochMillis - b.epochMillis }
    public static func < (a: Instant, b: Instant) -> Bool { a.epochMillis < b.epochMillis }
}

public enum SecondsToMillis {
    /// whisper の offsets を秒へ直した値（小数 3 桁）を、Instant に足すミリ秒の整数へ戻す（PLAN §5.7）。
    /// `(s × 1000).rounded()`（.toNearestOrAwayFromZero）。
    public static func fromWhisperSeconds(_ s: Double) -> Int64 { Int64((s * 1000).rounded()) }
}
