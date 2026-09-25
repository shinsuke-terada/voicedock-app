// デバイス判定のネットワークの FS の除外と、既定の includeVolumes（PLAN §8.1 規則 1・2・§6.2・F-81・issue #119・F-94）。
// volumesRoot は一時ディレクトリ（FakeVolume の <tmp>/Volumes）。MountInspector と lstat は差し替えて、呼ばれたパスを記録する。
import Darwin
import Foundation
import Synchronization
import TestSupport
import Testing
import VDCore

@testable import VDDevice

@Suite("DeviceDetector のネットワークの FS と既定の include（F-81・F-94）")
struct DeviceDetectorNetworkTests {
    static let origRelpath = "TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav"

    /// 呼ばれたパスを溜める（Sendable な箱）
    final class PathLog: Sendable {
        private let paths = Mutex<[String]>([])
        func append(_ path: String) { paths.withLock { $0.append(path) } }
        var all: [String] { paths.withLock { $0 } }
    }

    /// 呼ばれたパスを記録して FakeMountInspector に委ねる（allMounts はパスを取らないので記録しない）
    final class RecordingInspector: MountInspector {
        let base: FakeMountInspector
        let log = PathLog()

        init(_ base: FakeMountInspector) { self.base = base }

        func mountInfo(path: String) -> MountInfo? {
            log.append(path)
            return base.mountInfo(path: path)
        }

        func allMounts() -> [MountInfo] { base.allMounts() }

        func volumeName(path: String) -> String? {
            log.append(path)
            return base.volumeName(path: path)
        }

        func isMountPoint(path: String) -> Bool {
            log.append(path)
            return base.isMountPoint(path: path)
        }
    }

    struct Fixture {
        let tmp: TempDirectory
        /// <tmp>/Volumes
        let volumesRoot: URL
        var inspector = FakeMountInspector()
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo").device
        let lstatLog = PathLog()

        init() throws {
            tmp = try TempDirectory()
            volumesRoot = tmp.url.appendingPathComponent("Volumes", isDirectory: true)
            try FileManager.default.createDirectory(at: volumesRoot, withIntermediateDirectories: true)
        }

        /// <volumesRoot>/<name>（末尾の / なし）
        func path(_ name: String) -> String {
            volumesRoot.appendingPathComponent(name, isDirectory: false).path(percentEncoded: false)
        }

        /// 録音 1 件のボリュームを作り、マウント点・ボリューム名・statfs・マウント一覧に登録する（isLocal を選べる）
        mutating func addVolume(_ name: String, isLocal: Bool = true) throws {
            let volume = try FakeVolume(in: tmp, deviceID: name)
            try volume.addFile(Self.origRelpath, data: Data("x".utf8), mtime: FakeVolume.oldMtime)
            register(name, isLocal: isLocal)
        }

        mutating func register(_ name: String, isLocal: Bool = true) {
            let p = path(name)
            let info = MountInfo(
                mountOnName: p, mountFromName: isLocal ? "/dev/disk4" : "//user@nas/" + name,
                fsTypeName: isLocal ? "msdos" : "smbfs", readOnly: false, freeBytes: 4_500_000_000, isLocal: isLocal)
            inspector.infos[p] = info
            inspector.mountPoints.insert(p)
            inspector.volumeNames[p] = name
            inspector.mounts.append(info)
        }

        static var origRelpath: String { DeviceDetectorNetworkTests.origRelpath }

        /// lstat を記録する DeviceReader で判定する
        func detect(with recorder: RecordingInspector) -> DetectionResult {
            let log = lstatLog
            let reader = DeviceReader(lstat: { path, st in
                log.append(path)
                return Darwin.lstat(path, &st) == 0 ? 0 : errno
            })
            return DeviceDetector(
                config: config, volumesRoot: volumesRoot.path(percentEncoded: false), inspector: recorder,
                reader: reader
            ).detect()
        }

        /// path そのものかその下のパス
        func touched(_ paths: [String], _ name: String) -> Bool {
            let p = path(name)
            return paths.contains { $0 == p || $0.hasPrefix(p + "/") }
        }
    }

    @Test("F-81 ネットワークの FS（MNT_LOCAL でない）のマウント点は excluded で、lstat・statfs・realpath・ボリューム名に進まない")
    func networkVolumeIsExcludedBeforeBlockingCalls() throws {
        var f = try Fixture()
        f.config.includeVolumes = []
        try f.addVolume("DJIMIC3")
        try f.addVolume("Share", isLocal: false)
        let recorder = RecordingInspector(f.inspector)
        let result = f.detect(with: recorder)
        #expect(result.devices.map(\.deviceID) == ["DJIMIC3"])
        #expect(result.skipped == [SkippedVolume(name: "Share", reason: .excluded, listingError: nil)])
        #expect(!f.touched(recorder.log.all, "Share"))
        #expect(!f.touched(f.lstatLog.all, "Share"))
        // 対照: 記録は空振りしていない（ローカルのデバイスには判定の呼び出しが届いている）
        #expect(f.touched(recorder.log.all, "DJIMIC3"))
        #expect(f.touched(f.lstatLog.all, "DJIMIC3"))
    }

