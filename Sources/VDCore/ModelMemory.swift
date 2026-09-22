// モデルを選べるかのメモリの条件（PLAN §8.10「ProcessInfo.physicalMemory < minMemoryGB × 1024³ のモデルは選べない」）。
// パネルの Picker（T-31）・DR-08（T-32）・解析のガード（T-22）が同じ式を使う（CR-06）。

/// モデルを選べるかのメモリの条件（PLAN §8.10）。
public enum ModelMemory {
    public static let bytesPerGB: UInt64 = 1024 * 1024 * 1024
    /// minMemoryGB が nil なら常に真。等号は足りる側（>=）。掛け算が溢れる大きさは足りない（trap しない。CR-16）。
    public static func hasEnough(minMemoryGB: Int?, physicalMemoryBytes: UInt64) -> Bool {
        guard let g = minMemoryGB, g > 0 else { return true }
        let (need, overflow) = UInt64(g).multipliedReportingOverflow(by: bytesPerGB)
        if overflow { return false }
        return physicalMemoryBytes >= need
    }
    /// 表示用の GB（切り捨て）
    public static func gb(_ bytes: UInt64) -> Int { Int(bytes / bytesPerGB) }
}
