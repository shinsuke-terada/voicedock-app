// TargetIdentity の検査（T-07 §5.1。層 R2）。
import Darwin
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("TargetIdentity")
struct TargetIdentityTests {
    static let folder = "TX_MIC001_20260912_090000"
    static let file = "TX00_MIC001_20260912_090000_orig.wav"
    static let rel = folder + "/" + file
    static let size: Int64 = 4096
    static let mtime = 1_787_000_000.0

    /// ベンチ（voicedock の reaper ベンチと同じ値）。tmp を保持して一時ディレクトリを生かしておく。
    struct Bench {
        let tmp: TempDirectory
        let fake: FakeVolume
        let volume: VolumeHandle

        /// 期待値はベンチの既定（4096 バイト・MTIME）。body の呼び出し回数も返す。
        func verify(
            relpath: String = TargetIdentityTests.rel, expectedSize: Int64 = TargetIdentityTests.size,
            expectedMtime: Double = TargetIdentityTests.mtime
        ) -> (result: Result<Int, IdentityMismatch>, calls: Int) {
            var calls = 0
            let result = TargetIdentity.withVerifiedTarget(
                volume: volume, relpath: relpath, expectedSize: expectedSize, expectedMtime: expectedMtime
            ) { _ in
                calls += 1
                return 42
            }
            return (result, calls)
        }

        /// ボリュームの外（tmp/outside）の URL
        func outside(_ relpath: String) -> URL {
            tmp.url.appendingPathComponent("outside").appendingPathComponent(relpath)
        }

        /// ボリュームの中の要素を消す（準備で置き換えるため）
        func remove(_ relpath: String) throws {
            try FileManager.default.removeItem(at: fake.url(relpath))
        }
    }