    @Test("F-81 既定の include（VOICEDOCK）に一致する名前でも、ネットワークの FS なら excluded で止まりうる呼び出しに進まない")
    func networkVolumeNamedLikeTheDeviceIsExcluded() throws {
        var f = try Fixture()
        try f.addVolume("VOICEDOCK", isLocal: false)
        let recorder = RecordingInspector(f.inspector)
        let result = f.detect(with: recorder)
        #expect(result.devices == [])
        #expect(result.skipped == [SkippedVolume(name: "VOICEDOCK", reason: .excluded, listingError: nil)])
        #expect(recorder.log.all == [])
        #expect(!f.touched(f.lstatLog.all, "VOICEDOCK"))
    }

    @Test("F-81 対照: ローカルの FS のマウント点は従来どおり判定する")
    func localVolumesAreEvaluatedAsBefore() throws {
        var f = try Fixture()
        f.config.includeVolumes = []
        try f.addVolume("DJIMIC3")
        try f.addVolume("DJIMIC4")
        let result = f.detect(with: RecordingInspector(f.inspector))
        #expect(result.devices.map(\.deviceID) == ["DJIMIC3", "DJIMIC4"])
        #expect(result.skipped == [])
    }

    @Test("F-81 マウントの一覧が空（getmntinfo が取れない）なら、どれも除外せず従来どおり判定する（TEST-28）")
    func emptyMountListExcludesNothing() throws {
        var f = try Fixture()
        f.config.includeVolumes = []
        try f.addVolume("DJIMIC3")
        try f.addVolume("Share", isLocal: false)
        f.inspector.mounts = []
        let result = f.detect(with: RecordingInspector(f.inspector))
        #expect(result.devices.map(\.deviceID) == ["DJIMIC3", "Share"])
        #expect(result.skipped == [])
    }

    @Test("F-81 MountInfo(statfs:) は f_flags の MNT_LOCAL を isLocal に写す")
    func statfsLocalFlagIsMapped() {
        var s = statfs()
        s.f_flags = UInt32(MNT_LOCAL)
        #expect(MountInfo(statfs: s).isLocal == true)
        s.f_flags = UInt32(MNT_RDONLY)
        #expect(MountInfo(statfs: s).isLocal == false)
        #expect(MountInfo(statfs: s).readOnly == true)
        s.f_flags = 0
        #expect(MountInfo(statfs: s).isLocal == false)
    }

    @Test("F-94 既定の includeVolumes は VOICEDOCK だけ")
    func defaultIncludeIsVOICEDOCKOnly() {
        #expect(AppConfig.defaults(timeZone: "Asia/Tokyo").device.includeVolumes == ["VOICEDOCK"])
    }

    @Test("F-94 既定の include では、利用者が VOICEDOCK に改名した実機をデバイスとして検出する")
    func defaultIncludeDetectsRenamedDevice() throws {
        var f = try Fixture()
        try f.addVolume("VOICEDOCK")
        let result = f.detect(with: RecordingInspector(f.inspector))
        #expect(result.devices.map(\.deviceID) == ["VOICEDOCK"])
        #expect(result.skipped == [])
        #expect(result.notIncludedDevices == [])
    }

    @Test("F-94 既定の include では、改名前の DJIMIC3 は not_included で取り込まず、改名の案内の対象にする")
    func unrenamedDJIMIC3IsNotIncludedButHinted() throws {
        var f = try Fixture()
        try f.addVolume("DJIMIC3")
        let result = f.detect(with: RecordingInspector(f.inspector))
        #expect(result.devices == [])
        #expect(result.skipped == [SkippedVolume(name: "DJIMIC3", reason: .notIncluded, listingError: nil)])
        #expect(result.notIncludedDevices == ["DJIMIC3"])
    }

    @Test("F-81 既定の include では、録音のフォルダがある別の名前の外付け（バックアップのメモリ）を not_included にする")
    func defaultIncludeSkipsOtherVolumesWithRecordings() throws {
        var f = try Fixture()
        try f.addVolume("BACKUP")
        try f.addVolume("VOICEDOCK")
        let recorder = RecordingInspector(f.inspector)
        let result = f.detect(with: recorder)
        #expect(result.devices.map(\.deviceID) == ["VOICEDOCK"])
        #expect(result.skipped == [SkippedVolume(name: "BACKUP", reason: .notIncluded, listingError: nil)])
        // 取り込まないが、録音のフォルダがあるので改名の案内の対象（F-81 のレビュー。利用者の決定 2026-09-23）
        #expect(result.notIncludedDevices == ["BACKUP"])
    }

