// voicedock-reaper × FAT32 のディスクイメージ（T-37 §5.4。層 R3。VOICEDOCK_DISK_TESTS=1 のときだけ）。
// イメージは一時ディレクトリの下にだけ attach する（/Volumes には触れない。名前は DJIMIC3 ではなく VDTxxxx。PLAN §10.2）。
// 各テストは弾かせたい条件以外をすべて満たす（TEST-19）。要求の size / mtime は FAT が丸めた実物の値。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract

@Suite(
    "voicedock-reaper × FAT32（層 R3）", .serialized, .enabled(if: TestEnvironment.diskTests), .tags(.diskImage))
struct ReaperDiskImageTests {
    static let id = ReaperBench.requestID
    /// ND-31 の 2 台目
    static let otherDeviceID = "VDT0038"

    /// 共通の準備: FAT32 のイメージとその上の舞台
    static func bench(_ tmp: TempDirectory) throws -> ReaperBench {
        let image = try DiskImageVolume(in: tmp, deviceID: ReaperBench.deviceID, filesystem: .fat32)
        return try ReaperBench(in: tmp, diskImage: image)
    }

    static func logged(_ bench: ReaperBench, _ tail: String) -> Bool {
        bench.logLines().contains { $0.hasSuffix(" " + tail) }
    }

    /// 拒否の共通の期待: detail が理由語、要求が消える
    static func expectRefused(_ bench: ReaperBench, _ reason: String) throws {
        let run = try bench.run()
        #expect(run.exitCode == 0)
        let result = try bench.result(id)
        #expect(result.status == .sourceIdentityMismatch)
        #expect(result.detail == reason)
        #expect(bench.requests() == [])
    }

