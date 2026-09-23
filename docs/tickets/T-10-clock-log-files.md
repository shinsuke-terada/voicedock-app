# T-10 VDCore: 時刻・ログ・SafeUnlink・AppPaths・Transcript 型・指紋・Block

> （F-61 で共存ガードは外した。2026-09-22、利用者の決定）`LogEvent.coexistenceBlocked`（`coexistence_blocked`）は消し、イベントは 47 個になった。以下の本文の共存ガードの記述は記録として残す。

> （F-83・issue #119、2026-09-23。マージ後の追記）`LogFile` の回転の rename に失敗したとき大きさを 0 に戻さない（開き直した `st_size` を使う。PLAN §8.15）。`FileHasher.sha256(of:chunkBytes:)` の読みを 1 回ずつ `autoreleasepool` で包む。
> `LogLevel` に `configValue`（CV-54 の 4 語。internal）を足し、`init?(configValue:)` はそれで照らす。テストは `LogFileRotationFailureTests.swift`・`FileHasherChunkTests.swift`・`ConfigValidatorScalarTests.swift`。

| 項目 | 値 |
|---|---|
| Phase | 2（記録の土台） |
| 前提 | T-08（`PartStatus`）、**T-45（`PyJSON`・`PyRound`。ログの値の引用・transcript の符号化・指紋が使う）**。T-06（`HomeLayout`・`Contract`・`LocalDateTime`・`SessionKey`・`KeySlug`）は T-08 の前提、T-25（golden の `keys`・`fingerprint`・`blocks`）は T-45 の前提として入っている |
| 見積もり | ソース約 850 行、テスト約 800 行（部品が多いので 600 行を超える。PR 本文に理由を書く） |
| ブランチ | `feat/T-10-clock-log-files` |

## 目的

後続のすべてのモジュールが使う基礎部品を VDCore に作る:
時刻（`Instant`・`AppClock`・`ZonedTime`）、待ち（`Sleeper`）、同期 I/O の逃がし先（`BlockingIO`）、ログ（登録制のイベントとキー、本文の遮断）、
安全な削除（`SafeUnlink`）、バンドル内のパス（`AppPaths`）、ハッシュ、文字数、Part の transcript の型と符号化、Session の統合結果の型・指紋・Block、モデルの照合キャッシュ。

## 参照

- PLAN §2.1（BlockingIO）、§5.6（Block・統合）、§5.7（時刻・JSON）、§8.4（正規化 transcript の形と合格条件）、§8.5（指紋）、§8.10（照合キャッシュ）、§8.15（ログ）、§9.2（CR-08・CR-10・CR-23・SafeUnlink）、付録 A.4
- voicedock@d3d595e: `src/voicedock/log.py`（全体）、`src/voicedock/session.py:60-93`（指紋）、`329-367`（compute_blocks）、`src/voicedock/transcribe.py:392-444`（transcript の読み書き）、`src/voicedock/paths.py:335-421`（safe_unlink）、`tests/unit/test_log.py`、`tests/unit/test_blocks.py`
- 移植メモ V2 §7、V4 §2.5・§3.13

## 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDCore/Instant.swift` | `Instant`・`SecondsToMillis` |
| `Sources/VDCore/Clock.swift` | `AppClock`・`SystemClock`・`Sleeper`・`TaskSleeper`（PT-09 の許可場所） |
| `Sources/VDCore/BlockingIO.swift` | `BlockingIO` |
| `Sources/VDCore/ZonedTime.swift` | `ZonedTime`・`LocalDate`・`ISOWallClock`・内部の `CivilDays` |
| `Sources/VDCore/Log.swift` | `LogEvent`・`LogLevel`・`LogValue`・`LogKey`・`LogSink`・`AppLog`・`OSLogSink`（PT-08 の許可場所。`Logger(` はこのファイルだけ） |
| `Sources/VDCore/LogFormatter.swift` | `LogFormatter` |
| `Sources/VDCore/LogFile.swift` | `LogFile`（PT-12 の許可場所）・`TeeSink`（00-api-map §2.3 の置き場所） |
| `Sources/VDCore/SafeUnlink.swift` | `SafeUnlinkRoot`・`SafeUnlink`・`SafeUnlinkError`（PT-01 の許可場所） |
| `Sources/VDCore/AppPaths.swift` | `AppPaths`（PT-11: `bundledReaperURL` の定義） |
| `Sources/VDCore/FileHasher.swift` | `FileHasher` |
| `Sources/VDCore/TextLimit.swift` | `TextLimit` |
| `Sources/VDCore/Transcript.swift` | `PartTranscript`・`TranscriptSegment`・`PartTranscriptCodec` |
| `Sources/VDCore/SessionTranscript.swift` | `AbsoluteSegment`・`TimeBlock`・`SessionTranscript`・`TranscriptFingerprint`・`BlockComputer` |
| `Sources/VDCore/ModelVerificationCache.swift` | `ModelVerificationCache` |
| `Tests/TestSupport/FixedClock.swift` | `FixedClock` |
| `Tests/TestSupport/SteppingClock.swift` | `SteppingClock` |
| `Tests/TestSupport/RecordingSleeper.swift` | `RecordingSleeper` |
| `Tests/TestSupport/CapturingLogSink.swift` | `CapturingLogSink`（00-api-map §15 の名前） |
| `Tests/VDCoreTests/InstantTests.swift` ほか | 下の「テスト」の節 |
| `Tests/VDCoreTests/SpecSyncLogEventsTests.swift` | T-05 §5 の全文（`LogEvent` の宣言順 = SPEC の S4） |
| `Tests/VDCoreTests/GoldenCoreTests.swift` | T-25 の golden（`keys`・`fingerprint`・`blocks`）との照合 |

`RawNoteMembership` は 00-api-map §2.1 の置き場所に従い T-08 が作る（このチケットでは作らない）。

## 仕様

### 1. `Instant.swift`

```swift
/// 絶対時刻（Unix 紀元からのミリ秒）。Double の Date で加算しない（PLAN §5.7。等号の境界を Python と一致させる）。
public struct Instant: Comparable, Hashable, Sendable {
    public let epochMillis: Int64
    public init(epochMillis: Int64) { self.epochMillis = epochMillis }
    /// Date から。ミリ秒未満は切り捨て（負の値も −∞ 方向）。
    public init(date: Date) { self.epochMillis = Int64((date.timeIntervalSince1970 * 1000).rounded(.down)) }
    /// Foundation の API に渡すときだけ使う。
    public var date: Date { Date(timeIntervalSince1970: Double(epochMillis) / 1000) }
    public func adding(milliseconds: Int64) -> Instant { Instant(epochMillis: epochMillis + milliseconds) }
    public func adding(seconds: Int) -> Instant { Instant(epochMillis: epochMillis + Int64(seconds) * 1000) }
    /// a − b のミリ秒。
    public static func - (a: Instant, b: Instant) -> Int64 { a.epochMillis - b.epochMillis }
    public static func < (a: Instant, b: Instant) -> Bool { a.epochMillis < b.epochMillis }
}

public enum SecondsToMillis {
    /// whisper の offsets を秒へ直した値（小数 3 桁）を、Instant に足すミリ秒の整数へ戻す（PLAN §5.7）。`(s × 1000).rounded()`（.toNearestOrAwayFromZero）。
    public static func fromWhisperSeconds(_ s: Double) -> Int64 { Int64((s * 1000).rounded()) }
}
```

