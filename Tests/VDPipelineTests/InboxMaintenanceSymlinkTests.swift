// <HOME> の途中に symlink があっても inbox の孤児の partkey がずれないこと（PLAN §5.3・§8.12。F-82・issue #119 の D9）。
// 列挙子は symlink を解決した絶対パスの URL を返すので、要素数の差で relpath を作ると DB に行のある _orig.wav を消しうる。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("InboxMaintenance（F-82 symlink を挟んだ <HOME>）")
struct InboxMaintenanceSymlinkTests {
    static let folder = "TX_MIC001_20260829_071201"

    static func relpath(_ hhmmss: String) -> String { folder + "/TX01_MIC002_20260829_" + hhmmss + "_orig.wav" }

    /// 実体を `<tmp>/deep/er/home` に作り、`<tmp>/alias` → 実体の symlink を <HOME> にした HomeLayout。
    /// symlink の側は実体より要素が 2 つ少ない（要素数の差で relpath を作ると、先頭の `inbox/DJIMIC3` まで relpath に入る）。
    static func aliasedLayout(_ w: PipelineWorld) throws -> HomeLayout {
        let real = w.tmp.url.appendingPathComponent("deep/er/home", isDirectory: true)
        try HomeLayout(root: real).createDirectories()
        let aliasPath = w.tmp.url.appendingPathComponent("alias").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: aliasPath, withDestinationPath: real.path(percentEncoded: false))
        return HomeLayout(root: URL(fileURLWithPath: aliasPath, isDirectory: true))
    }

    static func put(_ url: URL, bytes: Int = 10) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    @Test("F-82 <HOME> の途中に symlink があっても、DB に行のある _orig.wav を孤児として消さない（孤児と .partial は消す）")
    func keepsKnownOrigThroughSymlink() async throws {
        let w = try await PipelineWorld.make()
        let layout = try Self.aliasedLayout(w)
        let known = Self.relpath("071204")
        try w.insertPart(relpath: known)
        let knownFile = layout.inboxFile(deviceID: "DJIMIC3", relpath: known)
        let orphan = layout.inboxFile(deviceID: "DJIMIC3", relpath: Self.relpath("081204"))
        let partial = layout.inboxPartial(deviceID: "DJIMIC3", relpath: known)
        for url in [knownFile, orphan, partial] { try Self.put(url) }

        let removed = try InboxMaintenance(store: w.store, layout: layout, log: w.log).removeOrphans()

        #expect(removed == 2)
        #expect(PipelineFixtures.exists(knownFile))
        #expect(!PipelineFixtures.exists(orphan))
        #expect(!PipelineFixtures.exists(partial))
    }

    @Test("F-82 取り残しの集計も symlink の向こうで同じ partkey で数える")
    func leftoversThroughSymlink() async throws {
        let w = try await PipelineWorld.make()
        let layout = try Self.aliasedLayout(w)
        let known = Self.relpath("071204")
        let pk = try w.insertPart(relpath: known)
        try w.forcePart(pk, status: .completed, sessionKey: nil)
        try Self.put(layout.inboxFile(deviceID: "DJIMIC3", relpath: known), bytes: 10)

        let result = try InboxMaintenance(store: w.store, layout: layout, log: w.log).leftovers()

        #expect(result.count == 1)
        #expect(result.bytes == 10)
    }

    @Test("F-82 TEST-28 inbox が空なら何も消さずに 0 件、基底の無い URL（照合できない）は relpath を作らない")
    func emptyInboxAndUnmatchableURL() async throws {
        let w = try await PipelineWorld.make()
        let layout = try Self.aliasedLayout(w)

        #expect(try InboxMaintenance(store: w.store, layout: layout, log: w.log).removeOrphans() == 0)
        #expect(InboxMaintenance.relpath(URL(fileURLWithPath: "/tmp/DJIMIC3/" + Self.relpath("071204"))) == nil)
        let relative = URL(fileURLWithPath: Self.relpath("071204"), relativeTo: layout.inbox)
        #expect(InboxMaintenance.relpath(relative) == Self.relpath("071204"))
    }
}
