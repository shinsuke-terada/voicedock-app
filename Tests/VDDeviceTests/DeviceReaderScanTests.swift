// DeviceReader の走査・stat・原本を開く（T-14 §5.1）。FakeVolume の一時ディレクトリだけを見る（/Volumes に触れない）。
import Darwin
import Foundation
import Synchronization
import TestSupport
import Testing

@testable import VDDevice

@Suite("DeviceReader の走査")
struct DeviceReaderScanTests {
    static let orig120950 = "TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav"
    static let orig163444 = "TX_MIC001_20260912_163444/TX00_MIC001_20260912_163444_orig.wav"
    static let denoised163444 = "TX_MIC001_20260912_163444/TX00_MIC001_20260912_163444.wav"
    static let denoised090000 = "TX_MIC002_20260913_090000/TX01_MIC003_20260913_090000.wav"

    static func root(_ fake: FakeVolume) -> String { fake.root.path(percentEncoded: false) }

    @Test("_orig も denoised も relpaths に載り、候補は _orig だけ")
    func listsOrigAndDenoised() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try DefaultDeviceTree.populate(fake)
        let listing = DeviceReader().scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.relpaths == [Self.orig120950, Self.orig163444, Self.denoised163444, Self.denoised090000])
        #expect(listing.origCandidates == [Self.orig120950, Self.orig163444])
        #expect(listing.unparsable.isEmpty)
        #expect(listing.complete)
    }

    @Test("`.` で始まるものは無視し unparsable にも入れない")
    func dotEntriesAreIgnoredSilently() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile(Self.orig120950, mtime: FakeVolume.oldMtime)
        try fake.addNoise(wavBytes: FakeVolume.standardContent)
        let listing = DeviceReader().scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(!listing.relpaths.contains { $0.contains(".Trashes") || $0.contains("._") })
        #expect(listing.relpaths == [Self.orig120950])
        #expect(listing.unparsable.isEmpty)
    }

    @Test("NOTES.txt は無視する")
    func nonRecordingFilesAreIgnored() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile("TX_MIC001_20260912_120950/NOTES.txt", data: Data("memo\n".utf8), mtime: FakeVolume.oldMtime)
        let listing = DeviceReader().scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.relpaths.isEmpty)
        #expect(listing.unparsable.isEmpty)
    }

    @Test("形は一致するが日時が不正なら unparsable")
    func invalidDateIsUnparsable() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        let bad = "TX_MIC001_20260912_120950/TX00_MIC001_20260230_120950_orig.wav"
        try fake.addFile(bad, mtime: FakeVolume.oldMtime)
        let listing = DeviceReader().scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.unparsable == [bad])
        #expect(listing.relpaths.isEmpty)
        #expect(listing.origCandidates.isEmpty)
    }

    @Test("CE device.maxScanDepth より深いファイルは見ない")
    func depthIsBounded() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        let deep = "a/b/c/d/TX00_MIC009_20260101_000000_orig.wav"
        try fake.addFile(deep, mtime: FakeVolume.oldMtime)
        let reader = DeviceReader()
        #expect(!reader.scan(volumeRoot: Self.root(fake), maxDepth: 2).relpaths.contains(deep))
        #expect(!reader.scan(volumeRoot: Self.root(fake), maxDepth: 3).relpaths.contains(deep))
        #expect(reader.scan(volumeRoot: Self.root(fake), maxDepth: 5).relpaths.contains(deep))
    }

    @Test("maxDepth 3 で root/a/b/file まで、root/a/b/c/file は見ない")
    func depthThreeReachesTwoFolders() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        let reachable = "a/b/TX00_MIC001_20260912_120950_orig.wav"
        let beyond = "a/b/c/TX00_MIC001_20260912_130000_orig.wav"
        try fake.addFile(reachable, mtime: FakeVolume.oldMtime)
        try fake.addFile(beyond, mtime: FakeVolume.oldMtime)
        let listing = DeviceReader().scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.relpaths == [reachable])
    }

    @Test("ファイルもディレクトリも symlink は辿らない")
    func symlinksAreNotFollowed() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile(Self.orig120950, mtime: FakeVolume.oldMtime)
        let fileLink = "TX_MIC001_20260912_120950/TX00_MIC001_20260912_120951_orig.wav"
        try fake.addSymlink(fileLink, destination: "TX00_MIC001_20260912_120950_orig.wav")
        let folderLink = "TX_MIC001_20260912_130000"
        try fake.addSymlink(folderLink, destination: "TX_MIC001_20260912_120950")
        let listing = DeviceReader().scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(!listing.relpaths.contains(fileLink))
        #expect(!listing.relpaths.contains { $0.hasPrefix(folderLink) })
        #expect(listing.relpaths == [Self.orig120950])
    }

    @Test("ボリューム直下の録音の relpath はファイル名だけ")
    func rootLevelFileHasNoFolder() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile("TX00_MIC001_20260912_120950_orig.wav", mtime: FakeVolume.oldMtime)
        let listing = DeviceReader().scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.relpaths == ["TX00_MIC001_20260912_120950_orig.wav"])
        #expect(listing.origCandidates == ["TX00_MIC001_20260912_120950_orig.wav"])
    }

    @Test("列挙できないサブディレクトリがあれば complete は偽")
    func unlistableSubdirectoryMakesIncomplete() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile(Self.orig120950, mtime: FakeVolume.oldMtime)
        try fake.addFile(Self.orig163444, mtime: FakeVolume.oldMtime)
        let locked = fake.url("TX_MIC001_20260912_163444").path(percentEncoded: false)
        #expect(chmod(locked, 0o000) == 0)
        defer { _ = chmod(locked, 0o755) }
        let listing = DeviceReader().scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.complete == false)
    }

    @Test("録音 0 件のデバイスは空で complete（DEV-19）")
    func emptyVolumeIsCompleteAndEmpty() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addDirectory("TX_MIC001_20260912_120950")
        let listing = DeviceReader().scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.relpaths.isEmpty)
        #expect(listing.origCandidates.isEmpty)
        #expect(listing.unparsable.isEmpty)
        #expect(listing.complete == true)
    }

    @Test("stat は原本の size と小数付きの mtime")
    func statReturnsFractionalMtime() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile(Self.orig120950, data: Data(repeating: 0x61, count: 1234), mtime: 1_789_214_990.25)
        let stat = DeviceReader().stat(volumeRoot: Self.root(fake), relpath: Self.orig120950)
        #expect(stat == FileStat(size: 1234, mtime: 1_789_214_990.25))
    }

    @Test("symlink と無いファイルの stat は nil")
    func statOfSymlinkIsNil() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile(Self.orig120950, mtime: FakeVolume.oldMtime)
        let link = "TX_MIC001_20260912_120950/TX00_MIC001_20260912_120951_orig.wav"
        try fake.addSymlink(link, destination: "TX00_MIC001_20260912_120950_orig.wav")
        let reader = DeviceReader()
        #expect(reader.stat(volumeRoot: Self.root(fake), relpath: link) == nil)
        #expect(reader.stat(volumeRoot: Self.root(fake), relpath: Self.orig163444) == nil)
    }

    @Test("stat が一致すれば開けて全バイトを読める")
    func openForCopyReadsBytes() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        let content = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
        try fake.addFile(Self.orig120950, data: content, mtime: FakeVolume.oldMtime)
        let expected = FileStat(size: 10_000, mtime: FakeVolume.oldMtime)
        let result = DeviceReader().openForCopy(
            volumeRoot: Self.root(fake), relpath: Self.orig120950, expected: expected)
        guard case .success(let handle) = result else {
            Issue.record("開けなかった: \(result)")
            return
        }
        defer { handle.close() }
        var read = Data()
        while true {
            let chunk = try handle.read(maxBytes: 4096)
            if chunk.isEmpty { break }
            read.append(chunk)
        }
        #expect(read == content)
    }

    @Test("mtime か size が違えば changed")
    func openForCopyDetectsChange() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile(Self.orig120950, data: Data(repeating: 0x61, count: 100), mtime: FakeVolume.oldMtime)
        let reader = DeviceReader()
        let newerMtime = reader.openForCopy(
            volumeRoot: Self.root(fake), relpath: Self.orig120950,
            expected: FileStat(size: 100, mtime: FakeVolume.oldMtime + 2))
        let largerSize = reader.openForCopy(
            volumeRoot: Self.root(fake), relpath: Self.orig120950,
            expected: FileStat(size: 101, mtime: FakeVolume.oldMtime))
        #expect(Self.failure(newerMtime) == .changed)
        #expect(Self.failure(largerSize) == .changed)
    }

    @Test("symlink は ELOOP の read_error")
    func openForCopyRejectsSymlink() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile(Self.orig120950, data: Data(repeating: 0x61, count: 100), mtime: FakeVolume.oldMtime)
        let link = "TX_MIC001_20260912_120950/TX00_MIC001_20260912_120951_orig.wav"
        try fake.addSymlink(link, destination: "TX00_MIC001_20260912_120950_orig.wav")
        let result = DeviceReader().openForCopy(
            volumeRoot: Self.root(fake), relpath: link, expected: FileStat(size: 100, mtime: FakeVolume.oldMtime))
        #expect(Self.failure(result) == .readError(ELOOP))
    }

    @Test("無ければ ENOENT の read_error")
    func openForCopyMissingIsENOENT() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        let result = DeviceReader().openForCopy(
            volumeRoot: Self.root(fake), relpath: Self.orig120950,
            expected: FileStat(size: 100, mtime: FakeVolume.oldMtime))
        #expect(Self.failure(result) == .readError(ENOENT))
    }

    // MARK: - lstat の失敗と一覧の完全さ（#97・PLAN 付録 F の F-67）

    /// lstat の失敗の注入。試みたパスを残し、enabled が偽の間は注入しない（一時的な失敗の再現）
    final class LstatProbe: Sendable {
        private let state = Mutex((calls: [String](), enabled: true))

        var calls: [String] { state.withLock { $0.calls } }

        func setEnabled(_ value: Bool) { state.withLock { $0.enabled = value } }

        /// 試みたパスを残し、注入が有効かを返す
        func record(_ path: String) -> Bool {
            state.withLock { value in
                value.calls.append(path)
                return value.enabled
            }
        }
    }

    /// relpath（ボリュームのルートから）で終わるパスの lstat だけを errno で失敗させ、ほかは本物の lstat を呼ぶ
    static func injectingReader(failing: [String: Int32], probe: LstatProbe = LstatProbe()) -> DeviceReader {
        DeviceReader(lstat: { path, st in
            if probe.record(path) {
                for (rel, code) in failing where path.hasSuffix("/" + rel) { return code }
            }
            return Darwin.lstat(path, &st) == 0 ? 0 : errno
        })
    }

    @Test("lstat が ENOENT 以外で失敗した項目があれば complete は偽", arguments: [EACCES, EIO, EPERM])
    func lstatFailureMakesIncomplete(code: Int32) throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile(Self.orig120950, mtime: FakeVolume.oldMtime)
        try fake.addFile(Self.orig163444, mtime: FakeVolume.oldMtime)
        let listing = Self.injectingReader(failing: [Self.orig163444: code])
            .scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.complete == false)
        #expect(listing.relpaths == [Self.orig120950])
    }

    @Test("フォルダの lstat が失敗しても complete は偽（降りられない）")
    func folderLstatFailureMakesIncomplete() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile(Self.orig120950, mtime: FakeVolume.oldMtime)
        try fake.addFile(Self.orig163444, mtime: FakeVolume.oldMtime)
        let listing = Self.injectingReader(failing: ["TX_MIC001_20260912_163444": EIO])
            .scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.complete == false)
        #expect(listing.relpaths == [Self.orig120950])
    }

    @Test("読めるが辿れないフォルダ（r--）は、中の項目の lstat が EACCES になり complete は偽")
    func searchDeniedFolderMakesIncomplete() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile(Self.orig120950, mtime: FakeVolume.oldMtime)
        try fake.addFile(Self.orig163444, mtime: FakeVolume.oldMtime)
        // opendir / readdir は r だけで通り、lstat は x が無いので EACCES（本物の lstat。注入しない）
        let folder = fake.url("TX_MIC001_20260912_163444").path(percentEncoded: false)
        #expect(chmod(folder, 0o444) == 0)
        defer { _ = chmod(folder, 0o755) }
        let listing = DeviceReader().scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.complete == false)
        #expect(listing.relpaths == [Self.orig120950])
    }

    @Test("列挙から lstat までの間に消えた（ENOENT）項目は飛ばし、complete は真のまま")
    func vanishedEntryIsSkipped() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile(Self.orig120950, mtime: FakeVolume.oldMtime)
        try fake.addFile(Self.orig163444, mtime: FakeVolume.oldMtime)
        let listing = Self.injectingReader(failing: [Self.orig163444: ENOENT])
            .scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.complete == true)
        #expect(listing.relpaths == [Self.orig120950])
        #expect(listing.origCandidates == [Self.orig120950])
    }

    @Test("深さの上限の外は列挙も lstat もせず、complete に影響しない")
    func beyondDepthDoesNotAffectCompleteness() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.addFile(Self.orig120950, mtime: FakeVolume.oldMtime)
        let beyond = "a/b/c/TX00_MIC001_20260912_130000_orig.wav"
        try fake.addFile(beyond, mtime: FakeVolume.oldMtime)
        // 上限ちょうどの階層のフォルダ c は列挙できない（chmod 000）。中の lstat も失敗させる
        let limit = fake.url("a/b/c").path(percentEncoded: false)
        #expect(chmod(limit, 0o000) == 0)
        defer { _ = chmod(limit, 0o755) }
        let probe = LstatProbe()
        let listing = Self.injectingReader(failing: [beyond: EIO], probe: probe)
            .scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.complete == true)
        #expect(listing.relpaths == [Self.orig120950])
        #expect(!probe.calls.contains { $0.hasSuffix("/" + beyond) })
    }

    @Test("録音 0 件・項目 0 件のデバイスは、lstat が全部失敗する注入でも空で complete")
    func emptyVolumeWithFailingLstatIsComplete() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        // `.` で始まる名前だけ（lstat の前に捨てるので、見える項目は 0 件）
        try fake.addFile(".Spotlight-V100/dummy", data: Data([0x00]), mtime: FakeVolume.oldMtime)
        try fake.addFile("._TX00_MIC001_20260912_120950_orig.wav", data: Data([0x00]), mtime: FakeVolume.oldMtime)
        let probe = LstatProbe()
        let reader = DeviceReader(lstat: { path, _ in
            _ = probe.record(path)
            return EIO
        })
        let listing = reader.scan(volumeRoot: Self.root(fake), maxDepth: 3)
        #expect(listing.relpaths.isEmpty)
        #expect(listing.origCandidates.isEmpty)
        #expect(listing.unparsable.isEmpty)
        #expect(listing.complete == true)
        #expect(probe.calls.isEmpty)
    }

    static func failure(_ result: Result<DeviceFileHandle, CopyError>) -> CopyError? {
        if case .failure(let e) = result { return e }
        return nil
    }
}
