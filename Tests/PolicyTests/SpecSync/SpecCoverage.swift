// どの種類の ID について「SPEC の表 = テストの表示名」を確かめるか（T-05。後続のチケットが足す）。
import TestSupport

enum SpecCoverage {
    /// 表とテストが揃ったので、ID の集合の一致を確かめる種類。
    /// T-09 が `.cv`、T-32 が `.dr`、T-37 が `.rv`、T-39 が `.nd` を足す（E2E は docs/E2E.md の側で T-35 が確かめる）。
    static let activated: Set<SpecIDKind> = [.cv]
}
