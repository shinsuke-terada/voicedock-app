// パイプを EOF（か停止要求）まで読む。BlockingIO の上で動かし、actor を止めない（PLAN §2.1）。
import Darwin
import Foundation
import VDCore

enum PipeReader {
    static let chunkBytes = 65_536
    static let pollMilliseconds: Int32 = 100

    static func drain(fd: Int32, into tail: OutputTail) async {
        _ = try? await BlockingIO.run {
            var buffer = [UInt8](repeating: 0, count: chunkBytes)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            while !tail.shouldStop {
                let ready = poll(&pfd, 1, pollMilliseconds)
                if ready == 0 { continue }
                if ready < 0 { if errno == EINTR { continue } else { break } }
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, chunkBytes) }
                if n > 0 {
                    buffer.withUnsafeBytes { tail.append(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                } else if n == 0 {
                    break  // EOF（書き口がすべて閉じた）
                } else if errno == EINTR || errno == EAGAIN {
                    continue
                } else {
                    break
                }
            }
            close(fd)
            tail.finish()
        }
    }
}
