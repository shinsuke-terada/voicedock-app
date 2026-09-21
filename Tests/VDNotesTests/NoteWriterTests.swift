// ノートの atomic な書き込み・フォルダ・エラーの文言（PLAN §8.7。T-28 §5.2）。一時ディレクトリの中だけに書く。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDNotes

@Suite("NoteWriter")
struct NoteWriterTests {
    static var isRoot: Bool { geteuid() == 0 }

    func path(_ url: URL) -> String {
        url.path(percentEncoded: false)
    }

    func contents(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path(dir)).sorted()
    }

    @Test("書いて SHA を返す")
    func writesAndReturnsSHA() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("a.md")
        let sha = try NoteWriter.write("# x\n", to: url)
        #expect(sha == FileHasher.sha256(Data("# x\n".utf8)))
        // "# x\n" の SHA-256（固定値。shasum -a 256 で求めた）
        #expect(sha == "253b610bd786f2543252c8d4b45bb40eb375882587f825cb9ce1fd1241f66f1e")
        #expect(try Data(contentsOf: url) == Data("# x\n".utf8))
    }

    @Test("一時ファイルが残らない")
    func noTemporaryLeft() throws {
        let temp = try TempDirectory()
        _ = try NoteWriter.write("# x\n", to: temp.url.appendingPathComponent("a.md"))
        #expect(!FileManager.default.fileExists(atPath: path(temp.url.appendingPathComponent(".a.md.tmp"))))
        #expect(try contents(temp.url) == ["a.md"])
    }

    @Test("既存のノートを上書きする")
    func overwritesExisting() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("a.md")
        try Data("old".utf8).write(to: url)
        _ = try NoteWriter.write("new", to: url)
        #expect(try Data(contentsOf: url) == Data("new".utf8))
    }

    @Test("既存の一時ファイルを切り詰めて使う")
    func staleTempIsReused() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("a.md")
        let tmp = temp.url.appendingPathComponent(".a.md.tmp")
        try Data(repeating: 0x5A, count: 1_048_576).write(to: tmp)
        _ = try NoteWriter.write("# fresh\n", to: url)
        #expect(try Data(contentsOf: url) == Data("# fresh\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: path(tmp)))
    }

    @Test("書けないときは既存のノートを変えない", .enabled(if: !NoteWriterTests.isRoot))
    func failureLeavesExistingIntact() throws {
        let temp = try TempDirectory()
        let d = temp.url.appendingPathComponent("d", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let url = d.appendingPathComponent("a.md")
        try Data("original".utf8).write(to: url)
        #expect(chmod(path(d), 0o555) == 0)
        defer { _ = chmod(path(d), 0o755) }
        #expect(throws: AtomicFileError.self) {
            _ = try NoteWriter.write("replacement", to: url)
        }
        #expect(try Data(contentsOf: url) == Data("original".utf8))
        #expect(try contents(d) == ["a.md"])
    }

    @Test("空の内容も書ける")
    func emptyContentWritten() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("a.md")
        let sha = try NoteWriter.write("", to: url)
        // 空の SHA-256（固定値）
        #expect(sha == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test("フォルダを中間ごと作る")
    func folderCreatesIntermediates() throws {
        let temp = try TempDirectory()
        let dir = try NoteFolder.ensure(relative: "Daily/Voice/Raw/20260829", vault: temp.url)
        var isDirectory: ObjCBool = false
        let expected = temp.url.appendingPathComponent("Daily/Voice/Raw/20260829", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: path(expected), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(path(dir) == path(temp.url) + "Daily/Voice/Raw/20260829/")
        #expect(try NoteFolder.ensure(relative: "", vault: temp.url) == temp.url)
    }

    @Test("危ないフォルダ名は作らない", arguments: ["../x", "/abs", ".hidden/x"])
    func folderRejectsUnsafe(_ relative: String) throws {
        let temp = try TempDirectory()
        let vault = temp.url.appendingPathComponent("v", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        #expect(throws: NoteFolderError.unsafeRelative) {
            _ = try NoteFolder.ensure(relative: relative, vault: vault)
        }
        #expect(try contents(vault).isEmpty)
        #expect(try contents(temp.url) == ["v"])
    }

    @Test("エラーの文言")
    func errorText() {
        #expect(NoteErrorText.describe(AtomicFileError.open(errno: 13)) == "AtomicFileError: open(errno: 13)")
    }
}