### 2. `Clock.swift`（`Date()` と単調時計を読んでよい唯一のファイル。PT-09）

```swift
/// 時計（CR-08）。標準ライブラリの `Clock` と名前を分ける。
public protocol AppClock: Sendable {
    /// 壁時計の現在（毎回読む。tick の先頭で固定しない。TIME-04）
    func now() -> Instant
    /// 単調時計（TTL やタイムアウトの計測用。スリープ中も進む）
    func uptime() -> Duration
}

public struct SystemClock: AppClock {
    private let origin: ContinuousClock.Instant
    public init() { origin = ContinuousClock.now }
    public func now() -> Instant { Instant(date: Date()) }
    public func uptime() -> Duration { origin.duration(to: ContinuousClock.now) }
}

/// 待ち（工程内リトライ・安定性判定・ポーリング）。テストは RecordingSleeper で待たない。
public protocol Sleeper: Sendable {
    func sleep(seconds: Int) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}
    /// `Task.sleep(for: .seconds(seconds))`。0 以下なら何もしない。キャンセルで CancellationError。
    public func sleep(seconds: Int) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}
```

### 3. `BlockingIO.swift`

```swift
/// actor の中で長い同期 I/O をしないための逃がし先（PLAN §2.1）。
public enum BlockingIO {
    static let queue = DispatchQueue(label: "voicedock.blocking-io", qos: .utility, attributes: .concurrent)
    /// work を専用の並行キューで実行し、結果を continuation で返す。work の中のキャンセルは呼び手が時間の上限で行う（Task のキャンセルは work に伝わらない）。
    public static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
```

### 4. `ZonedTime.swift`

```swift
/// 設定のタイムゾーンでの時刻の書式と暦（PLAN §5.7）。ISO 文字列を作るのは `iso(_:)` だけ。
public struct ZonedTime: Sendable {
    public let timeZone: TimeZone
    public init(timeZone: TimeZone)
    /// 固定オフセットで描く（Raw の見出しなど、保存文字列のオフセットのまま描く所。PLAN §5.7・X-32）。
    /// `TimeZone(secondsFromGMT:)` が nil（±18 時間を超える）なら `.gmt`。
    public init(fixedOffsetSeconds: Int)
    /// ISO 8601、秒まで（秒未満は切り捨て）、オフセット付き（例 "2026-08-30T07:00:12+09:00"。UTC は "+00:00"）。
    public func iso(_ i: Instant) -> String
    /// `iso(_:)` が作る形だけを読む（例外を投げず nil）。
    public func parseISO(_ s: String) -> Instant?
    public func localDateTime(_ i: Instant) -> LocalDateTime
    public func localDate(_ i: Instant) -> LocalDate
    /// ファイル名の時刻にタイムゾーンを「付与」する（変換しない。TIME-03）。
    public func instant(of local: LocalDateTime) -> Instant
    public func today(_ now: Instant) -> LocalDate { localDate(now) }
}
```

- 内部に `private let calendar: Calendar`（`Calendar(identifier: .gregorian)`、`timeZone` を設定）を持つ
- `iso(_:)` の手順: `secs = floorDiv(i.epochMillis, 1000)`（負の値は −∞ 方向。`epochMillis >= 0 ? m / 1000 : -((-m + 999) / 1000)`）→ `date = Date(timeIntervalSince1970: Double(secs))` →
  `calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)` → `offset = timeZone.secondsFromGMT(for: date)` →
  `String(format: "%04d-%02d-%02dT%02d:%02d:%02d", …)` ＋ 符号（`offset >= 0` なら `+`、でなければ `-`）＋ `|offset| / 3600` と `(|offset| % 3600) / 60` を `%02d:%02d`、
  `|offset| % 60 != 0` のときだけ `:%02d` を足す（Python の isoformat と同じ）
- `parseISO(_:)` の手順（Foundation の日付解析を使わない）:
  1. 長さが 25（`±HH:MM`）か 28（`±HH:MM:SS`）でなければ nil
  2. 位置 4・7 が `-`、10 が `T`、13・16 が `:`、19 が `+` か `-`、22 が `:`（28 のときは 25 も `:`）。それ以外の位置は ASCII の数字。違えば nil
  3. `LocalDateTime(year:month:day:hour:minute:second:)`（T-06。整数範囲の検査）が nil なら nil。オフセットの時は 0〜23、分・秒は 0〜59 でなければ nil
  4. `days = CivilDays.fromCivil(year, month, day)`（下記）、`utc = days × 86400 + hour × 3600 + minute × 60 + second − sign × offsetSeconds` → `Instant(epochMillis: utc × 1000)`
- `CivilDays`（internal。Howard Hinnant の days_from_civil / civil_from_days を整数で）:
  ```text
  fromCivil(y, m, d): y -= (m <= 2 ? 1 : 0); era = (y >= 0 ? y : y - 399) / 400; yoe = y - era × 400
                      doy = (153 × (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1; doe = yoe × 365 + yoe / 4 - yoe / 100 + doy
                      return era × 146097 + doe - 719468
  toCivil(z): z += 719468; era = (z >= 0 ? z : z - 146096) / 146097; doe = z - era × 146097
              yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; y = yoe + era × 400; doy = doe - (365 × yoe + yoe / 4 - yoe / 100)
              mp = (5 × doy + 2) / 153; d = doy - (153 × mp + 2) / 5 + 1; m = mp + (mp < 10 ? 3 : -9); return (y + (m <= 2 ? 1 : 0), m, d)
  ```
- `localDateTime` / `localDate`: `iso` と同じく秒へ切り捨てた Date の `dateComponents` から作る
- `instant(of:)`: `calendar.date(from: DateComponents(year:month:day:hour:minute:second:))`（calendar の timeZone で解釈）→ `Instant(date:)`。nil のとき（到達しない）は
  `CivilDays` の UTC 秒から `timeZone.secondsFromGMT()` を引いた値。夏時間の存在しない・重なる時刻は Foundation の解釈に従う（JST では起きない。RK として記録）

```swift
public struct LocalDate: Comparable, Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    /// LocalDateTime(year:month:day:hour: 0, minute: 0, second: 0) が作れるときだけ。
    public init?(year: Int, month: Int, day: Int)
    /// "yyyy-MM-dd" 丁度 10 文字（ASCII 数字）だけ。
    public init?(dashed: String)
    /// "yyyyMMdd" 丁度 8 文字だけ。
    public init?(stamp: String)
    public var dashed: String   // String(format: "%04d-%02d-%02d", …)
    public var stamp: String    // String(format: "%04d%02d%02d", …)
    public func adding(days: Int) -> LocalDate   // CivilDays で計算
    public static func < (a: LocalDate, b: LocalDate) -> Bool   // (year, month, day) の辞書順
}

/// 保存された ISO 文字列（設定のタイムゾーンのオフセット付き）の壁時計を、文字列の数字そのままで取り出す（PLAN §5.7。変換しない）。
public enum ISOWallClock {
    /// 位置 10 が "T"、13・16 が ":" で長さが 19 以上なら文字 11..<16（"HH:MM"）。そうでなければ nil。
    public static func hhmm(_ iso: String) -> String?
    /// 同じ条件で 11..<19（"HH:MM:SS"）。
    public static func hhmmss(_ iso: String) -> String?
}
```

