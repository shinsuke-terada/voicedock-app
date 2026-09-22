// E2E-18 に対応する結合（T-33 §5.3。PLAN §8.13・§8.8・付録 B.3）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDNotes
import VDStore

@testable import VDPipeline

@Suite("E2E-18 voicedock からの乗り換え", .serialized)
struct MigrationIntegrationTests {
    static let key = "DJIMIC3:20260829"
    static let folder = "Daily/Voice/Raw/20260829"
    static let voicedockRel = "Daily/Voice/Raw/20260829/2026-08-29 raw.md"
    static let appRel = "Daily/Voice/Raw/20260829/2026-08-29 raw (2).md"

    struct Setup {
        let world: PipelineWorld
        let vault: URL
        let before: Data
        let beforeSHA: String
        let beforeStat: stat
        let pk: String
    }

    static func lstatOf(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else {
            throw PipelineFixtureError.badFixture(url.path(percentEncoded: false))
        }
        return info
    }

    static func setUp() async throws -> Setup {
        let world = try await PipelineWorld.make()
        let vault = try await world.installVault()
        try world.writeVaultNote(
            voicedockRel, world.voicedockRawNote(keys: [PipelineFixtures.foreignKeyA, PipelineFixtures.foreignKeyB]))
        let url = vault.appendingPathComponent(voicedockRel, isDirectory: false)
        let before = try Data(contentsOf: url)
        let beforeSHA = FileHasher.sha256(before)
        let beforeStat = try lstatOf(url)
        try world.addSession(key: key, day: "2026-08-29", status: .ready)
        let pk = try world.addPart(PipelineFixtures.partA, status: .transcribed)
        return Setup(world: world, vault: vault, before: before, beforeSHA: beforeSHA, beforeStat: beforeStat, pk: pk)
    }

    /// worker.start() → ensureRawNote。
    static func run(_ s: Setup) async throws -> Bool {
        await s.world.worker().start()
        return await PartSteps(ctx: try await s.world.context()).ensureRawNote(try s.world.part(s.pk))
    }

    static func folderEntries(_ s: Setup) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: s.vault.appendingPathComponent(folder, isDirectory: true).path(percentEncoded: false)
        ).sorted()
    }

    @Test("E2E-18 取り込み → 同じ日の新しい録音は ` (2)` に書く")
    func e2e18ImportsThenWritesToTheSuffixedNote() async throws {
        let s = try await Self.setUp()
        let w = s.world
        #expect(try await Self.run(s))
        #expect(try Self.folderEntries(s) == ["2026-08-29 raw (2).md", "2026-08-29 raw.md"])
        #expect(try w.part(s.pk).status == .rawSaved)
        let session = try w.session(Self.key)
        #expect(session.rawOutputPath == "Daily/Voice/Raw/20260829/2026-08-29 raw (2).md")
        let appURL = s.vault.appendingPathComponent(Self.appRel, isDirectory: false)
        let appData = try Data(contentsOf: appURL)
        #expect(session.rawOutputSHA256 == FileHasher.sha256(appData))
        #expect(Frontmatter.recordingKeys(ofFile: appURL) == [s.pk])
        guard let cfg = await w.configStore.current(), let sha = session.rawOutputSHA256 else {
            throw PipelineFixtureError.noConfig
        }
        let verification = NoteVerifier.verify(
            url: appURL, kind: .raw, sessionKey: Self.key, expectedSHA256: sha, expectedKeys: [s.pk],
            summaryHeading: DailyNote.summaryHeading(config: cfg))
        #expect(verification.passed)
        let lines = w.sink.lines
        let added = lines.indices.filter { lines[$0].hasSuffix("imported_keys_added count=2") }
        let saved = lines.indices.filter { lines[$0].contains(" raw_note_saved ") }
        #expect(added.count == 1)
        #expect(saved.count == 1)
        if let a = added.first, let b = saved.first { #expect(a < b) }
    }

    @Test("E2E-18 voicedock のノートは 1 バイトも変わらない")
    func e2e18VoicedockNoteIsByteIdentical() async throws {
        let s = try await Self.setUp()
        #expect(try await Self.run(s))
        let url = s.vault.appendingPathComponent(Self.voicedockRel, isDirectory: false)
        let after = try Data(contentsOf: url)
        #expect(after == s.before)
        #expect(FileHasher.sha256(after) == s.beforeSHA)
        let afterStat = try Self.lstatOf(url)
        #expect(afterStat.st_mtimespec.tv_sec == s.beforeStat.st_mtimespec.tv_sec)
        #expect(afterStat.st_mtimespec.tv_nsec == s.beforeStat.st_mtimespec.tv_nsec)
        #expect(afterStat.st_ino == s.beforeStat.st_ino)
        #expect(try Self.folderEntries(s).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test("取り込んだ鍵は取り込みの候補にならない")
    func e2e18ImportedKeysAreNotCopyCandidates() async throws {
        let s = try await Self.setUp()
        #expect(try await Self.run(s))
        #expect(try s.world.store.importedKeys() == [PipelineFixtures.foreignKeyA, PipelineFixtures.foreignKeyB])
        #expect(try s.world.store.recording(PipelineFixtures.foreignKeyA) == nil)
        #expect(try s.world.store.recording(PipelineFixtures.foreignKeyB) == nil)
    }

    @Test("2 回目の起動で何も増えない")
    func e2e18SecondRunChangesNothing() async throws {
        let s = try await Self.setUp()
        #expect(try await Self.run(s))
        #expect(await s.world.importedKeys.scanIfAvailable(.startup) == 0)
        #expect(try s.world.store.importedKeys().count == 2)
        #expect(try Self.folderEntries(s) == ["2026-08-29 raw (2).md", "2026-08-29 raw.md"])
        #expect(s.world.lines("imported_keys_added").count == 1)
    }

    @Test("アプリが書いた ` (2)` は次から上書きされる")
    func e2e18AppNoteIsOverwrittenOnRerun() async throws {
        let s = try await Self.setUp()
        let w = s.world
        #expect(try await Self.run(s))
        try w.forcePart(s.pk, status: .transcribed, sessionKey: Self.key)
        #expect(await PartSteps(ctx: try await w.context()).ensureRawNote(try w.part(s.pk)))
        #expect(try Self.folderEntries(s) == ["2026-08-29 raw (2).md", "2026-08-29 raw.md"])
        #expect(try w.session(Self.key).rawOutputPath == "Daily/Voice/Raw/20260829/2026-08-29 raw (2).md")
        #expect(w.lines("raw_note_saved").count == 2)
        #expect(try Data(contentsOf: s.vault.appendingPathComponent(Self.voicedockRel)) == s.before)
    }
}
