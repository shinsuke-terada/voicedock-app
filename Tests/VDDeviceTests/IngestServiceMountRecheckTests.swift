// 走査の、列挙の後のマウントの確かめ直し（C5）と、再マウントでアンマウントされたままのデバイス（C6）（PLAN §8.1・F-81・issue #119）。
// volumesRoot は一時ディレクトリ（<tmp>/Volumes。/Volumes に触れない）。MountInspector・Remounter・lstat は差し替える。
import Darwin
import Foundation
import Synchronization
import Testing
import VDContract
import VDCore
import VDStore

@testable import TestSupport
@testable import VDDevice

@Suite("IngestService のマウントの確かめ直し（F-81）", .serialized)
struct IngestServiceMountRecheckTests {
    static let deviceID = "DJIMIC3"
    /// 列挙だけが開くパス（判定の規則 6 はボリュームの直下しか見ない）
    static let notes = "TX_MIC001_20260912_120950/NOTES.txt"

    /// flip() の前は before、後は after の値を返す MountInspector（FakeMountInspector は不変なので、走査の途中の変化はこれで作る）
    final class SwitchingInspector: MountInspector {
        let before: FakeMountInspector
        let after: FakeMountInspector
        private let switched = Mutex(false)
        private let flippedOnce = Mutex(false)

        init(before: FakeMountInspector, after: FakeMountInspector) {
            self.before = before
            self.after = after
        }

        func flip(_ on: Bool = true) { switched.withLock { $0 = on } }

        /// 最初の 1 回だけ flip する（挿し直しの後の 2 回目の再マウントでは切り替えない）
        func flipOnce() {
            let first = flippedOnce.withLock { value in
                defer { value = true }
                return !value
            }
            if first { flip() }
        }

        private var current: FakeMountInspector { switched.withLock { $0 } ? after : before }

        func mountInfo(path: String) -> MountInfo? { current.mountInfo(path: path) }
        func allMounts() -> [MountInfo] { current.allMounts() }
        func volumeName(path: String) -> String? { current.volumeName(path: path) }
        func isMountPoint(path: String) -> Bool { current.isMountPoint(path: path) }
    }

    /// 差し替えた lstat が「在る」と答える /dev の node
    final class DevNodes: Sendable {
        private let present = Mutex<Set<String>>(["/dev/disk4"])
        func contains(_ node: String) -> Bool { present.withLock { $0.contains(node) } }
        /// 抜いた（node が /dev から消えた）
        func remove(_ node: String) { _ = present.withLock { $0.remove(node) } }
    }

    /// flip の後に見える状態
    enum After {
        /// statfs が取れず、マウント点でもない（アンマウントされた・抜かれた）
        case gone
        /// マウント点のパスで親の FS が見えている（f_mntonname が違う）
        case parent
        /// 同じマウント点に別の node（挿し直しで disk 番号が変わった）
        case otherNode
        /// f_mntonname だけ綴り（NFC / NFD）が違う（otherSpelling(of: realpath)）
        case otherSpelling
    }

    /// NFC なら NFD、そうでなければ NFC の綴り
    static func otherSpelling(of s: String) -> String {
        let nfc = s.precomposedStringWithCanonicalMapping
        return Array(s.unicodeScalars) == Array(nfc.unicodeScalars) ? s.decomposedStringWithCanonicalMapping : nfc
    }

    /// いつ flip するか
    enum Trigger {
        case never
        /// 再マウントの呼び出しの中（unmount → mount の途中で外れた・アンマウントされたまま）
        case onRemount
        /// 列挙が notes を lstat したとき（列挙の途中の unmount）
        case duringListing
    }

    struct Harness {
        let tmp: TempDirectory
        let fake: FakeVolume
        let layout: HomeLayout
        let store: Store
        let sink: CapturingLogSink
        let inspector: SwitchingInspector
        let remounter: FakeRemounter
        let service: IngestService
        /// 差し替えた lstat が「在る」と答える /dev の node（既定は判定のときの node の /dev/disk4）
        let devNodes: DevNodes

