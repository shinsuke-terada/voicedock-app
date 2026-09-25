// 削除要求の ID（PLAN §4.4）。UTC・Z 付き。
import Darwin
import Foundation

public enum RequestID {
    public static let pattern = "^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}-[0-9a-f]{6}$"

    /// "<gmtime の yyyyMMdd'T'HHmmss>Z-<KeySlug.of(partkey)>-<randomHex6>"。
    /// 時刻は gmtime_r で UTC に分解し String(format: "%04d%02d%02dT%02d%02d%02dZ", ...) で作る（Calendar・DateFormatter を使わない）。
    /// randomHex6 は検査しない（形式外なら isValid が偽になる文字列を返す。呼び手は randomHex6() の値だけを渡す）。
    /// gmtime_r が失敗したら年月日時分秒をすべて 0 として書く（例外にしない）。
    public static func make(partkey: String, utcEpochSeconds: Int64, randomHex6: String) -> String {
        var seconds = time_t(utcEpochSeconds)
        var parts = tm()
        var fields: (Int32, Int32, Int32, Int32, Int32, Int32) = (0, 0, 0, 0, 0, 0)
        if gmtime_r(&seconds, &parts) != nil {
            fields = (parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec)
        }
        let stamp = String(
            format: "%04d%02d%02dT%02d%02d%02dZ", fields.0, fields.1, fields.2, fields.3, fields.4, fields.5)
        return stamp + "-" + KeySlug.of(partkey) + "-" + randomHex6
    }

    /// PatternMatch.wholeMatch(pattern, id) != nil
    public static func isValid(_ id: String) -> Bool {
        PatternMatch.wholeMatch(pattern, id) != nil
    }

    /// SystemRandomNumberGenerator から 3 バイト（UInt8.random(in: 0...255, using:) を 3 回）を小文字 16 進 6 文字に（PLAN §4.4）。
    public static func randomHex6() -> String {
        var generator = SystemRandomNumberGenerator()
        var hex = ""
        for _ in 0..<3 {
            hex += String(format: "%02x", UInt8.random(in: 0...255, using: &generator))
        }
        return hex
    }
}
