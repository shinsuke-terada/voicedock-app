// DeviceReader の列挙と lstat の種類の検査（T-13 §5.2）。一時ディレクトリだけを見る。
import Darwin
import Foundation
import TestSupport
import Testing

@testable import VDDevice

@Suite("DeviceReader の列挙")
struct DeviceReaderListingTests {
    @Test("名前を UTF-8 のバイト順で返す")
    func listsNamesInByteOrder() throws {
        let tmp = try TempDirectory()
        for name in ["b", "a", ".hidden", "あ"] {
            try Data().write(to: tmp.url.appendingPathComponent(name, isDirectory: false))
        }
        let result = DeviceReader().listEntries(of: tmp.url.path(percentEncoded: false))
        #expect(result == .success([".hidden", "a", "b", "あ"]))
    }

    @Test("空のディレクトリは空配列")
    func emptyDirectoryListsNothing() throws {
        let tmp = try TempDirectory()
        #expect(DeviceReader().listEntries(of: tmp.url.path(percentEncoded: false)) == .success([]))
    }

    @Test("列挙できなければ errno を返す（EACCES）")
    func unlistableDirectoryReturnsErrno() throws {
        let tmp = try TempDirectory()
        let dir = tmp.url.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.path(percentEncoded: false)
        #expect(chmod(path, 0o000) == 0)
        defer { _ = chmod(path, 0o755) }
        #expect(DeviceReader().listEntries(of: path) == .failure(ErrnoError(EACCES)))
    }

    @Test("無いディレクトリは ENOENT")
    func missingDirectoryReturnsENOENT() throws {
        let tmp = try TempDirectory()
        let path = tmp.url.appendingPathComponent("missing", isDirectory: false).path(percentEncoded: false)
        #expect(DeviceReader().listEntries(of: path) == .failure(ErrnoError(ENOENT)))
    }

    @Test("lstat で判定し symlink を辿らない")
    func entryKindDoesNotFollowSymlinks() throws {
        let tmp = try TempDirectory()
        let manager = FileManager.default
        let file = tmp.url.appendingPathComponent("file", isDirectory: false)
        let dir = tmp.url.appendingPathComponent("dir", isDirectory: true)
        try Data("x".utf8).write(to: file)
        try manager.createDirectory(at: dir, withIntermediateDirectories: true)
        func child(_ name: String) -> String {
            tmp.url.appendingPathComponent(name, isDirectory: false).path(percentEncoded: false)
        }
        try manager.createSymbolicLink(atPath: child("fileLink"), withDestinationPath: "file")
        try manager.createSymbolicLink(atPath: child("dirLink"), withDestinationPath: "dir")
        let reader = DeviceReader()
        #expect(reader.entryKind(child("file")) == .regularFile)
        #expect(reader.entryKind(child("dir")) == .directory)
        #expect(reader.entryKind(child("fileLink")) == .symlink)
        #expect(reader.entryKind(child("dirLink")) == .symlink)
        #expect(reader.entryKind(child("absent")) == .missing)
    }
}
