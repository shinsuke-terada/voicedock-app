// FakeVolume のノイズの extension の検査（T-13 §5.5。TEST-05）。本体のテストは T-07 の FakeVolumeTests。
import Foundation
import TestSupport
import Testing

@Suite("FakeVolume のノイズ")
struct FakeVolumeNoiseTests {
    @Test("ノイズの木が fake_tree.py と同じ")
    func noiseMatchesTheRealDevice() throws {
        let tmp = try TempDirectory()
        let volume = try FakeVolume(in: tmp)
        try volume.addNoise(wavBytes: Data("RIFF".utf8))
        let expected: [(String, Data)] = [
            (
                "TX_MIC001_20260912_120950/._TX00_MIC001_20260912_120950_orig.wav",
                Data("Mac OS X\0Mac OS X\0Mac OS X\0Mac OS X\0".utf8)
            ),
            (".Spotlight-V100/dummy", Data([0x00])),
            (".fseventsd/dummy", Data([0x00])),
            (".Trashes/TX_MIC001_20260901_101010/TX00_MIC001_20260901_101010_orig.wav", Data("RIFF".utf8)),
            ("TX_MIC001_20260912_120950/NOTES.txt", Data("memo\n".utf8)),
        ]
        for (relpath, content) in expected {
            let stat = try #require(volume.fileStat(relpath), "\(relpath) が無い")
            #expect(stat.mtime == 1_789_214_990, "\(relpath) の mtime")
            #expect(try Data(contentsOf: volume.url(relpath)) == content, "\(relpath) の中身")
        }
        #expect(FakeVolume.oldMtime == 1_789_214_990)
    }
}
