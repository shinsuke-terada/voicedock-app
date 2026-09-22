// 乗り換えの走査の単体（T-33 §5.1。PLAN §8.13）。
import Foundation
import GRDB
import TestSupport
import Testing
import VDContract
import VDCore
import VDNotes

@testable import VDPipeline
@testable import VDStore

@Suite("ImportedKeysScanner")
struct ImportedKeysScannerTests {
    static let keyA = PipelineFixtures.foreignKeyA
    static let keyB = PipelineFixtures.foreignKeyB
    static let rawNote = "Daily/Voice/Raw/20260829/2026-08-29 raw.md"

    /// 既定の準備（Vault・scanner・既定の ObsidianConfig）。configure で設定を変える。
    static func setUp(
        configure: (inout AppConfig) -> Void = { _ in }
    ) async throws -> (PipelineWorld, URL, ImportedKeysScanner, ObsidianConfig) {
        let world = try await PipelineWorld.make(configure: configure)
        let vault = try await world.installVault()
        let scanner = ImportedKeysScanner(store: world.store, log: world.log)
        guard let cfg = await world.configStore.current()?.obsidian else { throw PipelineFixtureError.noConfig }
        return (world, vault, scanner, cfg)
    }

    static func sourceNote(_ world: PipelineWorld, _ key: String) throws -> String? {
        try world.store.pool.read { db in
            try String.fetchOne(db, sql: "SELECT source_note FROM imported_keys WHERE partkey = ?", arguments: [key])
        }
    }

    static func note(_ world: PipelineWorld, _ keys: [String]) -> String {
        world.voicedockRawNote(keys: keys)
    }

    /// Vault の外（tmp の直下）にノートを書く。
    static func writeOutside(_ world: PipelineWorld, _ relative: String, _ text: String) throws -> URL {
        let url = world.tmp.url.appendingPathComponent(relative, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("Raw フォルダのノートの鍵を入れる")
    func importsKeysFromTheRawFolder() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        try w.writeVaultNote(Self.rawNote, Self.note(w, [Self.keyA, Self.keyB]))
        #expect(try scanner.scan(vault: vault, config: cfg) == 2)
        #expect(try w.store.importedKeys() == [Self.keyA, Self.keyB])
        let lines = w.lines("imported_keys_added")
        #expect(lines.count == 1)
        #expect(lines.first?.hasSuffix("imported_keys_added count=2") == true)
    }

    @Test("source_note は Vault からの相対パス")
    func sourceNoteIsTheVaultRelativePath() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        try w.writeVaultNote(Self.rawNote, Self.note(w, [Self.keyA, Self.keyB]))
        _ = try scanner.scan(vault: vault, config: cfg)
        #expect(try Self.sourceNote(w, Self.keyA) == "Daily/Voice/Raw/20260829/2026-08-29 raw.md")
        #expect(try Self.sourceNote(w, Self.keyB) == "Daily/Voice/Raw/20260829/2026-08-29 raw.md")
    }

