// どの種類の ID について「SPEC の表 = テストの表示名」を確かめるか（T-05。後続のチケットが足す）。
import TestSupport

enum SpecCoverage {
    /// 表とテストが揃ったので、ID の集合の一致を確かめる種類。
    /// T-09 が `.cv`、T-32 が `.dr`、T-39 が `.nd` を足した（E2E は docs/E2E.md の側で T-35 が確かめる）。
    /// `.rv` は T-37 の積み残しだったものを、RV-01・02・05 のテストを揃えて issue #87 で足した。
    static let activated: Set<SpecIDKind> = [.cv, .dr, .nd, .rv]
}
