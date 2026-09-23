// ノートの書き出しを F_FULLFSYNC にすることと、フォルダをスカラー単位で分けて作ることのテスト（F-83。PLAN §8.7。issue #119 の F9）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("NoteWriter（F-83）")
struct NoteWriterFullSyncTests {
    func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    @Test("F-83 ノートは F_FULLFSYNC で書き出す（Raw ノートは原本の削除の根拠）")
    func notesUseFullSync() {
        #expect(NoteWriter.fullSync == true)
    }

    @Test("F-83 F_FULLFSYNC でも中身と SHA-256 は今までどおり")
    func fullSyncWriteKeepsContentAndDigest() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("2026-08-29 raw.md", isDirectory: false)
        let sha = try NoteWriter.write("x", to: url)
        #expect(sha == "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881")
        #expect(try Data(contentsOf: url) == Data("x".utf8))
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent(".2026-08-29 raw.md.tmp").path))
    }

    @Test("F-83 空の本文も書ける（TEST-28）")
    func emptyContent() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("empty.md", isDirectory: false)
        let sha = try NoteWriter.write("", to: url)
        #expect(sha == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(try Data(contentsOf: url) == Data())
    }

    @Test("F-83 フォルダは / でスカラー単位に分けて 1 段ずつ作る（/ の直後の結合文字で区切りを見落とさない）")
    func folderIsSplitByScalars() throws {
        let temp = try TempDirectory()
        let made = try NoteFolder.ensure(relative: "a/\u{301}b", vault: temp.url)
        let first = temp.url.appendingPathComponent("a", isDirectory: true)
        let second = first.appendingPathComponent("\u{301}b", isDirectory: true)
        #expect(isDirectory(first))
        #expect(isDirectory(second))
        #expect(
            made.path(percentEncoded: false).unicodeScalars.elementsEqual(
                second.path(percentEncoded: false).unicodeScalars))
    }
}
