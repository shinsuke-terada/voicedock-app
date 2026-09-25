// Vault の確認（PLAN §8.7 手順 0 / DEL-06。T-28 §5.1）。一時ディレクトリの中だけに Vault を作る。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDNotes

@Suite("VaultCheck")
struct VaultCheckTests {
    static let marker = ".obsidian"

    func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ url: URL) -> String {
        url.path(percentEncoded: false)
    }

    /// root で走っていると chmod 000 でも読めてしまう
    static var isRoot: Bool { geteuid() == 0 }

    @Test("目印のある Vault は使える")
    func vaultWithMarkerAvailable() throws {
        let temp = try TempDirectory()
        let v = temp.url.appendingPathComponent("v", isDirectory: true)
        try mkdir(v.appendingPathComponent(".obsidian", isDirectory: true))
        #expect(VaultCheck.evaluate(path: path(v), marker: Self.marker) == .available)
        #expect(VaultCheck.evaluate(path: path(v), marker: Self.marker).isAvailable)
    }

    @Test("空のディレクトリは Vault でない（DEL-06）")
    func emptyDirectoryIsNotVault() throws {
        let temp = try TempDirectory()
        let v = temp.url.appendingPathComponent("v", isDirectory: true)
        try mkdir(v)
        #expect(VaultCheck.evaluate(path: path(v), marker: Self.marker) == .missingMarker)
        #expect(!VaultCheck.evaluate(path: path(v), marker: Self.marker).isAvailable)
    }

    @Test("ルートが無い")
    func missingRoot() throws {
        let temp = try TempDirectory()
        let v = temp.url.appendingPathComponent("nowhere", isDirectory: true)
        #expect(VaultCheck.evaluate(path: path(v), marker: Self.marker) == .missingRoot)
    }

    @Test("ルートがファイル")
    func rootIsFile() throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("v")
        try Data("x".utf8).write(to: file)
        #expect(VaultCheck.evaluate(path: path(file), marker: Self.marker) == .missingRoot)
    }

    @Test("目印がファイルでは足りない")
    func markerFileNotEnough() throws {
        let temp = try TempDirectory()
        let v = temp.url.appendingPathComponent("v", isDirectory: true)
        try mkdir(v)
        try Data("x".utf8).write(to: v.appendingPathComponent(".obsidian"))
        #expect(VaultCheck.evaluate(path: path(v), marker: Self.marker) == .missingMarker)
    }

    @Test("CE vault.marker 目印の名前を変えられる")
    func customMarker() throws {
        #expect(AppConfig.defaults(timeZone: "Asia/Tokyo").vault.marker == ".obsidian")
        let temp = try TempDirectory()
        let custom = temp.url.appendingPathComponent("custom", isDirectory: true)
        try mkdir(custom.appendingPathComponent(".vault", isDirectory: true))
        #expect(VaultCheck.evaluate(path: path(custom), marker: ".vault") == .available)
        let plain = temp.url.appendingPathComponent("plain", isDirectory: true)
        try mkdir(plain.appendingPathComponent(".obsidian", isDirectory: true))
        #expect(VaultCheck.evaluate(path: path(plain), marker: ".vault") == .missingMarker)
    }

    @Test("CE vault.path が指す場所を見る")
    func ceVaultPath() throws {
        let temp = try TempDirectory()
        let v1 = temp.url.appendingPathComponent("v1", isDirectory: true)
        let v2 = temp.url.appendingPathComponent("v2", isDirectory: true)
        try mkdir(v1.appendingPathComponent(".obsidian", isDirectory: true))
        try mkdir(v2)
        #expect(VaultCheck.evaluate(path: path(v1), marker: Self.marker) == .available)
        #expect(VaultCheck.evaluate(path: path(v2), marker: Self.marker) == .missingMarker)
        for vault in [v1, v2] {
            let result = OutputPathResolver.resolve(
                folder: vault, baseName: "2026-08-29 raw", existing: nil, sessionKey: NotesFixtures.sessionKey,
                ownedPartkeys: [NotesFixtures.keyA], kind: .raw)
            let url = try result.get()
            #expect(url.path(percentEncoded: false) == path(vault) + "2026-08-29 raw.md")
        }
    }

    @Test("空の目印では通さない（X-18）", arguments: ["", "  ", "a/b", ".", ".."])
    func emptyMarkerFailsClosed(_ marker: String) throws {
        let temp = try TempDirectory()
        let v = temp.url.appendingPathComponent("v", isDirectory: true)
        try mkdir(v.appendingPathComponent("a/b", isDirectory: true))
        try mkdir(v.appendingPathComponent(".obsidian", isDirectory: true))
        #expect(VaultCheck.evaluate(path: path(v), marker: marker) == .missingMarker)
    }

    @Test("未設定")
    func notConfigured() {
        #expect(VaultCheck.evaluate(path: nil, marker: Self.marker) == .notConfigured)
    }

    @Test("列挙できないルートは notReadable", .enabled(if: !VaultCheckTests.isRoot))
    func unreadableRoot() throws {
        let temp = try TempDirectory()
        let v = temp.url.appendingPathComponent("v", isDirectory: true)
        try mkdir(v.appendingPathComponent(".obsidian", isDirectory: true))
        #expect(chmod(path(v), 0o000) == 0)
        defer { _ = chmod(path(v), 0o755) }
        #expect(VaultCheck.evaluate(path: path(v), marker: Self.marker) == .notReadable(errno: EACCES))
    }

    @Test("親が辿れないルートは notReadable", .enabled(if: !VaultCheckTests.isRoot))
    func unreachableRoot() throws {
        let temp = try TempDirectory()
        let p = temp.url.appendingPathComponent("p", isDirectory: true)
        let v = p.appendingPathComponent("v", isDirectory: true)
        try mkdir(v.appendingPathComponent(".obsidian", isDirectory: true))
        #expect(chmod(path(p), 0o000) == 0)
        defer { _ = chmod(path(p), 0o755) }
        #expect(VaultCheck.evaluate(path: path(v), marker: Self.marker) == .notReadable(errno: EACCES))
    }

    @Test("symlink の Vault と目印を辿る")
    func followsSymlinks() throws {
        let temp = try TempDirectory()
        let v = temp.url.appendingPathComponent("v", isDirectory: true)
        let real = temp.url.appendingPathComponent("real", isDirectory: true)
        try mkdir(v)
        try mkdir(real)
        try FileManager.default.createSymbolicLink(
            at: v.appendingPathComponent(".obsidian"), withDestinationURL: real)
        let link = temp.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: v)
        #expect(VaultCheck.evaluate(path: path(link), marker: Self.marker) == .available)
    }

    @Test("文言は逐語")
    func messagesAreVerbatim() {
        let p = "/tmp/v"
        let m = ".obsidian"
        #expect(VaultStatus.notConfigured.message(path: p, marker: m) == "Vault が選ばれていません")
        #expect(VaultStatus.missingRoot.message(path: p, marker: m) == "/tmp/v がありません")
        #expect(VaultStatus.notReadable(errno: 13).message(path: p, marker: m) == "/tmp/v を読めません（errno 13）")
        #expect(
            VaultStatus.missingMarker.message(path: p, marker: m)
                == "/tmp/v に .obsidian/ がありません（Vault が未マウントか、別の場所を指しています）")
        #expect(VaultStatus.available.message(path: p, marker: m) == "")
    }

    @Test("何も作らない（NOTE-16）")
    func createsNothing() throws {
        let temp = try TempDirectory()
        let v = temp.url.appendingPathComponent("v", isDirectory: true)
        try mkdir(v)
        _ = VaultCheck.evaluate(path: path(v), marker: Self.marker)
        #expect(try FileManager.default.contentsOfDirectory(atPath: path(v)).isEmpty)
        let missing = temp.url.appendingPathComponent("missing", isDirectory: true)
        _ = VaultCheck.evaluate(path: path(missing), marker: Self.marker)
        #expect(!FileManager.default.fileExists(atPath: path(missing)))
    }
}