### 5. `Log.swift`（`Logger(` を書いてよい唯一のファイル。PT-08）

```swift
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
    case coexistenceBlocked = "coexistence_blocked"
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
    /// 行に出す表記（5 桁左寄せ。WARNING は 7 桁のまま。voicedock `{level:<5}`）。
    public var token: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO "
        case .warning: "WARNING"
        case .error: "ERROR"
        }
    }
    /// config.json の `logging.level`（大文字。CV-54）から。それ以外は nil。
    public init?(configValue: String)
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
    // リテラルの init（それぞれ対応するケース）
    public static func of(_ v: String?) -> LogValue   // nil → .null
    public static func of(_ v: Int) -> LogValue
    public static func of(_ v: Int64) -> LogValue
    public static func of(_ v: Double?) -> LogValue   // nil → .null
    public static func of(_ v: Bool) -> LogValue
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

    public var isContent: Bool   // 最後の 15 個だけ true（switch で書く）
}

public protocol LogSink: Sendable {
    func write(line: String, level: LogLevel, category: String)
}

/// 構造化ログ（PLAN §8.15）。設定が変わったら作り直す（不変）。
public final class AppLog: Sendable {
    public let threshold: LogLevel
    public let unsafeContent: Bool
    public let category: String
    public init(sink: any LogSink, level: LogLevel, unsafeContent: Bool, zone: ZonedTime, clock: any AppClock, category: String = "core")
    public func withCategory(_ category: String) -> AppLog
    public func log(_ level: LogLevel, _ event: LogEvent, _ fields: [(LogKey, LogValue)] = [])
    public func debug(_ event: LogEvent, _ fields: [(LogKey, LogValue)] = [])
    public func info(_ event: LogEvent, _ fields: [(LogKey, LogValue)] = [])
    public func warning(_ event: LogEvent, _ fields: [(LogKey, LogValue)] = [])
    public func error(_ event: LogEvent, _ fields: [(LogKey, LogValue)] = [])
}

/// os.Logger へ流す（subsystem = BUNDLE_ID、category は AppLog の category）。行は遮断済みなので privacy は public。
public struct OSLogSink: LogSink {
    public let subsystem: String
    public init(subsystem: String)
    public func write(line: String, level: LogLevel, category: String)
}
```

- `AppLog.log` の手順（voicedock log.py `_emit`。イベントとキーの検証は型が済ませている）:
  1. `level < threshold` なら何もしない
  2. `redact = !(unsafeContent && level == .debug)`（**遮断を外すのは「unsafeLogContent が真」かつ「その行のレベルが DEBUG」のときだけ**。voicedock の `_sanitize` と同じ。閾値ではなく行のレベルで決める）
  3. `ts = zone.iso(clock.now())`
  4. `line = LogFormatter.line(ts: ts, level: level, event: event, fields: fields, redact: redact)`
  5. `sink.write(line: line, level: level, category: category)`
- `OSLogSink.write`: `let logger = Logger(subsystem: subsystem, category: category)`。`.debug` → `logger.debug("\(line, privacy: .public)")`、`.info` → `logger.info`、`.warning` → `logger.notice`、`.error` → `logger.error`
- `LogLevel.init?(configValue:)`: `"DEBUG"` / `"INFO"` / `"WARNING"` / `"ERROR"`（大小区別）

### 6. `LogFormatter.swift`

```swift
public enum LogFormatter {
    public static let redacted = "<redacted>"
    public static let maxValueScalars = 200
    public static func line(ts: String, level: LogLevel, event: LogEvent, fields: [(LogKey, LogValue)], redact: Bool) -> String
    public static func formatValue(_ v: LogValue) -> String
}
```

- `line`: `"\(ts) \(level.token) \(event.rawValue)"` の後に、fields を**渡された順に** `" \(key.rawValue)=\(formatValue(値))"` をつなぐ。`redact` が真のとき、値は次のとおり置き換える:
  `key.isContent` なら `.string("<redacted>")`、そうでなく `.string(s)` で `TextLimit.scalarCount(s) > 200` なら `.string("<redacted>")`
- `formatValue`:
  - `.null` → `null`、`.bool` → `true` / `false`、`.int` → 10 進、`.double` → `Double.description`（`1800.0`・`0.1`）
  - `.string(s)`: `s` が空でなく、**全スカラーが U+0021〜U+007E で `"` でも `=` でもない**ならそのまま。そうでなければ `PyJSON.dumpsCompact(.string(s))`（Python `json.dumps(s, ensure_ascii=False)` と同じ引用）
  - （voicedock は Python の `$` のため末尾の改行 1 つを素通しした。本アプリは全体一致で判定し、改行を含む値は必ず引用する）
- 例: `2026-08-30T07:00:12+09:00 INFO  service_started version=1.0.0`、`… WARNING disk_space_low reason="空き 1 バイトが必要量 2 バイトを下回る"`

### 7. `LogFile.swift`（PT-12 の許可場所）

```swift
/// `<HOME>/logs/app.log`。追記し、maxBytes を超える書き込みの前に `.1` へ rename（1 世代）。
public final class LogFile: LogSink {
    public let url: URL
    public let maxBytes: Int
    public init(url: URL, maxBytes: Int = 5 * 1024 * 1024)
    public func write(line: String, level: LogLevel, category: String)
    public func close()
}

/// 複数の行き先へ同じ行を渡す（アプリは OSLogSink と LogFile を束ねる）。
public struct TeeSink: LogSink {
    public let sinks: [any LogSink]
    public init(_ sinks: [any LogSink])
    public func write(line: String, level: LogLevel, category: String)   // 順に全部へ
}
```

- 状態 `struct State: Sendable { var fd: Int32 = -1; var size: Int64 = 0 }` を `Mutex<State>`（`import Synchronization`）で守る（00-api-map §0。`@unchecked Sendable` を使わない。PT-14）
- `write` の手順（ロックの中で）:
  1. `bytes = Array((line + "\n").utf8)`
  2. `fd < 0` なら `open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)`。成功したら `fstat` で `size` を得る。失敗なら何もせず返る（ログの失敗はログに書けない。os.Logger 側には残る）
  3. `size > 0 && size + bytes.count > maxBytes` なら: `close(fd)` → `rename(path, path + ".1")`（`path = url.path(percentEncoded: false)`）（既存の `.1` を置き換える）→ 2 と同じく開き直し `size = 0`
  4. `write` を全部書き終わるまで繰り返す（`EINTR` はやり直し、ほかの失敗は `close` して `fd = -1`）。`size += 書いたバイト数`
- `close()`: `fd >= 0` なら閉じて `-1`
- `fsync` はしない（ログは失ってもよい。速度優先）

### 8. `SafeUnlink.swift`（PLAN §9.2。PT-01 の許可場所）