        init(
            deviceID: String = IngestServiceMountRecheckTests.deviceID, outcomes: [RemountOutcome],
            after: After = .gone, trigger: Trigger, recordings: Bool = true, include: [String] = []
        ) throws {
            tmp = try TempDirectory()
            fake = try FakeVolume(in: tmp, deviceID: deviceID)
            if recordings { try DefaultDeviceTree.populate(fake) }
            try fake.addFile(
                IngestServiceMountRecheckTests.notes, data: Data("memo\n".utf8), mtime: FakeVolume.oldMtime)
            layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
            try layout.createDirectories()
            let clock = FixedClock(epochMillis: 1_790_000_000_000)
            let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
            store = try Store(url: layout.database, clock: clock, zone: zone)
            sink = CapturingLogSink()
            let log = AppLog(sink: sink, level: .debug, unsafeContent: false, zone: zone, clock: clock)
            var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
            // 名前を変えるテストがあるので include は既定で空にする（既定の ["DJIMIC3"] は DeviceDetectorNetworkTests と下の案内のテスト）
            config.device.includeVolumes = include
            let provided = config
            // ファイルシステムが保った綴りの名前（NFC か NFD）。判定はこの綴りでパスを作り、規則 8 はスカラー列で比べる
            let volumesRoot = fake.volumesRoot.path(percentEncoded: false)
            let stored = try #require(try DeviceReader().listEntries(of: volumesRoot).get().first)
            let path = fake.volumesRoot.appendingPathComponent(stored, isDirectory: false).path(percentEncoded: false)
            // 本物の statfs と同じく f_mntonname は realpath 側（/var → /private/var）にする
            let real = try #require(SystemMountInspector.realPath(path))
            var before = FakeMountInspector.mounted([path])
            before.infos[path] = MountInfo(
                mountOnName: real, mountFromName: "/dev/disk4", fsTypeName: "msdos", readOnly: false,
                freeBytes: 4_500_000_000)
            before.volumeNames[path] = stored
            var afterInspector = before
            switch after {
            case .gone:
                afterInspector = FakeMountInspector()
            case .parent:
                afterInspector.infos[path] = MountInfo(
                    mountOnName: "/", mountFromName: "/dev/disk3s1", fsTypeName: "apfs", readOnly: false,
                    freeBytes: 500_000_000_000)
            case .otherNode:
                afterInspector.infos[path] = MountInfo(
                    mountOnName: real, mountFromName: "/dev/disk5", fsTypeName: "msdos", readOnly: false,
                    freeBytes: 4_500_000_000)
            case .otherSpelling:
                afterInspector.infos[path] = MountInfo(
                    mountOnName: IngestServiceMountRecheckTests.otherSpelling(of: real), mountFromName: "/dev/disk4",
                    fsTypeName: "msdos", readOnly: false, freeBytes: 4_500_000_000)
            }
            let inspector = SwitchingInspector(before: before, after: afterInspector)
            self.inspector = inspector
            let devNodes = DevNodes()
            self.devNodes = devNodes
            let flipsDuringListing: Bool
            if case .duringListing = trigger { flipsDuringListing = true } else { flipsDuringListing = false }
            let marker = "/" + IngestServiceMountRecheckTests.notes
            // /dev の lstat は本物を見ない（開発機のディスク番号に左右されない）。devNodes に在る node だけ「在る」
            let reader = DeviceReader(lstat: { p, st in
                if p.hasPrefix("/dev/") { return devNodes.contains(p) ? 0 : ENOENT }
                if flipsDuringListing && p.hasSuffix(marker) { inspector.flip() }
                return Darwin.lstat(p, &st) == 0 ? 0 : errno
            })
            let onRemount: (@Sendable () async -> Void)?
            if case .onRemount = trigger {
                onRemount = { inspector.flipOnce() }
            } else {
                onRemount = nil
            }
            remounter = FakeRemounter(outcomes: outcomes, onRemount: onRemount)
            let deps = IngestDependencies(
                layout: layout, configProvider: { provided }, store: store, inspector: inspector,
                remounter: remounter, mountEvents: FakeMountEventSource(), reader: reader, clock: clock,
                sleeper: RecordingSleeper(), zone: zone, log: log,
                volumesRoot: fake.volumesRoot.path(percentEncoded: false))
            service = IngestService(deps: deps)
        }

        func snapshot() async throws -> DeviceSnapshot {
            try #require(await service.latestSnapshot())
        }

