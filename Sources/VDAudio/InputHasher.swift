// 入力の SHA-256。変換の経路と再利用の経路で同じ関数を使う（DEV-18）。
import CryptoKit
import Foundation
import VDCore

/// 変換の時間上限（PLAN §8.3 手順 4。ASR-08）。
struct Deadline: Sendable {
    let clock: any AppClock
    let start: Duration  // clock.uptime() の値
    let limitSeconds: Int

    /// `clock.uptime() - start > .seconds(limitSeconds)`（等しいときは超えていない）
    func isExceeded() -> Bool {
        clock.uptime() - start > .seconds(limitSeconds)
    }
}

enum InputHasherError: Error, Equatable { case deadlineExceeded }

enum InputHasher {
    /// ファイル全体を `chunkBytes` ずつ読み、SHA-256 の小文字 16 進と読んだバイト数を返す。
    /// `deadline` が与えられていれば、チャンクを 1 つ読むたびに `isExceeded()` を確かめ、超えたら `deadlineExceeded` を投げる。
    static func hash(_ url: URL, chunkBytes: Int, deadline: Deadline?) throws -> (sha256: String, bytes: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: chunkBytes), !chunk.isEmpty {
            hasher.update(data: chunk)
            bytes += Int64(chunk.count)
            if let deadline, deadline.isExceeded() { throw InputHasherError.deadlineExceeded }
        }
        let digest = hasher.finalize()
        return (digest.map { String(format: "%02x", $0) }.joined(), bytes)
    }
}
