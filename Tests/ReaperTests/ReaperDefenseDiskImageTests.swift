// 走行中の無効化（PLAN §8.9.4・F-73・issue #113）を FAT32 のイメージの上で確かめる（層 R3。VOICEDOCK_DISK_TESTS=1 のときだけ）。
// RV-13 まで進む経路は普通のディレクトリでは RV-06 で弾かれるので、本物の FAT32 のマウント点の上で RequestProcessor を
// プロセス内で組み、起動時の conf（true）の後に reaper.conf を false に書き換えてから process(name:) を呼ぶ。
// イメージは一時ディレクトリの下にだけ attach する（/Volumes には触れない。名前は DJIMIC3 ではなく VDTxxxx。PLAN §10.2）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract

@testable import voicedock_reaper

@Suite(
    "voicedock-reaper の走行中の無効化 × FAT32（層 R3。F-73）", .serialized, .enabled(if: TestEnvironment.diskTests),
    .tags(.diskImage))
struct ReaperDefenseDiskImageTests {
    static let id = ReaperBench.requestID

    /// FAT32 のイメージの上の舞台（通る要求 1 件）と、起動時の conf（ロック 1 が開いている）で組んだ RequestProcessor
    struct Stage {
        let tmp: TempDirectory
        let bench: ReaperBench
        let name: String
        let log: ReaperLog
        var processor: RequestProcessor

        init() throws {
            tmp = try TempDirectory()
            let image = try DiskImageVolume(in: tmp, deviceID: ReaperBench.deviceID, filesystem: .fat32)
            bench = try ReaperBench(in: tmp, diskImage: image)
            name = try bench.writeRequest()
            log = ReaperLog(url: bench.layout.reaperLog)
            guard let queue = QueueFiles.make(layout: bench.layout) else {
                throw BenchError(description: "queue/delete を開けない")
            }
            let startup = ReaperConf(
                deleteSourceAudio: true, volumesRoot: bench.volumesRoot.path(percentEncoded: false))
            processor = RequestProcessor(
                layout: bench.layout, conf: startup, queue: queue, log: log, clock: ReaperClock(),
                processed: ProcessedLog(url: bench.layout.processedLog))
        }
    }

    @Test("RV-01 [R3] 走行中に reaper.conf が false になれば unlink の直前で止まり、要求を残して何も書かない")
    func rv01Lock1ClosedWhileRunningKeepsEverything() throws {
        var stage = try Stage()
        // 無効化（§8.9.8）は reaper.conf を先に false にする。起動時の conf は true のまま
        try stage.bench.writeReaperConf(deleteSourceAudio: false)
        let outcome = stage.processor.process(name: stage.name)
        stage.log.close()
        #expect(outcome == .stopped("lock1"))
        #expect(stage.bench.requests() == [stage.name])
        #expect(stage.bench.results() == [])
        #expect(stage.bench.processedLines() == [])
        #expect(stage.bench.logLines().contains { $0.hasSuffix(" INFO  reaper_disabled reason=lock1") })
        #expect(stage.bench.logLines().allSatisfy { !$0.contains(" source_deleted ") })
        #expect(stage.bench.sourceExists())
    }

    @Test("RV-13 [R3] 対照: 走行中も reaper.conf が true のままなら、同じ準備で本当に消える")
    func rv13Lock1StillOpenDeletes() throws {
        var stage = try Stage()
        let outcome = stage.processor.process(name: stage.name)
        stage.log.close()
        #expect(outcome == .deleted(relpath: ReaperBench.relpath))
        #expect(!stage.bench.sourceExists())
        #expect(stage.bench.requests() == [])
        #expect(stage.bench.processedLines() == [Self.id])
        #expect(try stage.bench.result(Self.id).status == .deleted)
    }
}
