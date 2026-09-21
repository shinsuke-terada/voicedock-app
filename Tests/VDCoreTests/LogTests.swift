// 構造化ログ（イベント・書式・遮断・閾値）の検査（PLAN §8.15・PR-08。T-10）。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract

@testable import VDCore

/// category も覚える sink（withCategory の検査だけで使う）。
private final class CategorySink: LogSink {
    private let captured = Mutex<[String]>([])

    func write(line: String, level: LogLevel, category: String) {
        captured.withLock { $0.append(category) }
    }

    var categories: [String] { captured.withLock { $0 } }
}

@Suite("Log")
struct LogTests {
    let sink = CapturingLogSink()

    func makeLog(level: LogLevel = .debug, unsafe: Bool = false) throws -> AppLog {
        let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
        let now = try #require(zone.parseISO("2026-08-30T07:00:12+09:00"))
        return AppLog(sink: sink, level: level, unsafeContent: unsafe, zone: zone, clock: FixedClock(now: now))
    }

    @Test("イベントは付録 A.4 の順（48 個）")
    func eventsMatchAppendixA4() {
        let expected = [
            "service_started", "service_stopping", "config_warning", "config_invalid", "recovery_completed",
            "part_discovered", "part_skipped", "unparsable_filename",
            "normalize_completed", "normalize_failed", "transcription_completed", "transcription_failed",
            "raw_note_saved", "raw_note_failed", "session_merged", "session_merge_failed", "session_empty",
            "session_reopened",
            "llm_completed", "llm_failed", "analysis_trimmed", "obsidian_saved", "obsidian_failed",
            "delete_requested", "source_deleted", "source_delete_skipped", "source_delete_pending", "disk_space_low",
            "scan_completed", "volume_skipped", "file_not_stable", "copy_completed", "copy_failed", "remount_failed",
            "coexistence_blocked",
            "inbox_orphans_removed", "imported_keys_added", "pipeline_paused", "pipeline_resumed",
            "llm_server_started", "llm_server_stopped", "reaper_run", "reaper_failed", "deletion_enabled",
            "deletion_disabled",
            "model_downloaded", "model_download_failed", "diagnostics_completed",
        ]
        #expect(expected.count == 48)
        #expect(LogEvent.allCases.map(\.rawValue) == expected)
    }

