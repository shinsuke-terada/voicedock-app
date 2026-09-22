// 削除の往復: 要求 → 本物の reaper → 走査 → 回収（PLAN §8.9.5〜§8.9.7・§10.5。T-38 §6.10）。FAT32 のディスクイメージ。
// イメージは <tmp>/Volumes/VDT… に attach する（/Volumes の下には決して attach しない。ボリューム名に DJIMIC3 を使わない。PLAN §10.2）。
// Part と Session はインスタンスの値（scene.partkey・scene.sessionKey・scene.deviceID。T-36 §4.10）で指す。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDProcess
import VDStore

@testable import VDPipeline

@Suite("削除の往復", .serialized, .enabled(if: TestEnvironment.diskTests))
struct DeletionRoundTripTests {
    struct Stage {
        let tmp: TempDirectory
        let image: DiskImageVolume
        let scene: DeletionScene
        let ingest: ScriptedIngest
        let deps: DeletionDependencies
    }

    static func stage() async throws -> Stage {
        let tmp = try TempDirectory()
        let image = try DiskImageVolume(in: tmp, deviceID: DiskImageVolume.uniqueName(), filesystem: .fat32)
        let scene = try DeletionScene(in: tmp, diskImage: image)
        try scene.installRealReaper()
        let locks = LockEvaluator(
            layout: scene.layout, verifier: FakeSignatureVerifier(), runner: ProcessRunner(), log: scene.log)
        let ingest = ScriptedIngest(snapshot: scene.scannedSnapshot(generation: 1))
        await ingest.setScanner { scene.scannedSnapshot(generation: $0) }
        return Stage(
            tmp: tmp, image: image, scene: scene, ingest: ingest,
            deps: scene.deletionDependencies(ingest: ingest, locks: locks))
    }

    static func original(_ s: Stage) -> URL {
        s.scene.deviceRoot.appendingPathComponent(DeletionScene.relpath, isDirectory: false)
    }

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path(percentEncoded: false), &st) == 0
    }

    static func part(_ s: Stage) throws -> RecordingRow {
        try #require(try s.scene.store.recording(s.scene.partkey))
    }

    static func text(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("往復: 要求 → 本物の reaper → 走査 → 回収で COMPLETED（FAT32）")
    func realReaperDeletesAndTheAppCollects() async throws {
        let s = try await Self.stage()
        defer { s.image.detach() }
        #expect(await DeletionRequester(deps: s.deps).requestDeletions(sessionKey: s.scene.sessionKey) == 1)
        let id = try #require(try Self.part(s).deleteRequestID)
        #expect(await ResultCollector(deps: s.deps).runReaperIfNeeded(reaperScanGeneration: 0) == 2)
        #expect(!Self.exists(Self.original(s)))
        let part = try Self.part(s)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt != nil)
        #expect(part.deleteRequestID == nil)
        #expect(s.scene.requests() == [])
        #expect(s.scene.results() == [])
        #expect(Self.text(s.scene.layout.processedLog).split(separator: "\n").contains { $0.contains(id) })
        #expect(
            Self.text(s.scene.layout.reaperLog).contains(
                "source_deleted request_id=" + id + " partkey=" + s.scene.partkey))
        #expect(s.scene.logLines.contains { $0.hasSuffix(" reaper_run exit=0") })
        #expect(s.scene.logLines.contains { $0.contains(" source_deleted ") })
    }

    @Test("往復: 要求の後にファイルが変わると reaper が拒否し PENDING")
    func realReaperRejectsAChangedFile() async throws {
        let s = try await Self.stage()
        defer { s.image.detach() }
        #expect(await DeletionRequester(deps: s.deps).requestDeletions(sessionKey: s.scene.sessionKey) == 1)
        let path = Self.original(s).path(percentEncoded: false)
        var before = stat()
        #expect(lstat(path, &before) == 0)
        let handle = try FileHandle(forWritingTo: Self.original(s))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x78]))
        try handle.close()
        var times = [
            timeval(tv_sec: before.st_mtimespec.tv_sec, tv_usec: Int32(before.st_mtimespec.tv_nsec / 1000)),
            timeval(tv_sec: before.st_mtimespec.tv_sec, tv_usec: Int32(before.st_mtimespec.tv_nsec / 1000)),
        ]
        #expect(utimes(path, &times) == 0)
        _ = await ResultCollector(deps: s.deps).runReaperIfNeeded(reaperScanGeneration: 0)
        let part = try Self.part(s)
        #expect(part.status == .sourceDeletePending)
        #expect(part.errorCode == .sourceIdentityMismatch)
        #expect(try s.scene.store.events(entity: .recording, key: s.scene.partkey).last?.detail == "size_mismatch")
        #expect(Self.exists(Self.original(s)))
    }

    @Test("読み取り専用で再マウントしたイメージでは要求を書かず device_readonly で完了")
    func readOnlyImageCompletesWithoutRequest() async throws {
        let s = try await Self.stage()
        defer { s.image.detach() }
        try s.image.reattach(readOnly: true)
        await s.ingest.setSnapshot(s.scene.scannedSnapshot(generation: 2))
        await SessionDeletionStage(deps: s.deps).deleteSourcesIfSafe(sessionKey: s.scene.sessionKey)
        #expect(s.scene.requests() == [])
        #expect(try s.scene.store.session(s.scene.sessionKey)?.status == .completed)
        #expect(Self.exists(Self.original(s)))
    }

    @Test("DEL-12 inbox のコピーの時刻を DB に入れると事前確認で弾く")
    func copyTimestampWritesNoRequest() async throws {
        let s = try await Self.stage()
        defer { s.image.detach() }
        let mtime = try #require(try Self.part(s).sourceMtime)
        try s.scene.store.updateRecording(s.scene.partkey, [.sourceMtime(mtime + 16_440)])
        #expect(await DeletionRequester(deps: s.deps).requestDeletions(sessionKey: s.scene.sessionKey) == 0)
        #expect(Self.exists(Self.original(s)))
    }
}