```swift
public enum SafeUnlinkRoot: Sendable, Equatable {
    case inbox, staging, transcripts, analysis, queueDelete, queueResult, models, run
    case vaultTmp(vault: URL)
}
public enum SafeUnlinkError: Error, Equatable, Sendable {
    case notAbsolute, containsDotDot, rootUnresolvable, outsideRoot, nameNotAllowed, notFound
    case isSymlink, notRegularFile, notDirectory
    case unlinkFailed(errno: Int32)
    case rmdirFailed(errno: Int32)
}
public enum SafeUnlink {
    public static func remove(_ target: URL, under root: SafeUnlinkRoot, layout: HomeLayout, missingOK: Bool = true) throws(SafeUnlinkError)
    public static func removeEmptyDirectory(_ target: URL, under root: SafeUnlinkRoot, layout: HomeLayout) throws(SafeUnlinkError)
}
```

ルートの対応: `inbox` → `layout.inbox`、`staging` → `layout.staging`、`transcripts` → `layout.transcriptsParts`、`analysis` → `layout.analysis`、`queueDelete` → `layout.queueDelete`、
`queueResult` → `layout.queueResult`、`models` → `layout.modelsDirectory`、`run` → `layout.runDirectory`、`vaultTmp(vault)` → `vault`。

`remove` の検査の順（最初に当たったもので止める）:
1. `target.path(percentEncoded: false)`（00-api-map §0）が `/` で始まらない → `.notAbsolute`
2. 同じパスを `/` で分けた要素に `..` がある → `.containsDotDot`
3. ルートの `realpath` が取れない → `.rootUnresolvable`
4. 親（`target.deletingLastPathComponent()`）の `realpath` が取れない: `ENOENT` なら `missingOK ? return : throw .notFound`、ほかは `.outsideRoot`
5. 親の realpath が、ルートの realpath と**等しい**か `ルート + "/"` で始まる、のどちらでもない → `.outsideRoot`（接頭辞だけ一致する兄弟 `staging-old` は配下ではない）
6. `name = target.lastPathComponent` が空・`.`・`..` → `.nameNotAllowed`
7. ルートごとの名前の規則: `queueDelete` / `queueResult` は「親の realpath == ルートの realpath」かつ `name.hasSuffix(".json")`、`vaultTmp` は `name.hasPrefix(".")` かつ `name.hasSuffix(".tmp")` かつ `TextLimit.scalarCount(name) > 5`。違えば `.nameNotAllowed`
8. `path = 親の realpath + "/" + name` に `lstat`: `ENOENT` → `missingOK ? return : throw .notFound`。symlink → `.isSymlink`（リンクも消さない）。通常ファイルでない → `.notRegularFile`。`lstat` がほかの errno で失敗 → `.unlinkFailed(errno:)`（`removeEmptyDirectory` では `.rmdirFailed(errno:)`）
9. `unlink(path)`: 成功で返る。`ENOENT` は 8 と同じ扱い。ほかは `.unlinkFailed(errno:)`

`removeEmptyDirectory` は 1〜6 を同じく行い（7 は行わない）、8 の代わりに `lstat` が `ENOENT` → 返る、symlink → `.isSymlink`、ディレクトリでない → `.notDirectory`、9 の代わりに `rmdir`:
成功・`ENOTEMPTY`・`EEXIST`・`ENOENT` → 返る（中身があれば何もしない）、ほか → `.rmdirFailed(errno:)`。ルートそのものは 5 の親の検査で必ず `.outsideRoot` になる（消させない）。

### 9. `AppPaths.swift`

```swift
/// バンドル内の資源とヘルパーのパス（PLAN §3.4・§11.1）。SwiftPM の Bundle.module は使わない。テストはリポジトリの Resources/ を注入する。
public struct AppPaths: Sendable, Equatable {
    public let resources: URL
    public let helpers: URL
    public init(resources: URL, helpers: URL)
    public static func fromMainBundle() -> AppPaths   // Bundle.main.bundleURL + "Contents/Resources" と "Contents/Helpers"
    public var promptsDirectory: URL    // resources/prompts
    public var modelCatalog: URL        // resources/ModelCatalog.json
    public var whisperCLI: URL          // helpers/whisper-cli
    public var llamaServer: URL         // helpers/llama-server
    /// バンドル内の reaper。**参照してよいのは DeletionEnabler だけ**（PT-11）。ここから実行しない（D-5）。
    public var bundledReaperURL: URL    // helpers/<Contract.reaperFileName>
}
```

### 10. `FileHasher.swift`・`TextLimit.swift`

```swift
public enum FileHasher {
    /// ファイル全体の SHA-256（小文字 16 進 64 文字）。`FileHandle(forReadingFrom:)` で chunkBytes ずつ読む。読めなければ投げる。
    public static func sha256(of url: URL, chunkBytes: Int) throws -> String
    public static func sha256(_ data: Data) -> String
}

/// 文字数の規則（CR-23）: Unicode スカラー数で数え、スカラー単位で切る（Python の len と同じ）。
public enum TextLimit {
    public static func scalarCount(_ s: String) -> Int { s.unicodeScalars.count }
    public static func prefix(_ s: String, scalars n: Int) -> String   // 先頭 n スカラー
    /// 200 スカラー以下はそのまま、超えたら先頭 199 スカラー + "…"（U+2026）。error_message・events.detail に使う（PLAN §5.2）。
    public static func truncate200(_ s: String) -> String
}
```

### 11. `Transcript.swift`

```swift
public struct TranscriptSegment: Equatable, Sendable {
    public let start: Double; public let end: Double; public let text: String
    public init(start: Double, end: Double, text: String)
}
public struct PartTranscript: Equatable, Sendable {
    public let partkey: String
    public let language: String
    public let durationSeconds: Double?
    public let startedAt: String     // Part の started_at（ISO 文字列）をそのまま
    public let text: String
    public let segments: [TranscriptSegment]
    public init(partkey: String, language: String, durationSeconds: Double?, startedAt: String, text: String, segments: [TranscriptSegment])
}
public enum PartTranscriptCodec {
    /// transcripts/parts/<slug>.json の中身（PLAN §8.4）: PyJSON の indent 2 ＋ 末尾改行。キーの順は partkey, language, duration_seconds, started_at, text, segments（各要素 start, end, text）。
    public static func encode(_ t: PartTranscript) -> Data
    /// 読み戻し。合格条件（PLAN §8.4）を 1 つでも満たさなければ nil（例外にしない）。
    public static func decode(_ data: Data) -> PartTranscript?
}
```

- `encode`: `PyJSON.fileData(.object([("partkey", .string(t.partkey)), ("language", .string(t.language)), ("duration_seconds", t.durationSeconds.map { .double($0) } ?? .null),
  ("started_at", .string(t.startedAt)), ("text", .string(t.text)), ("segments", .array(t.segments.map { .object([("start", .double($0.start)), ("end", .double($0.end)), ("text", .string($0.text))]) }))]))`
  （start / end / duration は常に `.double`。`0.0` は `0.0`、`1800.0` は `1800.0` と書かれる。voicedock の実測と同じ）