    static func makeBench() throws -> Bench {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp, deviceID: "DJIMIC3")
        try fake.addFile(rel, data: FakeVolume.standardContent, mtime: mtime)
        let opened = FakeVolumeOpener().open(
            volumesRoot: fake.volumesRoot.path(percentEncoded: false), deviceID: "DJIMIC3")
        guard case .opened(let volume) = opened else {
            Issue.record("FakeVolumeOpener がベンチのボリュームを開けなかった")
            throw POSIXError(.ENOENT)
        }
        return Bench(tmp: tmp, fake: fake, volume: volume)
    }

    /// 失敗なら理由語、成功なら nil
    static func reason(_ result: Result<Int, IdentityMismatch>) -> String? {
        if case .failure(let mismatch) = result { return mismatch.reason }
        return nil
    }

    /// VolumeOpenResult を比べられる文字列にする（opened / absent / 理由語）
    static func describe(_ result: VolumeOpenResult) -> String {
        switch result {
        case .opened: return "opened"
        case .absent: return "absent"
        case .rejected(let mismatch): return mismatch.reason
        }
    }

    /// 外のファイルを置く（ベンチと同じ中身と mtime）
    static func writeOutside(_ bench: Bench, _ relpath: String) throws -> URL {
        let url = bench.outside(relpath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FakeVolume.standardContent.write(to: url)
        var times = [timeval(tv_sec: 1_787_000_000, tv_usec: 0), timeval(tv_sec: 1_787_000_000, tv_usec: 0)]
        #expect(utimes(url.path(percentEncoded: false), &times) == 0)
        return url
    }

    // MARK: - openVolume

    @Test("RV-06 普通のディレクトリはマウント点ではない")
    func rv06PlainDirectoryIsNotAMountPoint() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        let result = TargetIdentity.openVolume(
            volumesRoot: fake.volumesRoot.path(percentEncoded: false), deviceID: "DJIMIC3")
        #expect(Self.describe(result) == "not_a_mount_point")
    }

    @Test("RV-06 無いデバイスは device_absent")
    func rv06MissingDeviceIsAbsent() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        let result = TargetIdentity.openVolume(
            volumesRoot: fake.volumesRoot.path(percentEncoded: false), deviceID: "NOPE")
        #expect(Self.describe(result) == "absent")
    }

    @Test("RV-06 ボリュームの親が無ければ absent")
    func rv06MissingVolumesRootIsAbsent() throws {
        let tmp = try TempDirectory()
        let missing = tmp.url.appendingPathComponent("no-such-volumes").path(percentEncoded: false)
        let result = TargetIdentity.openVolume(volumesRoot: missing, deviceID: "DJIMIC3")
        #expect(Self.describe(result) == "absent")
    }

    @Test("RV-06 symlink のボリュームは not_a_mount_point")
    func rv06SymlinkVolumeIsRejected() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try FileManager.default.createSymbolicLink(
            atPath: fake.volumesRoot.appendingPathComponent("ESCAPE").path(percentEncoded: false),
            withDestinationPath: "DJIMIC3")
        let result = TargetIdentity.openVolume(
            volumesRoot: fake.volumesRoot.path(percentEncoded: false), deviceID: "ESCAPE")
        #expect(Self.describe(result) == "not_a_mount_point")
    }

    @Test("RV-06 ファイルのボリュームは not_a_mount_point")
    func rv06FileAsVolumeIsRejected() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try Data("x".utf8).write(to: fake.volumesRoot.appendingPathComponent("FILEVOL"))
        let result = TargetIdentity.openVolume(
            volumesRoot: fake.volumesRoot.path(percentEncoded: false), deviceID: "FILEVOL")
        #expect(Self.describe(result) == "not_a_mount_point")
    }

    @Test("RV-06 不正な device_id は not_a_mount_point（パラメータ化）", arguments: ["", "a:b", ".x", "a/b", "DJIMIC3/.."])
    func rv06InvalidDeviceIDIsRejected(deviceID: String) throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        // "a/b" と "DJIMIC3/.." が実在のディレクトリに届くようにしておく（ファイルシステムに触れる前に弾くことを見る）
        try FileManager.default.createDirectory(
            at: fake.volumesRoot.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        let result = TargetIdentity.openVolume(
            volumesRoot: fake.volumesRoot.path(percentEncoded: false), deviceID: deviceID)
        #expect(Self.describe(result) == "not_a_mount_point")
    }

    @Test("SystemVolumeOpener は openVolume と同じ結果")
    func systemVolumeOpenerDelegates() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        let root = fake.volumesRoot.path(percentEncoded: false)
        let opener = SystemVolumeOpener()

        let plain = opener.open(volumesRoot: root, deviceID: "DJIMIC3")
        #expect(Self.describe(plain) == "not_a_mount_point")
        #expect(
            Self.describe(plain) == Self.describe(TargetIdentity.openVolume(volumesRoot: root, deviceID: "DJIMIC3")))

        let missing = opener.open(volumesRoot: root, deviceID: "NOPE")
        #expect(Self.describe(missing) == "absent")
        #expect(Self.describe(missing) == Self.describe(TargetIdentity.openVolume(volumesRoot: root, deviceID: "NOPE")))
    }

    // MARK: - withVerifiedTarget

    @Test("正の対照 [R2] 正しい対象なら body が呼ばれ、親 fd と名前を渡す")
    func positiveControl() throws {
        let bench = try Self.makeBench()
        var calls = 0
        var statResult: Int32 = -1
        var seenName = ""
        let result = TargetIdentity.withVerifiedTarget(
            volume: bench.volume, relpath: Self.rel, expectedSize: 4096, expectedMtime: 1_787_000_000.0
        ) { target in
            calls += 1
            var st = stat()
            statResult = fstatat(target.parentFD, target.name, &st, AT_SYMLINK_NOFOLLOW)
            seenName = target.name
            return 42
        }
        #expect(result == .success(42))
        #expect(calls == 1)
        #expect(statResult == 0)
        #expect(seenName == "TX00_MIC001_20260912_090000_orig.wav")
    }

    @Test(
        "RV-08 不健全な relpath は relpath_unsafe（パラメータ化）",
        arguments: ["", "/abs", "a//b", "./" + rel, folder + "/../" + rel])
    func rv08UnsafeRelpath(relpath: String) throws {
        let bench = try Self.makeBench()
        let outcome = bench.verify(relpath: relpath)
        #expect(Self.reason(outcome.result) == "relpath_unsafe")
        #expect(outcome.calls == 0)
    }

    @Test("ND-24 [R2] relpath に ../ があれば relpath_unsafe")
    func nd24ParentTraversal() throws {
        let bench = try Self.makeBench()
        let outsideFile = try Self.writeOutside(bench, Self.rel)
        let outcome = bench.verify(relpath: "../../outside/" + Self.rel)
        #expect(Self.reason(outcome.result) == "relpath_unsafe")
        #expect(outcome.calls == 0)
        #expect(FileManager.default.fileExists(atPath: outsideFile.path(percentEncoded: false)))
    }

    @Test("ND-28 [R2] . 始まりの要素は relpath_unsafe")
    func nd28DotPrefixed() throws {
        let bench = try Self.makeBench()
        let trashed = ".Trashes/501/" + Self.file
        try bench.fake.addFile(trashed, mtime: Self.mtime)
        let outcome = bench.verify(relpath: trashed)
        #expect(Self.reason(outcome.result) == "relpath_unsafe")
        #expect(outcome.calls == 0)
        #expect(bench.fake.fileStat(trashed) != nil)
    }

    @Test("RV-09 経路の途中の symlink は path_contains_symlink")
    func rv09IntermediateSymlink() throws {
        let bench = try Self.makeBench()
        try bench.remove(Self.folder)
        try bench.fake.addFile("real/" + Self.file, mtime: Self.mtime)
        try bench.fake.addSymlink(Self.folder, destination: "real")
        let outcome = bench.verify()
        #expect(Self.reason(outcome.result) == "path_contains_symlink")
        #expect(outcome.calls == 0)
    }

    @Test("ND-25 [R2] symlink 経由でボリュームの外を指せば path_contains_symlink")
    func nd25SymlinkEscapesVolume() throws {
        let bench = try Self.makeBench()
        try bench.remove(Self.folder)
        let outsideFile = try Self.writeOutside(bench, Self.rel)
        let outsideFolder = outsideFile.deletingLastPathComponent().path(percentEncoded: false)
        try bench.fake.addSymlink(Self.folder, destination: outsideFolder)
        let outcome = bench.verify()
        #expect(Self.reason(outcome.result) == "path_contains_symlink")
        #expect(outcome.calls == 0)
        #expect(FileManager.default.fileExists(atPath: outsideFile.path(percentEncoded: false)))
    }

    @Test("ND-20 [R2] 対象自身か経路の途中に symlink があれば他の場所に触れない（パラメータ化）", arguments: ["a", "b"])
    func nd20SymlinkInPath(variant: String) throws {
        let bench = try Self.makeBench()
        let expected: String
        if variant == "a" {
            // (a) FILE を別の実ファイルへの symlink
            let other = Self.folder + "/TX00_MIC001_20260912_090002_orig.wav"
            try bench.fake.addFile(other, mtime: Self.mtime)
            try bench.remove(Self.rel)
            try bench.fake.addSymlink(Self.rel, destination: "TX00_MIC001_20260912_090002_orig.wav")
            expected = "target_is_symlink"
        } else {
            // (b) FOLDER を symlink
            try bench.remove(Self.folder)
            try bench.fake.addFile("real/" + Self.file, mtime: Self.mtime)
            try bench.fake.addSymlink(Self.folder, destination: "real")
            expected = "path_contains_symlink"
        }
        let outcome = bench.verify()
        #expect(Self.reason(outcome.result) == expected)
        #expect(outcome.calls == 0)
    }

    @Test("RV-09 経路の途中が通常ファイルなら path_contains_symlink")
    func rv09IntermediateRegularFile() throws {
        let bench = try Self.makeBench()
        try bench.remove(Self.folder)
        try bench.fake.addFile(Self.folder, mtime: Self.mtime)
        let outcome = bench.verify()
        #expect(Self.reason(outcome.result) == "path_contains_symlink")
        #expect(outcome.calls == 0)
    }

    @Test("RV-09 対象が無ければ target_missing（パラメータ化）", arguments: ["a", "b"])
    func rv09MissingTarget(variant: String) throws {
        let bench = try Self.makeBench()
        // (a) ファイルを消す、(b) FOLDER ごと無い
        try bench.remove(variant == "a" ? Self.rel : Self.folder)
        let outcome = bench.verify()
        #expect(Self.reason(outcome.result) == "target_missing")
        #expect(outcome.calls == 0)
    }

    @Test("RV-10 対象が symlink なら target_is_symlink")
    func rv10TargetIsSymlink() throws {
        let bench = try Self.makeBench()
        try bench.fake.addFile(Self.folder + "/TX00_MIC001_20260912_090002_orig.wav", mtime: Self.mtime)
        try bench.remove(Self.rel)
        try bench.fake.addSymlink(Self.rel, destination: "TX00_MIC001_20260912_090002_orig.wav")
        let outcome = bench.verify()
        #expect(Self.reason(outcome.result) == "target_is_symlink")
        #expect(outcome.calls == 0)
    }

    @Test("RV-10 通常ファイルでなければ not_regular_file（パラメータ化）", arguments: ["a", "b"])
    func rv10NotRegularFile(variant: String) throws {
        let bench = try Self.makeBench()
        try bench.remove(Self.rel)
        if variant == "a" {
            // (a) FILE の名前のディレクトリ
            try bench.fake.addDirectory(Self.rel)
        } else {
            // (b) FILE の名前の FIFO
            try bench.fake.addFIFO(Self.rel)
        }
        let outcome = bench.verify()
        #expect(Self.reason(outcome.result) == "not_regular_file")
        #expect(outcome.calls == 0)
    }

    @Test(
        "RV-11 ファイル名が _orig の規則に合わなければ filename_rule（パラメータ化）",
        arguments: [
            "TX00_MIC001_20260912_090000.wav", "TX00_MIC001_20260912_090000_orig.wav.partial", "notes.txt",
        ])
    func rv11FilenameRule(name: String) throws {
        let bench = try Self.makeBench()
        let relpath = Self.folder + "/" + name
        try bench.fake.addFile(relpath, mtime: Self.mtime)
        let outcome = bench.verify(relpath: relpath)
        #expect(Self.reason(outcome.result) == "filename_rule")
        #expect(outcome.calls == 0)
    }

    @Test("ND-37 [R2] denoised のファイルは filename_rule")
    func nd37Denoised() throws {
        let bench = try Self.makeBench()
        let relpath = Self.folder + "/TX00_MIC001_20260912_090000.wav"
        try bench.fake.addFile(relpath, mtime: Self.mtime)
        let outcome = bench.verify(relpath: relpath)
        #expect(Self.reason(outcome.result) == "filename_rule")
        #expect(outcome.calls == 0)
        #expect(bench.fake.fileStat(relpath) != nil)
    }

    @Test("RV-11 親フォルダ名が規則に合わなければ folder_rule（パラメータ化）", arguments: ["a", "b"])
    func rv11FolderRule(variant: String) throws {
        let bench = try Self.makeBench()
        // (a) フォルダ other、(b) ボリューム直下の FILE（relpath 1 要素）
        let relpath = variant == "a" ? "other/" + Self.file : Self.file
        try bench.fake.addFile(relpath, mtime: Self.mtime)
        let outcome = bench.verify(relpath: relpath)
        #expect(Self.reason(outcome.result) == "folder_rule")
        #expect(outcome.calls == 0)
    }

    @Test("ND-29 [R2] 親フォルダ名が規則外なら folder_rule")
    func nd29BadFolder() throws {
        let bench = try Self.makeBench()
        let relpath = "TX_MIC001_2026091_090000/" + Self.file
        try bench.fake.addFile(relpath, mtime: Self.mtime)
        let outcome = bench.verify(relpath: relpath)
        #expect(Self.reason(outcome.result) == "folder_rule")
        #expect(outcome.calls == 0)
        #expect(bench.fake.fileStat(relpath) != nil)
    }

    @Test("RV-12 size が違えば size_mismatch")
    func rv12SizeMismatch() throws {
        let bench = try Self.makeBench()
        let outcome = bench.verify(expectedSize: 4097)
        #expect(Self.reason(outcome.result) == "size_mismatch")
        #expect(outcome.calls == 0)
    }

    @Test("ND-18 [R2] 削除直前にサイズが変わると size_mismatch")
    func nd18SizeChangedJustBeforeDeletion() throws {
        let bench = try Self.makeBench()
        let recorded = try #require(bench.fake.fileStat(Self.rel))
        let handle = try FileHandle(forWritingTo: bench.fake.url(Self.rel))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x78]))
        try handle.close()
        try bench.fake.setMtime(Self.rel, Self.mtime)
        #expect(bench.fake.fileStat(Self.rel)?.size == 4097)
        let outcome = bench.verify(expectedSize: recorded.size, expectedMtime: recorded.mtime)
        #expect(Self.reason(outcome.result) == "size_mismatch")
        #expect(outcome.calls == 0)
    }

    @Test(
        "RV-12 mtime の差が 2.0 以上なら mtime_mismatch（パラメータ化）",
        arguments: [
            (2.0, false), (-2.0, false), (120.0, false), (1.999, true), (-1.999, true), (1.0, true), (0.0, true),
        ])
    func rv12MtimeBoundary(delta: Double, matches: Bool) throws {
        let bench = try Self.makeBench()
        let outcome = bench.verify(expectedMtime: 1_787_000_000.0 + delta)
        if matches {
            #expect(outcome.result == .success(42))
            #expect(outcome.calls == 1)
        } else {
            #expect(Self.reason(outcome.result) == "mtime_mismatch")
            #expect(outcome.calls == 0)
        }
    }

    @Test("RV-12 期待する mtime が NaN なら不一致（fail-closed）")
    func rv12NaNExpectedMtime() throws {
        let bench = try Self.makeBench()
        let outcome = bench.verify(expectedMtime: .nan)
        #expect(Self.reason(outcome.result) == "mtime_mismatch")
        #expect(outcome.calls == 0)
    }

    @Test("ND-19 [R2] 削除直前に mtime が変わると mtime_mismatch")
    func nd19MtimeChangedJustBeforeDeletion() throws {
        let bench = try Self.makeBench()
        let recorded = try #require(bench.fake.fileStat(Self.rel))
        try bench.fake.setMtime(Self.rel, Self.mtime + 120)
        let outcome = bench.verify(expectedSize: recorded.size, expectedMtime: recorded.mtime)
        #expect(Self.reason(outcome.result) == "mtime_mismatch")
        #expect(outcome.calls == 0)
    }

    @Test("検査の順序（パラメータ化）", arguments: ["a", "b", "c"])
    func checksRunInOrder(variant: String) throws {
        let bench = try Self.makeBench()
        let relpath: String
        let expected: String
        switch variant {
        case "a":
            // (a) denoised の名前で size も違う
            relpath = Self.folder + "/TX00_MIC001_20260912_090000.wav"
            try bench.fake.addFile(relpath, data: Data(repeating: 0x78, count: 10), mtime: Self.mtime)
            expected = "filename_rule"
        case "b":
            // (b) フォルダも名前も違う
            relpath = "other/TX00_MIC001_20260912_090000.wav"
            try bench.fake.addFile(relpath, mtime: Self.mtime)
            expected = "filename_rule"
        default:
            // (c) symlink で名前も違う
            relpath = Self.folder + "/notes.txt"
            try bench.fake.addSymlink(relpath, destination: Self.file)
            expected = "target_is_symlink"
        }
        let outcome = bench.verify(relpath: relpath)
        #expect(Self.reason(outcome.result) == expected)
        #expect(outcome.calls == 0)
    }

    @Test("不一致のとき body を呼ばない")
    func bodyNotCalledOnMismatch() throws {
        let bench = try Self.makeBench()
        let outcome = bench.verify(expectedSize: 1)
        #expect(Self.reason(outcome.result) == "size_mismatch")
        #expect(outcome.calls == 0)
    }

    @Test("理由語の一覧（付録 B.2）")
    func reasonsAreVerbatim() {
        let expected = [
            "lock1", "conf_invalid", "malformed_request_id", "malformed_request", "replayed", "partkey_mismatch",
            "device_absent", "not_a_mount_point", "unexpected_fs", "mount_readonly", "relpath_unsafe",
            "path_contains_symlink", "target_missing", "target_is_symlink", "not_regular_file", "filename_rule",
            "folder_rule", "size_mismatch", "mtime_mismatch", "unlink_failed", "still_present",
        ]
        #expect(IdentityReason.all == expected)
        #expect(IdentityReason.all.count == 21)
        #expect(Set(IdentityReason.all).count == 21)
    }
}
