// ファイルとデータの SHA-256（小文字 16 進 64 文字）。
import CryptoKit
import Foundation

public enum FileHasher {
    /// ファイル全体の SHA-256（小文字 16 進 64 文字）。`FileHandle(forReadingFrom:)` で chunkBytes ずつ読む。読めなければ投げる。
    /// F-83: 1 回の読みごとに autoreleasepool で包む（18 GB のモデルの照合の間、読んだ Data が溜まり続けない）。
    public static func sha256(of url: URL, chunkBytes: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var more = true
        while more {
            more = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: max(1, chunkBytes)), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
        }
        return hex(hasher.finalize())
    }

    public static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { byte in
            let text = String(byte, radix: 16)
            return byte < 16 ? "0" + text : text
        }.joined()
    }
}
