// DeletionScene（削除の評価の舞台）そのもののテスト（TEST-05。T-36 §6.3）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDNotes
import VDStore

@testable import VDPipeline

@Suite("DeletionScene")
struct DeletionSceneTests {
    @Test("舞台の DB の値はデバイス上の原本と一致する")
    func sceneMatchesTheDevice() throws {
        let scene = try DeletionScene()
        let row = try #require(try scene.store.recording(DeletionScene.partkey))
        var st = stat()
        let path = scene.deviceRoot.appendingPathComponent(DeletionScene.relpath, isDirectory: false)
            .path(percentEncoded: false)
        #expect(lstat(path, &st) == 0)
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        #expect(row.sourceSize == 4096)
        #expect(row.sourceMtime == mtime)
        #expect(row.sourceMtime == 1_789_171_260)
        #expect(row.sourcePath == DeletionScene.relpath)
        #expect(row.partkey == DeletionScene.partkey)
    }

    @Test("Raw ノートに既定の Part の鍵が載り、SHA が DB と一致する")
    func sceneRawNoteCarriesTheKey() throws {
        let scene = try DeletionScene()
        let session = try #require(try scene.store.session(DeletionScene.sessionKey))
        let url = try scene.rawNoteURL()
        #expect(Frontmatter.recordingKeys(ofFile: url).contains(DeletionScene.partkey))
        #expect(try FileHasher.sha256(of: url, chunkBytes: 1_048_576) == session.rawOutputSHA256)
        #expect(session.rawOutputPath == "Daily/Voice/Raw/20260912/2026-09-12 raw.md")
    }

    @Test("transcript が §8.4 の合格条件を満たす")
    func sceneTranscriptDecodes() throws {
        let scene = try DeletionScene()
        let data = try Data(contentsOf: scene.transcriptURL(DeletionScene.partkey))
        #expect(PartTranscriptCodec.decode(data) != nil)
    }

    @Test("三重ロックが全部外れている")
    func sceneLocksAreReleased() async throws {
        let scene = try DeletionScene()
        #expect(await scene.locks.readiness(config: scene.config) == .configured)
        let observed = await scene.locks.observe(config: scene.config, snapshot: scene.snapshot())
        #expect(observed.allReleased(for: "DJIMIC3"))
        #expect(observed.volumesRoot == scene.volumesRoot.path(percentEncoded: false))
    }

    @Test("始めは要求も結果も無い")
    func sceneHasNoRequests() throws {
        let scene = try DeletionScene()
        #expect(scene.requests() == [])
        #expect(scene.results() == [])
    }

    @Test("StorePaths は全状態へ辺だけで進める（パラメータ化: PartStatus.allCases）", arguments: PartStatus.allCases)
    func storePathsReachEveryStatus(_ status: PartStatus) throws {
        let scene = try DeletionScene()
        let pk = try scene.addPart(
            fileName: "TX00_MIC003_20260912_110000_orig.wav", folder: "TX_MIC001_20260912_110000",
            startedAt: "2026-09-12T11:00:00+09:00", status: .discovered, inRawNote: false)
        try StorePaths.advancePart(scene.store, partkey: pk, to: status)
        #expect(try scene.store.recording(pk)?.status == status)
    }

    @Test("同じく Session（SessionStatus.allCases）", arguments: SessionStatus.allCases)
    func sessionPathsReachEveryStatus(_ status: SessionStatus) throws {
        let scene = try DeletionScene()
        let key = "DJIMIC3:20260913"
        try scene.addSession(key: key, dayDate: "2026-09-13")
        try StorePaths.advanceSession(scene.store, sessionKey: key, to: status)
        #expect(try scene.store.session(key)?.status == status)
    }
}
