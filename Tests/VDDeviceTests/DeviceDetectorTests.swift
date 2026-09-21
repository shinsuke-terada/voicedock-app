// デバイス判定（規則 1〜9）の検査（T-13 §5.3）。volumesRoot は必ず一時ディレクトリ（FakeVolume の <tmp>/Volumes）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDDevice

@Suite("DeviceDetector")
struct DeviceDetectorTests {
    static let origRelpath = "TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav"

    /// 共通の準備。弾かせたい規則以外はすべて満たす（TEST-19）
    struct Fixture {
        let tmp: TempDirectory
        let volume: FakeVolume
        var config: DeviceConfig
        var inspector: FakeMountInspector

        init() throws {
            tmp = try TempDirectory()
            volume = try FakeVolume(in: tmp)
            try volume.addFile(Self.origRelpath, data: Data("x".utf8), mtime: FakeVolume.oldMtime)
            config = AppConfig.defaults(timeZone: "Asia/Tokyo").device
            inspector = FakeMountInspector.mounted([
                volume.volumesRoot.appendingPathComponent("DJIMIC3", isDirectory: false).path(percentEncoded: false)
            ])
        }

        static var origRelpath: String { DeviceDetectorTests.origRelpath }

        /// <volumesRoot>/<name>（末尾の / なし）
        func entryPath(_ name: String) -> String {
            volume.volumesRoot.appendingPathComponent(name, isDirectory: false).path(percentEncoded: false)
        }

        var volumesRootPath: String { volume.volumesRoot.path(percentEncoded: false) }

        /// DJIMIC3 の中身を消す（ボリュームのディレクトリは残す）
        func emptyVolume() throws {
            let manager = FileManager.default
            for child in try manager.contentsOfDirectory(at: volume.root, includingPropertiesForKeys: nil) {
                try manager.removeItem(at: child)
            }
        }

        /// 別のボリュームを足す（中身は録音 1 件）。マウント点・ボリューム名も登録する
        mutating func addMountedVolume(_ name: String) throws -> FakeVolume {
            let other = try FakeVolume(in: tmp, deviceID: name)
            try other.addFile(Self.origRelpath, data: Data("x".utf8), mtime: FakeVolume.oldMtime)
            register(name)
            return other
        }

        mutating func register(_ name: String) {
            let path = entryPath(name)
            inspector.mountPoints.insert(path)
            inspector.volumeNames[path] = name
            inspector.infos[path] = MountInfo(
                mountOnName: path, mountFromName: "/dev/disk5", fsTypeName: "msdos", readOnly: false,
                freeBytes: 4_500_000_000)
        }

        func detect() -> DetectionResult {
            DeviceDetector(config: config, volumesRoot: volumesRootPath, inspector: inspector, reader: DeviceReader())
                .detect()
        }

        func reason(_ name: String) -> DetectionReason? {
            detect().skipped.first { $0.name == name }?.reason
        }

        func detectedIDs() -> [String] {
            detect().devices.map(\.deviceID)
        }
    }

