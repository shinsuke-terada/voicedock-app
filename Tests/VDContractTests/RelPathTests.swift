// RelPath の検査（T-06 §5.5）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("RelPath")
struct RelPathTests {
    @Test(
        "健全な relpath",
        arguments: ["TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav", "a.wav", "a/b/c.wav"])
    func acceptsSafeRelpaths(_ relpath: String) {
        #expect(RelPath.isSafe(relpath))
    }

    @Test(
        "RV-08 の全拒否条件（パラメータ化）",
        arguments: [
            "", "/TX01/a.wav", "../a.wav", "TX01/../a.wav", ".Trashes/a.wav", "TX01/.fseventsd", "TX01/a\nb.wav",
            "TX01/a\u{7f}b.wav", "./a.wav", "a//b.wav", "a/", "a\\b.wav", "a/./b.wav", "..", ".",
        ])
    func rejectsUnsafeRelpaths(_ relpath: String) {
        #expect(!RelPath.isSafe(relpath))
    }

    @Test("UTF-8 で 1024 バイト超は偽")
    func rejectsOverlongRelpath() {
        let exact = "a/" + String(repeating: "b", count: 1022)
        #expect(exact.utf8.count == 1024)
        #expect(RelPath.isSafe(exact))
        #expect(!RelPath.isSafe(exact + "b"))
        let japanese = String(repeating: "あ", count: 342)
        #expect(japanese.utf8.count == 1026)
        #expect(!RelPath.isSafe(japanese))
    }

    /// voicedock の `is_safe_relpath` は `PurePosixPath` で正規化してから見ていたので `./a.wav` と `a//b.wav` を
    /// 真にしていた。こちらは生の文字列を見るので偽にする（より厳しい）。
    @Test("voicedock が真にしていた ./a と a//b を偽にする")
    func stricterThanVoicedock() {
        #expect(!RelPath.isSafe("./a.wav"))
        #expect(!RelPath.isSafe("a//b.wav"))
    }

    @Test("components は空要素を省かない")
    func componentsKeepEmpty() {
        #expect(RelPath.components("a//b") == ["a", "", "b"])
        #expect(RelPath.components("a/") == ["a", ""])
    }

    @Test("結合・親・最後の要素")
    func joinParentLast() {
        #expect(RelPath.join(["a", "b"]) == "a/b")
        #expect(RelPath.parent("a/b/c") == "a/b")
        #expect(RelPath.parent("c") == "")
        #expect(RelPath.lastComponent("a/b/c") == "c")
    }
}
