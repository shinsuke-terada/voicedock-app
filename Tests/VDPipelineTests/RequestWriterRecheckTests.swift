// 要求ファイルを書く直前に reaper.conf を読み直す（PLAN §8.9.5。F-72・issue #112 の B6）。舞台は DeletionScene（/Volumes には触れない）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

/// 開くたびに reaper.conf を無効側へ書き換えてから、舞台の opener に任せる
/// （削除段が readiness を評価した後・要求を書く前に、無効化の段 1 が走った状況を作る）
struct DisablingVolumeOpener: VolumeOpener {
    let scene: DeletionScene

    func open(volumesRoot: String, deviceID: String) -> VolumeOpenResult {
        try? scene.writeReaperConf(deleteSourceAudio: false)
        return scene.opener.open(volumesRoot: volumesRoot, deviceID: deviceID)
    }
}

@Suite("RequestWriter（F-72 ロック 1 の読み直し）")
struct RequestWriterRecheckTests {
    static let pk = DeletionScene.partkey
    static let skippedLine = "source_delete_skipped recording_key=" + DeletionScene.partkey + " reason=lock_mismatch"

    static func write(_ scene: DeletionScene) async throws -> String? {
        let deps = scene.deletionDependencies(ingest: ScriptedIngest(snapshot: scene.snapshot()))
        let part = try #require(try scene.store.recording(Self.pk))
        return try await RequestWriter(deps: deps).write(part: part, sessionKey: DeletionScene.sessionKey)
    }

    static func expectNothingWritten(_ scene: DeletionScene) throws {
        #expect(scene.requests() == [])
        let part = try #require(try scene.store.recording(Self.pk))
        #expect(part.deleteRequestID == nil)
        #expect(part.status == .rawSaved)
        #expect(scene.logLines.contains { $0.contains(" INFO ") && $0.hasSuffix(" " + Self.skippedLine) })
    }

    @Test(
        "F-72 reaper.conf が有効でなければ要求を書かず ID を外す（パラメータ化: false・無い・不正な値）",
        arguments: ["false", "missing", "invalid"])
    func writerRefusesWhenLock1IsNotReleased(_ conf: String) async throws {
        let scene = try DeletionScene()
        switch conf {
        case "false": try scene.writeReaperConf(deleteSourceAudio: false)
        case "missing": try scene.removeReaperConf()
        default: try scene.writeReaperConfRaw(Data("SCHEMA=1\nDELETE_SOURCE_AUDIO=yes\n".utf8))
        }
        #expect(try await Self.write(scene) == nil)
        try Self.expectNothingWritten(scene)
    }

    @Test("F-72 空の reaper.conf（0 バイト）でも書かない（TEST-28）")
    func writerRefusesAnEmptyConf() async throws {
        let scene = try DeletionScene()
        try scene.writeReaperConfRaw(Data())
        #expect(try await Self.write(scene) == nil)
        try Self.expectNothingWritten(scene)
    }

    @Test("F-72 有効な reaper.conf なら従来どおり書く")
    func writerWritesWhenLock1IsReleased() async throws {
        let scene = try DeletionScene()
        let id = try #require(try await Self.write(scene))
        #expect(scene.requests().map(\.lastPathComponent) == [id + ".json"])
        #expect(try #require(try scene.store.recording(Self.pk)).deleteRequestID == id)
    }

    @Test("F-72 削除段が readiness を評価した後に無効化されたら、その後の要求は書かない（遷移もしない）")
    func requesterStopsWhenDisabledAfterReadiness() async throws {
        let scene = try DeletionScene()
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        let deps = scene.deletionDependencies(ingest: ingest, opener: DisablingVolumeOpener(scene: scene))
        let requested = await DeletionRequester(deps: deps).requestDeletions(sessionKey: DeletionScene.sessionKey)
        #expect(requested == 0)
        try Self.expectNothingWritten(scene)
    }
}
