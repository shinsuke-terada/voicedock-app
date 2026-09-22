// InboxScan（inbox の処理待ちと取り残し。読むだけ）のテスト（T-32 §5.8）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDPipeline

@Suite("InboxScan")
struct InboxScanTests {
    static func layout(_ tmp: TempDirectory) throws -> HomeLayout {
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        return layout
    }

    /// inbox/<relative> に bytes バイトのファイルを置き、<HOME> からの相対パスを返す
    @discardableResult
    static func put(_ layout: HomeLayout, _ relative: String, bytes: Int) throws -> String {
        let url = layout.inbox.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return "inbox/" + relative
    }

    @Test("TEST-28 空")
    func emptyInbox() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        #expect(InboxScan.counts(layout: layout, leftoverRelativePaths: []) == .empty)
        #expect(InboxScan.leftovers(layout: layout, relativePaths: []) == (0, 0))
    }

    @Test("サブディレクトリの .wav も数える")
    func countsNestedWav() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        try Self.put(layout, "DJIMIC3/a_orig.wav", bytes: 3)
        try Self.put(layout, "DJIMIC3/F1/b_orig.wav", bytes: 5)
        let c = InboxScan.counts(layout: layout, leftoverRelativePaths: [])
        #expect(c == InboxCounts(pendingCount: 2, pendingBytes: 8, leftoverCount: 0, leftoverBytes: 0))
    }

    @Test("#120 取り残しを処理待ちに数えない")
    func leftoversAreExcludedFromPending() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        try Self.put(layout, "DJIMIC3/F/a_orig.wav", bytes: 2)
        try Self.put(layout, "DJIMIC3/F/b_orig.wav", bytes: 3)
        let left = try Self.put(layout, "DJIMIC3/F/c_orig.wav", bytes: 7)
        let c = InboxScan.counts(layout: layout, leftoverRelativePaths: [left])
        #expect(c.pendingCount == 2)
        #expect(c.pendingBytes == 5)
        #expect(c.leftoverCount == 1)
        #expect(c.leftoverBytes == 7)
    }

    @Test("DB に在ってファイルが無ければ数えない")
    func missingLeftoverPathIsNotCounted() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        let c = InboxScan.counts(layout: layout, leftoverRelativePaths: ["inbox/DJIMIC3/F/gone_orig.wav"])
        #expect(c.leftoverCount == 0)
        #expect(c.leftoverBytes == 0)
    }

    @Test(".meta.json は数えない")
    func nonWavFilesAreIgnoredInPending() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        try Self.put(layout, "DJIMIC3/F/a_orig.meta.json", bytes: 9)
        #expect(InboxScan.counts(layout: layout, leftoverRelativePaths: []).pendingCount == 0)
    }

    @Test("読めないものは飛ばす")
    func unreadableEntriesAreSkipped() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        try Self.put(layout, "DJIMIC3/a_orig.wav", bytes: 3)
        try Self.put(layout, "DJIMIC3/locked/b_orig.wav", bytes: 5)
        let locked = layout.inbox.appendingPathComponent("DJIMIC3/locked", isDirectory: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: locked.path(percentEncoded: false))
        }
        let c = InboxScan.counts(layout: layout, leftoverRelativePaths: [])
        #expect(c.pendingCount == 1)
        #expect(c.pendingBytes == 3)
    }

    @Test("通常ファイルだけ足す")
    func directoryBytesSumsRegularFilesOnly() throws {
        let tmp = try TempDirectory()
        let dir = tmp.url.appendingPathComponent("d", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        try Data(count: 10).write(to: dir.appendingPathComponent("a"))
        try Data(count: 20).write(to: dir.appendingPathComponent("sub/b"))
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("a"))
        #expect(InboxScan.directoryBytes(dir) == 30)
        #expect(InboxScan.directoryBytes(tmp.url.appendingPathComponent("missing", isDirectory: true)) == 0)
    }
}