    @Test("F-81 既定の include では出荷時名 NO NAME も not_included で、録音のフォルダがあれば改名の案内の対象")
    func factoryNamedDeviceIsNotIncludedButHinted() throws {
        var f = try Fixture()
        try f.addVolume("NO NAME")
        let result = f.detect(with: RecordingInspector(f.inspector))
        #expect(result.devices == [])
        #expect(result.skipped == [SkippedVolume(name: "NO NAME", reason: .notIncluded, listingError: nil)])
        #expect(result.notIncludedDevices == ["NO NAME"])
    }

    @Test("F-81 古いマウント点が残って VOICEDOCK 1 にマウントされた実機も not_included で改名（挿し直し）の案内の対象")
    func numberedMountPointIsHinted() throws {
        var f = try Fixture()
        try f.addVolume("VOICEDOCK 1")
        // ボリューム名は VOICEDOCK（規則 8 は案内の判定では見ない）
        f.inspector.volumeNames[f.path("VOICEDOCK 1")] = "VOICEDOCK"
        let result = f.detect(with: RecordingInspector(f.inspector))
        #expect(result.devices == [])
        #expect(result.skipped.map(\.reason) == [.notIncluded])
        #expect(result.notIncludedDevices == ["VOICEDOCK 1"])
    }

    @Test("F-81 案内の対象にしないもの: 録音のフォルダが無い・exclude に当たる・マウント点でない・symlink")
    func nonDeviceLikeVolumesAreNotHinted() throws {
        var f = try Fixture()
        // 録音のフォルダが無いローカルのボリューム
        let plain = try FakeVolume(in: f.tmp, deviceID: "DATA")
        try plain.addFile("Documents/memo.txt", data: Data("x".utf8), mtime: FakeVolume.oldMtime)
        f.register("DATA")
        // exclude（既定の Macintosh HD）
        try f.addVolume("Macintosh HD")
        // マウント点でない（登録しない）
        let notMounted = try FakeVolume(in: f.tmp, deviceID: "LOOSE")
        try notMounted.addFile(Self.origRelpath, data: Data("x".utf8), mtime: FakeVolume.oldMtime)
        // symlink のエントリ
        try FileManager.default.createSymbolicLink(atPath: f.path("LINK"), withDestinationPath: "LOOSE")
        f.register("LINK")
        let result = f.detect(with: RecordingInspector(f.inspector))
        #expect(result.devices == [])
        #expect(result.skipped.map(\.name) == ["DATA", "LINK", "LOOSE", "Macintosh HD"])
        #expect(result.skipped.allSatisfy { $0.reason == .notIncluded })
        #expect(result.notIncludedDevices == [])
    }

    @Test("F-81 not_included のネットワークの FS は、案内の判定でも止まりうる呼び出しに進まない")
    func networkVolumeIsNotProbedForHint() throws {
        var f = try Fixture()
        try f.addVolume("Share", isLocal: false)
        let recorder = RecordingInspector(f.inspector)
        let result = f.detect(with: recorder)
        #expect(result.skipped == [SkippedVolume(name: "Share", reason: .notIncluded, listingError: nil)])
        #expect(result.notIncludedDevices == [])
        #expect(!f.touched(recorder.log.all, "Share"))
        #expect(!f.touched(f.lstatLog.all, "Share"))
    }

    @Test("F-81 include が空なら not_included は出ず、案内の対象も無い（TEST-28）")
    func emptyIncludeHasNoHints() throws {
        var f = try Fixture()
        f.config.includeVolumes = []
        try f.addVolume("BACKUP")
        let result = f.detect(with: RecordingInspector(f.inspector))
        #expect(result.devices.map(\.deviceID) == ["BACKUP"])
        #expect(result.notIncludedDevices == [])
    }

    @Test("F-81 include の照合は UTF-8 のバイト列（正準等価でも綴りの違う名前は一致しない）")
    func includeMatchesBytesNotCanonicalEquivalence() throws {
        var f = try Fixture()
        try f.addVolume("VDT\u{304C}")
        // ファイルシステムが保った綴り（NFC か NFD）を読み、もう一方の綴りを include に書く
        let listed = try #require(
            try DeviceReader().listEntries(of: f.volumesRoot.path(percentEncoded: false)).get().first)
        let nfc = listed.precomposedStringWithCanonicalMapping
        let nfd = listed.decomposedStringWithCanonicalMapping
        let other = Array(listed.unicodeScalars) == Array(nfc.unicodeScalars) ? nfd : nfc
        // 準備の確かめ: == では等しく、スカラー列では違う（これが成り立たなければテストが空振りする）
        try #require(other == listed)
        try #require(Array(other.unicodeScalars) != Array(listed.unicodeScalars))
        f.inspector.volumeNames[f.path(listed)] = listed
        f.config.includeVolumes = [other]
        #expect(f.detect(with: RecordingInspector(f.inspector)).devices == [])
        #expect(f.detect(with: RecordingInspector(f.inspector)).skipped.map(\.reason) == [.notIncluded])
        // 対照: 同じ綴りなら一致する
        f.config.includeVolumes = [listed]
        #expect(f.detect(with: RecordingInspector(f.inspector)).devices.map(\.deviceID) == [listed])
    }
}