- `decode` の合格条件（順に。どれかで nil）: `PyJSON.parse(data)` が辞書 → 6 つのキー `partkey, language, duration_seconds, started_at, text, segments` をすべて持つ（ほかのキーはあってよい）→
  `segments` が配列で、各要素が辞書・`start` と `end` が数（`PyJSON.isBool` が偽の `NSNumber`）・`text` が文字列 → `text`・`started_at`・`language`・**`partkey`** が文字列 →
  `duration_seconds` が `NSNull` か数（bool でない）。（voicedock は bool を数として受け、partkey を文字列化していた。本アプリは厳しく読む）

### 12. `SessionTranscript.swift`

```swift
public struct AbsoluteSegment: Equatable, Sendable {
    public let at: Instant; public let endAt: Instant; public let text: String
    public init(at: Instant, endAt: Instant, text: String)
}
public struct TimeBlock: Equatable, Sendable { public let start: Instant; public let end: Instant; public init(start: Instant, end: Instant) }
public struct SessionTranscript: Equatable, Sendable {
    public let dayDate: LocalDate
    public let segments: [AbsoluteSegment]      // (at, endAt) で安定ソート済み（作るのは VDPipeline。PLAN §5.6）
    public let blocks: [TimeBlock]
    public let excludedPartkeys: [String]
    public init(dayDate: LocalDate, segments: [AbsoluteSegment], blocks: [TimeBlock], excludedPartkeys: [String])
}

public enum TranscriptFingerprint {
    /// voicedock session.py:60-93 と同一定義（PLAN §8.5）。
    public static func of(_ t: SessionTranscript, zone: ZonedTime) -> String
}

public enum BlockComputer {
    /// 連続録音の塊（PLAN §5.6。voicedock session.py:329-367）。入力の順は問わない（中で並べる）。
    public static func blocks(_ parts: [(startedAt: Instant, endedAt: Instant?)], gapSeconds: Int) -> [TimeBlock]
}
```

- `TranscriptFingerprint` は internal の `static func payload(_ t: SessionTranscript, zone: ZonedTime) -> String`（下の値の `dumpsCompact`。golden の照合に使う）を持ち、`of` は `FileHasher.sha256(Data(payload(t, zone: zone).utf8))`
- `TranscriptFingerprint.of`: 値
  `.object([("segments", .array(t.segments.map { .object([("at", .string(zone.iso($0.at))), ("end_at", .string(zone.iso($0.endAt))), ("text", .string($0.text))]) })),
  ("blocks", .array(t.blocks.map { .array([.string(zone.iso($0.start)), .string(zone.iso($0.end))]) }))])` を
  `PyJSON.dumpsCompact(値, sortKeys: true)` で書き、その UTF-8 の `FileHasher.sha256(_:)`。除外 Part・プロンプト・設定は混ぜない
- `BlockComputer.blocks` の手順:
  1. 安定ソート: キーは `(startedAt, endedAt == nil ? 0 : 1, endedAt?.epochMillis ?? 0)`（voicedock の `(started_at, ended_at or "")` と同じ順。nil は同じ開始の中で先）
  2. 空なら `[]`
  3. 最初の Part: `start = startedAt`、`end = endedAt ?? startedAt`、`unknownEnd = endedAt == nil`
  4. 以降の各 Part: `gap = startedAt − end`（ミリ秒）。`unknownEnd || gap > gapSeconds × 1000` なら `TimeBlock(start, end)` を確定し、3 と同じく新しく始める。そうでなければ `unknownEnd = endedAt == nil`、`end = max(end, endedAt ?? startedAt)`
  5. 最後の塊を確定して返す

### 13. `ModelVerificationCache.swift`

```swift
/// 照合済みのモデルの SHA-256 を覚える（PLAN §8.10）。(path, inode, size, mtime) が変わっていなければ照合を飛ばせる。メモリだけ（何も書かない。診断が使う）。
public actor ModelVerificationCache {
    public init()
    public func verifiedSHA256(path: String, inode: UInt64, size: Int64, mtime: Double) -> String?
    public func record(path: String, inode: UInt64, size: Int64, mtime: Double, sha256: String)
}
```
中身は `[String: (inode: UInt64, size: Int64, mtime: Double, sha256: String)]`。`verifiedSHA256` は 4 つが全部一致したときだけ sha256 を返す。`record` は上書き。

### 14. TestSupport

```swift
/// 手で進める時計。now と uptime を同じだけ進める。
public final class FixedClock: AppClock {
    public init(now: Instant, uptime: Duration = .zero)
    /// `init(now: Instant(epochMillis:))` の短縮（T-11・T-14 などが使う）。
    public convenience init(epochMillis: Int64)
    public func now() -> Instant
    public func uptime() -> Duration
    public func set(_ now: Instant)
    public func advance(seconds: Int)
    public func advance(milliseconds: Int64)
}
/// now() と uptime() のどちらも、呼ばれるたびに step ずつ進む時計（経過時間・時間上限を測る処理のテスト用。00-api-map §15）。
/// now() は start、start + step、start + 2·step … を、uptime() は .zero、step、2·step … を返す（返してから進める）。now と uptime は別々に数える。
public final class SteppingClock: AppClock {
    public init(start: Instant, stepMilliseconds: Int64)
    public func now() -> Instant
    public func uptime() -> Duration
}
/// 待たずに待ち秒を記録する。clock を渡すとその秒数だけ進める。
public final class RecordingSleeper: Sleeper {
    public init(clock: FixedClock? = nil)
    public func sleep(seconds: Int) async throws
    public var recorded: [Int] { get }
}
/// 行を覚える LogSink（00-api-map §15 の `CapturingLogSink`）。
public final class CapturingLogSink: LogSink {
    public init()
    public func write(line: String, level: LogLevel, category: String)
    public var lines: [String] { get }
}
```
可変状態は `Synchronization.Mutex` で守る（`import Synchronization`。macOS 15 以上。`@unchecked Sendable` を使わない）。
`TempDirectory` は T-01 が作る（T-01 §9。このチケットでは作らない）。

## テスト

`@testable import VDCore`、`import VDContract`、`import TestSupport`。

### `Tests/VDCoreTests/InstantTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `dateRoundTripFloors` | `Date からの変換はミリ秒未満を切り捨てる` | `Date(timeIntervalSince1970: 1.9999)` → 1999、`-0.0005` → -1 |
| `addingAndDifference` | `足し算と差はミリ秒の整数` | `adding(seconds: 300)` と `-` |
| `whisperSecondsToMillis` | `whisper の秒はミリ秒に丸めて戻す` | `9.001 → 9001`、`12.999 → 12999`、`3.2 → 3200`、`0.0005 → 1`、`0.0004 → 0` |

### `Tests/VDCoreTests/ClockTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `systemClockUptimeIsMonotonic` | `SystemClock の uptime は減らない` | 2 回読んで 2 回目 ≥ 1 回目 |
| `taskSleeperZeroReturnsImmediately` | `0 秒の待ちはすぐ返る` | 例外なし |
| `fixedClockAdvances` | `FixedClock は now と uptime を同じだけ進める` | |
| `steppingClockAdvancesBoth` | `SteppingClock は now と uptime を呼ぶたびに別々に進める` | `SteppingClock(start: Instant(epochMillis: 1000), stepMilliseconds: 500)` で `now()` 2 回 → 1000・1500、続けて `uptime()` 2 回 → `.zero`・`.milliseconds(500)`、もう一度 `now()` → 2000 |
| `recordingSleeperRecords` | `RecordingSleeper は待たずに記録する` | `[3, 10]`、clock を渡すと 13 秒進む |

