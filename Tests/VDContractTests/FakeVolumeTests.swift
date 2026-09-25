// FakeVolume・FakeVolumeOpener そのものの検査（T-07 §5.3。TEST-05）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("FakeVolume")
struct FakeVolumeTests {
    static let allFiles =
        FakeVolume.StandardTree.origInScope + FakeVolume.StandardTree.denoised
        + FakeVolume.StandardTree.beyondDepth + FakeVolume.StandardTree.hidden

    @Test("標準の木が StandardTree のとおり")
    func standardTreeLayout() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.populateStandardTree(copyTime: 1_787_016_440)
        #expect(Self.allFiles.count == 9)
        for relpath in Self.allFiles {
            #expect(fake.fileStat(relpath) != nil, "\(relpath) が無い")
        }
        for relpath in FakeVolume.StandardTree.origInScope + FakeVolume.StandardTree.denoised
            + FakeVolume.StandardTree.beyondDepth
        {
            #expect(fake.fileStat(relpath)?.size == 4096)
        }
        for relpath in FakeVolume.StandardTree.hidden {
            #expect(fake.fileStat(relpath)?.size == 82)
        }
        let link = fake.url("TX_MIC001_20260829_080001").path(percentEncoded: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: link)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "TX_MIC001_20260829_071201")
    }

    @Test("原本の mtime はコピー時刻の 4 時間 34 分前")
    func deviceMtimeIsOffset() throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        try fake.populateStandardTree(copyTime: 1_787_016_440)
        for relpath in Self.allFiles {
            #expect(fake.fileStat(relpath)?.mtime == 1_787_000_000, "\(relpath) の mtime")
        }
    }

    @Test("候補の名前は規則に一致する")
    func origNamesParse() {
        for relpath in FakeVolume.StandardTree.origInScope {
            let name = RelPath.lastComponent(relpath)
            #expect(RecordingName.parseFile(name)?.isOrig == true, "\(name)")
        }
    }

    @Test("FakeVolumeOpener は普通のディレクトリを開く", arguments: [false, true])
    func fakeOpenerSkipsMountCheck(readOnly: Bool) throws {
        let tmp = try TempDirectory()
        let fake = try FakeVolume(in: tmp)
        let result = FakeVolumeOpener(readOnly: readOnly).open(
            volumesRoot: fake.volumesRoot.path(percentEncoded: false), deviceID: "DJIMIC3")
        guard case .opened(let handle) = result else {
            Issue.record("開けなかった")
            return
        }
        #expect(handle.readOnly == readOnly)
    }

    @Test("DiskImageVolume は実機に触れ得る名前を hdiutil の前に拒む", arguments: ["VOICEDOCK", "DJIMIC3", "", "../x", "a:b"])
    func diskImageVolumeRefusesUnsafeNames(_ deviceID: String) throws {
        let tmp = try TempDirectory()
        #expect(throws: DiskImageError.self) { try DiskImageVolume(in: tmp, deviceID: deviceID) }
        #expect(
            !FileManager.default.fileExists(
                atPath: tmp.url.appendingPathComponent("Volumes").path(percentEncoded: false)))
    }
}