    @Test("条件をすべて満たすと検出する（正の対照）")
    func validDeviceIsDetected() throws {
        let f = try Fixture()
        let result = f.detect()
        #expect(
            result.devices == [
                DetectedDevice(deviceID: "DJIMIC3", mountPath: f.entryPath("DJIMIC3"), node: "/dev/disk4")
            ])
        #expect(result.skipped == [])
        #expect(result.listingError == nil)
    }

    @Test("規則 1: include が空なら素通り")
    func includeEmptyLetsEverythingThrough() throws {
        var f = try Fixture()
        f.config.includeVolumes = []
        #expect(f.detectedIDs() == ["DJIMIC3"])
    }

    @Test("規則 1: include の glob に一致すれば通る")
    func includeGlobMatches() throws {
        var f = try Fixture()
        f.config.includeVolumes = ["DJIMIC*"]
        #expect(f.detectedIDs() == ["DJIMIC3"])
    }

    @Test("CE device.includeVolumes 規則 1: どれにも一致しなければ not_included")
    func includeThatMatchesNothing() throws {
        var f = try Fixture()
        #expect(f.detectedIDs() == ["DJIMIC3"])
        f.config.includeVolumes = ["NOPE"]
        let result = f.detect()
        #expect(result.devices == [])
        #expect(result.skipped == [SkippedVolume(name: "DJIMIC3", reason: .notIncluded, listingError: nil)])
    }

    @Test("規則 1・2: `.*` は glob（`.` で始まる）で正規表現ではない")
    func patternsAreGlobsNotRegexes() throws {
        var f = try Fixture()
        f.config.includeVolumes = [".*"]
        #expect(f.detectedIDs() == [])
        #expect(f.reason("DJIMIC3") == .notIncluded)
    }

    @Test("CE device.excludeVolumes 規則 2: 空白を含む名前は 1 つのパターン（一致すれば excluded、しなければ検出）")
    func excludeWithSpaceIsOnePattern() throws {
        var f = try Fixture()
        _ = try f.addMountedVolume("My Device")
        f.config.excludeVolumes = ["My Device"]
        #expect(f.reason("My Device") == .excluded)
        #expect(!f.detectedIDs().contains("My Device"))
        f.config.excludeVolumes = ["My"]
        #expect(f.detectedIDs().contains("My Device"))
        #expect(f.reason("My Device") == nil)
    }

    @Test("規則 2: 既定の exclude は Macintosh HD と TimeMachine と `.` 始まり")
    func defaultExcludesMacintoshHD() throws {
        var f = try Fixture()
        #expect(f.config.excludeVolumes == ["Macintosh HD", "com.apple.TimeMachine.*", ".*"])
        _ = try f.addMountedVolume("Macintosh HD")
        _ = try f.addMountedVolume("com.apple.TimeMachine.localsnapshots")
        #expect(f.reason("Macintosh HD") == .excluded)
        #expect(f.reason("com.apple.TimeMachine.localsnapshots") == .excluded)
        #expect(f.detectedIDs() == ["DJIMIC3"])
    }

    @Test("規則 3: エントリが symlink なら symlink（本物は検出）")
    func symlinkedVolumeIsSkipped() throws {
        var f = try Fixture()
        try FileManager.default.createSymbolicLink(atPath: f.entryPath("Escape"), withDestinationPath: "DJIMIC3")
        f.register("Escape")
        f.config.excludeVolumes = []
        #expect(f.reason("Escape") == .symlink)
        #expect(f.detectedIDs() == ["DJIMIC3"])
    }

    @Test("規則 4: マウント点でないディレクトリは not_a_mount_point")
    func plainDirectoryIsNotAMountPoint() throws {
        var f = try Fixture()
        f.inspector = FakeMountInspector()
        let result = f.detect()
        #expect(result.devices == [])
        #expect(result.skipped == [SkippedVolume(name: "DJIMIC3", reason: .notAMountPoint, listingError: nil)])
    }

    @Test("規則 5: 列挙できなければ errno によらず not_listable（EACCES）")
    func unlistableVolumeIsNotListableEvenWithEACCES() throws {
        let f = try Fixture()
        let path = f.entryPath("DJIMIC3")
        #expect(chmod(path, 0o000) == 0)
        defer { _ = chmod(path, 0o755) }
        let result = f.detect()
        #expect(result.devices == [])
        #expect(
            result.skipped == [SkippedVolume(name: "DJIMIC3", reason: .notListable, listingError: ErrnoError(EACCES))])
        #expect(result.skipped.first?.reason != .noRecordings)
    }

    @Test("規則 6: 読めるのに空なら no_recordings（陰性対照）")
    func listableEmptyVolumeSaysNoRecordings() throws {
        let f = try Fixture()
        try f.emptyVolume()
        #expect(f.detect().skipped == [SkippedVolume(name: "DJIMIC3", reason: .noRecordings, listingError: nil)])
    }

    @Test("規則 6: 録音の無いディレクトリは no_recordings")
    func directoryWithoutRecordingsIsNotADevice() throws {
        let f = try Fixture()
        try f.emptyVolume()
        try f.volume.addDirectory("Documents")
        #expect(f.reason("DJIMIC3") == .noRecordings)
    }

    @Test("規則 6: フォルダ規則のディレクトリだけでも通る（録音 0 件のデバイス。DEV-19）")
    func emptyRecordingFolderStillCounts() throws {
        let f = try Fixture()
        try f.emptyVolume()
        try f.volume.addDirectory("TX_MIC001_20260912_120950")
        #expect(f.detectedIDs() == ["DJIMIC3"])
    }

    @Test("規則 6: 直下の denoised ファイルでも通る")
    func rootLevelDenoisedFileCounts() throws {
        let f = try Fixture()
        try f.emptyVolume()
        try f.volume.addFile("TX00_MIC001_20260912_120950.wav", data: Data("x".utf8), mtime: FakeVolume.oldMtime)
        #expect(f.detectedIDs() == ["DJIMIC3"])
    }

    @Test("規則 6: `.` で始まるものは数えない")
    func dotEntriesDoNotCount() throws {
        let f = try Fixture()
        try f.emptyVolume()
        try f.volume.addFile(
            "._TX00_MIC001_20260912_120950_orig.wav", data: Data("x".utf8), mtime: FakeVolume.oldMtime)
        try f.volume.addDirectory(".Trashes/TX_MIC001_20260901_101010")
        #expect(f.reason("DJIMIC3") == .noRecordings)
    }

    @Test("規則 6: symlink のフォルダは数えない")
    func symlinkToFolderDoesNotCount() throws {
        let f = try Fixture()
        try f.emptyVolume()
        let outside = f.tmp.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try f.volume.addSymlink("TX_MIC001_20260912_120950", destination: outside.path(percentEncoded: false))
        #expect(f.reason("DJIMIC3") == .noRecordings)
    }

    @Test("規則 6: 日付が不正なファイル名は数えない")
    func invalidDateFileDoesNotCount() throws {
        let f = try Fixture()
        try f.emptyVolume()
        try f.volume.addFile(
            "TX00_MIC001_20260230_120950_orig.wav", data: Data("x".utf8), mtime: FakeVolume.oldMtime)
        #expect(f.reason("DJIMIC3") == .noRecordings)
    }

    @Test("規則 8: ボリューム名と違えば mount_name_mismatch（` 1` 付き）")
    func nameMismatchIsSkipped() throws {
        var f = try Fixture()
        _ = try f.addMountedVolume("DJIMIC3 1")
        f.inspector.volumeNames[f.entryPath("DJIMIC3 1")] = "DJIMIC3"
        #expect(f.reason("DJIMIC3 1") == .mountNameMismatch)
        #expect(f.detectedIDs() == ["DJIMIC3"])
    }

    @Test("規則 8: ボリューム名が取れなければ mount_name_mismatch")
    func missingVolumeNameIsMismatch() throws {
        var f = try Fixture()
        f.inspector.volumeNames = [:]
        #expect(f.detect().skipped == [SkippedVolume(name: "DJIMIC3", reason: .mountNameMismatch, listingError: nil)])
    }

    @Test("規則 8: 名前とボリューム名はスカラー列で比べ、nil は不一致（純粋関数）")
    func nameMatchesVolumeComparesScalars() {
        #expect(!DeviceDetector.nameMatchesVolume("が", volumeName: "か\u{3099}"))
        #expect(!DeviceDetector.nameMatchesVolume("DJIMIC3", volumeName: nil))
        #expect(DeviceDetector.nameMatchesVolume("DJIMIC3", volumeName: "DJIMIC3"))
    }

    @Test("規則 9: `:` を含む名前は invalid_device_id")
    func colonInNameIsInvalidDeviceID() throws {
        var f = try Fixture()
        _ = try f.addMountedVolume("DJI:MIC")
        #expect(f.reason("DJI:MIC") == .invalidDeviceID)
    }

    @Test("規則 9: 空白は可（NO NAME）")
    func spaceInNameIsValid() throws {
        var f = try Fixture()
        _ = try f.addMountedVolume("NO NAME")
        #expect(f.detectedIDs() == ["DJIMIC3", "NO NAME"])
        #expect(f.detect().skipped == [])
    }

    @Test("`.` で始まるエントリは skipped にも入らない")
    func dotEntryIsSilentlyIgnored() throws {
        var f = try Fixture()
        f.config.excludeVolumes = []
        _ = try f.addMountedVolume(".Trashes")
        let result = f.detect()
        #expect(result.skipped == [])
        #expect(result.devices.map(\.deviceID) == ["DJIMIC3"])
    }

    @Test("最初に当たった規則の理由を返す（symlink かつ exclude なら excluded）")
    func ruleOrderIsFixed() throws {
        var f = try Fixture()
        try FileManager.default.createSymbolicLink(atPath: f.entryPath("Escape"), withDestinationPath: "DJIMIC3")
        f.register("Escape")
        f.config.excludeVolumes = ["Escape"]
        #expect(f.reason("Escape") == .excluded)
    }

    @Test("複数デバイスをバイト順で返す")
    func multipleDevicesInByteOrder() throws {
        var f = try Fixture()
        _ = try f.addMountedVolume("DJIMIC4")
        let result = f.detect()
        #expect(result.devices.map(\.deviceID) == ["DJIMIC3", "DJIMIC4"])
        #expect(result.devices.map(\.node) == ["/dev/disk4", "/dev/disk5"])
    }

    @Test("/Volumes 自体が読めなければ 0 台と listingError")
    func volumesRootListingFailure() throws {
        let tmp = try TempDirectory()
        let missing = tmp.url.appendingPathComponent("Volumes", isDirectory: false).path(percentEncoded: false)
        let result = DeviceDetector(
            config: AppConfig.defaults(timeZone: "Asia/Tokyo").device, volumesRoot: missing,
            inspector: FakeMountInspector(), reader: DeviceReader()
        ).detect()
        #expect(result.devices == [])
        #expect(result.skipped == [])
        #expect(result.listingError == ErrnoError(ENOENT))
    }

    @Test("エントリ 0 件なら 0 台（空の状態）")
    func zeroEntriesIsZeroDevices() throws {
        let tmp = try TempDirectory()
        let root = tmp.url.appendingPathComponent("Volumes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = DeviceDetector(
            config: AppConfig.defaults(timeZone: "Asia/Tokyo").device, volumesRoot: root.path(percentEncoded: false),
            inspector: FakeMountInspector(), reader: DeviceReader()
        ).detect()
        #expect(result.devices == [])
        #expect(result.skipped == [])
        #expect(result.listingError == nil)
    }

    @Test("利用者の操作が要る理由は 3 つだけ")
    func needsUserActionIsExactlyThree() {
        #expect(
            DetectionReason.allCases.filter(\.needsUserAction) == [.notListable, .mountNameMismatch, .invalidDeviceID])
    }
}
