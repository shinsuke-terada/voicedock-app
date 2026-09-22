// IngestService × 本物の FAT32 イメージ（T-15 §5.5。.diskImage。VOICEDOCK_DISK_TESTS=1 のときだけ）。
// イメージは <tmp>/Volumes/VDTxxxx に attach する（/Volumes の下には決して attach しない）。再マウントは必ず useMountPoint: true。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess
import VDStore

@testable import VDDevice

@Suite(
    "IngestService × FAT32 イメージ", .serialized, .enabled(if: TestEnvironment.diskTests), .tags(.diskImage))
struct IngestServiceDiskImageTests {
    static let origRelpath = "TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav"

    struct Harness {
        let tmp: TempDirectory
        let disk: DiskImageVolume
        let layout: HomeLayout
        let store: Store
        let service: IngestService

        init(mountMode: String) throws {
            tmp = try TempDirectory()
            disk = try DiskImageVolume(in: tmp, deviceID: DiskImageVolume.uniqueName())
            layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
            try layout.createDirectories()
            let clock = FixedClock(epochMillis: 1_790_000_000_000)
            let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
            store = try Store(url: layout.database, clock: clock, zone: zone)
            let log = AppLog(sink: CapturingLogSink(), level: .debug, unsafeContent: false, zone: zone, clock: clock)
            var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
            config.device.mountMode = mountMode
            let provided = config
            let inspector = SystemMountInspector()
            let deps = IngestDependencies(
                layout: layout, configProvider: { provided }, store: store, inspector: inspector,
                remounter: DiskutilRemounter(runner: ProcessRunner(), inspector: inspector, useMountPoint: true),
                mountEvents: FakeMountEventSource(), reader: DeviceReader(),
                clock: clock, sleeper: RecordingSleeper(), zone: zone, log: log,
                volumesRoot: disk.volumesRoot.path(percentEncoded: false))
            service = IngestService(deps: deps)
        }

        /// イメージに BWF の _orig を 1 本置き、mtime を古くする（書く先は <tmp> の下のイメージだけ）
        func addOrig() throws {
            let target = disk.mountPoint.appendingPathComponent(IngestServiceDiskImageTests.origRelpath)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try BWFWriter.build(seconds: 1.5, format: .pcm24, content: .speech).write(to: target)
            let seconds = Int(FakeVolume.oldMtime.rounded(.down)) | 1
            var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
            #expect(utimes(target.path(percentEncoded: false), &times) == 0)
        }
    }

    /// 取り違えたら何もせずに止める（5.0）
    static func requireOutsideVolumes(_ disk: DiskImageVolume) throws {
        try #require(!disk.mountPoint.resolvingSymlinksInPath().path(percentEncoded: false).hasPrefix("/Volumes/"))
    }

    @Test("本物の FAT をマウント点として検出し取り込む（realpath の比較）")
    func diskImageIsDetectedAndIngested() async throws {
        let h = try Harness(mountMode: "rw")
        try Self.requireOutsideVolumes(h.disk)
        try h.addOrig()
        #expect(await h.service.scanNow() == 1)
        let observation = try #require(await h.service.latestSnapshot()?.devices[h.disk.deviceID])
        #expect(observation.readOnly == false)
        let inbox = h.layout.inboxFile(deviceID: h.disk.deviceID, relpath: Self.origRelpath)
        #expect(FileManager.default.fileExists(atPath: inbox.path(percentEncoded: false)))
        let row = try #require(try h.store.recording(h.disk.deviceID + "/" + Self.origRelpath))
        let mtime = try #require(row.sourceMtime)
        #expect(mtime.truncatingRemainder(dividingBy: 2) == 0)
    }

    @Test("本物の diskutil で読み取り専用に再マウントし、観測が真になる")
    func realRemountMakesItReadOnly() async throws {
        let h = try Harness(mountMode: "ro")
        try Self.requireOutsideVolumes(h.disk)
        try h.addOrig()
        #expect(await h.service.scanNow() == 1)
        let observation = try #require(await h.service.latestSnapshot()?.devices[h.disk.deviceID])
        #expect(observation.readOnly == true)
        var s = statfs()
        try #require(statfs(h.disk.mountPoint.path(percentEncoded: false), &s) == 0)
        #expect((s.f_flags & UInt32(MNT_RDONLY)) != 0)
        // 観測のパスは realpath（/private/var/…）。TempDirectory.url は /var/… のことがあるので realpath どうしで比べる
        let tmpReal = try #require(SystemMountInspector.realPath(h.tmp.url.path(percentEncoded: false)))
        #expect(observation.mountPath.hasPrefix(tmpReal + "/"))
        #expect(!observation.mountPath.hasPrefix("/Volumes/"))
    }

    @Test("読み取り専用で attach したイメージは再マウントしない")
    func alreadyReadOnlyImageIsNotUnmounted() async throws {
        let tmp = try TempDirectory()
        let disk = try DiskImageVolume(in: tmp, deviceID: DiskImageVolume.uniqueName())
        try Self.requireOutsideVolumes(disk)
        try disk.reattach(readOnly: true)
        let runner = ScriptedProcessRunner(results: [ScriptedProcessRunner.exited(0)])
        let sut = DiskutilRemounter(runner: runner, inspector: SystemMountInspector(), useMountPoint: true)
        let outcome = await sut.remountReadOnly(
            path: disk.mountPoint.path(percentEncoded: false), node: disk.node ?? "")
        #expect(outcome == .alreadyReadOnly)
        #expect(await runner.recorded == [])
    }
}
