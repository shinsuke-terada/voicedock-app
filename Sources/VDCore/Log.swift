// 構造化ログ（PLAN §8.15）: 登録制のイベントとキー、本文の遮断、os.Logger への出力。`Logger(` を書いてよい唯一のファイル（PT-08）。
import Foundation
import os

/// 登録制のイベント名（PLAN 付録 A.4。宣言順 = 付録 A.4 の出現順。SPEC 同期が突き合わせる）。
public enum LogEvent: String, CaseIterable, Sendable {
    case serviceStarted = "service_started"
    case serviceStopping = "service_stopping"
    case configWarning = "config_warning"
    case configInvalid = "config_invalid"
    case recoveryCompleted = "recovery_completed"
    case partDiscovered = "part_discovered"
    case partSkipped = "part_skipped"
    case unparsableFilename = "unparsable_filename"
    case normalizeCompleted = "normalize_completed"
    case normalizeFailed = "normalize_failed"
    case transcriptionCompleted = "transcription_completed"
    case transcriptionFailed = "transcription_failed"
    case rawNoteSaved = "raw_note_saved"
    case rawNoteFailed = "raw_note_failed"
    case sessionMerged = "session_merged"
    case sessionMergeFailed = "session_merge_failed"
    case sessionEmpty = "session_empty"
    case sessionReopened = "session_reopened"
    case llmCompleted = "llm_completed"
    case llmFailed = "llm_failed"
    case analysisTrimmed = "analysis_trimmed"
    case obsidianSaved = "obsidian_saved"
    case obsidianFailed = "obsidian_failed"
    case deleteRequested = "delete_requested"
    case sourceDeleted = "source_deleted"
    case sourceDeleteSkipped = "source_delete_skipped"
    case sourceDeletePending = "source_delete_pending"
    case diskSpaceLow = "disk_space_low"
    case scanCompleted = "scan_completed"
    case volumeSkipped = "volume_skipped"
    case fileNotStable = "file_not_stable"
    case copyCompleted = "copy_completed"
    case copyFailed = "copy_failed"
    case remountFailed = "remount_failed"
    case inboxOrphansRemoved = "inbox_orphans_removed"
    case importedKeysAdded = "imported_keys_added"
    case pipelinePaused = "pipeline_paused"
    case pipelineResumed = "pipeline_resumed"
    case llmServerStarted = "llm_server_started"
    case llmServerStopped = "llm_server_stopped"
    case reaperRun = "reaper_run"
    case reaperFailed = "reaper_failed"
    case deletionEnabled = "deletion_enabled"
    case deletionDisabled = "deletion_disabled"
    case modelDownloaded = "model_downloaded"
    case modelDownloadFailed = "model_download_failed"
    case diagnosticsCompleted = "diagnostics_completed"
}

public enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case debug = 10
    case info = 20
    case warning = 30
    case error = 40

    /// 行に出す表記（`configValue` を 5 桁に左寄せ。WARNING は 7 桁のまま。voicedock `{level:<5}`）。
    /// F-83: 語は `configValue` の 1 か所から作る（CR-06）
    public var token: String {
        configValue + String(repeating: " ", count: max(0, Self.tokenWidth - configValue.unicodeScalars.count))
    }

    /// token の最小の桁数（voicedock `{level:<5}`）
    static let tokenWidth = 5

    /// config.json の `logging.level` の語（大文字。CV-54）。F-83: 4 語はここだけに書く（CR-06。ConfigValidator もこれを使う）
    var configValue: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARNING"
        case .error: "ERROR"
        }
    }

    /// config.json の `logging.level`（大文字。CV-54）から。それ以外は nil（比較はスカラー列）。
    public init?(configValue: String) {
        guard let level = LogLevel.allCases.first(where: { PyText.scalarsEqual($0.configValue, configValue) }) else {
            return nil
        }
        self = level
    }

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// ログの値（voicedock の str / int / float / bool / None）。これ以外の型は渡せない。
public enum LogValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral
{
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }

    /// nil → .null
    public static func of(_ v: String?) -> LogValue { v.map { .string($0) } ?? .null }
    public static func of(_ v: Int) -> LogValue { .int(Int64(v)) }
    public static func of(_ v: Int64) -> LogValue { .int(v) }
    /// nil → .null
    public static func of(_ v: Double?) -> LogValue { v.map { .double($0) } ?? .null }
    public static func of(_ v: Bool) -> LogValue { .bool(v) }
}