    @Test("行の書式は voicedock と同じ")
    func lineFormat() throws {
        let log = try makeLog(level: .info)
        log.info(.serviceStarted, [(.version, "1.0.0")])
        log.warning(.diskSpaceLow)
        log.error(.copyFailed, [(.relpath, "a/b.wav"), (.count, 3)])
        #expect(
            sink.lines == [
                "2026-08-30T07:00:12+09:00 INFO  service_started version=1.0.0",
                "2026-08-30T07:00:12+09:00 WARNING disk_space_low",
                "2026-08-30T07:00:12+09:00 ERROR copy_failed relpath=a/b.wav count=3",
            ])
    }

    @Test("レベルの表記")
    func levelTokens() {
        #expect(LogLevel.debug.token == "DEBUG")
        #expect(LogLevel.info.token == "INFO ")
        #expect(LogLevel.warning.token == "WARNING")
        #expect(LogLevel.error.token == "ERROR")
    }

    @Test("値の書式")
    func valueFormats() {
        #expect(LogFormatter.formatValue(.null) == "null")
        #expect(LogFormatter.formatValue(nil) == "null")
        #expect(LogFormatter.formatValue(true) == "true")
        #expect(LogFormatter.formatValue(.bool(false)) == "false")
        #expect(LogFormatter.formatValue(42) == "42")
        #expect(LogFormatter.formatValue(1800.0) == "1800.0")
        #expect(LogFormatter.formatValue(.double(0.1)) == "0.1")
        #expect(LogFormatter.formatValue("abc") == "abc")
        #expect(LogFormatter.formatValue("a b") == "\"a b\"")
        #expect(LogFormatter.formatValue("") == "\"\"")
        #expect(LogFormatter.formatValue("a=b") == "\"a=b\"")
        #expect(LogFormatter.formatValue("日本語") == "\"日本語\"")
        #expect(LogFormatter.formatValue("x\"y") == "\"x\\\"y\"")
        #expect(LogValue.of(nil as String?) == .null)
        #expect(LogValue.of(Int(5)) == .int(5))
        #expect(LogValue.of(Int64(6)) == .int(6))
        #expect(LogValue.of(nil as Double?) == .null)
        #expect(LogValue.of(true) == .bool(true))
    }

    @Test("改行を含む値は必ず引用する")
    func newlineIsQuoted() {
        #expect(LogFormatter.formatValue("abc\n") == "\"abc\\n\"")
    }

    @Test("本文のキーは常に <redacted>（PR-08）")
    func contentKeysAreRedacted() throws {
        let contentKeys: [LogKey] = [
            .text, .transcript, .summary, .content, .body, .prompt, .title, .tags, .keyPoints, .tasks, .decisions,
            .ideas, .segments, .filename, .noteName,
        ]
        #expect(LogKey.allCases.filter(\.isContent) == contentKeys)
        let log = try makeLog()
        for key in contentKeys {
            log.info(.rawNoteSaved, [(key, "abc")])
        }
        let expected = contentKeys.map { "2026-08-30T07:00:12+09:00 INFO  raw_note_saved \($0.rawValue)=<redacted>" }
        #expect(sink.lines == expected)
    }

    @Test("200 スカラーを超える文字列は <redacted>")
    func longValuesAreRedacted() throws {
        let log = try makeLog()
        let exact = String(repeating: "a", count: 200)
        let over = String(repeating: "a", count: 201)
        // 「か＋濁点」を 67 個 ＝ 134 スカラー・67 書記素、＋ "a" 67 個 ＝ 201 スカラー・134 書記素
        let combining = String(repeating: "か\u{3099}", count: 67) + String(repeating: "a", count: 67)
        #expect(combining.count < 200)
        log.info(.rawNoteSaved, [(.detail, .string(exact))])
        log.info(.rawNoteSaved, [(.detail, .string(over))])
        log.info(.rawNoteSaved, [(.detail, .string(combining))])
        #expect(
            sink.lines == [
                "2026-08-30T07:00:12+09:00 INFO  raw_note_saved detail=\(exact)",
                "2026-08-30T07:00:12+09:00 INFO  raw_note_saved detail=<redacted>",
                "2026-08-30T07:00:12+09:00 INFO  raw_note_saved detail=<redacted>",
            ])
    }

    @Test("閾値未満は出さない")
    func thresholdFilters() throws {
        let log = try makeLog(level: .info)
        log.debug(.scanCompleted)
        #expect(sink.lines.isEmpty)
        log.warning(.scanCompleted)
        #expect(sink.lines == ["2026-08-30T07:00:12+09:00 WARNING scan_completed"])
    }

    @Test("CE logging.level WARNING にすると INFO を出さない")
    func ceLoggingLevel() throws {
        let level = try #require(LogLevel(configValue: "WARNING"))
        let log = try makeLog(level: level)
        log.info(.scanCompleted)
        #expect(sink.lines.isEmpty)
        log.warning(.scanCompleted)
        #expect(sink.lines.count == 1)
        #expect(LogLevel(configValue: "info") == nil)
        #expect(LogLevel(configValue: "") == nil)
        #expect(LogLevel(configValue: "DEBUG") == .debug)
        #expect(LogLevel(configValue: "INFO") == .info)
        #expect(LogLevel(configValue: "ERROR") == .error)
    }

    @Test("CE logging.unsafeLogContent true でも DEBUG の行だけ本文を出す")
    func ceLoggingUnsafeContent() throws {
        let unsafeLog = try makeLog(level: .debug, unsafe: true)
        unsafeLog.debug(.llmCompleted, [(.text, "abc")])
        unsafeLog.info(.llmCompleted, [(.text, "abc")])
        let safeLog = try makeLog(level: .debug, unsafe: false)
        safeLog.debug(.llmCompleted, [(.text, "abc")])
        #expect(
            sink.lines == [
                "2026-08-30T07:00:12+09:00 DEBUG llm_completed text=abc",
                "2026-08-30T07:00:12+09:00 INFO  llm_completed text=<redacted>",
                "2026-08-30T07:00:12+09:00 DEBUG llm_completed text=<redacted>",
            ])
    }

    @Test("withCategory は閾値と遮断を引き継ぐ")
    func withCategoryKeepsSettings() throws {
        let categorySink = CategorySink()
        let zone = ZonedTime(timeZone: .gmt)
        let log = AppLog(
            sink: categorySink, level: .warning, unsafeContent: true, zone: zone,
            clock: FixedClock(epochMillis: 0))
        #expect(log.category == "core")
        let device = log.withCategory("device")
        #expect(device.category == "device")
        #expect(device.threshold == .warning)
        #expect(device.unsafeContent == true)
        log.warning(.scanCompleted)
        device.info(.scanCompleted)
        device.warning(.scanCompleted)
        #expect(categorySink.categories == ["core", "device"])
    }

    @Test("予約名 ts / level / event はキーに無い")
    func logKeysHaveNoReservedNames() {
        #expect(LogKey(rawValue: "ts") == nil)
        #expect(LogKey(rawValue: "level") == nil)
        #expect(LogKey(rawValue: "event") == nil)
    }
}
