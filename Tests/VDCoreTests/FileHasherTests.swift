// FileHasher の検査（T-10）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("FileHasher")
struct FileHasherTests {
    @Test("ファイルの SHA-256 はデータの SHA-256 と同じ")
    func sha256OfFileMatchesData() throws {
        let temp = try TempDirectory()
        let data = Data((0..<(3 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let file = temp.url.appendingPathComponent("data.bin")
        try data.write(to: file)
        let whole = FileHasher.sha256(data)
        #expect(whole.count == 64)
        #expect(try FileHasher.sha256(of: file, chunkBytes: 1024 * 1024) == whole)
        #expect(try FileHasher.sha256(of: file, chunkBytes: 7) == whole)

        let empty = temp.url.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(try FileHasher.sha256(of: empty, chunkBytes: 1024) == emptyHash)
        #expect(FileHasher.sha256(Data()) == emptyHash)

        #expect(throws: (any Error).self) {
            try FileHasher.sha256(of: temp.url.appendingPathComponent("missing.bin"), chunkBytes: 1024)
        }
    }

    @Test("16 進は小文字")
    func sha256Lowercase() {
        #expect(
            FileHasher.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
