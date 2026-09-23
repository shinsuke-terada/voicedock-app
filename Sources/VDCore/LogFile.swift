// `<HOME>/logs/app.log` への追記と 1 世代の回転（PT-12 の許可場所）、複数の行き先への分配。
import Darwin
import Foundation
import Synchronization

/// `<HOME>/logs/app.log`。追記し、maxBytes を超える書き込みの前に `.1` へ rename（1 世代）。
public final class LogFile: LogSink {
    public let url: URL
    public let maxBytes: Int

    struct State: Sendable {
        var fd: Int32 = -1
        var size: Int64 = 0
    }

    private let state = Mutex(State())

    public init(url: URL, maxBytes: Int = 5 * 1024 * 1024) {
        self.url = url
        self.maxBytes = maxBytes
    }

    public func write(line: String, level: LogLevel, category: String) {
        let path = url.path(percentEncoded: false)
        state.withLock { state in
            let bytes = Array((line + "\n").utf8)
            if state.fd < 0 {
                guard Self.open(path, into: &state) else { return }
            }
            if state.size > 0 && state.size + Int64(bytes.count) > Int64(maxBytes) {
                Darwin.close(state.fd)
                state.fd = -1
                _ = Darwin.rename(path, path + ".1")
                // F-83: 大きさは開き直した app.log の st_size（open が入れる）。rename に失敗したときに 0 と思い込むと、
                // 次に上限を超えるまで回転を試みず、ログが上限を超えて伸び続けた
                guard Self.open(path, into: &state) else { return }
            }
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { buffer in
                    Darwin.write(state.fd, buffer.baseAddress?.advanced(by: offset), bytes.count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    Darwin.close(state.fd)
                    state.fd = -1
                    return
                }
                offset += written
                state.size += Int64(written)
            }
        }
    }

    public func close() {
        state.withLock { state in
            if state.fd >= 0 {
                Darwin.close(state.fd)
                state.fd = -1
            }
        }
    }

    /// 開いて fstat で大きさを得る。失敗なら何もせず false（ログの失敗はログに書けない。os.Logger 側には残る）。
    private static func open(_ path: String, into state: inout State) -> Bool {
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            Darwin.close(fd)
            return false
        }
        state.fd = fd
        state.size = Int64(info.st_size)
        return true
    }
}

/// 複数の行き先へ同じ行を渡す（アプリは OSLogSink と LogFile を束ねる）。
public struct TeeSink: LogSink {
    public let sinks: [any LogSink]

    public init(_ sinks: [any LogSink]) {
        self.sinks = sinks
    }

    /// 順に全部へ。
    public func write(line: String, level: LogLevel, category: String) {
        for sink in sinks {
            sink.write(line: line, level: level, category: category)
        }
    }
}
