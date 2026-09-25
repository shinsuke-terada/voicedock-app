// RelPath をスカラー（UTF-8 の 0x2F）で分割する（PLAN §4.3・F-73・issue #113）。書記素で分けると "/" の直後の結合文字で
// 区切りを見落とし、1 つの要素に "/" が紛れて openat が途中の symlink を辿る。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("RelPath のスカラー単位の分割（F-73）")
struct RelPathScalarTests {
    /// スカラー列で比べる（Swift の == は正準等価で比べるため。00-api-map §0）
    static func scalars(_ parts: [String]) -> [[Unicode.Scalar]] {
        parts.map { Array($0.unicodeScalars) }
    }

    @Test(
        "RV-08 「/」の直後に結合文字・ZWJ があっても、前に Prepend の文字があっても「/」で区切る",
        arguments: [
            ("x/\u{301}y/z", ["x", "\u{301}y", "z"]),
            ("a/\u{200D}b", ["a", "\u{200D}b"]),
            ("\u{600}/a", ["\u{600}", "a"]),
        ])
    func rv08SplitsAtEverySlashScalar(_ relpath: String, _ expected: [String]) {
        #expect(Self.scalars(RelPath.components(relpath)) == Self.scalars(expected))
        #expect(
            Array(RelPath.lastComponent(relpath).unicodeScalars) == Array(expected[expected.count - 1].unicodeScalars))
    }

    @Test("RV-08 先頭の「/」に結合文字が続いても「/」で始まるので偽")
    func rv08LeadingSlashWithCombiningMarkIsUnsafe() {
        #expect(!RelPath.isSafe("/\u{301}x/TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"))
        #expect(!RelPath.isSafe("/\u{301}"))
    }

    @Test("RV-08 「.」に結合文字が続く要素も「.」で始まるので偽")
    func rv08DotWithCombiningMarkIsUnsafe() {
        #expect(!RelPath.isSafe(".\u{301}Trashes/TX00_MIC001_20260912_090000_orig.wav"))
        #expect(!RelPath.isSafe("TX_MIC001_20260912_090000/.\u{301}x/TX00_MIC001_20260912_090000_orig.wav"))
    }

    @Test("RV-08 「/」＋結合文字で始まる中間要素は独立した要素になり、ほかに当たらなければ真")
    func rv08CombiningMarkComponentIsItsOwnComponent() {
        let relpath = "x/\u{301}y/TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"
        #expect(RelPath.isSafe(relpath))
        #expect(
            Self.scalars(RelPath.components(relpath))
                == Self.scalars([
                    "x", "\u{301}y", "TX_MIC001_20260912_090000", "TX00_MIC001_20260912_090000_orig.wav",
                ]))
        #expect(
            Array(RelPath.parent(relpath).unicodeScalars)
                == Array("x/\u{301}y/TX_MIC001_20260912_090000".unicodeScalars))
    }

    @Test(
        "F-73 ASCII の入力では分割・親・最後の要素・結合がこれまでと同じ",
        arguments: [
            (
                "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
                ["TX_MIC001_20260829_071201", "TX01_MIC002_20260829_071204_orig.wav"], "TX_MIC001_20260829_071201",
                "TX01_MIC002_20260829_071204_orig.wav"
            ),
            ("a.wav", ["a.wav"], "", "a.wav"),
            ("a/b/c.wav", ["a", "b", "c.wav"], "a/b", "c.wav"),
            ("a//b", ["a", "", "b"], "a/", "b"),
            ("a/", ["a", ""], "a", ""),
            ("/abs", ["", "abs"], "", "abs"),
            ("..", [".."], "", ".."),
        ])
    func f73AsciiResultsAreUnchanged(
        _ relpath: String, _ components: [String], _ parent: String, _ last: String
    ) {
        #expect(RelPath.components(relpath) == components)
        #expect(RelPath.parent(relpath) == parent)
        #expect(RelPath.lastComponent(relpath) == last)
        #expect(RelPath.join(components) == relpath)
    }

    @Test("F-73 空の relpath は空の要素 1 つに分かれ、親も最後の要素も空で、偽（TEST-28）")
    func f73EmptyRelpath() {
        #expect(RelPath.components("") == [""])
        #expect(RelPath.parent("") == "")
        #expect(RelPath.lastComponent("") == "")
        #expect(RelPath.join([]) == "")
        #expect(!RelPath.isSafe(""))
    }
}