/// 登録制のキー（予約名 ts / level / event を持たないことで型で防ぐ）。
public enum LogKey: String, CaseIterable, Sendable {
    // 識別・分類
    case recordingKey = "recording_key"
    case sessionKey = "session_key"
    case requestID = "request_id"
    case relpath, name, path, id
    case reason
    case errorCode = "error_code"
    case detail, rule, key, message
    // 数
    case version, schema
    case rolledBack = "rolled_back"
    case requeued, count, parts, excluded, chars, chunks, bytes
    case inBytes = "in_bytes"
    case outBytes = "out_bytes"
    case elapsedS = "elapsed_s"
    case durationS = "duration_s"
    case rtf
    case speechRatio = "speech_ratio"
    case regeneratedCount = "regenerated_count"
    case devices, copied, recopy, port, exit, fields, passed, failed, notices
    // 本文を運ぶキー（常に遮断。voicedock log.py CONTENT_FIELDS の 15 個。PR-08）
    case text, transcript, summary, content, body, prompt, title, tags
    case keyPoints = "key_points"
    case tasks, decisions
    case ideas, segments, filename
    case noteName = "note_name"

    /// 最後の 15 個（本文を運ぶキー）だけ true。
    public var isContent: Bool {
        switch self {
        case .text, .transcript, .summary, .content, .body, .prompt, .title, .tags, .keyPoints, .tasks, .decisions,
            .ideas, .segments, .filename, .noteName:
            return true
        default:
            return false
        }
    }
}

public protocol LogSink: Sendable {
    func write(line: String, level: LogLevel, category: String)
}

/// 構造化ログ（PLAN §8.15）。設定が変わったら作り直す（不変）。
public final class AppLog: Sendable {
    public let threshold: LogLevel
    public let unsafeContent: Bool
    public let category: String
    private let sink: any LogSink
    private let zone: ZonedTime
    private let clock: any AppClock

    public init(
        sink: any LogSink, level: LogLevel, unsafeContent: Bool, zone: ZonedTime, clock: any AppClock,
        category: String = "core"
    ) {
        self.sink = sink
        self.threshold = level
        self.unsafeContent = unsafeContent
        self.zone = zone
        self.clock = clock
        self.category = category
    }

    public func withCategory(_ category: String) -> AppLog {
        AppLog(sink: sink, level: threshold, unsafeContent: unsafeContent, zone: zone, clock: clock, category: category)
    }

    /// voicedock log.py `_emit`。イベントとキーの検証は型が済ませている。
    public func log(_ level: LogLevel, _ event: LogEvent, _ fields: [(LogKey, LogValue)] = []) {
        guard level >= threshold else { return }
        // 遮断を外すのは「unsafeLogContent が真」かつ「その行のレベルが DEBUG」のときだけ（閾値ではなく行のレベル）。
        let redact = !(unsafeContent && level == .debug)
        let ts = zone.iso(clock.now())
        let line = LogFormatter.line(ts: ts, level: level, event: event, fields: fields, redact: redact)
        sink.write(line: line, level: level, category: category)
    }

    public func debug(_ event: LogEvent, _ fields: [(LogKey, LogValue)] = []) { log(.debug, event, fields) }
    public func info(_ event: LogEvent, _ fields: [(LogKey, LogValue)] = []) { log(.info, event, fields) }
    public func warning(_ event: LogEvent, _ fields: [(LogKey, LogValue)] = []) { log(.warning, event, fields) }
    public func error(_ event: LogEvent, _ fields: [(LogKey, LogValue)] = []) { log(.error, event, fields) }
}

/// os.Logger へ流す（subsystem = BUNDLE_ID、category は AppLog の category）。行は遮断済みなので privacy は public。
public struct OSLogSink: LogSink {
    public let subsystem: String

    public init(subsystem: String) {
        self.subsystem = subsystem
    }

    public func write(line: String, level: LogLevel, category: String) {
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .warning: logger.notice("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        }
    }
}
