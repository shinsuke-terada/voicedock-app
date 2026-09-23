// AtomicFile の fullSync（F_FULLFSYNC。使えなければ fsync に戻す）のテスト（F-83。issue #119 の F9）。
import Darwin
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("AtomicFile（F-83）")
struct AtomicFileFullSyncTests {
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    @Test("F-83 fullSync でも中身・権限は同じで tmp を残さない")
    func fullSyncWrites() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("a.md")
        try AtomicFile.write(Data("hello".utf8), to: url, permissions: 0o600, verifyReadBack: true, fullSync: true)
        #expect(try Data(contentsOf: url) == Data("hello".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(!Self.exists(tmp.url.appendingPathComponent(".a.md.tmp")))
    }

    @Test("F-83 fullSync で空のデータも書ける（TEST-28）")
    func fullSyncWritesEmptyData() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("empty")
        try AtomicFile.write(Data(), to: url, fullSync: true)
        #expect(try Data(contentsOf: url) == Data())
    }

    @Test("F-83 fullFsync は通常のファイルで成功する")
    func fullFsyncSucceedsOnRegularFile() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("f")
        try Data("x".utf8).write(to: url)
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(AtomicFile.fullFsync(fd) == nil)
    }

    @Test("F-83 F_FULLFSYNC に対応しない fd（/dev/null）では fsync に戻して成功する")
    func fullFsyncFallsBackToFsync() {
        let fd = open("/dev/null", O_WRONLY | O_CLOEXEC)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(fcntl(fd, F_FULLFSYNC) == -1)
        #expect(AtomicFile.fullFsync(fd) == nil)
    }

    @Test("F-83 fsync も失敗する fd（パイプ）では fsync の errno（EINVAL）")
    func fullFsyncReportsFsyncErrno() {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        #expect(AtomicFile.fullFsync(fds[1]) == EINVAL)
    }
}