    @Test("正の対照: 通る要求は本当に消える")
    func aValidRequestActuallyDeletes() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        try bench.writeRequest()
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(!bench.sourceExists())
        let result = try bench.result(Self.id)
        #expect(result.status == .deleted)
        #expect(result.detail == ReaperBench.relpath)
        #expect(result.partkey == "VDT0037/" + ReaperBench.relpath)
        #expect(bench.processedLines() == [Self.id])
        #expect(bench.requests() == [])
        #expect(
            Self.logged(bench, "INFO  source_deleted request_id=\(Self.id) partkey=VDT0037/" + ReaperBench.relpath))
    }

    @Test("ND-18 [R3] 削除直前にサイズが変わると size_mismatch")
    func nd18SizeMismatchBlocksTheDelete() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let actual = try bench.actualStat()
        try bench.writeRequest(size: actual.size + 1, mtime: actual.mtime)
        try Self.expectRefused(bench, "size_mismatch")
        #expect(bench.sourceExists())
    }

    @Test("ND-19 [R3] 削除直前に mtime が変わると mtime_mismatch")
    func nd19MtimeMismatchBlocksTheDelete() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let actual = try bench.actualStat()
        try bench.writeRequest(size: actual.size, mtime: actual.mtime + 4.0)
        try Self.expectRefused(bench, "mtime_mismatch")
        #expect(bench.sourceExists())
    }

    @Test("対照: mtime の差が 2 秒未満なら消える")
    func aSmallMtimeDriftIsTolerated() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let actual = try bench.actualStat()
        try bench.writeRequest(size: actual.size, mtime: actual.mtime + 1.0)
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(!bench.sourceExists())
        #expect(try bench.result(Self.id).status == .deleted)
    }

    @Test("FAT の mtime は 2 秒刻み（実物の値を使う）")
    func fatMtimeHasTwoSecondResolution() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let mtime = try bench.actualStat().mtime
        #expect(mtime.truncatingRemainder(dividingBy: 2) == 0)
        #expect(mtime.rounded(.down) == mtime)
    }

    @Test("ND-20 [R3] 対象自身が symlink なら target_is_symlink")
    func nd20ASymlinkTargetIsNeverDeleted() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let realName = ReaperBench.folder + "/TX00_MIC001_20260912_090000_real.wav"
        try bench.placeSource(realName)
        let link = bench.deviceRoot.appendingPathComponent(ReaperBench.relpath)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            atPath: link.path(percentEncoded: false), withDestinationPath: "TX00_MIC001_20260912_090000_real.wav")
        let real = try bench.actualStat(realName)
        try bench.writeRequest(size: real.size, mtime: real.mtime)
        try Self.expectRefused(bench, "target_is_symlink")
        #expect(bench.sourceExists())
        #expect(bench.sourceExists(realName))
    }

    @Test("ND-25 [R3] 経路の途中が symlink なら path_contains_symlink")
    func nd25ASymlinkInThePathIsNotFollowed() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let folder = bench.deviceRoot.appendingPathComponent(ReaperBench.folder, isDirectory: true)
        try FileManager.default.removeItem(at: folder)
        try bench.placeSource("REAL/" + ReaperBench.fileName)
        try FileManager.default.createSymbolicLink(
            atPath: folder.path(percentEncoded: false), withDestinationPath: "REAL")
        try bench.writeRequest()
        try Self.expectRefused(bench, "path_contains_symlink")
        #expect(bench.sourceExists("REAL/" + ReaperBench.fileName))
    }

    @Test("ND-24 [R3] relpath に ../ があれば relpath_unsafe")
    func nd24ATraversalRelpathIsRefused() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let relpath = ReaperBench.folder + "/../" + ReaperBench.relpath
        try bench.writeRequest(relpath: relpath)
        try Self.expectRefused(bench, "relpath_unsafe")
        #expect(bench.sourceExists())
    }

    @Test(
        "ND-28 [R3] . で始まる要素があれば relpath_unsafe",
        arguments: [".Trashes/" + ReaperBench.fileName, ReaperBench.folder + "/." + ReaperBench.fileName])
    func nd28ADotPrefixedElementIsRefused(_ relpath: String) throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        try bench.placeSource(relpath)
        try bench.writeRequest(relpath: relpath)
        try Self.expectRefused(bench, "relpath_unsafe")
        #expect(bench.sourceExists(relpath))
    }

    @Test("ND-23 [R3] 読み取り専用で再マウントされていたら要求を残す（RV-07）")
    func nd23AReadOnlyMountLeavesTheRequest() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let name = try bench.writeRequest()
        let image = try #require(bench.image)
        try image.reattach(readOnly: true)
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(bench.requests() == [name])
        #expect(bench.results() == [])
        #expect(bench.processedLines() == [])
        #expect(Self.logged(bench, "WARN  mount_readonly request_id=\(Self.id) device=VDT0037"))
        #expect(bench.sourceExists())
    }

    @Test("ND-29 [R3] 親フォルダ名が規則外なら folder_rule")
    func nd29AFolderThatBreaksTheRuleIsRefused() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let relpath = "OTHER/" + ReaperBench.fileName
        try bench.placeSource(relpath)
        try bench.writeRequest(relpath: relpath)
        try Self.expectRefused(bench, "folder_rule")
        #expect(bench.sourceExists(relpath))
    }

    @Test("ND-29 [R3] ボリューム直下のファイルは常に folder_rule")
    func nd29AFileAtTheVolumeRootIsRefused() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let relpath = ReaperBench.fileName
        try bench.placeSource(relpath)
        try bench.writeRequest(relpath: relpath)
        try Self.expectRefused(bench, "folder_rule")
        #expect(bench.sourceExists(relpath))
    }

    @Test("ND-37 [R3] _orig の無いファイルは filename_rule")
    func nd37ADenoisedFileIsRefused() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let relpath = ReaperBench.folder + "/TX00_MIC001_20260912_090000.wav"
        try bench.placeSource(relpath)
        try bench.writeRequest(relpath: relpath)
        try Self.expectRefused(bench, "filename_rule")
        #expect(bench.sourceExists(relpath))
    }

    @Test("ND-31 [R3] device_id だけが違う同名ファイルは消さない")
    func nd31AnotherDeviceIsNotTouched() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let other = try DiskImageVolume(in: tmp, deviceID: Self.otherDeviceID, filesystem: .fat32)
        let otherFile = other.mountPoint.appendingPathComponent(ReaperBench.relpath)
        try FileManager.default.createDirectory(
            at: otherFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ReaperBench.content.write(to: otherFile)
        try bench.writeRequest()
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(!bench.sourceExists())
        #expect(FileManager.default.fileExists(atPath: otherFile.path(percentEncoded: false)))
        withExtendedLifetime(other) {}
    }

    @Test("ND-39 [R3] HFS+ のイメージは unexpected_fs")
    func nd39AnHfsImageIsUnexpectedFS() throws {
        let tmp = try TempDirectory()
        let image = try DiskImageVolume(in: tmp, deviceID: ReaperBench.deviceID, filesystem: .hfsPlus)
        let bench = try ReaperBench(in: tmp, diskImage: image)
        try bench.writeRequest()
        try Self.expectRefused(bench, "unexpected_fs")
        #expect(bench.sourceExists())
    }

    @Test("RV-09 対象が無ければ target_missing")
    func rv09AMissingTargetIsRefused() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        try bench.writeRequest()
        try FileManager.default.removeItem(at: bench.deviceRoot.appendingPathComponent(ReaperBench.relpath))
        try Self.expectRefused(bench, "target_missing")
    }

    @Test("RV-09 経路の途中が無ければ target_missing")
    func rv09AMissingDirectoryIsRefused() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        try bench.writeRequest()
        try FileManager.default.removeItem(
            at: bench.deviceRoot.appendingPathComponent(ReaperBench.folder, isDirectory: true))
        try Self.expectRefused(bench, "target_missing")
    }

    @Test("RV-10 対象がディレクトリなら not_regular_file")
    func rv10ADirectoryIsNotARegularFile() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let target = bench.deviceRoot.appendingPathComponent(ReaperBench.relpath, isDirectory: true)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try bench.writeRequest()
        try Self.expectRefused(bench, "not_regular_file")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: target.path(percentEncoded: false), isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("RV-13 unlink の後に不在を確かめる")
    func rv13TheAbsenceIsVerifiedAfterUnlink() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        try bench.writeRequest()
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(try bench.result(Self.id).status == .deleted)
        var st = stat()
        let path = bench.deviceRoot.appendingPathComponent(ReaperBench.relpath).path(percentEncoded: false)
        // errno は #expect の中の処理で上書きされ得るので、先に受けてから比べる
        let rc = lstat(path, &st)
        let e = errno
        #expect(rc != 0)
        #expect(e == ENOENT)
    }

    @Test("2 件の要求が両方とも消える（走査の続き）")
    func twoRequestsAreBothDeleted() throws {
        let tmp = try TempDirectory()
        let bench = try Self.bench(tmp)
        let second = ReaperBench.folder + "/TX00_MIC001_20260912_091000_orig.wav"
        try bench.placeSource(second)
        try bench.writeRequest()
        try bench.writeRequest(requestID: "20260912T091000Z-a5d046dce76cfedc-a1b2c4", relpath: second)
        let run = try bench.run()
        #expect(run.exitCode == 0)
        #expect(!bench.sourceExists())
        #expect(!bench.sourceExists(second))
        #expect(Self.logged(bench, "INFO  reaper_completed requests=2"))
    }
}
