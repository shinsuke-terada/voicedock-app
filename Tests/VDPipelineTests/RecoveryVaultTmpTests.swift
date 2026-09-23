// 復旧時の Vault の一時ファイルの削除のテスト（T-29 §6.5。PLAN §5.3 の本計画の差分）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("RecoveryVaultTmp", .serialized, .timeLimit(.minutes(1)))
struct RecoveryVaultTmpTests {
    static let key = PipelineFixtures.vaultSessionKey
    static let rawFolder = "Daily/Voice/Raw/20260829"
    static let dailyFolder = "Daily/Voice/Wiki/20260829"

    /// Vault（marker で目印）と、day 2026-08-29 の Session（status）。
    static func world(marker: Bool = true, session: SessionStatus = .ready) async throws -> PipelineWorld {
        let w = try await PipelineWorld.make()
        try await w.installVault(marker: marker)
        try w.addSession(key: key, day: "2026-08-29", status: session)
        return w
    }

    static func recover(_ w: PipelineWorld) async throws {
        let config = try #require(await w.configStore.current())
        _ = try Recovery(store: w.store, layout: w.layout, log: w.log, config: config, zone: PipelineFixtures.zone)
            .run()
    }

    /// Vault の中に空のファイルを置く。
    static func place(_ w: PipelineWorld, _ rel: String) throws -> URL {
        let url = w.vaultURL.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(Data("tmp".utf8), to: url)
        return url
    }

    /// symlink も「在る」と数える（lstat）。
    static func present(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
    }

    // F-83: raw_output_path があっても、今のフォルダの候補名の tmp も消す（書き手は DB のパスを使えなければ候補名へ書く）。
    // 以前は「その tmp だけ消す」で、base を残すことを確かめていた
    @Test("raw_output_path があればその tmp と、今のフォルダの候補名の tmp を消す（F-83）")
    func rawTmpByOutputPath() async throws {
        let w = try await Self.world()
        let pk = try w.addPart(PipelineFixtures.partA, status: .rawWriting)
        try w.store.updateSession(Self.key, [.rawOutputPath(Self.rawFolder + "/2026-08-29 raw (2).md")])
        let own = try Self.place(w, Self.rawFolder + "/.2026-08-29 raw (2).md.tmp")
        let base = try Self.place(w, Self.rawFolder + "/.2026-08-29 raw.md.tmp")
        try await Self.recover(w)
        #expect(!Self.present(own))
        #expect(!Self.present(base))
        #expect(try w.part(pk).status == .transcribed)
    }

    @Test("出力パスが無ければ候補名の tmp（完全一致だけ）を消す")
    func rawTmpCandidates() async throws {
        let w = try await Self.world()
        try w.addPart(PipelineFixtures.partA, status: .rawWriting)
        let base = try Self.place(w, Self.rawFolder + "/.2026-08-29 raw.md.tmp")
        let third = try Self.place(w, Self.rawFolder + "/.2026-08-29 raw (3).md.tmp")
        let bak = try Self.place(w, Self.rawFolder + "/.2026-08-29 raw.md.tmp.bak")
        let other = try Self.place(w, Self.rawFolder + "/.other.md.tmp")
        try await Self.recover(w)
        #expect(!Self.present(base))
        #expect(!Self.present(third))
        #expect(Self.present(bak))
        #expect(Self.present(other))
    }

    @Test("WRITING の Session は Daily の tmp")
    func dailyTmpForWritingSession() async throws {
        let w = try await Self.world(session: .writing)
        let tmp = try Self.place(w, Self.dailyFolder + "/.2026-08-29 Voice.md.tmp")
        try await Self.recover(w)
        #expect(!Self.present(tmp))
        #expect(try w.session(Self.key).status == .analyzed)
    }

    @Test("Vault の確認が通らなければ消さない")
    func unavailableVaultIsNotTouched() async throws {
        let w = try await Self.world(marker: false)
        let pk = try w.addPart(PipelineFixtures.partA, status: .rawWriting)
        let tmp = try Self.place(w, Self.rawFolder + "/.2026-08-29 raw.md.tmp")
        try await Self.recover(w)
        #expect(Self.present(tmp))
        #expect(try w.part(pk).status == .transcribed)
    }

    @Test("tmp が symlink なら消さない")
    func symlinkTmpIsNotFollowed() async throws {
        let w = try await Self.world()
        try w.addPart(PipelineFixtures.partA, status: .rawWriting)
        let outside = w.tmp.url.appendingPathComponent("outside.txt")
        try AtomicFile.write(Data("outside".utf8), to: outside)
        let link = w.vaultURL.appendingPathComponent(Self.rawFolder + "/.2026-08-29 raw.md.tmp")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try await Self.recover(w)
        #expect(Self.present(link))
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect(
            w.lines("config_warning").contains {
                $0.contains(
                    "config_warning rule=recovery message=\"Daily/Voice/Raw/20260829/.2026-08-29 raw.md.tmp を消せません: ")
            })
    }
}
