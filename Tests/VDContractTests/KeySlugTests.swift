// KeySlug の検査（T-06 §5.8）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("KeySlug")
struct KeySlugTests {
    /// 期待値を書き換えて通すな。規則を変えると、それ以前に保存した録音が永久に削除対象外になる（DEL-01、RK-27）。
    @Test("key_slug の固定値")
    func fixedSlugs() {
        #expect(
            KeySlug.of("DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav") == "a5d046dce76cfedc")
        #expect(KeySlug.of("DJIMIC3:20260829") == "43a71bce144be7a7")
    }

    @Test("16 文字の小文字 16 進", arguments: ["DJIMIC3:20260829#2", "NO NAME/a.wav", ""])
    func slugIsSixteenLowerHex(_ key: String) {
        #expect(PatternMatch.wholeMatch("^[0-9a-f]{16}$", KeySlug.of(key)) != nil)
    }
}
