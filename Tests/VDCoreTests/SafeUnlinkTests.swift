// SafeUnlink の検査（PLAN §9.2・CR-10）。一時ディレクトリの中だけで行う。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("SafeUnlink")
struct SafeUnlinkTests {
    let home: TempDirectory
    let layout: HomeLayout

    init() throws {
        home = try TempDirectory()
        layout = HomeLayout(root: home.url)
        try layout.createDirectories()
    }

    func makeFile(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    @Test("ルート配下の通常ファイルを消す")
    func removesFileUnderRoot() throws {
        let file = try makeFile(layout.normalizedAudio(slug: "slug"))
        #expect(file.path(percentEncoded: false).hasSuffix("staging/slug/audio16k.wav"))
        try SafeUnlink.remove(file, under: .staging, layout: layout)
        #expect(!exists(file))
        #expect(exists(layout.stagingDirectory(slug: "slug")))
    }

    @Test("無いファイルは既定では何もしない")
    func missingIsOKByDefault() throws {
        let missing = layout.staging.appendingPathComponent("nothing.wav")
        try SafeUnlink.remove(missing, under: .staging, layout: layout)
        let missingParent = layout.staging.appendingPathComponent("no-dir").appendingPathComponent("nothing.wav")
        try SafeUnlink.remove(missingParent, under: .staging, layout: layout)
        #expect(throws: SafeUnlinkError.notFound) {
            try SafeUnlink.remove(missing, under: .staging, layout: layout, missingOK: false)
        }
        #expect(throws: SafeUnlinkError.notFound) {
            try SafeUnlink.remove(missingParent, under: .staging, layout: layout, missingOK: false)
        }
    }

    @Test("相対パスは拒否")
    func refusesRelative() throws {
        let relative = try #require(URL(string: "staging/x.wav"))
        #expect(throws: SafeUnlinkError.notAbsolute) {
            try SafeUnlink.remove(relative, under: .staging, layout: layout)
        }
        let empty = try #require(URL(string: "x"))
        #expect(throws: SafeUnlinkError.notAbsolute) {
            try SafeUnlink.removeEmptyDirectory(empty, under: .staging, layout: layout)
        }
    }

    @Test(".. を含むパスは拒否")
    func refusesDotDot() throws {
        let inboxFile = try makeFile(layout.inbox.appendingPathComponent("x"))
        let target = URL(fileURLWithPath: layout.staging.path(percentEncoded: false) + "../inbox/x")
        #expect(throws: SafeUnlinkError.containsDotDot) {
            try SafeUnlink.remove(target, under: .staging, layout: layout)
        }
        #expect(exists(inboxFile))
    }

    @Test("ルートの外は拒否")
    func refusesOutsideRoot() throws {
        let inboxFile = try makeFile(layout.inbox.appendingPathComponent("x.wav"))
        #expect(throws: SafeUnlinkError.outsideRoot) {
            try SafeUnlink.remove(inboxFile, under: .staging, layout: layout)
        }
        #expect(exists(inboxFile))
    }

    @Test("接頭辞だけ一致する兄弟は配下ではない")
    func refusesPrefixSibling() throws {
        let sibling = try makeFile(home.url.appendingPathComponent("staging-old").appendingPathComponent("x"))
        #expect(throws: SafeUnlinkError.outsideRoot) {
            try SafeUnlink.remove(sibling, under: .staging, layout: layout)
        }
        #expect(exists(sibling))
    }

    @Test("ルートそのものは消させない")
    func refusesRootItself() throws {
        #expect(throws: SafeUnlinkError.outsideRoot) {
            try SafeUnlink.removeEmptyDirectory(layout.staging, under: .staging, layout: layout)
        }
        #expect(exists(layout.staging))
    }

    @Test("symlink はリンクも消さない")
    func refusesSymlinkTarget() throws {
        let target = try makeFile(layout.staging.appendingPathComponent("real.wav"))
        let link = layout.staging.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: SafeUnlinkError.isSymlink) {
            try SafeUnlink.remove(link, under: .staging, layout: layout)
        }
        #expect(exists(link))
        #expect(exists(target))
    }

    @Test("親の symlink でルートの外へ出られない")
    func refusesSymlinkedParentEscape() throws {
        let outside = try TempDirectory()
        let victim = try makeFile(outside.url.appendingPathComponent("victim.wav"))
        let evil = layout.staging.appendingPathComponent("evil")
        try FileManager.default.createSymbolicLink(at: evil, withDestinationURL: outside.url)
        #expect(throws: SafeUnlinkError.outsideRoot) {
            try SafeUnlink.remove(evil.appendingPathComponent("victim.wav"), under: .staging, layout: layout)
        }
        #expect(exists(victim))
    }

    @Test("ディレクトリは remove で消さない")
    func refusesDirectory() throws {
        let directory = layout.stagingDirectory(slug: "slug")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(throws: SafeUnlinkError.notRegularFile) {
            try SafeUnlink.remove(directory, under: .staging, layout: layout)
        }
        #expect(exists(directory))
    }

    @Test("queue は直下の .json だけ")
    func queueOnlyDirectJSON() throws {
        let json = try makeFile(layout.queueDelete.appendingPathComponent("x.json"))
        try SafeUnlink.remove(json, under: .queueDelete, layout: layout)
        #expect(!exists(json))
        let text = try makeFile(layout.queueDelete.appendingPathComponent("x.txt"))
        #expect(throws: SafeUnlinkError.nameNotAllowed) {
            try SafeUnlink.remove(text, under: .queueDelete, layout: layout)
        }
        let nested = try makeFile(layout.queueDelete.appendingPathComponent("sub").appendingPathComponent("x.json"))
        #expect(throws: SafeUnlinkError.nameNotAllowed) {
            try SafeUnlink.remove(nested, under: .queueDelete, layout: layout)
        }
        let result = try makeFile(layout.queueResult.appendingPathComponent("y.json"))
        try SafeUnlink.remove(result, under: .queueResult, layout: layout)
        #expect(!exists(result))
        #expect(exists(text))
        #expect(exists(nested))
    }

    @Test("Vault は .<name>.tmp だけ")
    func vaultTmpOnlyDotTmp() throws {
        let vaultHome = try TempDirectory()
        let vault = vaultHome.url.appendingPathComponent("Vault", isDirectory: true)
        let tmp = try makeFile(vault.appendingPathComponent(".2026-08-29 raw.md.tmp"))
        try SafeUnlink.remove(tmp, under: .vaultTmp(vault: vault), layout: layout)
        #expect(!exists(tmp))
        for name in ["2026-08-29 raw.md", ".tmp", ".x.tm"] {
            let file = try makeFile(vault.appendingPathComponent(name))
            #expect(throws: SafeUnlinkError.nameNotAllowed) {
                try SafeUnlink.remove(file, under: .vaultTmp(vault: vault), layout: layout)
            }
            #expect(exists(file))
        }
    }

    @Test("Vault 内の symlink のディレクトリ経由は許す（voicedock どおり）")
    func vaultSymlinkedDirectoryAllowed() throws {
        let vaultHome = try TempDirectory()
        let vault = vaultHome.url.appendingPathComponent("Vault", isDirectory: true)
        let real = vault.appendingPathComponent("real", isDirectory: true)
        let tmp = try makeFile(real.appendingPathComponent(".a.md.tmp"))
        let daily = vault.appendingPathComponent("Daily")
        try FileManager.default.createSymbolicLink(at: daily, withDestinationURL: real)
        try SafeUnlink.remove(daily.appendingPathComponent(".a.md.tmp"), under: .vaultTmp(vault: vault), layout: layout)
        #expect(!exists(tmp))
        #expect(exists(daily))
    }

    @Test("中身のあるディレクトリは消さない")
    func removeEmptyDirectoryKeepsNonEmpty() throws {
        let full = layout.stagingDirectory(slug: "full")
        _ = try makeFile(full.appendingPathComponent("audio16k.wav"))
        try SafeUnlink.removeEmptyDirectory(full, under: .staging, layout: layout)
        #expect(exists(full))
        let empty = layout.stagingDirectory(slug: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try SafeUnlink.removeEmptyDirectory(empty, under: .staging, layout: layout)
        #expect(!exists(empty))
        try SafeUnlink.removeEmptyDirectory(empty, under: .staging, layout: layout)
        let file = try makeFile(layout.staging.appendingPathComponent("file"))
        #expect(throws: SafeUnlinkError.notDirectory) {
            try SafeUnlink.removeEmptyDirectory(file, under: .staging, layout: layout)
        }
    }

    @Test("database は <HOME> 直下の DB の 3 つのファイルだけを消す（F-95）")
    func databaseRootAllowsOnlyTheThreeFiles() throws {
        for name in ["voicedock.sqlite", "voicedock.sqlite-wal", "voicedock.sqlite-shm"] {
            let file = try makeFile(layout.url(relative: name))
            try SafeUnlink.remove(file, under: .database, layout: layout)
            #expect(!exists(file))
        }
        // 設定・ui-state・似た名前は拒む
        for name in ["config.json", "ui-state.json", "voicedock.sqlite.bak"] {
            let file = try makeFile(layout.url(relative: name))
            #expect(throws: SafeUnlinkError.nameNotAllowed) {
                try SafeUnlink.remove(file, under: .database, layout: layout)
            }
            #expect(exists(file))
        }
        // 下位のディレクトリの同じ名前も拒む（直下だけ）
        let nested = try makeFile(layout.inbox.appendingPathComponent("voicedock.sqlite"))
        #expect(throws: SafeUnlinkError.nameNotAllowed) {
            try SafeUnlink.remove(nested, under: .database, layout: layout)
        }
        #expect(exists(nested))
    }
}
