// `logs/reaper.log`（PLAN §8.9.4）。5 MiB を超える書き込みの前に `.1` へ回す。PT-08・PT-12 の許可場所。
import Darwin
import Foundation
import Synchronization

final class ReaperLog: Sendable {
    enum Level: String, Sendable {
        case info = "INFO"
        case warn = "WARN"
    }

    /// イベント名（PLAN §8.9.4。固定。ここ以外に書かない。CR-06）
    enum Event {
        static let started = "reaper_started"
        static let busy = "reaper_busy"
        static let disabled = "reaper_disabled"
        static let requestRejected = "request_rejected"
        static let sourceDeleteRejected = "source_delete_rejected"
        static let deviceAbsent = "device_absent"
        static let mountReadonly = "mount_readonly"
        static let sourceDeleted = "source_deleted"
        static let completed = "reaper_completed"
    }

    /// キー（PLAN §8.9.4 の逐語）
    enum Key {
        static let reason = "reason"
        static let file = "file"
        static let requestID = "request_id"
        static let device = "device"
        static let partkey = "partkey"
        static let requests = "requests"
    }

    static let maxBytes = 5 * 1024 * 1024

    private struct State {
        var fd: Int32 = -1
        var size: Int64 = 0
    }

    private let url: URL
    private let maxBytes: Int
    private let clock: ReaperClock
    private let state = Mutex<State>(State())

    init(url: URL, maxBytes: Int = ReaperLog.maxBytes, clock: ReaperClock = ReaperClock()) {
        self.url = url
        self.maxBytes = maxBytes
        self.clock = clock
    }

    func info(_ event: String, _ fields: [(String, String)] = []) {
        write(.info, event, fields)
    }

    func warn(_ event: String, _ fields: [(String, String)] = []) {
        write(.warn, event, fields)
    }

    func close() {
        state.withLock { s in
            if s.fd >= 0 {
                Darwin.close(s.fd)
                s.fd = -1
            }
        }
    }

    /// PLAN §8.15 の値の書式（テストが直接呼ぶ）。末尾の改行は含まない
    static func format(ts: String, level: Level, event: String, fields: [(String, String)]) -> String {
        var line = ts + " " + level.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0) + " " + event
        for (k, v) in fields {
            line += " " + k + "=" + value(v)
        }
        return line
    }

    /// PLAN §8.15。空でなく、全スカラーが U+0021〜U+007E で `"` でも `=` でもなければそのまま。
    /// そうでなければ JSON の文字列表記（ensure_ascii=False と同じ）
    static func value(_ s: String) -> String {
        let plain =
            !s.isEmpty
            && s.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7E && $0 != "\"" && $0 != "=" }
        if plain { return s }
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x5C: out += "\\\\"
            case 0x22: out += "\\\""
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0C: out += "\\f"
            case 0x0D: out += "\\r"
            case 0x00...0x1F, 0x7F: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    private func write(_ level: Level, _ event: String, _ fields: [(String, String)]) {
        let line = Self.format(ts: clock.nowISO(), level: level, event: event, fields: fields) + "\n"
        let bytes = Data(line.utf8)
        let path = url.path(percentEncoded: false)
        state.withLock { s in
            if s.fd < 0 {
                guard Self.openLog(path, into: &s) else { return }
            }
            if s.size > 0 && s.size + Int64(bytes.count) > Int64(maxBytes) {
                Darwin.close(s.fd)
                s.fd = -1
                // 既存の `.1` を置き換える
                _ = rename(path, path + ".1")
                guard Self.openLog(path, into: &s) else { return }
                s.size = 0
            }
            if ReaperIO.writeAll(fd: s.fd, bytes) {
                s.size += Int64(bytes.count)
            } else {
                Darwin.close(s.fd)
                s.fd = -1
            }
        }
    }

    /// 開いて fstat で大きさを取る。失敗なら何もしない（ログの失敗はログに書けない）。
    /// symlink は辿らない（ELOOP で失敗）。FIFO は読み手が無ければ ENXIO で失敗し、開くところで止まらない（F-73）
    private static func openLog(_ path: String, into s: inout State) -> Bool {
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        var st = stat()
        s.fd = fd
        s.size = fstat(fd, &st) == 0 ? Int64(st.st_size) : 0
        return true
    }
}
