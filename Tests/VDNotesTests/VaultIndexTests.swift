// Vault 索引（PLAN §8.6 / NOTE-11。T-27 §5.4）。一時ディレクトリの中だけに Vault を作る。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("VaultIndex")
struct VaultIndexTests {
    /// 中間を作って `"# x\n"` を書く
    func note(_ vault: URL, _ rel: String) throws {
        let url = vault.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# x\n".utf8).write(to: url)
    }

    func build(_ vault: URL, exclude: [String] = []) -> VaultIndex {
        VaultIndex.build(vault: vault, excludePrefixes: exclude, builtAt: .zero)
    }

    @Test(".md の basename を集める")
    func collectsMarkdownBasenames() throws {
        let temp = try TempDirectory()
        for rel in ["VoiceDock.md", "Projects/DJI.md", "Projects/Deep/Nested.md", "notes.txt"] {
            try note(temp.url, rel)
        }
        let index = build(temp.url)
        #expect(index.contains("VoiceDock"))
        #expect(index.contains("DJI"))
        #expect(index.contains("Nested"))
        #expect(!index.contains("notes"))
        #expect(index.names == ["voicedock", "dji", "nested"])
    }

    @Test(". で始まるディレクトリは見ない")
    func dotDirectoriesExcluded() throws {
        let temp = try TempDirectory()
        try note(temp.url, ".obsidian/Template.md")
        try note(temp.url, ".trash/Template.md")
        #expect(!build(temp.url).contains("Template"))
    }

    @Test("Raw フォルダを除外する")
    func rawFolderExcluded() throws {
        let temp = try TempDirectory()
        try note(temp.url, "Daily/Voice/Raw/20260912/2026-09-12 raw.md")
        try note(temp.url, "VoiceDock.md")
        let index = build(temp.url, exclude: ["Daily/Voice/Raw"])
        #expect(!index.contains("2026-09-12 raw"))
        #expect(index.contains("VoiceDock"))
    }

    @Test("過去日の Raw も全部除外")
    func everyPastRawExcluded() throws {
        let temp = try TempDirectory()
        for day in ["20260910", "20260911", "20260912"] {
            try note(temp.url, "Daily/Voice/Raw/\(day)/raw \(day).md")
        }
        #expect(build(temp.url, exclude: ["Daily/Voice/Raw"]).names.isEmpty)
    }

    @Test("Wiki フォルダは除外しない")
    func wikiFolderNotExcluded() throws {
        let temp = try TempDirectory()
        try note(temp.url, "Daily/Voice/Wiki/20260911/2026-09-11 Voice.md")
        #expect(build(temp.url, exclude: ["Daily/Voice/Raw"]).contains("2026-09-11 Voice"))
    }

    @Test("除外は接頭辞の境界で")
    func prefixBoundary() throws {
        let temp = try TempDirectory()
        try note(temp.url, "Daily/Voice/RawNotes/x.md")
        try note(temp.url, "Daily/Voice/Raw/y.md")
        let index = build(temp.url, exclude: ["Daily/Voice/Raw"])
        #expect(index.contains("x"))
        #expect(!index.contains("y"))
    }

    @Test("読めないディレクトリは飛ばす", .enabled(if: geteuid() != 0))
    func unreadableSkipped() throws {
        let temp = try TempDirectory()
        try note(temp.url, "locked/Hidden.md")
        try note(temp.url, "open/Visible.md")
        let locked = temp.url.appendingPathComponent("locked").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let index = build(temp.url)
        #expect(!index.contains("Hidden"))
        #expect(index.contains("Visible"))
    }

    @Test("Vault が無ければ空")
    func missingVaultEmpty() throws {
        let temp = try TempDirectory()
        let index = build(temp.url.appendingPathComponent("missing"))
        #expect(index.names.isEmpty)
        #expect(index.scannedDirectories == 0)
    }

    @Test("symlink のディレクトリは辿らない")
    func symlinkedDirectoriesNotFollowed() throws {
        let temp = try TempDirectory()
        try note(temp.url, "outside/Outside.md")
        let vault = temp.url.appendingPathComponent("vault")
        try note(vault, "Inside.md")
        try FileManager.default.createSymbolicLink(
            at: vault.appendingPathComponent("link"), withDestinationURL: temp.url.appendingPathComponent("outside"))
        let index = build(vault)
        #expect(!index.contains("Outside"))
        #expect(index.contains("Inside"))
    }

    @Test("NFC で突き合わせる")
    func matchesNFC() throws {
        let temp = try TempDirectory()
        let nfd = "\u{304B}\u{3099}\u{304D}\u{3099}\u{304F}\u{3099}"
        try note(temp.url, nfd + ".md")
        #expect(build(temp.url).contains("\u{304C}\u{304E}\u{3050}"))
    }

    @Test("大小を区別しない")
    func ignoresCase() throws {
        let temp = try TempDirectory()
        try note(temp.url, "VoiceDock.md")
        let index = build(temp.url)
        #expect(index.contains("voicedock"))
        #expect(index.contains("VOICEDOCK"))
    }

    @Test("完全一致だけ")
    func exactOnly() throws {
        let temp = try TempDirectory()
        try note(temp.url, "VoiceDock の設計.md")
        #expect(!build(temp.url).contains("VoiceDock"))
    }

    @Test("casefold の難しい例")
    func normalizeHardCases() {
        #expect(VaultIndex.normalize("Straße") == "strasse")
        #expect(VaultIndex.normalize("STRASSE") == "strasse")
    }

    @Test("rawFolderPrefix")
    func rawFolderPrefixCases() {
        #expect(VaultIndex.rawFolderPrefix("Daily/Voice/Raw/{yyyymmdd}") == "Daily/Voice/Raw")
        #expect(VaultIndex.rawFolderPrefix("Voice/Raw") == "Voice/Raw")
        #expect(VaultIndex.rawFolderPrefix("/Voice/Raw/") == "Voice/Raw")
        #expect(VaultIndex.rawFolderPrefix("{yyyymmdd}/x") == "")
        #expect(VaultIndex.rawFolderPrefix("") == "")
    }

    @Test("TTL の境界は古い側")
    func staleAtBoundary() {
        let index = VaultIndex(names: [], builtAt: .seconds(0))
        #expect(!index.isStale(ttlSeconds: 300, now: .seconds(299)))
        #expect(index.isStale(ttlSeconds: 300, now: .seconds(300)))
    }

    @Test("builtAt は渡した値")
    func builtAtIsGiven() throws {
        let temp = try TempDirectory()
        #expect(VaultIndex.build(vault: temp.url, excludePrefixes: [], builtAt: .seconds(42)).builtAt == .seconds(42))
    }

    @Test("入れ子まで降りる")
    func walksNested() throws {
        let temp = try TempDirectory()
        try note(temp.url, "a/b/c/Deep.md")
        let index = build(temp.url)
        #expect(index.contains("Deep"))
        #expect(index.scannedDirectories >= 4)
    }

    @Test("空の Vault は空の索引")
    func emptyVault() throws {
        let temp = try TempDirectory()
        let index = build(temp.url)
        #expect(index.names.isEmpty)
        #expect(index.scannedDirectories == 1)
    }
}
