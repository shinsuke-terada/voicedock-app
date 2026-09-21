// 空き容量の 2 条件（PLAN §8.3「空き容量」。voicedock audio.py:292-349）。
import Foundation
import VDContract
import VDCore

public enum SpaceMath {
    /// 16 kHz / 1 ch / s16 のバイトレート。
    static let bytesPerSecond: Int64 = 32_000
    /// duration が不明なときの仮定値（30 分）。
    static let defaultDurationSeconds: Double = 1800

    /// `Int64(max(0, duration ?? 1800) × 32000)`（0 方向への切り捨て）。Int64 に収まらない積は `Int64.max`（トラップしない。PT-19）。
    public static func expectedBytes(_ durationSeconds: Double?) -> Int64 {
        let seconds = durationSeconds ?? defaultDurationSeconds
        return saturatingInt64(max(0, seconds) * Double(bytesPerSecond))
    }

    /// `Int64(Double(expected) × freeSpaceMultiplier) + freeSpaceMarginBytes`。桁あふれは `Int64.max`（トラップしない。PT-19）。
    public static func requiredBytes(expected: Int64, config: AudioConfig) -> Int64 {
        saturatingAdd(
            saturatingInt64(Double(expected) * config.freeSpaceMultiplier), Int64(config.freeSpaceMarginBytes))
    }

    /// 0 方向へ切り捨てて Int64 にする。`Int64.max` 以上と NaN は `Int64.max`、`Int64.min` 以下は `Int64.min`。
    static func saturatingInt64(_ value: Double) -> Int64 {
        if value.isNaN || value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value)
    }

    /// 桁あふれを `Int64.max` / `Int64.min` に留める足し算。
    static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs > 0 ? Int64.max : Int64.min
    }
}

public enum SpaceCheckResult: Equatable, Sendable {
    case ok
    case insufficient(String)  // error_message にそのまま使う文言
}

public struct SpaceCheck: Sendable {
    private let config: AudioConfig
    private let layout: HomeLayout

    public init(config: AudioConfig, layout: HomeLayout) {
        self.config = config
        self.layout = layout
    }

    /// 空き容量（`free < required`）と staging の上限（`used + expected > stagingMaxBytes`）をこの順に確かめる。
    public func check(durationSeconds: Double?) -> SpaceCheckResult {
        let expected = SpaceMath.expectedBytes(durationSeconds)
        let required = SpaceMath.requiredBytes(expected: expected, config: config)
        let target = isDirectory(layout.staging) ? layout.staging : layout.root
        var st = statfs()
        guard statfs(target.path(percentEncoded: false), &st) == 0 else {
            return .insufficient("空き容量を取得できません: errno \(errno)")
        }
        let (product, overflow) = Int64(clamping: st.f_bavail).multipliedReportingOverflow(
            by: Int64(clamping: st.f_bsize))
        let free = overflow ? Int64.max : product
        let used = stagingBytes()
        if free < required {
            return .insufficient("空き \(free) バイトが必要量 \(required) バイトを下回る")
        }
        if SpaceMath.saturatingAdd(used, expected) > Int64(config.stagingMaxBytes) {
            return .insufficient("staging 使用量 \(used) + 想定 \(expected) が上限 \(config.stagingMaxBytes) を超える")
        }
        return .ok
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &directory)
            && directory.boolValue
    }

    /// staging 配下の通常ファイルの size の合計（再帰）。読めないものは飛ばす。staging が無ければ 0。
    private func stagingBytes() -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: layout.staging, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true, let size = values.fileSize
            else { continue }
            total = SpaceMath.saturatingAdd(total, Int64(size))
        }
        return total
    }
}
