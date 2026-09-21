// 行を覚える LogSink（00-api-map §15。T-10）。
import Foundation
import Synchronization
import VDCore

/// 行を覚える LogSink（00-api-map §15 の `CapturingLogSink`）。
public final class CapturingLogSink: LogSink {
    private let captured = Mutex<[String]>([])

    public init() {}

    public func write(line: String, level: LogLevel, category: String) {
        captured.withLock { $0.append(line) }
    }

    public var lines: [String] { captured.withLock { $0 } }
}
