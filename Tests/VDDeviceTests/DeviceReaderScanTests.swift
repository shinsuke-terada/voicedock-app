// DeviceReader の走査・stat・原本を開く（T-14 §5.1）。FakeVolume の一時ディレクトリだけを見る（/Volumes に触れない）。
import Darwin
import Foundation
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

    static func failure(_ result: Result<DeviceFileHandle, CopyError>) -> CopyError? {
        if case .failure(let e) = result { return e }
        return nil
    }
}
