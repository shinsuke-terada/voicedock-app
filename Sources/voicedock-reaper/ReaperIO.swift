// fd の読み書き（voicedock-reaper の中だけ。VDContract の PosixIO は internal で使えない）。
import Darwin
import Foundation

enum ReaperIO {
    /// 最大 limit バイトまで読む。EINTR は再試行、0 で終わり。limit を超えて読めたら nil（大きすぎる）。失敗も nil
    static func readAll(fd: Int32, limit: Int) -> Data? {
        var result = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.read(fd, base, buffer.count)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            result.append(contentsOf: chunk[0..<n])
            if result.count > limit { return nil }
        }
        return result
    }

    /// 部分書き込みを続けて全部書く。EINTR は再試行。成功で true
    static func writeAll(fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, base + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    /// realpath(3)。失敗で nil（返った領域は free する）
    static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// lstat が成功し S_IFREG なら true
    static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }
}
