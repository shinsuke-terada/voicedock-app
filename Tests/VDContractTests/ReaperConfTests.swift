// ReaperConf の検査（T-06 §5.11）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("ReaperConf")
struct ReaperConfTests {
    @Test("必須の 2 行だけ")
    func parsesMinimal() throws {
        let conf = try ReaperConf.parse(Data("SCHEMA=1\nDELETE_SOURCE_AUDIO=true\n".utf8)).get()
        #expect(conf.schema == 1)
        #expect(conf.deleteSourceAudio == true)
        #expect(conf.volumesRoot == "/Volumes")
    }

    @Test("コメントと空行を無視")
    func parsesWithCommentsAndBlankLines() throws {
        let text = "# c\n\nSCHEMA=1\n# x\nDELETE_SOURCE_AUDIO=false\nVOLUMES_ROOT=/tmp/v\n"
        let conf = try ReaperConf.parse(Data(text.utf8)).get()
        #expect(conf.deleteSourceAudio == false)
        #expect(conf.volumesRoot == "/tmp/v")
    }

    @Test("render の逐語")
    func renderIsExact() {
        #expect(
            ReaperConf(deleteSourceAudio: true).render()
                == Data("SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=/Volumes\n".utf8))
    }

    @Test("render と parse が往復", arguments: [true, false])
    func renderRoundTrips(_ flag: Bool) {
        let conf = ReaperConf(deleteSourceAudio: flag, volumesRoot: "/tmp/v")
        #expect(ReaperConf.parse(conf.render()) == .success(conf))
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let data: Data
        let expected: ReaperConfError
        init(_ text: String, _ expected: ReaperConfError) {
            self.data = Data(text.utf8)
            self.expected = expected
        }
        init(bytes: [UInt8], _ expected: ReaperConfError) {
            self.data = Data(bytes)
            self.expected = expected
        }
        var testDescription: String { String(decoding: data, as: UTF8.self).debugDescription }
    }

    @Test(
        "不正はすべて無効側（パラメータ化）",
        arguments: [
            Case("", .missingKey("SCHEMA")),
            Case("SCHEMA=1\n", .missingKey("DELETE_SOURCE_AUDIO")),
            Case("SCHEMA=2\nDELETE_SOURCE_AUDIO=true\n", .badValue("SCHEMA")),
            Case("SCHEMA=1\nDELETE_SOURCE_AUDIO=yes\n", .badValue("DELETE_SOURCE_AUDIO")),
            Case("SCHEMA=1\nDELETE_SOURCE_AUDIO=TRUE\n", .badValue("DELETE_SOURCE_AUDIO")),
            Case("SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=Volumes\n", .badValue("VOLUMES_ROOT")),
            Case("SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=\n", .badValue("VOLUMES_ROOT")),
            Case("SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nMOUNT_MODE=rw\n", .unknownKey("MOUNT_MODE")),
            Case("SCHEMA=1\nSCHEMA=1\nDELETE_SOURCE_AUDIO=true\n", .duplicateKey("SCHEMA")),
            Case("SCHEMA=1\nDELETE_SOURCE_AUDIO=true \n", .badLine(2)),
            Case("SCHEMA=1\r\nDELETE_SOURCE_AUDIO=true\r\n", .badLine(1)),
            Case("schema=1\n", .badLine(1)),
            Case("SCHEMA = 1\n", .badLine(1)),
            Case("export SCHEMA=1\n", .badLine(1)),
            Case("SCHEMA=1\nDELETE_SOURCE_AUDIO=$(rm -rf ~)\n", .badLine(2)),
            Case(bytes: [0xFF], .unreadable),
        ])
    func failClosed(_ c: Case) {
        #expect(ReaperConf.parse(c.data) == .failure(c.expected))
    }

    @Test("ファイルが無い")
    func observeMissing() throws {
        let tmp = try TempDirectory()
        #expect(ReaperConf.observe(at: tmp.url.appendingPathComponent("reaper.conf")) == .missing)
    }

    @Test("symlink は拒む")
    func observeSymlink() throws {
        let tmp = try TempDirectory()
        let real = tmp.url.appendingPathComponent("real.conf")
        try Data("SCHEMA=1\nDELETE_SOURCE_AUDIO=true\n".utf8).write(to: real)
        let link = tmp.url.appendingPathComponent("reaper.conf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(ReaperConf.observe(at: link) == .invalid(.notRegularFile))
    }

    @Test("ディレクトリは拒む")
    func observeDirectory() throws {
        let tmp = try TempDirectory()
        let dir = tmp.url.appendingPathComponent("reaper.conf", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        #expect(ReaperConf.observe(at: dir) == .invalid(.notRegularFile))
    }

    @Test("64 KiB 超")
    func observeTooLarge() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("reaper.conf")
        var text = "SCHEMA=1\nDELETE_SOURCE_AUDIO=true\n"
        let line = "#" + String(repeating: "x", count: 99) + "\n"
        while text.utf8.count + line.utf8.count <= 65_537 { text += line }
        text += "#" + String(repeating: "x", count: 65_537 - text.utf8.count - 1)
        #expect(text.utf8.count == 65_537)
        try Data(text.utf8).write(to: url)
        #expect(ReaperConf.observe(at: url) == .invalid(.tooLarge))
    }

    @Test("読めない")
    func observeUnreadable() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("reaper.conf")
        try ReaperConf(deleteSourceAudio: true).render().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        #expect(ReaperConf.observe(at: url) == .invalid(.unreadable))
    }

    @Test("正しいファイル")
    func observeValid() throws {
        let tmp = try TempDirectory()
        let url = tmp.url.appendingPathComponent("reaper.conf")
        try ReaperConf(deleteSourceAudio: true, volumesRoot: "/tmp/v").render().write(to: url)
        #expect(ReaperConf.observe(at: url) == .valid(ReaperConf(deleteSourceAudio: true, volumesRoot: "/tmp/v")))
    }
}
