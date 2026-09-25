// FakeVolume に macOS が作るノイズを足す（voicedock tests/fixtures/fake_tree.py の _write_noise）。本体は T-07。
import Foundation

extension FakeVolume {
    /// 安定性判定の fast path を必ず通る古い時刻（2026-09-12T12:09:50Z = 1789214990）
    public static let oldMtime: Double = 1_789_214_990

    /// macOS が作るノイズ（voicedock fake_tree.py の _write_noise）を足す: `TX_MIC001_20260912_120950/._TX00_MIC001_20260912_120950_orig.wav`（"Mac OS X\0"×4）、
    /// `.Spotlight-V100/dummy`、`.fseventsd/dummy`、`.Trashes/TX_MIC001_20260901_101010/TX00_MIC001_20260901_101010_orig.wav`（中身 wavBytes）、`TX_MIC001_20260912_120950/NOTES.txt`（"memo\n"）。mtime はすべて oldMtime
    public func addNoise(wavBytes: Data) throws {
        var appleDouble = Data()
        for _ in 0..<4 { appleDouble.append(Data("Mac OS X\0".utf8)) }
        try addFile(
            "TX_MIC001_20260912_120950/._TX00_MIC001_20260912_120950_orig.wav", data: appleDouble,
            mtime: Self.oldMtime)
        try addFile(".Spotlight-V100/dummy", data: Data([0x00]), mtime: Self.oldMtime)
        try addFile(".fseventsd/dummy", data: Data([0x00]), mtime: Self.oldMtime)
        try addFile(
            ".Trashes/TX_MIC001_20260901_101010/TX00_MIC001_20260901_101010_orig.wav", data: wavBytes,
            mtime: Self.oldMtime)
        try addFile("TX_MIC001_20260912_120950/NOTES.txt", data: Data("memo\n".utf8), mtime: Self.oldMtime)
    }
}
