// FileHasher の読みのループ（autoreleasepool の中で chunkBytes ずつ）のテスト（F-83。issue #119 の F11）。
import Foundation
import TestSupport
import Testing

@testable import VDCore

@Suite("FileHasher（F-83）")
struct FileHasherChunkTests {
    @Test("F-83 何回にも分けて読んでも SHA-256 はファイル全体のもの（\"a\" × 1,000,000 は FIPS 180-2 の検査値）")
    func chunkedHashMatchesTheTestVector() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("a.bin")
        try Data(repeating: UInt8(ascii: "a"), count: 1_000_000).write(to: url)
        #expect(
            try FileHasher.sha256(of: url, chunkBytes: 4096)
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test("F-83 空のファイルは空の SHA-256（TEST-28）")
    func emptyFile() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("empty.bin")
        try Data().write(to: url)
        #expect(
            try FileHasher.sha256(of: url, chunkBytes: 4096)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