### `Tests/VDCoreTests/ZonedTimeTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `isoTokyo` | `ISO は秒まで・オフセット付き` | `Asia/Tokyo` で 2026-08-30 07:00:12.999 JST → `2026-08-30T07:00:12+09:00`（切り捨て） |
| `isoUTCHasPlusZero` | `UTC は +00:00（Z にしない）` | |
| `isoNegativeOffset` | `負のオフセット` | `America/New_York` の夏 → `…-04:00` |
| `isoNegativeEpochFloors` | `紀元前の秒の切り捨ては −∞ 方向` | `epochMillis = -1` → `1969-12-31T23:59:59+00:00` |
| `parseRoundTrip` | `iso → parseISO は秒単位で一致` | ランダムでない固定の 5 つの時刻で `parseISO(iso(x)) == x（秒に切り捨てたもの）` |
| `parseRejectsOtherForms` | `iso が作らない形は読まない` | `2026-08-30T07:00:12Z`、`2026-08-30 07:00:12+09:00`、`2026-08-30T07:00:12.5+09:00`、`2026-02-30T00:00:00+09:00`、`2026-08-30T07:00:12+0900` → nil |
| `parseSecondsOffset` | `秒付きのオフセットを読む` | `1900-01-01T00:00:00+09:18:59` |
| `fileNameTimeIsAttachedNotConverted` | `ファイル名の時刻にはタイムゾーンを付与するだけ（TIME-03）` | `LocalDateTime(2026,8,29,7,12,4)` を JST と UTC で `instant(of:)` → `iso` がどちらも `07:12:04` を含む |
| `localDateAt2350` | `23:50 の Part の日付は設定のタイムゾーンで決まる（TIME-02）` | `2026-08-29T14:50:00+00:00` の Instant → JST の localDate は 2026-08-29 23:50 → `20260829`、UTC では `20260829`、`2026-08-29T15:10:00+00:00` は JST で `20260830` |
| `localDateArithmetic` | `日付の足し算は月末・閏年をまたぐ` | `2024-02-28 +1 = 2024-02-29`、`2023-02-28 +1 = 2023-03-01`、`2026-12-31 +1 = 2027-01-01`、`2026-01-01 -1 = 2025-12-31` |
| `localDateParse` | `LocalDate は dashed と stamp を読み書きする` | `2026-08-29` ⇄ `20260829`、`2026-8-29` → nil、`20260230` → nil |
| `fixedOffsetZone` | `固定オフセットのゾーンは夏時間をまたいでも同じオフセットで描く` | `ZonedTime(fixedOffsetSeconds: -18000)` で 2026-03-08T12:00:00Z → `2026-03-08T07:00:00-05:00`（America/New_York なら `08:00:00-04:00`）、`fixedOffsetSeconds: 999999` は UTC（`+00:00`） |
| `wallClockFromString` | `壁時計は保存文字列の数字をそのまま` | `hhmm("2026-08-29T07:12:04+09:00") == "07:12"`、`hhmmss == "07:12:04"`、`"garbage"` → nil |

### `Tests/VDCoreTests/LogTests.swift`

準備: `CapturingLogSink`、`FixedClock(now: parseISO("2026-08-30T07:00:12+09:00"))`、`ZonedTime(Asia/Tokyo)`。

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `eventsMatchAppendixA4` | `イベントは付録 A.4 の順（48 個）` | `LogEvent.allCases.map(\.rawValue)` を付録 A.4 の 48 語の逐語の配列と比較 |
| `lineFormat` | `行の書式は voicedock と同じ` | `info(.serviceStarted, [(.version, "1.0.0")])` → `2026-08-30T07:00:12+09:00 INFO  service_started version=1.0.0` |
| `levelTokens` | `レベルの表記` | 4 つの token が `DEBUG` / `INFO ` / `WARNING` / `ERROR` |
| `valueFormats` | `値の書式` | `null`・`true`・`42`・`1800.0`・`abc`・`"a b"`・`""`（空文字は `""`）・`"a=b"`・`"日本語"`・`"x\"y"` → `"x\"y"` の JSON 表記 |
| `newlineIsQuoted` | `改行を含む値は必ず引用する` | `"abc\n"` → `"abc\n"`（JSON 表記） |
| `contentKeysAreRedacted` | `本文のキーは常に <redacted>（PR-08）` | 15 個のキーそれぞれに短い値を渡し、すべて `<redacted>` |
| `longValuesAreRedacted` | `200 スカラーを超える文字列は <redacted>` | 200 スカラーはそのまま（`"a"×200`）、201 は `<redacted>`、結合文字を含む 201 スカラーも `<redacted>`（書記素では 200 未満） |
| `thresholdFilters` | `閾値未満は出さない` | 閾値 INFO で debug は 0 行、warning は 1 行 |
| `ceLoggingLevel` | `CE logging.level WARNING にすると INFO を出さない` | `LogLevel(configValue: "WARNING")` を閾値にした AppLog で info 0 行・warning 1 行。`LogLevel(configValue: "info")` は nil |
| `ceLoggingUnsafeContent` | `CE logging.unsafeLogContent true でも DEBUG の行だけ本文を出す` | unsafe true・閾値 DEBUG: debug の `text=abc` は `abc`、info の `text=abc` は `<redacted>`。unsafe false: debug でも `<redacted>` |
| `withCategoryKeepsSettings` | `withCategory は閾値と遮断を引き継ぐ` | sink に渡る category が変わる |
| `logKeysHaveNoReservedNames` | `予約名 ts / level / event はキーに無い` | `LogKey(rawValue:)` が 3 つとも nil |

### `Tests/VDCoreTests/LogFileTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `appendsLines` | `行を追記する` | 2 行書いて中身が `a\nb\n` |
| `rotatesBeforeExceeding` | `上限を超える書き込みの前に .1 へ回す` | maxBytes 10 で `12345\n`（6）→ `6789\n`（5。11 > 10）: `app.log.1` が `12345\n`、`app.log` が `6789\n`。ちょうど上限に届く `12345\n`（6）→ `678\n`（4。10 = 10）は回さない（`.1` が無く `app.log` が `12345\n678\n`） |
| `rotationReplacesOldBackup` | `.1 は 1 世代だけ` | 3 回回して `.1` が直前の中身 |
| `unwritableDirectoryDoesNotThrow` | `書けない場所でも落ちない` | 存在しないディレクトリの URL で write しても例外にならない |

### `Tests/VDCoreTests/SafeUnlinkTests.swift`

