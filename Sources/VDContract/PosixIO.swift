// errno を返す低水準の読み書き（AtomicFile・ReaperConf・TargetIdentity が使う）。
import Darwin
import Foundation

enum PosixIO {
    /// EINTR で再試行し、部分書き込みを続けて全部書く。成功で nil、失敗でそのときの errno
    static func writeAll(fd: Int32, _ data: Data) -> Int32? {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int32? in
            guard let base = buffer.baseAddress else { return nil }
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, base + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += n
            }
            return nil
        }
    }

    /// 最大 limit バイトまで読む（EINTR で再試行、0 で終わり）。失敗で errno
    static func readAll(fd: Int32, limit: Int) -> Result<Data, PosixError> {
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while result.count < limit {
            let want = min(chunk.count, limit - result.count)
            let n = chunk.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.read(fd, base, want)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return .failure(PosixError(errno: errno))
            }
            if n == 0 { break }
            result.append(contentsOf: chunk[0..<n])
        }
        return .success(result)
    }

    /// realpath(3)。失敗で nil（返った領域は free する）
    static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// statfs の f_mntonname / f_fstypename のような固定長の C 文字列（タプル）を String にする（NUL まで。UTF-8 として解釈）
    static func string<T>(fromCTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}

struct PosixError: Error, Equatable, Sendable {
    let errno: Int32
}