    @Test("DB に行がある partkey は入れない")
    func keysInTheDatabaseAreNotImported() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        try w.addSession(key: PipelineFixtures.vaultSessionKey, day: "2026-08-29", status: .ready)
        let pk = try w.addPart(PipelineFixtures.partA, status: .rawSaved)
        try w.writeVaultNote(Self.rawNote, Self.note(w, [pk]))
        #expect(try scanner.scan(vault: vault, config: cfg) == 0)
        #expect(try w.store.importedKeys().isEmpty)
        #expect(w.lines("imported_keys_added").isEmpty)
    }

    @Test("既に在る partkey は上書きしない")
    func existingImportedKeysAreNotOverwritten() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        #expect(try w.store.insertImportedKeys([(Self.keyA, "old.md")]) == 1)
        try w.writeVaultNote(Self.rawNote, Self.note(w, [Self.keyA]))
        #expect(try scanner.scan(vault: vault, config: cfg) == 0)
        #expect(try Self.sourceNote(w, Self.keyA) == "old.md")
        #expect(w.lines("imported_keys_added").isEmpty)
    }

    @Test("Raw フォルダの外は見ない")
    func outsideTheRawFolderIsIgnored() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        try w.writeVaultNote("Daily/Voice/Wiki/2026-08-29 Voice.md", Self.note(w, [Self.keyA]))
        #expect(try scanner.scan(vault: vault, config: cfg) == 0)
        #expect(try w.store.importedKeys().isEmpty)
    }

    @Test("入れ子のフォルダも走る")
    func nestedFoldersAreScanned() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        try w.writeVaultNote("Daily/Voice/Raw/2026/08/note.md", Self.note(w, [Self.keyA]))
        #expect(try scanner.scan(vault: vault, config: cfg) == 1)
        #expect(try Self.sourceNote(w, Self.keyA) == "Daily/Voice/Raw/2026/08/note.md")
    }

    @Test("`.` 始まりは無視する")
    func dotDirectoriesAreSkipped() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        try w.writeVaultNote("Daily/Voice/Raw/.trash/old.md", Self.note(w, [Self.keyA]))
        try w.writeVaultNote("Daily/Voice/Raw/.hidden.md", Self.note(w, [Self.keyB]))
        #expect(try scanner.scan(vault: vault, config: cfg) == 0)
        #expect(try w.store.importedKeys().isEmpty)
    }

    @Test("ディレクトリの symlink を辿らない")
    func symlinkedDirectoryIsNotFollowed() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        let outside = try Self.writeOutside(w, "outside/dir/note.md", Self.note(w, [Self.keyA]))
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("Daily/Voice/Raw", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("Daily/Voice/Raw/linked", isDirectory: false),
            withDestinationURL: outside.deletingLastPathComponent())
        #expect(try scanner.scan(vault: vault, config: cfg) == 0)
        #expect(try w.store.importedKeys().isEmpty)
    }

    @Test("ファイルの symlink は開かない")
    func symlinkedFileIsNotRead() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        let outside = try Self.writeOutside(w, "outside/note.md", Self.note(w, [Self.keyA]))
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("Daily/Voice/Raw", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("Daily/Voice/Raw/x.md", isDirectory: false), withDestinationURL: outside)
        #expect(try scanner.scan(vault: vault, config: cfg) == 0)
        #expect(try w.store.importedKeys().isEmpty)
    }

    @Test("`.md` 以外と大文字の `.MD` は見ない")
    func nonMarkdownIsIgnored() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        try w.writeVaultNote("Daily/Voice/Raw/a.txt", Self.note(w, [Self.keyA]))
        try w.writeVaultNote("Daily/Voice/Raw/b.MD", Self.note(w, [Self.keyB]))
        #expect(try scanner.scan(vault: vault, config: cfg) == 0)
        #expect(try w.store.importedKeys().isEmpty)
    }

    @Test("読めないノートは飛ばして続ける")
    func unreadableNoteIsSkipped() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        try w.writeVaultNote("Daily/Voice/Raw/bad.md", Self.note(w, [Self.keyA]))
        try w.writeVaultNote("Daily/Voice/Raw/good.md", Self.note(w, [Self.keyB]))
        let bad = vault.appendingPathComponent("Daily/Voice/Raw/bad.md", isDirectory: false).path(
            percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bad)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bad) }
        #expect(try scanner.scan(vault: vault, config: cfg) == 1)
        #expect(try w.store.importedKeys() == [Self.keyB])
    }

    @Test("UTF-8 でないノートは飛ばす")
    func invalidUTF8IsSkipped() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        let broken = Data(Self.note(w, [Self.keyA]).utf8) + Data([0xFF, 0xFE, 0x80])
        let brokenURL = vault.appendingPathComponent("Daily/Voice/Raw/broken.md", isDirectory: false)
        try FileManager.default.createDirectory(
            at: brokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try broken.write(to: brokenURL)
        try w.writeVaultNote("Daily/Voice/Raw/good.md", Self.note(w, [Self.keyB]))
        #expect(try scanner.scan(vault: vault, config: cfg) == 1)
        #expect(try w.store.importedKeys() == [Self.keyB])
    }

    @Test("frontmatter が壊れていれば飛ばす")
    func brokenFrontmatterIsSkipped() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        try w.writeVaultNote("Daily/Voice/Raw/a.md", "---\n: :\n---\n")
        try w.writeVaultNote("Daily/Voice/Raw/b.md", "no frontmatter\n")
        try w.writeVaultNote(
            "Daily/Voice/Raw/c.md", "---\nvoicedock_recording_keys: \"" + Self.keyA + "\"\n---\n\n# x\n")
        #expect(try scanner.scan(vault: vault, config: cfg) == 0)
        #expect(try w.store.importedKeys().isEmpty)
    }

    @Test("鍵の形が壊れていれば入れない")
    func malformedKeysAreDropped() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        try w.writeVaultNote(
            "Daily/Voice/Raw/a.md",
            Self.note(w, ["", "x", "DJIMIC3/", "/a.wav", "DJI MIC/../a.wav", "DJI:MIC/a.wav", ".x/a.wav"]))
        #expect(try scanner.scan(vault: vault, config: cfg) == 0)
        #expect(try w.store.importedKeys().isEmpty)
    }

    @Test("同じ鍵が 2 つのノートに在れば先（昇順）の方")
    func duplicateKeysAcrossNotesTakeTheFirst() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        try w.writeVaultNote("Daily/Voice/Raw/b.md", Self.note(w, [Self.keyA]))
        try w.writeVaultNote("Daily/Voice/Raw/a.md", Self.note(w, [Self.keyA]))
        #expect(try scanner.scan(vault: vault, config: cfg) == 1)
        #expect(try Self.sourceNote(w, Self.keyA) == "Daily/Voice/Raw/a.md")
    }

    @Test("空の Vault では 0 件（TEST-28）")
    func emptyVaultAddsNothing() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("Daily/Voice/Raw", isDirectory: true), withIntermediateDirectories: true)
        let before = w.sink.lines.count
        #expect(try scanner.scan(vault: vault, config: cfg) == 0)
        #expect(w.sink.lines.count == before)
        #expect(try w.store.importedKeys().isEmpty)
    }

    @Test("Raw フォルダが無くても落ちない")
    func missingRawFolderAddsNothing() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp()
        #expect(
            !FileManager.default.fileExists(
                atPath: vault.appendingPathComponent("Daily/Voice/Raw", isDirectory: true).path(percentEncoded: false)))
        #expect(try scanner.scan(vault: vault, config: cfg) == 0)
        #expect(try w.store.importedKeys().isEmpty)
    }

    @Test("テンプレートが `{` で始まれば Vault 全体")
    func templateWithoutPrefixScansTheWholeVault() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp { $0.obsidian.raw.folderTemplate = "{yyyymmdd}" }
        try w.writeVaultNote("Notes/x.md", Self.note(w, [Self.keyA]))
        #expect(try scanner.scan(vault: vault, config: cfg) == 1)
        #expect(try Self.sourceNote(w, Self.keyA) == "Notes/x.md")
    }

    @Test("CE obsidian.raw.folderTemplate 変えると走る場所が変わる")
    func ceObsidianRawFolderTemplate() async throws {
        let (w, vault, scanner, cfg) = try await Self.setUp { $0.obsidian.raw.folderTemplate = "Voice/Raw/{yyyymmdd}" }
        try w.writeVaultNote("Voice/Raw/n.md", Self.note(w, [Self.keyA]))
        try w.writeVaultNote("Daily/Voice/Raw/n.md", Self.note(w, [Self.keyB]))
        #expect(try scanner.scan(vault: vault, config: cfg) == 1)
        #expect(try w.store.importedKeys() == [Self.keyA])
        #expect(try Self.sourceNote(w, Self.keyA) == "Voice/Raw/n.md")
    }
}