準備: `TempDirectory` を `<HOME>` にした `HomeLayout(root:)` で `createDirectories()`。

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `removesFileUnderRoot` | `ルート配下の通常ファイルを消す` | staging/slug/audio16k.wav が消える |
| `missingIsOKByDefault` | `無いファイルは既定では何もしない` | 例外なし。`missingOK: false` では `.notFound` |
| `refusesRelative` | `相対パスは拒否` | `.notAbsolute` |
| `refusesDotDot` | `.. を含むパスは拒否` | `staging/../inbox/x` → `.containsDotDot` |
| `refusesOutsideRoot` | `ルートの外は拒否` | inbox のファイルを `.staging` で消そうとする → `.outsideRoot` |
| `refusesPrefixSibling` | `接頭辞だけ一致する兄弟は配下ではない` | `<HOME>/staging-old/x` → `.outsideRoot` |
| `refusesRootItself` | `ルートそのものは消させない` | `removeEmptyDirectory(layout.staging, …)` → `.outsideRoot` |
| `refusesSymlinkTarget` | `symlink はリンクも消さない` | staging のリンク → `.isSymlink`、リンク先は残る |
| `refusesSymlinkedParentEscape` | `親の symlink でルートの外へ出られない` | staging/evil → `/tmp/…` の symlink の下のファイル → `.outsideRoot` |
| `refusesDirectory` | `ディレクトリは remove で消さない` | `.notRegularFile` |
| `queueOnlyDirectJSON` | `queue は直下の .json だけ` | `queue/delete/x.json` は消せる、`x.txt` と `sub/x.json` は `.nameNotAllowed` |
| `vaultTmpOnlyDotTmp` | `Vault は .<name>.tmp だけ` | `.2026-08-29 raw.md.tmp` は消せる、`2026-08-29 raw.md` と `.tmp` と `.x.tm` は `.nameNotAllowed` |
| `vaultSymlinkedDirectoryAllowed` | `Vault 内の symlink のディレクトリ経由は許す（voicedock どおり）` | Vault/Daily が Vault/real への symlink のとき Vault/Daily/.a.md.tmp を消せる |
| `removeEmptyDirectoryKeepsNonEmpty` | `中身のあるディレクトリは消さない` | 例外なしで残る。空なら消える |

### `Tests/VDCoreTests/AppPathsTests.swift`・`FileHasherTests.swift`・`TextLimitTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `appPathsLayout` | `AppPaths の各パス` | resources/prompts、resources/ModelCatalog.json、helpers/whisper-cli、helpers/llama-server、helpers/voicedock-reaper |
| `sha256OfFileMatchesData` | `ファイルの SHA-256 はデータの SHA-256 と同じ` | 3 MiB のデータを chunk 1 MiB と 7 バイトで読んでも同じ。空ファイルは `e3b0c442…b855` |
| `sha256Lowercase` | `16 進は小文字` | `sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"` |
| `scalarCount` | `文字数は Unicode スカラー数（CR-23）` | `"が"`（合成済み）1、`"か\u{3099}"` 2、`"👨‍👩‍👧"` 5 |
| `truncate200` | `200 文字の切り詰め` | 200 はそのまま、201 は 199 + `…`（合計 200 スカラー）、絵文字の途中で切れてもスカラー単位 |

### `Tests/VDCoreTests/TranscriptCodecTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `encodeMatchesVoicedock` | `符号化は voicedock の実測と同じバイト列` | 移植メモ V4 §2.5 の例（partkey・`"ja"`・1800.0・`2026-08-29T07:12:04+09:00`・text・2 segments）を encode した文字列が、テストに逐語で埋め込んだ JSON（indent 2、`"start": 0.0` など、末尾改行 1 つ）と一致。T-25 の golden があればそれと比べる |
| `encodeNullDuration` | `duration が無ければ null、segments が無ければ []` | `"duration_seconds": null`、`"segments": []` |
| `decodeRoundTrip` | `書いて読むと同じ` | |
| `decodeRejects` | `合格条件を 1 つでも満たさなければ nil` | キー欠落（6 通り）、segments が辞書でない、start が文字列、start が true、text が数、duration が true、partkey が数、JSON でない |
| `decodeAllowsExtraKeys` | `ほかのキーがあってもよい` | `"x": 1` を足しても読める |

### `Tests/VDCoreTests/SessionTranscriptTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `fingerprintMatchesVoicedock` | `指紋は voicedock の実測と同じ（PLAN §8.5）` | base = `parseISO("2026-08-29T07:12:04+09:00")`、segments `(base, base+3200ms, "おはようございます。")`・`(base+9001ms, base+12999ms, "今日は/\"x\"")`、blocks `[(base, base+1800s)]` → `894a61422b5c95830fe8b36c33ae2c3af728851d00a5e02e9f691d61ad5fb86f` |
| `fingerprintIgnoresExcluded` | `除外 Part は指紋に入らない` | excludedPartkeys を変えても同じ値 |
| `blocksEmpty` | `Part が無ければ Block も無い` | `[]` |
| `blocksBackToBack` | `続けて録った Part は 1 つ` | 9:00–9:30 と 9:30–10:30 → 1 つ（9:00–10:30） |
| `blocksExactThresholdDoesNotSplit` | `ちょうど閾値の間隔は区切らない` | 間隔 3600 秒 → 1 つ |
| `blocksOneSecondOverSplits` | `1 秒超えると区切る` | 3601 秒 → 2 つ |
| `blocksOrderDoesNotMatter` | `入力の順は問わない` | 逆順でも同じ |
| `blocksUnknownEndAlwaysSplits` | `終了不明の Part の後は必ず区切り、その開始を塊の終わりにする` | `[(9:00, nil), (9:01, 9:30)]` → `[(9:00, 9:00), (9:01, 9:30)]` |
| `blocksOverlapAndContain` | `重なりは 1 つ、内包で短くしない` | 9:00–9:30 と 9:10–9:40 → 9:00–9:40、9:00–10:00 と 9:10–9:20 → 9:00–10:00 |
| `blocksZeroGap` | `閾値 0 でも続けて録った Part は 1 つ` | |

### `Tests/VDCoreTests/GoldenCoreTests.swift`（`@Suite("golden core") struct GoldenCoreTests`。T-25 §4.11 の形）

共通: `zone = ZonedTime(timeZone: TimeZone(identifier: item.string("timeZone")))`（nil は `#require` で落とす）。時刻は T-25 §4.3 の約束（`base` を `zone.parseISO` で読み、`…Ms` はミリ秒の整数で `adding(milliseconds:)`、`…S` は秒で `adding(seconds:)`）。

| 関数名 | 表示名 | 準備（`arguments`） | 期待 |
|---|---|---|---|
| `goldenKeys(item:)` | `golden keys` | `Golden.cases("keys")` | `kind` が `partkey` なら `PartKey.make(deviceID:relpath:)`、`sessionKey` なら `SessionKey.make(deviceID:, dayStamp: zone.localDate(zone.parseISO(startedAt)).stamp, overflow:)`。`GoldenAssert.matchesJSON(["key": key, "slug": KeySlug.of(key)], group: "keys", name:)` |
| `goldenFingerprint(item:)` | `golden fingerprint` | `Golden.cases("fingerprint")` | `segments`（`atMs`・`endMs`・`text`）と `blocks`（`startMs`・`endMs`）から `SessionTranscript(dayDate: LocalDate(dashed: day), …, excludedPartkeys: [])` を作り、`TranscriptFingerprint.payload(t, zone:) + "\n" + TranscriptFingerprint.of(t, zone:) + "\n"` を `GoldenAssert.matches`（バイト一致） |
| `goldenBlocks(item:)` | `golden blocks` | `Golden.cases("blocks")` | `parts`（`startS`・`endS`（null 可））を `(base + startS, endS.map { base + $0 })` にして `BlockComputer.blocks(_, gapSeconds:)`。結果を `[[zone.iso(start), zone.iso(end)], …]` の `GoldenJSON` にして `GoldenAssert.matchesJSON` |
| `goldenGroupsHaveCases` | `golden keys・fingerprint・blocks のケースが在る` | — | 3 グループとも `Golden.cases` が空でない（TEST-28） |

