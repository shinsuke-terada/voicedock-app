// 絶対時刻（Unix 紀元からのミリ秒の整数）と、whisper の秒からミリ秒への戻し（PLAN §5.7）。
import Foundation

/// 絶対時刻（Unix 紀元からのミリ秒）。Double の Date で加算しない（PLAN §5.7。等号の境界を Python と一致させる）。
/// F-71: 算術は桁あふれで落ちない（Int64 の端に寄せる。CR-16）。
public struct Instant: Comparable, Hashable, Sendable {
    public let epochMillis: Int64
    public init(epochMillis: Int64) { self.epochMillis = epochMillis }
    /// Date から。ミリ秒未満は切り捨て（負の値も −∞ 方向）。Int64 に収まらなければ端、NaN は 0（F-71）。
    public init(date: Date) { self.epochMillis = Self.clamped((date.timeIntervalSince1970 * 1000).rounded(.down)) }
    /// Foundation の API に渡すときだけ使う。
    public var date: Date { Date(timeIntervalSince1970: Double(epochMillis) / 1000) }
    /// 桁あふれは Int64 の端に寄せる（F-71）。
    public func adding(milliseconds: Int64) -> Instant {
        let (sum, overflow) = epochMillis.addingReportingOverflow(milliseconds)
        return Instant(epochMillis: overflow ? (milliseconds < 0 ? .min : .max) : sum)
    }
    /// `epochMillis + seconds × 1000` を 128 ビットで厳密に計算し、Int64 に収まればその値、収まらなければ端（F-71）。
    /// （× 1000 だけがあふれても、基準が逆の符号なら和は収まりうる）
    public func adding(seconds: Int) -> Instant {
        let exact = Int128(epochMillis) + Int128(seconds) * 1000
        return Instant(epochMillis: Int64(exactly: exact) ?? (exact < 0 ? .min : .max))
    }
    /// a − b のミリ秒。桁あふれは Int64 の端に寄せる（F-71）。
    public static func - (a: Instant, b: Instant) -> Int64 {
        let (difference, overflow) = a.epochMillis.subtractingReportingOverflow(b.epochMillis)
        return overflow ? (b.epochMillis < 0 ? .max : .min) : difference
    }
    public static func < (a: Instant, b: Instant) -> Bool { a.epochMillis < b.epochMillis }

    /// 整数値の Double を Int64 にする。NaN は 0、Int64 に収まらなければ端（F-71。トラップしない）。
    static func clamped(_ millis: Double) -> Int64 {
        if let exact = Int64(exactly: millis) { return exact }
        return millis.isNaN ? 0 : (millis < 0 ? .min : .max)
    }
}

public enum SecondsToMillis {
    /// F-71: transcript と whisper の秒として読む値の絶対値の上限（10 億秒 ≈ 31.7 年。PLAN §5.7）。
    static let maxAbsSeconds: Double = 1_000_000_000

    /// F-71: transcript・whisper の秒として読めるか（有限で、絶対値が 10 億秒以下）。偽なら「読めない」（§8.4）。
    public static func isReadable(_ s: Double) -> Bool { s.isFinite && abs(s) <= maxAbsSeconds }

    /// whisper の offsets を秒へ直した値（小数 3 桁）を、Instant に足すミリ秒の整数へ戻す（PLAN §5.7）。
    /// `(s × 1000).rounded()`（.toNearestOrAwayFromZero）。
    /// F-71: 読めない値（`isReadable` が偽）でも落ちない（最後の防御）: NaN は 0、範囲外と ±∞ は ±10 億秒に寄せる。
    public static func fromWhisperSeconds(_ s: Double) -> Int64 {
        let bounded = s.isNaN ? 0 : min(max(s, -maxAbsSeconds), maxAbsSeconds)
        return Int64((bounded * 1000).rounded())
    }
}
