// デバイスから読んだ原本を inbox の .partial へ書き、確定する（PLAN §8.1 コピー）。デバイスには書かない。
import CryptoKit
import Darwin
import Foundation
import VDContract
import VDCore

public struct InboxWriter: Sendable {
    let layout: HomeLayout

    public init(layout: HomeLayout) {
        self.layout = layout
    }

    /// .partial を作って source を最後まで写し、SHA-256（小文字 16 進 64 文字）を返す。失敗したら .partial を消す。
    /// 原本を読むのは 1 回だけ（コピーと SHA-256 を同時に。USB を 2 回読まない）
    public func writePartial(
        from source: any ChunkReading, expectedSize: Int64, partial: URL, chunkBytes: Int
    ) -> Result<String, CopyError> {
        do {
            try FileManager.default.createDirectory(
                at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return .failure(.writeError(EIO))
        }
        let fd = open(
            partial.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { return .failure(.writeError(errno)) }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk: Data
            do {
                chunk = try source.read(maxBytes: chunkBytes)
            } catch {
                _ = close(fd)
                discardPartial(partial)
                return .failure(.readError(error.code))
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            if let code = Self.writeAll(fd: fd, chunk) {
                _ = close(fd)
                discardPartial(partial)
                return .failure(.writeError(code))
            }
            total += Int64(chunk.count)
        }
        if fsync(fd) != 0 {
            let code = errno
            _ = close(fd)
            discardPartial(partial)
            return .failure(.writeError(code))
        }
        _ = close(fd)
        if total != expectedSize {
            discardPartial(partial)
            return .failure(.sizeMismatch)
        }
        return .success(hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// .partial を最終の名前へ rename して確定する。失敗したら .partial を消す。
    /// 既存の最終ファイルは rename が置き換える（needs_recopy の再コピーはこれで上書きする）
    public func commitPartial(_ partial: URL, to final: URL) -> Result<Void, CopyError> {
        if rename(partial.path(percentEncoded: false), final.path(percentEncoded: false)) == 0 {
            return .success(())
        }
        let e = errno
        discardPartial(partial)
        return .failure(.writeError(e))
    }

    /// .partial を消す（無ければ何もしない。失敗は無視する）。inbox の外や symlink は SafeUnlink が拒否する（CR-10）
    public func discardPartial(_ partial: URL) {
        try? SafeUnlink.remove(partial, under: .inbox, layout: layout, missingOK: true)
    }

    /// data を全部書く（部分書き込みは残りを続けて書く。EINTR は再試行）。失敗したら errno
    private static func writeAll(fd: Int32, _ data: Data) -> Int32? {
        data.withUnsafeBytes { raw -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += n
            }
            return nil
        }
    }
}