### `Tests/VDCoreTests/ModelVerificationCacheTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `returnsOnlyWhenAllMatch` | `4 つが全部一致したときだけ返す` | inode・size・mtime のどれか 1 つが違えば nil |

## 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| `ZonedTime.iso` の秒の切り捨てを四捨五入にする | `isoTokyo`、`fingerprintMatchesVoicedock` |
| `LogFormatter` の本文キーの遮断を消す | `contentKeysAreRedacted` |
| 長さの判定を `s.count > 200` にする | `longValuesAreRedacted`（結合文字の例） |
| `AppLog` の遮断の条件を「閾値が DEBUG」にする | `ceLoggingUnsafeContent` |
| `formatValue` の plain の判定から `=` の除外を消す | `valueFormats` |
| `LogFile` の回転の条件を `size + n >= maxBytes` にする | `rotatesBeforeExceeding` |
| `SafeUnlink` の 5 の判定を `hasPrefix(ルート)`（`/` を付けない）にする | `refusesPrefixSibling` |
| `SafeUnlink` の lstat の symlink 検査を消す | `refusesSymlinkTarget` |
| `BlockComputer` の `gap >` を `>=` にする | `blocksExactThresholdDoesNotSplit` |
| `BlockComputer` の `unknownEnd \|\|` を消す（読まれない変数の警告がエラーになるので直前に `_ = unknownEnd` を置く） | `blocksUnknownEndAlwaysSplits`、`goldenBlocks(item:)`（`null_end_forces_split`） |
| `PartTranscriptCodec.decode` の bool の除外を消す | `decodeRejects` |
| `TranscriptFingerprint` の `sortKeys: true` を false にする | `fingerprintMatchesVoicedock`、`goldenFingerprint(item:)` |

## 受け入れ条件

- [ ] 上のファイルがあり、`make lint` と `make test` が通る
- [ ] `Date()`・`ContinuousClock` を読んでいるのが `Clock.swift` だけ（PT-09）、`Logger(` が `Log.swift` だけ（PT-08）、`unlink(` / `rmdir(` が `SafeUnlink.swift` だけ（PT-01）
- [ ] `@unchecked Sendable` を使っていない（PT-14）
- [ ] 指紋の固定値と transcript の符号化が voicedock の実測と一致する（golden の `keys`・`fingerprint`・`blocks` も全ケース一致）
- [ ] ConfigEffect の網羅テスト（T-09）で `logging.level` と `logging.unsafeLogContent` が covered になる（本チケットの `CE` テスト）
- [ ] 破壊による証明の結果を PR 本文に貼った

## SPEC の変更

- `docs/SPEC.md` の付録 A.4（ログイベント）は T-05 が PLAN から写したものを使う。SPEC 同期（T-05）の「ログイベントの出現順 = `LogEvent` の宣言順」をこのチケットで有効にする（`Tests/VDCoreTests/SpecSyncLogEventsTests.swift`。T-05 §5 の全文: `logEventsMatchSpec` /「LogEvent の宣言順が SPEC と同じ」= `LogEvent.allCases.map(\.rawValue) == SpecDocument.load().logEvents()`。PolicyTests は VDCore を `@testable import` しないので VDCoreTests に置く）

## マージ後にやること

なし

## API 地図への変更提案

→ 以下はすべて 00-api-map に反映済み（2026-09-18）。TestSupport の部品の名前は地図 §15 に合わせた（`MemoryLogSink` → `CapturingLogSink`、`TempDirectory` は T-01 が作る）。`ZonedTime.init(fixedOffsetSeconds:)` と `FixedClock.init(epochMillis:)` は地図と後続のチケットに合わせて足した。

- **`OSLogSink` を `LogFile.swift` から `Log.swift` へ移す**（PT-08 は `Logger(` を `VDCore/Log.swift` だけに許す。00-api-map §2.3 は LogFile.swift に置いていた）。あわせて `OSLogSink.init(subsystem:)` とし、category は `LogSink.write(line:level:category:)` の引数で渡す（AppLog の category ごとに os.Logger を作るため）
- `LogSink.write` の引数に `category: String` を足す、`AppLog` に `category` と `withCategory(_:)` を足す
- `LogValue` にリテラルの準拠と `of(_:)` を足す、`LogLevel.init?(configValue:)` を足す
- `ZonedTime.localDateTime(_:)`、`LocalDate.init?(year:month:day:)`・`init?(stamp:)`、`Instant.init(date:)`・`.date` を足す
- `SafeUnlinkError` の全ケース（本チケット §8）を 00-api-map に載せる
- README の一覧の前提を直す: **T-10 は T-45 に依存する**（PyJSON）。依存順を T-08 → T-45 → T-10 → T-09 にする
- TestSupport の許可 import に `Synchronization` を足す（PLAN §3.4 の TestSupport の行。`Mutex` のため）
- （整合修正で追記。地図に合わせた）`TeeSink` を地図 §2.3 の置き場所 `LogFile.swift` へ移した。`AppLog.init` の `category` の既定を地図の `"core"` にした。`LogFile` の状態は地図 §0 に合わせて `Mutex` で守る。`SteppingClock` は地図 §15 のとおり `now()` と `uptime()` の両方を進める
- （整合修正で追記）T-25 が本チケット向けに作る golden（`keys`・`fingerprint`・`blocks`）の照合を `GoldenCoreTests` に足した（`TranscriptFingerprint.payload` は internal）
- （整合修正で追記）00-api-map §15 は `TempDirectory` の作り手を T-06 と書くが、T-01 が作る（T-01 §9）。地図を T-01 に直すことを提案する
- （実装で追記）`TranscriptSegment`・`PartTranscript`・`AbsoluteSegment`・`TimeBlock`・`SessionTranscript` に全フィールドの `public init` を足した（本チケット §11・§12）。memberwise init は internal なので、T-17（VDTranscribe）・T-22（VDPipeline）など別モジュールが作れない。地図 §2.3 の各行に `public init(…全フィールド)` を足すことを提案する → 利用者が承認し、00-api-map §2.3 に反映済み（2026-09-21）
- （実装で追記）`swift format` の整形に合わせて §5 の `LogLevel`・`LogValue`・`LogKey` と §8 の `SafeUnlinkError` のケースの書き方を直した（値と順は同じ）。§7・§8 のパスは 00-api-map §0 に合わせて `url.path(percentEncoded: false)` にした
