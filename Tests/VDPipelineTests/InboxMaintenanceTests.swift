// inbox の孤児の削除と取り残しの集計のテスト（T-18 §6.3。PLAN §5.3・§8.12）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("InboxMaintenance")
struct InboxMaintenanceTests {
    static let folder = "TX_MIC001_20260829_071201"

    static func maintenance(_ w: PipelineWorld) -> InboxMaintenance {
        InboxMaintenance(store: w.store, layout: w.layout, log: w.log)
    }

    static func put(_ url: URL, bytes: Int = 10) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    static func relpath(_ hhmmss: String) -> String { folder + "/TX01_MIC002_20260829_" + hhmmss + "_orig.wav" }

    @Test("行の無い _orig.wav とすべての .partial を消す")
    func removesOrphansAndPartials() async throws {
        let w = try await PipelineWorld.make()
        let known = Self.relpath("071204")
        try w.insertPart(relpath: known)
        let knownFile = w.layout.inboxFile(deviceID: "DJIMIC3", relpath: known)
        let orphan = w.layout.inboxFile(deviceID: "DJIMIC3", relpath: Self.relpath("081204"))
        let partial = w.layout.inboxPartial(deviceID: "DJIMIC3", relpath: known)
        let notes = w.layout.inbox.appendingPathComponent("DJIMIC3/" + Self.folder + "/notes.txt")
        for url in [knownFile, orphan, partial, notes] { try Self.put(url) }
        #expect(partial.lastPathComponent == ".TX01_MIC002_20260829_071204_orig.wav.partial")

        let removed = try Self.maintenance(w).removeOrphans()

        #expect(removed == 2)
        #expect(PipelineFixtures.exists(knownFile))
        #expect(PipelineFixtures.exists(notes))
        #expect(!PipelineFixtures.exists(orphan))
        #expect(!PipelineFixtures.exists(partial))
    }

    @Test("ボリューム直下の録音も扱う")
    func rootLevelRecordingsAreHandled() async throws {
        let w = try await PipelineWorld.make()
        let file = w.layout.inbox.appendingPathComponent("DJIMIC3/TX01_MIC002_20260829_071204_orig.wav")
        try Self.put(file)
        _ = try Self.maintenance(w).removeOrphans()
        #expect(!PipelineFixtures.exists(file))
    }

    @Test("symlink は辿らず消さない")
    func symlinksAreNotFollowed() async throws {
        let w = try await PipelineWorld.make()
        let outside = w.tmp.url.appendingPathComponent("outside/TX01_MIC002_20260829_071204_orig.wav")
        try Self.put(outside)
        let link = w.layout.inboxFile(deviceID: "DJIMIC3", relpath: Self.relpath("071204"))
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        _ = try Self.maintenance(w).removeOrphans()
        let type =
            try FileManager.default.attributesOfItem(atPath: link.path(percentEncoded: false))[.type]
            as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        #expect(PipelineFixtures.exists(outside))
    }

    @Test("取り残しは終端（FAILED 以外）の Part だけ")
    func leftoversCountsTerminalOnly() async throws {
        let w = try await PipelineWorld.make()
        let saved = try w.insertPart(relpath: Self.relpath("071201"))
        let failed = try w.insertPart(relpath: Self.relpath("071202"))
        try w.insertPart(relpath: Self.relpath("071203"))
        try w.movePart(saved, [.normalizing, .normalized, .transcribing, .transcribed, .rawWriting, .rawSaved])
        try w.movePart(failed, [.normalizing, .failed])
        for hhmmss in ["071201", "071202", "071203"] {
            try Self.put(w.layout.inboxFile(deviceID: "DJIMIC3", relpath: Self.relpath(hhmmss)), bytes: 10)
        }
        let result = try Self.maintenance(w).leftovers()
        #expect(result.count == 1)
        #expect(result.bytes == 10)
    }

    @Test("空の inbox")
    func emptyInbox() async throws {
        let w = try await PipelineWorld.make()
        #expect(try Self.maintenance(w).removeOrphans() == 0)
        let result = try Self.maintenance(w).leftovers()
        #expect(result.count == 0)
        #expect(result.bytes == 0)
    }
}
