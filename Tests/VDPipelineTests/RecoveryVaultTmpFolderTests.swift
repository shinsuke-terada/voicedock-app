// 復旧で、DB のパスの tmp に加えて今の設定のフォルダの候補名の tmp も消すことのテスト（F-83。PLAN §5.3。issue #119 の F-75 の残り）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("RecoveryVaultTmp（F-83）", .serialized, .timeLimit(.minutes(1)))
struct RecoveryVaultTmpFolderTests {
    typealias Base = RecoveryVaultTmpTests
    static let key = PipelineFixtures.vaultSessionKey

    @Test("F-83 DB のパスの親フォルダが無い（F-75 で今のフォルダへ書いた）Raw は、今のフォルダの候補名の tmp を消す")
    func rawTmpInTheCurrentFolder() async throws {
        let w = try await Base.world()
        let pk = try w.addPart(PipelineFixtures.partA, status: .rawWriting)
        try w.store.updateSession(Self.key, [.rawOutputPath("Old/Raw/20260829/2026-08-29 raw.md")])
        let base = try Base.place(w, Base.rawFolder + "/.2026-08-29 raw.md.tmp")
        let second = try Base.place(w, Base.rawFolder + "/.2026-08-29 raw (2).md.tmp")
        let note = try Base.place(w, Base.rawFolder + "/2026-08-29 raw.md")
        let bak = try Base.place(w, Base.rawFolder + "/.2026-08-29 raw.md.tmp.bak")
        let other = try Base.place(w, Base.rawFolder + "/.other.md.tmp")
        try await Base.recover(w)
        #expect(!Base.present(base))
        #expect(!Base.present(second))
        #expect(Base.present(note))
        #expect(Base.present(bak))
        #expect(Base.present(other))
        #expect(try w.part(pk).status == .transcribed)
    }

    @Test("F-83 Daily も DB のパスに加えて今のフォルダの候補名の tmp を消す")
    func dailyTmpInTheCurrentFolder() async throws {
        let w = try await Base.world(session: .writing)
        try w.store.updateSession(Self.key, [.outputPath("Old/Wiki/20260829/2026-08-29 Voice.md")])
        let own = try Base.place(w, "Old/Wiki/20260829/.2026-08-29 Voice.md.tmp")
        let second = try Base.place(w, Base.dailyFolder + "/.2026-08-29 Voice (2).md.tmp")
        try await Base.recover(w)
        #expect(!Base.present(own))
        #expect(!Base.present(second))
        #expect(try w.session(Self.key).status == .analyzed)
    }

    @Test("F-83 消す対象は DB のパスの tmp と候補名 99 個（DB のパスが候補名と同じなら 1 回だけ）")
    func targetsAreDeduplicated() {
        let vault = URL(fileURLWithPath: "/private/tmp/vault", isDirectory: true)
        let folder = "Daily/Voice/Raw/20260829"
        let inFolder = Recovery.tmpTargets(
            vault: vault, existing: folder + "/2026-08-29 raw (3).md", folder: folder, baseName: "2026-08-29 raw")
        #expect(inFolder.count == 99)
        #expect(
            inFolder.first?.path(percentEncoded: false)
                == "/private/tmp/vault/Daily/Voice/Raw/20260829/.2026-08-29 raw (3).md.tmp")
        #expect(
            inFolder.dropFirst().first?.path(percentEncoded: false)
                == "/private/tmp/vault/Daily/Voice/Raw/20260829/.2026-08-29 raw.md.tmp")
        let elsewhere = Recovery.tmpTargets(
            vault: vault, existing: "Old/2026-08-29 raw.md", folder: folder, baseName: "2026-08-29 raw")
        #expect(elsewhere.count == 100)
        #expect(elsewhere.first?.path(percentEncoded: false) == "/private/tmp/vault/Old/.2026-08-29 raw.md.tmp")
        #expect(
            elsewhere.last?.path(percentEncoded: false)
                == "/private/tmp/vault/Daily/Voice/Raw/20260829/.2026-08-29 raw (99).md.tmp")
    }

    static func recoveryWarnings(_ w: PipelineWorld) -> [String] {
        w.lines("config_warning").filter { $0.contains("rule=recovery") }
    }

    @Test("F-83 今のフォルダの途中の要素がファイルなら、警告を 1 件だけ出して候補名を見ない")
    func intermediateFileWarnsOnce() async throws {
        let w = try await Base.world()
        try w.addPart(PipelineFixtures.partA, status: .rawWriting)
        _ = try Base.place(w, "Daily/Voice/Raw")
        try await Base.recover(w)
        let warnings = Self.recoveryWarnings(w)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("Daily/Voice/Raw/20260829 の一時ファイルを確かめられません（errno 20）") == true)
    }

    @Test("F-83 今のフォルダが Vault の外に解決されるなら、警告を 1 件だけ出して外のファイルに触れない")
    func folderOutsideTheVaultWarnsOnce() async throws {
        let w = try await Base.world()
        try w.addPart(PipelineFixtures.partA, status: .rawWriting)
        let outside = w.tmp.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent(".2026-08-29 raw.md.tmp")
        try AtomicFile.write(Data("keep".utf8), to: victim)
        let link = w.vaultURL.appendingPathComponent(Base.rawFolder, isDirectory: true)
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try await Base.recover(w)
        let warnings = Self.recoveryWarnings(w)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("（Vault の外に解決されます）") == true)
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
    }

    @Test("F-83 今のフォルダが無ければ警告を出さない")
    func absentFolderIsSilent() async throws {
        let w = try await Base.world()
        try w.addPart(PipelineFixtures.partA, status: .rawWriting)
        try await Base.recover(w)
        #expect(Self.recoveryWarnings(w).isEmpty)
    }

    @Test("F-83 DB のパスが無く、フォルダのテンプレートが空なら Vault の直下の候補名だけ（TEST-28）")
    func emptyFolderTemplate() {
        let vault = URL(fileURLWithPath: "/private/tmp/vault", isDirectory: true)
        let targets = Recovery.tmpTargets(vault: vault, existing: nil, folder: "", baseName: "2026-08-29 raw")
        #expect(targets.count == 99)
        #expect(targets.first?.path(percentEncoded: false) == "/private/tmp/vault/.2026-08-29 raw.md.tmp")
    }
}
