// AtomicFile の検査（T-06 §5.13）。readBackMismatch の経路は注入の手段が無いのでコードレビューで確かめる。
import Darwin
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("AtomicFile")
struct AtomicFileTests {
    static func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    @Test("新しく書く")
    func writesNewFile() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("x")
        try AtomicFile.write(Data("hello".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("hello".utf8))
        #expect(try Self.permissions(url) == 0o644)
        #expect(!Self.exists(tmp.url.appendingPathComponent(".x.tmp")))
    }

    @Test("空のデータも書ける")
    func writesEmptyData() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("empty")
        try AtomicFile.write(Data(), to: url, verifyReadBack: true)
        #expect(try Data(contentsOf: url) == Data())
    }

    @Test("既存を置き換える")
    func replacesExistingFile() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("a.json")
        try Data("old".utf8).write(to: url)
        try AtomicFile.write(Data("new".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("new".utf8))
        #expect(!Self.exists(tmp.url.appendingPathComponent(".a.json.tmp")))
    }

    @Test("権限を指定どおりにする")
    func honorsPermissions() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("a.json")
        let staleTmp = tmp.url.appendingPathComponent(".a.json.tmp")
        try Data("stale".utf8).write(to: staleTmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: staleTmp.path)
        try AtomicFile.write(Data("x".utf8), to: url, permissions: 0o600)
        #expect(try Self.permissions(url) == 0o600)
    }

    @Test("tmp の名前")
    func tmpNameIsDotNameDotTmp() {
        let dir = URL(fileURLWithPath: "/tmp/atomic-dir", isDirectory: true)
        #expect(AtomicFile.tmpURL(for: dir.appendingPathComponent("a.json")).path == "/tmp/atomic-dir/.a.json.tmp")
        #expect(
            AtomicFile.tmpURL(for: dir.appendingPathComponent("2026-08-29 raw.md")).path
                == "/tmp/atomic-dir/.2026-08-29 raw.md.tmp")
    }

    @Test("書けないディレクトリ")
    func openFailsInReadOnlyDirectory() throws {
        let tmp = try TempDirectory()
        let dir = tmp.url.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let url = dir.appendingPathComponent("a.json")
        #expect(throws: AtomicFileError.open(errno: EACCES)) { try AtomicFile.write(Data("x".utf8), to: url) }
        #expect(!Self.exists(url))
    }

    @Test("親が無い")
    func missingParentIsOpenError() throws {
        let tmp = try TempDirectory()
        let dir = tmp.url.appendingPathComponent("missing", isDirectory: true)
        let url = dir.appendingPathComponent("a.json")
        #expect(throws: AtomicFileError.open(errno: ENOENT)) { try AtomicFile.write(Data("x".utf8), to: url) }
        #expect(!Self.exists(dir))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).isEmpty)
    }

    @Test("rename の失敗で元を差し替えない")
    func renameFailureKeepsOriginalAndRemovesTmp() throws {
        let tmp = try TempDirectory()
        let dest = tmp.url.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        let inner = dest.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: inner)
        do {
            try AtomicFile.write(Data("x".utf8), to: dest)
            Issue.record("rename が成功してしまった")
        } catch {
            switch error {
            case .rename(let code):
                #expect(code == EISDIR || code == ENOTEMPTY)
            default:
                Issue.record("rename 以外の誤り: \(error)")
            }
        }
        #expect(Self.isDirectory(dest))
        #expect(try Data(contentsOf: inner) == Data("keep".utf8))
        #expect(!Self.exists(tmp.url.appendingPathComponent(".dest.tmp")))
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    @Test("symlink の宛先ではなくリンク自体を置き換える")
    func replacesSymlinkItself() throws {
        let tmp = try TempDirectory()
        let a = tmp.url.appendingPathComponent("a")
        let b = tmp.url.appendingPathComponent("b")
        try Data("b-content".utf8).write(to: b)
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try AtomicFile.write(Data("new".utf8), to: a)
        let attributes = try FileManager.default.attributesOfItem(atPath: a.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: a) == Data("new".utf8))
        #expect(try Data(contentsOf: b) == Data("b-content".utf8))
    }

    @Test("読み直しの照合が通る")
    func verifyReadBackPasses() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("v.json")
        #expect(throws: Never.self) { try AtomicFile.write(Data("verified".utf8), to: url, verifyReadBack: true) }
        #expect(try Data(contentsOf: url) == Data("verified".utf8))
    }
}