        /// inbox の下の通常ファイル（. 始まりを除く）の数
        func inboxFileCount() -> Int {
            guard let enumerator = FileManager.default.enumerator(at: layout.inbox, includingPropertiesForKeys: nil)
            else { return 0 }
            var count = 0
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                if values?.isRegularFile == true && !url.lastPathComponent.hasPrefix(".") { count += 1 }
            }
            return count
        }

        /// FakeVolume を一時ディレクトリの中で別名へ移す（/Volumes からエントリが消えた状態）
        func removeEntry() throws {
            try FileManager.default.moveItem(
                at: fake.root, to: tmp.url.appendingPathComponent("away", isDirectory: true))
        }
    }

    // MARK: - C5 列挙の後のマウントの確かめ直し

    @Test("F-81 列挙の途中でアンマウントされ、空の一覧が完全に見えても devices に載せず unavailable に not_listable")
    func unmountDuringListingOfEmptyVolumeIsNotPublished() async throws {
        let h = try Harness(outcomes: [.alreadyReadOnly], after: .gone, trigger: .duringListing, recordings: false)
        #expect(await h.service.scanNow() == 1)
        let snapshot = try await h.snapshot()
        #expect(snapshot.devices == [:])
        #expect(snapshot.unavailable == ["DJIMIC3": "not_listable"])
        #expect(snapshot.notListableErrno == [:])
        #expect(h.sink.lines.contains { $0.hasSuffix("WARNING volume_skipped name=DJIMIC3 reason=not_listable") })
    }

    @Test("F-81 対照: 列挙の前後で statfs が同じなら、空の一覧も録音 0 件のデバイスとして載せる（TEST-28・DEV-19）")
    func sameMountPublishesEmptyListing() async throws {
        let h = try Harness(outcomes: [.alreadyReadOnly], trigger: .never, recordings: false)
        #expect(await h.service.scanNow() == 1)
        let snapshot = try await h.snapshot()
        #expect(snapshot.devices["DJIMIC3"]?.relpaths == [])
        #expect(snapshot.unavailable == [:])
    }

    @Test("F-81 列挙の後に親の FS が見えていたら（f_mntonname が違う）載せない")
    func parentFileSystemAfterListingIsNotPublished() async throws {
        let h = try Harness(outcomes: [.alreadyReadOnly], after: .parent, trigger: .duringListing)
        #expect(await h.service.scanNow() == 1)
        let snapshot = try await h.snapshot()
        #expect(snapshot.devices == [:])
        #expect(snapshot.unavailable == ["DJIMIC3": "not_listable"])
    }

    @Test("F-81 列挙の後に f_mntfromname が違えば（挿し直しで別の disk 番号）載せない。その回の取り込みは続ける")
    func otherNodeAfterListingIsNotPublishedButCopies() async throws {
        let h = try Harness(outcomes: [.alreadyReadOnly], after: .otherNode, trigger: .duringListing)
        #expect(await h.service.scanNow() == 1)
        let snapshot = try await h.snapshot()
        #expect(snapshot.devices == [:])
        #expect(snapshot.unavailable == ["DJIMIC3": "not_listable"])
        #expect(h.inboxFileCount() == 2)
    }

    @Test("F-81 f_mntonname はスカラー列で比べる（正準等価でも綴りが違えば載せない）")
    func mountOnNameIsComparedByScalars() async throws {
        // 名前に「が」を含むボリューム。statfs の f_mntonname の側だけ、列挙の後にもう一方の綴りへ変える
        let h = try Harness(
            deviceID: "VDT\u{304C}", outcomes: [.alreadyReadOnly], after: .otherSpelling, trigger: .duringListing)
        let real = try #require(h.inspector.before.infos.values.first?.mountOnName)
        let other = try #require(h.inspector.after.infos.values.first?.mountOnName)
        // 準備の確かめ: == では等しく、スカラー列では違う（これが成り立たなければテストが空振りする）
        try #require(other == real)
        try #require(Array(other.unicodeScalars) != Array(real.unicodeScalars))
        #expect(await h.service.scanNow() == 1)
        let snapshot = try await h.snapshot()
        #expect(snapshot.devices == [:])
        #expect(Array(snapshot.unavailable.values) == ["not_listable"])
        // 対照: 綴りが変わらなければ載る
        let same = try Harness(deviceID: "VDT\u{304C}", outcomes: [.alreadyReadOnly], trigger: .never)
        #expect(await same.service.scanNow() == 1)
        #expect(try await same.snapshot().devices.count == 1)
        #expect(try await same.snapshot().unavailable == [:])
    }

    // MARK: - C6 unmount の後の mount の失敗

    @Test("F-81 unmount の後に mount が失敗してマウント点でなくなったら、unavailable に mount_failed で載せる")
    func mountFailureLeavingItUnmountedIsUnavailable() async throws {
        let h = try Harness(outcomes: [.failed(reason: "mount_failed")], after: .gone, trigger: .onRemount)
        #expect(await h.service.scanNow() == 1)
        let snapshot = try await h.snapshot()
        #expect(snapshot.devices == [:])
        #expect(snapshot.unavailable == ["DJIMIC3": "mount_failed"])
        #expect(h.inboxFileCount() == 0)
        #expect(h.sink.lines.contains { $0.hasSuffix("WARNING remount_failed name=DJIMIC3 reason=mount_failed") })
    }

    @Test("F-81 アンマウントされたままなら、次の走査でも（マウント点のディレクトリが残っても消えても）unavailable に残す")
    func unmountedDeviceStaysUnavailableAcrossScans() async throws {
        let h = try Harness(outcomes: [.failed(reason: "mount_failed")], after: .gone, trigger: .onRemount)
        #expect(await h.service.scanNow() == 1)
        // マウント点のディレクトリが残っている（判定は not_a_mount_point）
        #expect(await h.service.scanNow() == 2)
        #expect(try await h.snapshot().devices == [:])
        #expect(try await h.snapshot().unavailable == ["DJIMIC3": "mount_failed"])
        // ディレクトリも消えた（判定に名前が現れない）
        try h.removeEntry()
        #expect(await h.service.scanNow() == 3)
        #expect(try await h.snapshot().unavailable == ["DJIMIC3": "mount_failed"])
        // 判定を通らないので再マウントはもう試みない
        #expect(await h.remounter.calls.count == 1)
    }

    @Test("F-81 挿し直して名前が判定に戻れば unavailable から外し、従来どおり取り込む")
    func replugClearsMountFailure() async throws {
        let h = try Harness(
            outcomes: [.failed(reason: "mount_failed"), .alreadyReadOnly], after: .gone, trigger: .onRemount)
        #expect(await h.service.scanNow() == 1)
        #expect(try await h.snapshot().unavailable == ["DJIMIC3": "mount_failed"])
        h.inspector.flip(false)
        #expect(await h.service.scanNow() == 2)
        let snapshot = try await h.snapshot()
        #expect(snapshot.unavailable == [:])
        #expect(snapshot.devices["DJIMIC3"]?.relpaths.count == 4)
        #expect(h.inboxFileCount() == 2)
    }

    @Test("F-81 mount_failed でもマウント点のままなら、従来どおり取り込んで載せ、unavailable に載せない")
    func mountFailureStillMountedIsIngestedAsBefore() async throws {
        let h = try Harness(outcomes: [.failed(reason: "mount_failed")], trigger: .never)
        #expect(await h.service.scanNow() == 1)
        let snapshot = try await h.snapshot()
        #expect(snapshot.devices["DJIMIC3"]?.relpaths.count == 4)
        #expect(snapshot.unavailable == [:])
        #expect(h.inboxFileCount() == 2)
    }

    @Test(
        "F-81 unmount_failed・no_device_node で外れた（抜かれた）なら unavailable に載せない（アンマウントしたのはアプリではない）",
        arguments: ["unmount_failed", "no_device_node"])
    func otherRemountFailuresAreNotUnavailable(reason: String) async throws {
        let h = try Harness(outcomes: [.failed(reason: reason)], after: .gone, trigger: .onRemount)
        #expect(await h.service.scanNow() == 1)
        let snapshot = try await h.snapshot()
        #expect(snapshot.devices == [:])
        #expect(snapshot.unavailable == [:])
        #expect(await h.service.scanNow() == 2)
        #expect(try await h.snapshot().unavailable == [:])
    }

    @Test("F-81 抜いて node（/dev/diskN）が消えたら mount_failed を外す（抜いた後も残り続けない）")
    func unpluggedNodeClearsMountFailure() async throws {
        let h = try Harness(outcomes: [.failed(reason: "mount_failed")], after: .gone, trigger: .onRemount)
        #expect(await h.service.scanNow() == 1)
        #expect(try await h.snapshot().unavailable == ["DJIMIC3": "mount_failed"])
        h.devNodes.remove("/dev/disk4")
        try h.removeEntry()
        #expect(await h.service.scanNow() == 2)
        #expect(try await h.snapshot().unavailable == [:])
        #expect(try await h.snapshot().devices == [:])
    }

    @Test("F-81 not_a_mount_point 以外の理由で名前が判定に戻れば（no_recordings）mount_failed を外す")
    func otherSkipReasonClearsMountFailure() async throws {
        let h = try Harness(outcomes: [.failed(reason: "mount_failed")], after: .gone, trigger: .onRemount)
        #expect(await h.service.scanNow() == 1)
        #expect(try await h.snapshot().unavailable == ["DJIMIC3": "mount_failed"])
        // 挿し直した（マウント点に戻った）が、中身は録音の無いボリューム（一時ディレクトリの中だけ）
        h.inspector.flip(false)
        for child in try FileManager.default.contentsOfDirectory(at: h.fake.root, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: child)
        }
        #expect(await h.service.scanNow() == 2)
        let snapshot = try await h.snapshot()
        #expect(snapshot.unavailable == [:])
        #expect(snapshot.devices == [:])
        #expect(h.sink.lines.contains { $0.hasSuffix("DEBUG volume_skipped name=DJIMIC3 reason=no_recordings") })
    }

    @Test("F-81 sameMount は前後とも取れなければ同じ、片方だけ取れなければ違う、両方あれば 2 つの名前をスカラー列で比べる")
    func sameMountTable() {
        let a = MountInfo(
            mountOnName: "/Volumes/X", mountFromName: "/dev/disk4", fsTypeName: "msdos", readOnly: false,
            freeBytes: 1)
        let otherFree = MountInfo(
            mountOnName: "/Volumes/X", mountFromName: "/dev/disk4", fsTypeName: "exfat", readOnly: true, freeBytes: 2)
        let otherNode = MountInfo(
            mountOnName: "/Volumes/X", mountFromName: "/dev/disk5", fsTypeName: "msdos", readOnly: false,
            freeBytes: 1)
        #expect(IngestService.sameMount(nil, nil) == true)
        #expect(IngestService.sameMount(nil, a) == false)
        #expect(IngestService.sameMount(a, nil) == false)
        #expect(IngestService.sameMount(a, a) == true)
        #expect(IngestService.sameMount(a, otherFree) == true)
        #expect(IngestService.sameMount(a, otherNode) == false)
    }

    @Test("F-81 既定の include で録音のフォルダがある別の名前のメモリは、取り込まず再マウントもせず、unavailable に not_included（案内だけ）")
    func backupStickIsOnlyHinted() async throws {
        let h = try Harness(
            deviceID: "BACKUP", outcomes: [.alreadyReadOnly], trigger: .never, include: ["DJIMIC3"])
        let before = try IngestCopyTests.deviceSnapshot(h.fake)
        #expect(await h.service.scanNow() == 1)
        let snapshot = try await h.snapshot()
        #expect(snapshot.devices == [:])
        #expect(snapshot.unavailable == ["BACKUP": "not_included"])
        #expect(h.inboxFileCount() == 0)
        #expect(await h.remounter.calls.isEmpty)
        #expect(try h.store.recordings(status: .discovered).isEmpty)
        // メモリの中身は 1 バイトも変わらない（削除の要求は devices に載ったデバイスにしか書かれない）
        #expect(try IngestCopyTests.deviceSnapshot(h.fake) == before)
        // 変わったときだけ WARNING（OPS-12）
        #expect(await h.service.scanNow() == 2)
        let warnings = h.sink.lines.filter { $0.hasSuffix("WARNING volume_skipped name=BACKUP reason=not_included") }
        #expect(warnings.count == 1)
        #expect(try await h.snapshot().unavailable == ["BACKUP": "not_included"])
    }
}
