# API 地図（全モジュールのファイル・公開型・関数）

> **この文書はチケット間の契約である。**各チケットはここに書かれた名前・シグネチャ・置き場所に従う。
> チケットを書く／実装するときに、ここに無い「モジュールをまたぐ API」が要ると分かったら、**この文書とそのチケットを同じ PR で直す**（勝手に別名を作らない。CR-18）。
> モジュール内だけで使う型・関数（`internal` / `private`）は各チケットで決めてよい。
> 仕様の根拠は `docs/PLAN.md`（= 計画書 v1.1）。節番号は PLAN の節。

## 0. 全体の約束

- Swift 6 言語モード、strict concurrency complete。モジュールをまたぐ値はすべて `Sendable`
- 公開する宣言は `public`。テストからだけ触るものは `internal` にして `@testable import` で使う
- 1 ファイル 1 主要型。ファイル名 = 主要型の名前（`Foo.swift`）。拡張は `Foo+Bar.swift`
- 失敗の表し方:
  - **運用上の失敗**（ErrorCode を持つ）: `StageFailure`（VDCore）を返すか投げる
  - **プログラムの誤り・前提違反**: モジュールごとの `enum <名前>Error: Error, Equatable, Sendable`
  - 「不明」は Optional の nil か専用の enum（CR-04 / §9.1）
- 時刻は `Instant`（Int64 ミリ秒）。`Date` は `SystemClock` と、Foundation の API が要求する境界でだけ作る（PT-09）
- 文字数は Unicode スカラー数（CR-23）。Python 互換の処理は `PyText` / `PyJSON`（CR-24）
- ログは `AppLog`。値は `LogValue`、キーは `LogKey`（登録制）、イベントは `LogEvent`（登録制）
- パスは `HomeLayout` と `AppPaths` から得る。文字列で組み立てない。`URL` からパス文字列を取るときは `url.path(percentEncoded: false)` だけを使う
- 文字列の比較: Swift の `==`・ハッシュ・辞書のキーは**正準等価**で比べる（「が」と「か＋濁点」が等しい）。sanitize・重複除去・Vault 索引・JSON のキー・partkey の照合など**バイト一致が要る所ではスカラー列で比べる**（`PyText.scalarsEqual`、または `Array(s.unicodeScalars)` の比較）
- 共有の可変状態は actor か `Synchronization.Mutex` で持つ（`@unchecked Sendable` を使わない。PT-14）。`Synchronization` はすべてのモジュールで import してよい

---

## 1. VDContract（T-06 / T-07）— Foundation・Darwin・CryptoKit だけ

| ファイル | 公開宣言 |
|---|---|
| `Version.swift` | `public enum AppVersion { public static let string: String /* VERSION と同じ */; public static func components(_ s: String) -> (major: Int, minor: Int, patch: Int)?; public static func isSame(_ a: String, _ b: String) -> Bool }` |
| `Contract.swift` | `public enum Contract { mtimeToleranceSeconds = 2.0; requestSchema = 1; resultSchema = 1; reaperConfSchema = 1; reaperFileName = "voicedock-reaper"; volumesRoot = "/Volumes"; expectedFilesystem = "msdos"; maxRequestBytes = 65_536 }` |
| `LocalDateTime.swift` | `public struct LocalDateTime: Equatable, Hashable, Sendable, Comparable { year, month, day, hour, minute, second: Int; public init?(year:month:day:hour:minute:second:) /* 整数範囲の検査。§4.1 */; public var dayStamp: String /* yyyyMMdd */; public static func daysInMonth(year: Int, month: Int) -> Int /* VDCore の LocalDate と共有 */ }` |
| `PatternMatch.swift` | internal。`NSRegularExpression` の全体一致（T-06） |
| `PosixIO.swift` | internal。errno を返す低水準の読み書き（T-06。AtomicFile・ReaperConf・TargetIdentity が使う） |
| `RecordingName.swift` | `public enum RecordingName { static let filePattern: String; static let folderPattern: String; static func parseFile(_ name: String) -> ParsedFile?; static func matchesFilePattern(_ name: String) -> Bool /* 形だけ。日時は見ない */; static func isFolder(_ name: String) -> Bool }`、`public struct ParsedFile: Equatable, Sendable { transmitterID: String; micIndex: Int; local: LocalDateTime; isOrig: Bool; ext: String }` |
| `DeviceID.swift` | `public enum DeviceID { static func isValid(_ id: String) -> Bool }` |
| `RelPath.swift` | `public enum RelPath { static let maxUTF8Bytes = 1024; static func isSafe(_ relpath: String) -> Bool; static func components(_ relpath: String) -> [String] /* 空要素を省かない。Unicode スカラーの "/"（UTF-8 の 0x2F）で分割し、先頭の "/"・"." 始まりもスカラーで見る（F-73） */; static func join(_ components: [String]) -> String /* relpath の結合はこれだけ。PT-06 */; static func parent(_ relpath: String) -> String /* 直下なら "" */; static func lastComponent(_ relpath: String) -> String }` |
| `KeyError.swift` | `public enum KeyError: Error, Equatable, Sendable { case invalidDeviceID, unsafeRelpath, invalidDayStamp, invalidOverflow, malformedKey }` |
| `PartKey.swift` | `public enum PartKey { static func make(deviceID: String, relpath: String) throws(KeyError) -> String; static func deviceID(of partkey: String) -> String?; static func relpath(of partkey: String) -> String? }` |
| `SessionKey.swift` | `public enum SessionKey { static func make(deviceID: String, dayStamp: String, overflow: Int = 1) throws(KeyError) -> String; static func deviceID(of key: String) -> String?; static func dayStamp(of key: String) -> String?; static func overflow(of key: String) -> Int?; static func nextOverflow(_ key: String) throws(KeyError) -> String }` |
| `KeySlug.swift` | `public enum KeySlug { static func of(_ key: String) -> String /* sha256 hex 先頭 16 */ }` |
| `RequestID.swift` | `public enum RequestID { static let pattern = "^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}-[0-9a-f]{6}$"; static func make(partkey: String, utcEpochSeconds: Int64, randomHex6: String) -> String; static func randomHex6() -> String /* SystemRandomNumberGenerator の 3 バイト */; static func isValid(_ id: String) -> Bool }` |
| `DeleteRequest.swift` | `public struct DeleteRequest: Equatable, Sendable { schema: Int; requestID, createdAt, deviceID, partkey, sessionKey: String; target: DeleteTarget; public init(…全フィールド) }`、`public struct DeleteTarget: Equatable, Sendable { relpath: String; size: Int64; mtime: Double; public init(relpath:size:mtime:) }`（JSON では `targets` の 1 要素配列） |
| `DeleteResult.swift` | `public struct DeleteResult: Equatable, Sendable { schema: Int; requestID, completedAt, reaperVersion, deviceID, partkey: String; status: DeleteResultStatus; detail: String; public init(…全フィールド) }`、`public enum DeleteResultStatus: String, Sendable { case deleted = "DELETED"; case sourceIdentityMismatch = "SOURCE_IDENTITY_MISMATCH" }`（PT-06 の許可場所に含める） |
| `ContractJSON.swift` | `public enum ContractJSON { static let requestKeys, targetKeys, resultKeys: Set<String>; static func encode(_ r: DeleteRequest) throws(ContractEncodeError) -> Data; static func encode(_ r: DeleteResult) throws(ContractEncodeError) -> Data; static func decodeRequest(_ data: Data) -> Result<DeleteRequest, ContractDecodeError>; static func decodeResult(_ data: Data) -> Result<DeleteResult, ContractDecodeError> }`、`public enum ContractEncodeError: Error, Equatable, Sendable { case nonFiniteNumber }`、`public enum ContractDecodeError: Error, Equatable, Sendable { case notJSONObject, keySetMismatch, wrongType(String), badSchema, badTargets }`（細部は T-06） |
| `ReaperConf.swift` | `public struct ReaperConf: Equatable, Sendable { schema: Int; deleteSourceAudio: Bool; volumesRoot: String; public init(deleteSourceAudio: Bool, volumesRoot: String = Contract.volumesRoot); static let keySchema, keyDeleteSourceAudio, keyVolumesRoot: String; static let linePattern: String; static func parse(_ data: Data) -> Result<ReaperConf, ReaperConfError>; func render() -> Data; static func observe(at url: URL) -> ReaperConfObservation }`、`public enum ReaperConfObservation: Equatable, Sendable { case missing, invalid(ReaperConfError), valid(ReaperConf) }`、`public enum ReaperConfError: Error, Equatable, Sendable { case unreadable, tooLarge, notRegularFile, badLine(Int), unknownKey(String), duplicateKey(String), missingKey(String), badValue(String) }` |
| `HomeLayout.swift` | `public struct HomeLayout: Equatable, Sendable { public let root: URL; init(root: URL); static func production() -> HomeLayout; func createDirectories() throws` + 下記の計算プロパティと関数 |
| `AtomicFile.swift` | `public enum AtomicFile { static func write(_ data: Data, to url: URL, permissions: mode_t = 0o644, verifyReadBack: Bool = false) throws(AtomicFileError); static func tmpURL(for url: URL) -> URL /* .<name>.tmp */ }`、`public enum AtomicFileError: Error, Equatable, Sendable { case open(errno: Int32), write(errno: Int32), fsync(errno: Int32), readBackMismatch, rename(errno: Int32) }` |
| `FileLock.swift` | `public final class FileLock: Sendable { static func tryAcquire(url: URL) -> FileLock? /* open(O_RDWR\|O_CREAT\|O_NOFOLLOW, 0644) → flock(LOCK_EX\|LOCK_NB)。取れなければ nil（symlink も。F-73） */; func release() /* LOCK_UN。何度呼んでもよい。fd を閉じるのは deinit */ }`（アプリの IngestService（1 秒ごとに最大 130 回試す）と reaper（1 回だけ試す）が共有。PT-12 の許可場所） |
| `TargetIdentity.swift` | `TargetIdentity.openVolume(volumesRoot:deviceID:) -> VolumeOpenResult`、`TargetIdentity.withVerifiedTarget(volume:relpath:expectedSize:expectedMtime:_:) -> Result<R, IdentityMismatch>`、`VolumeOpenResult`、`VolumeHandle`（`final class`、internal init。本番で作るのは `openVolume` だけ。PT-22）、`VerifiedTarget`、`IdentityMismatch`（`public init(_ reason: String)`）、`IdentityReason`（reaper が使う全理由語 21 個の定数と `static let all`。T-07）、`public protocol VolumeOpener: Sendable { func open(volumesRoot: String, deviceID: String) -> VolumeOpenResult }`、`public struct SystemVolumeOpener: VolumeOpener { public init() }`（`openVolume` を呼ぶだけ） |

`HomeLayout` のプロパティ（すべて `URL`。§2.3 と一対一）:
`configFile`（config.json）、`database`（voicedock.sqlite）、`inbox`、`staging`、`transcriptsParts`（transcripts/parts）、`analysis`、`queueDelete`、`queueResult`、`queueRejected`、`stateDirectory`、`processedLog`、`reaperLock`、`appLock`（state/app.lock。アプリの単一起動のロック。F-76）、
`runDirectory`、`llamaAPIKeyFile`（run/llama-api-key）、`binDirectory`、`reaperExecutable`、`reaperConf`、`modelsDirectory`、`logsDirectory`、`appLog`、`reaperLog`、`uiState`（ui-state.json）。
関数: `stagingDirectory(slug:)`、`normalizedAudio(slug:)`（audio16k.wav）、`normalizedAudioTmp(slug:)`（audio16k.wav.tmp）、`whisperOutputBase(slug:)`（staging/<slug>/whisper）、`whisperJSON(slug:)`、
`transcript(slug:)`、`analysisJSON(sessionSlug:)`、`timelineJSON(sessionSlug:)`、`sourceJSON(sessionSlug:)`、`inboxFile(deviceID:relpath:)`、`inboxPartial(deviceID:relpath:)`、
`models(kind: String) -> URL`（models/<kind>）、`modelFile(kind: String, file: String)`、`modelPart(kind: String, file: String)`（models/<kind>/.<file>.part）、`modelResume(file: String)`（models/.<file>.resume）、
`relativePath(of url: URL) -> String?`（root からの相対 POSIX。配下でなければ nil）、`url(relative: String) -> URL`。
`createDirectories()` は root・inbox・staging・transcripts/parts・analysis・queue/delete・queue/result・queue/rejected・state・run・models/whisper・models/vad・models/llm・logs を作る（**bin は作らない**）。

---

## 2. VDCore（T-08 / T-09 / T-10 / T-45）

### 2.1 状態・エラー（T-08）

| ファイル | 公開宣言 |
|---|---|
| `RawNoteMembership.swift` | `public enum RawNoteMembership { static func isMember(status: PartStatus, transcriptReadable: Bool) -> Bool /* rawNoteMembers ∧ 読める */ }`（書き手と検証側が同じ関数で Part 集合を作る。PLAN §8.6・§8.7。行の型に依存しないよう VDCore に置き、VDPipeline が `RecordingRow` と transcript の読み取り結果を渡す） |
| `States.swift` | `public enum PartStatus: String, CaseIterable, Sendable`（12 値。宣言順 = 付録 A.1）、`public enum SessionStatus: String, CaseIterable, Sendable`（13 値）、`public enum TransitionKind: Sendable { case normal, recovery }`、`public struct Edge<S: Hashable & Sendable>: Hashable, Sendable { from: S; to: S }`、`public enum PartStates { static let terminal, deletable, stagingDisposable, awaitingDeletion, rawNoteMembers, inboxLeftover, inProgress, retryableFromFailed, retryReset, normalizable, transcribable, rawWritable, normalizedOrBeyond, transcribedOrBeyond, rawSavedOrBeyond: Set<PartStatus> }`、`public enum SessionStates { static let inProgress, retryableFromFailed, retryReset, mergeable, analyzable, writable, processable, reopenable, deleteEvaluated, cleanupFrom, savedOrBeyond, mergedOrBeyond: Set<SessionStatus> }`、`public enum SkipReasons { static let deletable: Set<ErrorCode>; static let benign: Set<ErrorCode> }`、`public enum TransitionTable { static let part: Set<Edge<PartStatus>>; static let session: Set<Edge<SessionStatus>>; static let partRecovery: [Edge<PartStatus>] /* 順序付き */; static let sessionRecovery: [Edge<SessionStatus>]; static func allows(_ e: Edge<PartStatus>, kind: TransitionKind) -> Bool; static func allows(_ e: Edge<SessionStatus>, kind: TransitionKind) -> Bool }` |
| `ErrorCode.swift` | `public enum ErrorCode: String, CaseIterable, Sendable`（32 値。宣言順 = 付録 A.3）、`public enum RetryPolicy: Sendable { case none, nextPoll, nextConnect, attempts }`、`extension ErrorCode { var retryPolicy: RetryPolicy; var countsAgainstMaxAttempts: Bool /* retryPolicy == .attempts */; var declarationIndex: Int; var skipReasonWord: String? /* source_missing 等 */ }` |
| `StageFailure.swift` | `public struct StageFailure: Error, Equatable, Sendable { public let code: ErrorCode; public let message: String; public init(_ code: ErrorCode, _ message: String) }` |
| `RetryDelay.swift` | `public enum RetryDelay { static func inProcess(retryCount: Int, maxAttempts: Int, backoff: [Int]) -> Int?; static func deleteEvaluation(attempts: Int, backoff: [Int]) -> Int }` |

### 2.2 設定・カタログ（T-09）

| ファイル | 公開宣言 |
|---|---|
| `Config/AppConfig.swift` | `public struct AppConfig: Codable, Equatable, Sendable { schemaVersion: Int; timeZone: String; vault: VaultConfig; device: DeviceConfig; audio: AudioConfig; session: SessionConfig; transcription: TranscriptionConfig; llm: LLMConfig; obsidian: ObsidianConfig; cleanup: CleanupConfig; retry: RetryConfig; logging: LoggingConfig; static func defaults(timeZone: String) -> AppConfig }`。入れ子の struct はすべて `Codable, Equatable, Sendable`、プロパティ名は §6.2 の JSON キーと同じ。`SectionConfig { enabled: Bool; heading: String?; maxItems: Int? }`、`AnalysisSections { summary, timeline, keyPoints /* JSON "key_points" */, tasks, decisions, ideas, tags: SectionConfig; func section(named: String) -> SectionConfig? }`（`summary` と `timeline` は JSON に `maxItems` を持たない。custom Codable で `enabled` と `heading` だけを読み書きする。F-54）、`public enum SectionName { static let all = ["summary","timeline","key_points","tasks","decisions","ideas","tags"] }`、`DeviceConfig.mode: MountMode`（`ro` / `rw` の enum。未知は ro 側）、`AudioConfig.retain: InboxRetain`（`normalized` / `raw_saved`）。細部（全プロパティ・CodingKeys・null の書き出し）は T-09 |
| `Config/ConfigViolation.swift` | `public struct ConfigViolation: Error, Equatable, Sendable { rule: String /* "CV-nn" */; code: ErrorCode; keyPath: String; message: String; var rendered: String }` |
| `Config/ConfigLoader.swift` | `public enum ConfigLoader { static func load(data: Data, catalog: ModelCatalog, reaperConfObservation: ReaperConfObservation) -> ConfigLoadResult; static func encode(_ c: AppConfig) -> Data }`、`public enum ConfigLoadResult: Equatable, Sendable { case valid(AppConfig), invalid([ConfigViolation]) }` |
| `Config/ConfigValidator.swift` | `public enum ConfigValidator { static func validate(_ c: AppConfig, catalog: ModelCatalog, reaperConfObservation: ReaperConfObservation) -> [ConfigViolation] /* CV-08〜59 を §6.4 の順に */ }` |
| `Config/ConfigMigrator.swift` | `public enum ConfigMigrator { static let currentVersion = 1; static func migrate(_ object: [String: Any]) -> Result<[String: Any], ConfigViolation> }` |
| `Config/ConfigKeys.swift` | `public enum ConfigKeys { static let allKeyPaths: [String] /* 全葉のキーパス。ConfigEffectTests が使う */ }` |
| `ModelCatalog.swift` | `public struct ModelCatalog: Equatable, Sendable { schema: Int; whisper, vad, llm: [ModelEntry]; static func load(_ data: Data) -> Result<ModelCatalog, CatalogError>; func entry(kind: ModelKind, id: String) -> ModelEntry? }`、`public enum ModelKind: String, Sendable, CaseIterable { case whisper, vad, llm }`、`public struct ModelEntry: Equatable, Sendable { id, displayName, file, url, sha256: String; bytes: Int64; license: String; minMemoryGB: Int?; verified: Bool? }`、`public enum CustomModelID { static func make(sha256: String) -> String; static func sha256(of id: String) -> String?; static func fileName(sha256: String) -> String }`、`ModelCatalog.rejected: [CatalogRejection]`（`public struct CatalogRejection: Equatable, Sendable { index: Int; kind: ModelKind; reason: String }`。タプルは Equatable にならないため）、`func entries(kind:) -> [ModelEntry]`、`var listedLLMs: [ModelEntry] /* verified == true */`、`CatalogError.unknownKey` |
| `ModelFiles.swift`（**T-09 が作る**。T-17・T-18・T-22・T-32 が使う） | `public enum ModelFiles { static func url(kind: ModelKind, entry: ModelEntry, layout: HomeLayout) -> URL; static func customLLMURL(id: String, layout: HomeLayout) -> URL?; static func isPresent(_ e: ModelEntry, kind: ModelKind, layout: HomeLayout) -> Bool /* 在り size == bytes */ }`（VDPipeline のガードと Worker が使う。VDPipeline は VDModels を import できないため。VDModels の ModelManager は UI だけが使う） |

### 2.3 時刻・ログ・ファイル（T-10）

| ファイル | 公開宣言 |
|---|---|
| `Instant.swift` | `public struct Instant: Comparable, Hashable, Sendable { public let epochMillis: Int64; init(epochMillis:); init(date: Date); var date: Date; func adding(milliseconds: Int64) -> Instant; func adding(seconds: Int) -> Instant; static func - (a: Instant, b: Instant) -> Int64 /* ミリ秒差 */ }`、`public enum SecondsToMillis { static func fromWhisperSeconds(_ s: Double) -> Int64 /* (s×1000).rounded()。F-71: NaN は 0、範囲外は ±10 億秒に寄せて落ちない */; static func isReadable(_ s: Double) -> Bool /* F-71: 有限で絶対値が 1,000,000,000 以下。transcript と whisper の秒の読み取りで共有 */ }`（F-71: `Instant` の加算・差・`init(date:)` は桁あふれで Int64 の端に寄せる） |
| `Clock.swift` | `public protocol AppClock: Sendable { func now() -> Instant; func uptime() -> Duration }`、`public struct SystemClock: AppClock`、`public protocol Sleeper: Sendable { func sleep(seconds: Int) async throws }`、`public struct TaskSleeper: Sleeper` |
| `BlockingIO.swift` | `public enum BlockingIO { static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T }`（専用の並行 `DispatchQueue`（QoS utility）で実行し continuation で待つ。PLAN §2.1） |
| `ModelVerificationCache.swift` | `public actor ModelVerificationCache { init(); func verifiedSHA256(path: String, inode: UInt64, size: Int64, mtime: Double) -> String?; func record(path: String, inode: UInt64, size: Int64, mtime: Double, sha256: String) }`（ModelManager と診断が共有） |
| `ZonedTime.swift` | `public struct ZonedTime: Sendable { init(timeZone: TimeZone); func iso(_ i: Instant) -> String /* 秒未満切り捨て、+09:00 */; func parseISO(_ s: String) -> Instant?; func localDate(_ i: Instant) -> LocalDate; func instant(of local: LocalDateTime) -> Instant; func localDateTime(_ i: Instant) -> LocalDateTime; func today(_ now: Instant) -> LocalDate; init(fixedOffsetSeconds: Int) /* 固定オフセットで描く（Raw の見出しなど、保存文字列のオフセットで描く所） */ }`、`public struct LocalDate: Comparable, Hashable, Sendable { year, month, day: Int; var dashed: String /* yyyy-MM-dd */; var stamp: String /* yyyyMMdd */; func adding(days: Int) -> LocalDate; init?(year:month:day:); init?(dashed: String); init?(stamp: String) }`、`public enum ISOWallClock { static func hhmm(_ iso: String) -> String?; static func hhmmss(_ iso: String) -> String? /* 保存文字列の壁時計をそのまま */ }` |
| `Log.swift` | `public enum LogEvent: String, CaseIterable, Sendable`（付録 A.4 の順）、`public enum LogLevel: Int, Comparable, Sendable { case debug = 10, info = 20, warning = 30, error = 40; var token: String /* "DEBUG" "INFO " "WARNING" "ERROR" */ }`、`public enum LogValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral { case string(String), int(Int64), double(Double), bool(Bool), null; static func of(_ s: String?) -> LogValue }`、`public enum LogKey: String, Sendable`（使うキーの登録。`content` 系 15 個を含む）、`public final class AppLog: Sendable { init(sink: LogSink, level: LogLevel, unsafeContent: Bool, zone: ZonedTime, clock: AppClock, category: String = "core"); func withCategory(_ c: String) -> AppLog; func log(_ level: LogLevel, _ event: LogEvent, _ fields: [(LogKey, LogValue)]); func debug/info/warning/error(_ event:, _ fields:) }`、`public protocol LogSink: Sendable { func write(line: String, level: LogLevel, category: String) }`、`public struct OSLogSink: LogSink { init(subsystem: String) }`（**`os.Logger` を作るのでこのファイルに置く。PT-08**）、`LogLevel.init?(configValue: String)` |
| `LogFormatter.swift` | `public enum LogFormatter { static func line(ts: String, level: LogLevel, event: LogEvent, fields: [(LogKey, LogValue)], redact: Bool) -> String; static func formatValue(_ v: LogValue) -> String }` |
| `LogFile.swift` | `public final class LogFile: LogSink { init(url: URL, maxBytes: Int = 5 * 1024 * 1024) }`（追記、超えたら `.1` へ rename）、`public struct TeeSink: LogSink` |
| `SafeUnlink.swift` | §9.2 の `SafeUnlinkRoot` / `SafeUnlink` / `SafeUnlinkError`（全ケースは T-10） |
| `AppPaths.swift` | `public struct AppPaths: Sendable { resources: URL; helpers: URL; init(resources:helpers:); static func fromMainBundle() -> AppPaths; var promptsDirectory, modelCatalog, whisperCLI, llamaServer, bundledReaperURL: URL }` |
| `FileHasher.swift` | `public enum FileHasher { static func sha256(of url: URL, chunkBytes: Int) throws -> String; static func sha256(_ data: Data) -> String }` |
| `TextLimit.swift` | `public enum TextLimit { static func scalarCount(_ s: String) -> Int; static func prefix(_ s: String, scalars: Int) -> String; static func truncate200(_ s: String) -> String /* ≤200 はそのまま、超えたら 199 + … */ }` |
| `Transcript.swift` | `public struct PartTranscript: Equatable, Sendable { partkey, language: String; durationSeconds: Double?; startedAt: String; text: String; segments: [TranscriptSegment]; public init(…全フィールド) }`、`public struct TranscriptSegment: Equatable, Sendable { start: Double; end: Double; text: String; public init(…) }`、`public enum PartTranscriptCodec { static func encode(_ t: PartTranscript) -> Data /* PyJSON indent 2 */; static func decode(_ data: Data) -> PartTranscript? /* §8.4 の合格条件 */ }` |
| `SessionTranscript.swift` | `public struct AbsoluteSegment: Equatable, Sendable { at: Instant; endAt: Instant; text: String; public init(…) }`、`public struct TimeBlock: Equatable, Sendable { start: Instant; end: Instant; public init(…) }`、`public struct SessionTranscript: Equatable, Sendable { dayDate: LocalDate; segments: [AbsoluteSegment]; blocks: [TimeBlock]; excludedPartkeys: [String]; public init(…全フィールド) }`、`public enum TranscriptFingerprint { static func of(_ t: SessionTranscript, zone: ZonedTime) -> String }`、`public enum BlockComputer { static func blocks(_ parts: [(startedAt: Instant, endedAt: Instant?)], gapSeconds: Int) -> [TimeBlock] }` |

### 2.4 Python 互換（T-45）

| ファイル | 公開宣言 |
|---|---|
| `PyText.swift` | `public enum PyText { static func scalarsEqual(_ a: String, _ b: String) -> Bool; static func isSpace(_ s: Unicode.Scalar) -> Bool; static func strip(_ s: String) -> String; static func strip(_ s: String, chars: Set<Unicode.Scalar>) -> String; static func splitLines(_ s: String) -> [String]; static func collapseWhitespace(_ s: String) -> String; static func casefold(_ s: String) -> String; static func isCombining(_ s: Unicode.Scalar) -> Bool; static func nfc(_ s: String) -> String; static func nfkc(_ s: String) -> String }` |
| `PyCaseFoldTable.swift` | （生成物）`enum PyCaseFoldTable { static let unicodeVersion: String; static let entryCount: Int; static let packed: [UInt32]; static let map: [UInt32: [UInt32]] }`（形は T-45） |
| `PyJSON.swift` | `public indirect enum PyJSONValue: Equatable, Sendable { case null, bool(Bool), int(Int64), double(Double), string(String), array([PyJSONValue]), object([(String, PyJSONValue)]) }`、`PyJSONValue.foundationObject: Any`（`==` は文字列をスカラー列、浮動小数をビット列で比べる）、`public enum PyJSON { static func dumpsIndent2(_ v: PyJSONValue) -> String /* 末尾改行なし。sortKeys なし */; static func dumpsCompact(_ v: PyJSONValue, sortKeys: Bool = false) -> String; static func fileData(_ v: PyJSONValue) -> Data /* indent2 + "\n" */; static func escape(_ s: String) -> String /* 両端の " を含まない */; static func formatDouble(_ d: Double) -> String /* Python repr と同じ。2^53〜1e16 の範囲を直す */; static func parse(_ data: Data) -> Any? /* decode の結果を Foundation の値に（VDNotes の frontmatter 周りが使う） */; static func isBool(_ any: Any) -> Bool }` |
| `PyJSONParser.swift` | `extension PyJSON { static func decode(_ text: String) -> PyJSONValue?; static func decode(_ data: Data) -> PyJSONValue? /* Python json.loads 互換。キーの順を保つ、重複キーは後勝ち・位置は最初、NaN / Infinity を受ける、先頭の U+FEFF を落とさない、入れ子は 64 段まで */ }`（**内部 JSON と LLM の応答の読み取りは JSONSerialization ではなくこれを使う**） |
| `PyRound.swift` | `public enum PyRound { static func round(_ x: Double, digits: Int) -> Double /* Python round(x, n) と同じ（最近接偶数・10 進表現の往復） */ }` |

---

## 3. VDStore（T-11）

| ファイル | 公開宣言 |
|---|---|
| `Store.swift`（`StoreError` は `StoreError.swift`、`EntityType` は `EntityType.swift`。1 ファイル 1 型） | `public final class Store: Sendable { init(url: URL, clock: AppClock, zone: ZonedTime) throws(StoreError); var appliedMigrations: [String] { get throws }; func quickCheck() throws -> String }`、`public enum StoreError: Error, Equatable, Sendable { case notWAL, open(String), migration(String) /* "superseded" = より新しいアプリが当てた版がある */, backup(String), corruptRow(String), invalidUpdate(String) }`、テスト用に internal `init(url:clock:zone:migrator:)` |
| `Schema.swift` | `enum Schema { static let v1Initial: String /* §7.2 の DDL */; static func migrator() -> DatabaseMigrator }` |
| `Rows.swift` | `public struct RecordingRow: Equatable, Sendable`（DB の 27 列を Swift の名前で（`errorCodeRaw` だけは列ではなく `error_code` の生の文字列を残す導出プロパティ）: `partkey, deviceID, sourceFolder, transmitterID, micIndex, startedAt, durationSeconds, endedAt, sourcePath, sourceSize, sourceMtime, sha256, sha256Helper, inboxPath, stagingDir, normalizedPath, transcriptPath, sessionKey, status: PartStatus, retryCount, errorCode: ErrorCode?, errorCodeRaw: String? /* 未知のコード文字列も残す。Daily の警告行が使う */, errorMessage, sourceDeletedAt, updatedAt, deleteRequestID, duplicateOf, needsRecopy: Bool`）、`public struct SessionRow: Equatable, Sendable`（22 列）、`public struct EventRow: Equatable, Sendable`、`public struct NewRecording: Sendable, Equatable`（INSERT に渡す列。登録時に必ず分かる列は非 Optional。init は T-11 で固定）、`public struct NewSession: Sendable, Equatable { sessionKey, dayDate, deviceID }` |
| `Transitions.swift` | `extension Store { func recordPartTransition(partkey:from:to:kind:errorCode:errorMessage:detail:resetRetry:) throws; func recordSessionTransition(sessionKey:from:to:kind:errorCode:errorMessage:detail:resetRetry:) throws; func insertRecording(_ r: NewRecording) throws /* PK 重複は GRDB の DatabaseError をそのまま投げ、events は書かない */; func insertSession(_ s: NewSession) throws; func updateRecordingIfStatus(_ partkey: String, status: PartStatus, _ fields: [RecordingField]) throws -> Bool /* WHERE に status を含む UPDATE なので PT-05 によりこのファイル */; func groupPart(_ partkey: String, into session: NewSession) throws -> SessionStatus? /* 分組の 1 件: Session の作成（無ければ）・session_key・集計・OPEN なら OPEN→OPEN（detail = partkey）を 1 トランザクションで。分組した時点の状態を返す。Part の行が無ければ何も書かずに nil。F-82 */ }`、`public struct TransitionConflict: Error, Equatable, Sendable { key: String; expected: String }`、`public struct IllegalTransition: Error, Equatable, Sendable { from: String; to: String; kind: TransitionKind }` |
| `Updates.swift` | `public enum RecordingField: Sendable { case sessionKey(String?), durationSeconds(Double?), endedAt(String?), sha256(String?), sha256Helper(String?), inboxPath(String?), stagingDir(String?), normalizedPath(String?), transcriptPath(String?), sourceSize(Int64?), sourceMtime(Double?), errorCode(ErrorCode?), errorMessage(String?), sourceDeletedAt(String?), deleteRequestID(String?), duplicateOf(String?), needsRecopy(Bool) }`、`public enum SessionField: Sendable { case startedAt(String?), endedAt(String?), recordedSeconds(Double?), partCount(Int), failedPartCount(Int), title(String?), analysisPath(String?), rawOutputPath(String?), rawOutputSHA256(String?), outputPath(String?), outputSHA256(String?), regeneratedCount(Int), deleteAttempts(Int), errorCode(ErrorCode?), errorMessage(String?), sourceDeletedAt(String?) }`、`extension Store { func updateRecording(_ partkey: String, _ fields: [RecordingField]) throws; func updateSession(_ key: String, _ fields: [SessionField]) throws }`（status を変えない。`updated_at` は常に now）。`RecordingField` / `SessionField` は `Equatable` |
| `Queries.swift` | `extension Store { func recording(_ partkey: String) throws -> RecordingRow?; func session(_ key: String) throws -> SessionRow?; func ungroupedRecordings() throws -> [RecordingRow]; func recordings(inSession key: String) throws -> [RecordingRow]; func recordings(status: PartStatus) throws -> [RecordingRow]; func sessions(status: SessionStatus) throws -> [SessionRow]; func nonTerminalPartkeys() throws -> [String]; func failedRecordingKeys() throws -> [String] /* ORDER BY updated_at, partkey */; func failedSessionKeys() throws -> [String]; func failedFromPart(_ partkey: String) throws -> PartStatus?; func failedFromSession(_ key: String) throws -> SessionStatus?; func sessionsForDeleteEvaluation() throws -> [SessionRow] /* ORDER BY updated_at, session_key */; func recording(normalizedPath: String) throws -> RecordingRow?; func recording(sha256: String) throws -> RecordingRow?; func recordingsAwaitingDeleteResult() throws -> [RecordingRow] /* delete_request_id IS NOT NULL */; func refreshSessionAggregates(_ key: String) throws; func events(entity: EntityType, key: String) throws -> [EventRow]; func knownPartkeys(_ keys: [String]) throws -> Set<String>; func importedKeys() throws -> Set<String>; func insertImportedKeys(_ rows: [(partkey: String, sourceNote: String)]) throws -> Int; func recordingsNeedingRecopy() throws -> [RecordingRow]; func partkeys(statuses: Set<PartStatus>) throws -> [String] }`、`public enum EntityType: String, Sendable, CaseIterable { case recording, session }` |
| `ReadOnlyStore.swift` | `public final class ReadOnlyStore: Sendable { static func open(url: URL) -> ReadOnlyStore? /* 無ければ nil。作らない */; func statusCounts() throws -> (parts: [PartStatus: Int], sessions: [SessionStatus: Int]); func backlog() throws -> (count: Int, seconds: Double, unknownDuration: Int); func failedParts(limit: Int) throws -> (rows: [RecordingRow], total: Int); func quickCheck() throws -> String; func appliedMigrations() throws -> [String]; func awaitingDeleteResultCount() throws -> Int; func partkeys(statuses: Set<PartStatus>) throws -> [String]; func completedParts(lastDetail detail: String) throws -> [RecordingRow] /* F-69 */ }` |

---

## 4. VDProcess（T-12）

| ファイル | 公開宣言 |
|---|---|
| `ProcessSpec.swift` | `public struct ProcessSpec: Sendable, Equatable { executable: URL; arguments: [String]; environment: [String: String]; public init(executable:arguments:environment:) }`、`public enum ProcessEnvironment { static let path: String; static let standard: [String: String]; static let cLocale: [String: String] }`、`public enum SpawnError: Error, Equatable, Sendable { case spawnFailed(errno: Int32), pipeFailed(errno: Int32) }` |
| `ProcessResult.swift` | `public struct ProcessResult: Sendable, Equatable { termination: Termination; stdoutTail: Data; stderrTail: Data; stoppedByTerminateAll: Bool /* 実行中に terminateAll が SIGTERM を送った。F-82 */; public init(termination:stdoutTail:stderrTail:stoppedByTerminateAll: Bool = false); var stdoutText: String; var stderrText: String; static let stdoutTailLimit = 65_536; static let stderrTailLimit = 4_096 }`、`enum Termination { exited(Int32), signaled(Int32), timedOut, spawnFailed(errno: Int32) }` |
| `ProcessRunner.swift` | `public actor ProcessRunner { init(); public static let killGrace: Duration /* 5 秒 */; func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult; func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess; func terminateAll(grace: Duration) async /* まず閉じる: 以後の run は起動せずに .spawnFailed(errno: ECANCELED)、spawn は SpawnError.spawnFailed(errno: ECANCELED)。全部が終われば grace を待たずに戻る。F-76 */; public static let closedErrno: Int32 /* ECANCELED。閉じた後の拒否を呼び手が見分ける。F-76 */ }`、`public protocol ProcessRunning: Sendable { func run(_:timeout:) async -> ProcessResult; func spawn(_:) async throws(SpawnError) -> RunningProcess }`（ProcessRunner が準拠。テストの差し替え用） |
| `RunningProcess.swift` | `public final class RunningProcess: Sendable { let pid: pid_t; func terminate(grace: Duration) async -> ProcessResult.Termination /* 終了済みなら待たずに返す */; func waitForExit() async -> ProcessResult.Termination; var isRunning: Bool { get async }; func stderrTail() async -> Data; func stdoutTail() async -> Data }` |
| `Spawn.swift` | internal: posix_spawn の薄い包み（`SETPGROUP`・`CLOEXEC_DEFAULT`・dup2・/dev/null） |

---

## 5. VDDevice（T-13 / T-14 / T-15）

| ファイル | 公開宣言 |
|---|---|
| `DevicePath.swift` | `public struct DevicePath: Hashable, Sendable { deviceID: String; relpath: String }`（I/O を持たない） |
| `ErrnoError.swift` | `public struct ErrnoError: Error, Equatable, Sendable { public let code: Int32; public init(_ code: Int32) }`（T-13） |
| `MountInspector.swift` | `public struct MountInfo: Equatable, Sendable { mountOnName: String; mountFromName: String; fsTypeName: String; readOnly: Bool; freeBytes: Int64? }`、`public protocol MountInspector: Sendable { func mountInfo(path: String) -> MountInfo?; func allMounts() -> [MountInfo]; func volumeName(path: String) -> String?; func isMountPoint(path: String) -> Bool /* realpath の比較をここに閉じる（規則 4） */ }`、`public struct SystemMountInspector: MountInspector` |
| `Remounter.swift` | `public enum RemountOutcome: Equatable, Sendable { case alreadyReadOnly, remounted(newPath: String), failed(reason: String) }`、`public protocol Remounter: Sendable { func remountReadOnly(path: String, node: String) async -> RemountOutcome }`、`public struct DiskutilRemounter: Remounter { init(runner: any ProcessRunning, inspector: any MountInspector, useMountPoint: Bool) }`、`public protocol MountEventSource: Sendable { func events() -> AsyncStream<Void> }`（NSWorkspace の通知。テストは差し替え。T-15） |
| `DeviceDetector.swift` | `public enum DetectionReason: String, Sendable { case notIncluded = "not_included", excluded, symlink, notAMountPoint = "not_a_mount_point", notListable = "not_listable", noRecordings = "no_recordings", mountNameMismatch = "mount_name_mismatch", invalidDeviceID = "invalid_device_id" }`、`public struct DetectedDevice: Sendable, Equatable { deviceID: String; mountPath: String; node: String? }`、`public struct DeviceDetector: Sendable { init(config: DeviceConfig, volumesRoot: String, inspector: any MountInspector, reader: DeviceReader); func detect() -> DetectionResult; static func nameMatchesVolume(_ name: String, volumeName: String?) -> Bool }`、`public struct DetectionResult: Sendable, Equatable { devices: [DetectedDevice]; skipped: [SkippedVolume] }`、`public struct SkippedVolume: Sendable, Equatable { name: String; reason: DetectionReason; listingError: ErrnoError? }` |
| `DeviceReader.swift` | `public struct DeviceReader: Sendable { func listEntries(of dir: String) -> Result<[String], ErrnoError>; func entryKind(_ path: String) -> EntryKind; func scan(volumeRoot: String, maxDepth: Int) -> ScanListing; func stat(volumeRoot: String, relpath: String) -> FileStat?; func openForCopy(volumeRoot: String, relpath: String, expected: FileStat) -> Result<DeviceFileHandle, CopyError> }`、`public enum EntryKind { directory, regularFile, symlink, other, missing }`、`public struct ScanListing: Sendable { relpaths: Set<String>; origCandidates: [String]; unparsable: [String]; complete: Bool /* サブディレクトリの列挙に失敗したら false → そのデバイスは not_listable */ }`、`public struct FileStat: Equatable, Sendable { size: Int64; mtime: Double }`、`public protocol ChunkReading { func read(maxBytes: Int) throws(ErrnoError) -> Data }`、`public final class DeviceFileHandle: ChunkReading`、`public enum CopyError: Error, Equatable, Sendable`（全ケースは T-14） |
| `InboxWriter.swift` | `public struct InboxWriter: Sendable { init(layout: HomeLayout); func writePartial(from reader: any ChunkReading, expectedSize: Int64, partial: URL, chunkBytes: Int) -> Result<String /* sha256 */, CopyError>; func commitPartial(_ partial: URL, to final: URL) -> Result<Void, CopyError>; func discardPartial(_ partial: URL) }`（`copyOne` の本体から `commitPartial(` → `registerCopied(` の順に直接呼ぶ。PT-16） |
| `StabilityChecker.swift` | `public struct StabilityChecker: Sendable { init(config: DeviceConfig, clock: AppClock, sleeper: Sleeper); func stableCandidates(_ c: [String], stat: @escaping @Sendable (String) -> FileStat?) async -> [String: FileStat] }` |
| `DeviceSnapshot.swift` | §8.1 の `DeviceSnapshot`（`unavailable` に加えて `notListableErrno: [String: Int32]`、公開の init）/ `DeviceObservation` / `IngestActivity`（`static let idle`）。すべて `Equatable`（T-15） |
| `CoexistenceGuard.swift` | — 取り下げ（共存ガード。PLAN F-61）。T-13 が作ったものを消した |
| `IngestService.swift` | `public actor IngestService { init(deps: IngestDependencies); func start(); func stop(); func scanNow() async -> UInt64? /* 呼び出しの後に始まり完了した走査の generation。見送りなら nil */; func latestSnapshot() -> DeviceSnapshot?; func activity() -> IngestActivity; func state() -> IngestState; func updates() -> AsyncStream<Void> }`、`public enum IngestState: Sendable, Equatable { case idle, scanning, disabled }`（`coexistenceBlocked` は取り下げ。PLAN F-61）、`public struct IngestDependencies: Sendable { layout, configProvider: @Sendable () async -> AppConfig?, store: Store, inspector: any MountInspector, remounter: any Remounter, mountEvents: any MountEventSource, reader: DeviceReader, clock: AppClock, sleeper: Sleeper, zone: ZonedTime, log: AppLog, volumesRoot: String }`（フィールドの順と init は T-14 で固定。`coexistence: CoexistenceGuard` は F-61 で外した）。内部に `func copyOne(…)`（PT-16） |

---

## 6. VDAudio（T-16。`AudioProbe` だけ T-14）

| ファイル | 公開宣言 |
|---|---|
| `AudioProbe.swift` | `public enum AudioProbe { static func durationSeconds(of url: URL) -> Double? }`（**T-14 が作る**。VDDevice の登録で使うため） |
| `SpaceCheck.swift` | `public struct SpaceCheck: Sendable { init(config: AudioConfig, layout: HomeLayout); func check(durationSeconds: Double?) -> SpaceCheckResult }`、`public enum SpaceCheckResult: Equatable, Sendable { case ok, insufficient(String) }`、`public enum SpaceMath { static func expectedBytes(_ d: Double?) -> Int64; static func requiredBytes(expected: Int64, config: AudioConfig) -> Int64 }` |
| `Normalizer.swift` | `public struct Normalizer: Sendable { init(config: AudioConfig, layout: HomeLayout, clock: AppClock); func normalize(_ req: NormalizeRequest) async -> NormalizeOutcome }`、`public struct NormalizeRequest: Sendable { input: URL; partkey: String; durationSeconds: Double?; sha256Helper: String?; claimedBy: String?; duplicateOf: @Sendable (String) -> String?; public init(…) }`、`public enum NormalizeOutcome: Equatable, Sendable { case success(sha256: String, output: URL, inBytes: Int64, outBytes: Int64, reused: Bool), duplicate(of: String, sha256: String), failure(StageFailure) }` |
| `OutputVerifier.swift` | `public enum OutputVerifier { static func verify(output: URL, inputDuration: Double?, tolerance: Double) -> String? /* 失敗文言。nil = 合格 */ }` |

---

## 7. VDTranscribe（T-17）

| ファイル | 公開宣言 |
|---|---|
| `WhisperArgs.swift` | `public enum WhisperArgs { static func build(model: URL, input: URL, outputBase: URL, config: TranscriptionConfig, vadModel: URL?, threads: Int) -> [String] /* argv[0] を含まない */; static func num(_ x: Double) -> String; static func resolvedThreads(_ configured: Int) -> Int }` |
| `WhisperOutputParser.swift` | `public enum WhisperOutputParser { static func parse(_ data: Data, fallbackLanguage: String) -> (language: String, text: String, segments: [TranscriptSegment])? }` |
| `Transcriber.swift` | `public struct Transcriber: Sendable { init(runner: any ProcessRunning, paths: AppPaths, layout: HomeLayout, config: TranscriptionConfig, catalog: ModelCatalog, clock: any AppClock); func missingPrerequisites() -> [TranscribePrerequisite]; func transcribe(_ req: TranscribeRequest) async -> TranscribeOutcome }`、`public enum TranscribePrerequisite: String, Sendable { case whisperMissing = "whisper_missing", modelMissing = "model_missing", vadModelMissing = "vad_model_missing" }`（rawValue は `PauseReason` と同じ語）、`public struct TranscribeRequest: Sendable { partkey: String; slug: String; input: URL; durationSeconds: Double?; startedAt: String; public init(…) }`、`public enum TranscribeOutcome: Equatable, Sendable { case transcribed(PartTranscript, metrics: TranscribeMetrics), noSpeech(PartTranscript, message: String), prerequisiteMissing(TranscribePrerequisite), failure(StageFailure), stopped /* アプリの終了で止めた・閉じた後に拒まれた。呼び手は行を動かさない。F-82 */ }`、`public struct TranscribeMetrics: Equatable, Sendable { elapsedSeconds: Double; chars: Int; rtf: Double?; speechRatio: Double?; public init(…) }` |
| `WhisperHelpCheck.swift` | `public enum WhisperHelpCheck { static let vadFlags: [String]; static func missingVADFlags(helpOutput: String) -> [String] }` |

---

## 8. VDLLM（T-19 / T-20 / T-21）

| ファイル | 公開宣言 |
|---|---|
| `AnalysisSchema.swift` | `public struct AnalysisSchema: Sendable { enum Kind { case final, partial }; init(config: AnalysisConfigView, kind: Kind); var fields: [SchemaField] /* 並び */ }`、`public struct AnalysisConfigView: Sendable { sections: AnalysisSections }` |
| `AnalysisResult.swift` | `public struct AnalysisResult: Equatable, Sendable { title: String?; summary: String?; keyPoints, decisions, ideas, tags: [String]?; tasks: [AnalysisTask]? /* nil = 無効な節 */; func pyJSON(schema: AnalysisSchema) -> PyJSONValue }`、`public struct AnalysisTask: Equatable, Sendable { text: String; due: String? }` |
| `SchemaBlock.swift` | `public enum SchemaBlock { static func render(_ s: AnalysisSchema) -> String }` |
| `Prompts.swift` | `public struct Prompts: Sendable { static func load(directory: URL) throws -> Prompts; func analyze(schema: AnalysisSchema, custom: String) -> String; func map(schema: AnalysisSchema, custom: String) -> String; func reduce(schema: AnalysisSchema, custom: String) -> String; func repair(schema: AnalysisSchema, errors: String, previousOutput: String) -> String }` |
| `JSONExtractor.swift` | `public enum JSONExtractor { static func stripThink(_ s: String) -> String; static func extractObject(_ text: String) -> [(String, PyJSONValue)]? /* キーの順を保つ（PyJSON.decode） */ }` |
| `AnalysisValidator.swift` | `public enum AnalysisValidator { static func trim(_ obj: [(String, PyJSONValue)], schema: AnalysisSchema) -> (obj: [(String, PyJSONValue)], trimmed: [String]); static func validate(_ obj: [(String, PyJSONValue)], schema: AnalysisSchema) -> Result<AnalysisResult, ValidationErrors> }`、`public enum LLMValidationMessages`（pydantic v2 の文言）、`public struct AnalysisCall`（1 回の呼び出し＋修復。T-19）、`public enum LLMProbe`（DR-09 の system / user）、`public struct ValidationErrors: Error, Equatable, Sendable { lines: [String]; var rendered: String }` |
| `Chunker.swift` | `public struct Chunk: Equatable, Sendable { text: String; startAt: Instant; endAt: Instant; segments: [AbsoluteSegment] }`、`public enum Chunker { static func chunk(_ segs: [AbsoluteSegment], maxChars: Int, maxSeconds: Int, overlapChars: Int) -> [Chunk] }` |
| `Dedupe.swift` | `public enum Dedupe { static func key(_ s: String) -> String; static func apply(_ r: AnalysisResult) -> AnalysisResult }` |
| `ChatTransport.swift` | `public protocol ChatTransport: Sendable { func complete(system: String, user: String) async -> ChatResult }`、`public enum ChatResult: Equatable, Sendable { case content(String /* 外形が壊れていれば "" */), failure(StageFailure) }`（**T-19 が作る**。FakeChatTransport も T-19） |
| `Analyzer.swift` | `public struct Analyzer: Sendable { init(transport: any ChatTransport, prompts: Prompts, config: LLMConfig); func analyze(_ t: SessionTranscript) async -> AnalyzeOutcome }`、`public enum AnalyzeOutcome: Sendable, Equatable { case success(AnalysisResult, partials: [AnalysisResult], chunks: [Chunk], trimmed: [String]), failure(StageFailure) }`、`Analyzer.reduceMaxDepth = 3` |
| `LoopbackHTTP.swift` | `public struct LoopbackEndpoint: Sendable { init?(port: UInt16) /* URL(string:) を使わず URLComponents で作る。PT-02 */; var chatCompletionsURL: URL; var healthURL: URL }`、`public protocol LoopbackSessionFactory: Sendable { func configuration() -> URLSessionConfiguration }`、`public struct EphemeralSessionFactory: LoopbackSessionFactory`、`public struct LoopbackChatTransport: ChatTransport { init(endpoint:apiKey:modelID:config:factory:) }`、`public enum FreePort { static func pick() -> UInt16? }`、`public enum LoopbackHealth { static func check(_ e: LoopbackEndpoint, factory:) async -> Int? /* HTTP status */ }` |
| `LlamaArgs.swift` | `public enum LlamaArgs { static func build(model: URL, port: UInt16, apiKeyFile: URL, contextSize: Int) -> [String]; static let usedFlags: [String]; static func missingFlags(helpOutput: String) -> [String] /* DR-07 と共有 */ }` |
| `LlamaServerSupervisor.swift` | `public actor LlamaServerSupervisor { init(runner: any ProcessRunning, paths: AppPaths, layout: HomeLayout, clock: AppClock, sleeper: Sleeper, log: AppLog, factory: any LoopbackSessionFactory, portPicker: @escaping @Sendable () -> UInt16? = FreePort.pick) /* メモリの確認はガード（VDPipeline）で行い、ここでは行わない。API キーファイルは停止・失敗で消す */; func ensureRunning(model: URL, modelID: String, config: LLMConfig) async -> Result<LlamaServerHandle, StageFailure> /* 停止の途中なら停止の終わりを待つ */; func stop() async /* 起動の途中なら起動中のプロセスを直ちに止め、起動を server_start_failed: cancelled で終わらせる。F-76 */ }`、`public struct LlamaServerHandle: Sendable, Equatable { endpoint: LoopbackEndpoint; apiKey: String; modelID: String; public init(endpoint:apiKey:modelID:) }` |

---

## 9. VDNotes（T-26 / T-27 / T-28）

| ファイル | 公開宣言 |
|---|---|
| `Sanitize.swift` | `public enum Sanitize { static func fileName(_ name: String, maxBytes: Int) -> String }` |
| `Templates.swift` | `public enum NoteTemplate { static func render(_ template: String, day: LocalDate) -> String }` |
| `Frontmatter.swift` | `public enum FrontmatterValue: Sendable { case string(String), bool(Bool), int(Int), null, array([String]) }`、`public enum Frontmatter { static let keySessionKey = "voicedock_session_key", keyRecordingKeys = "voicedock_recording_keys", keyFailedParts = "voicedock_failed_parts", keySkippedParts = "voicedock_skipped_parts", keyType = "type"; static func stringList(_ fm: [String: Any], _ key: String) -> [String]; static func render(_ fields: [(String, FrontmatterValue)]) -> String; static func quote(_ s: String) -> String; static func escapeBody(_ s: String) -> String; static func split(_ text: String) -> (front: String, body: String)?; static func parse(_ text: String) -> [String: Any]?; static func recordingKeys(ofFile url: URL) -> [String] }` |
| `RawNote.swift` | `public struct RawPart: Sendable { partkey: String; startedAt: String; endedAt: String?; segments: [AbsoluteSegment]; zone: ZonedTime }`、`public enum RawNote { static let noteType = "voice-raw"; static let sourceLabel = "DJI Mic 3"; static let intro: String; static func title(_ day: LocalDate) -> String; static func render(parts: [RawPart], day: LocalDate, sessionKey: String, config: ObsidianConfig) -> String; static func baseName(config: ObsidianConfig, day: LocalDate) -> String; static func folder(config: ObsidianConfig, day: LocalDate) -> String }`（`RawPart.zone` は並べ替えだけに使い、`##`・`###` の時刻は started_at の文字列のオフセットで描く。T-26） |
| `DailyNote.swift` | `public struct DailyInput: Sendable { analysis: AnalysisView; day: LocalDate; sessionKey: String; recordingKeys: [String]; excluded: [ExcludedPart]; recordedSeconds: Double?; blockCount: Int; timeline: [TimelineBlock]; links: LinkPlan; zone: ZonedTime /* Timeline の見出し */ }`、`public struct AnalysisView: Sendable { title, summary: String?; keyPoints, decisions, ideas, tags: [String]?; tasks: [(text: String, due: String?)]? }`、`public struct ExcludedPart: Sendable { partkey: String; status: PartStatus; errorCode: ErrorCode?; unknownCode: String?; rawNoteBlocked: Bool /* F-75。init の既定は false */ }`、`public enum DailyNote { static func render(_ input: DailyInput, config: AppConfig) -> String; static func baseName(config: ObsidianConfig, day: LocalDate) -> String; static func folder(config: ObsidianConfig, day: LocalDate) -> String; static func summaryHeading(config: AppConfig) -> String; static func rawLinkName(rawOutputPath: String?, config: ObsidianConfig, day: LocalDate) -> String /* X-15 */; static func tags(analysisTags: [String]?, defaults: [String]) -> [String]; static func recorded(_ s: Double?) -> String }` |
| `Warnings.swift` | `public enum DailyWarnings { static func lines(failed: [ExcludedPart], skipped: [ExcludedPart]) -> [String]; static func displayName(_ code: ErrorCode?) -> String; static let rawNoteBlockedLineTemplate: String /* F-75 */ }` |
| `Timeline.swift` | `public struct TimelineBlock: Equatable, Sendable { start: Instant; end: Instant; lines: [String] }`、`public enum Timeline { static func build(partials: [AnalysisView], chunks: [(start: Instant, end: Instant)], transcript: SessionTranscript, summary: String?) -> [TimelineBlock]; static func sentences(_ s: String) -> [String]; static func encode(_ b: [TimelineBlock], fingerprint: String, zone: ZonedTime) -> Data; static func decode(_ data: Data, fingerprint: String, zone: ZonedTime) -> [TimelineBlock] }` |
| `VaultIndex.swift` | `public struct VaultIndex: Sendable { names: Set<String>; builtAt: Duration; scannedDirectories: Int; static func build(vault: URL, excludePrefixes: [String], builtAt: Duration) -> VaultIndex; func contains(_ name: String) -> Bool; func isStale(ttlSeconds: Int, now: Duration) -> Bool; static func normalize(_ s: String) -> String; static func rawFolderPrefix(_ template: String) -> String }` |
| `LinkPlanner.swift`（`isLinkable` は自己参照も見る。voicedock と同じ判定（自己参照を見ない）は internal の `isWellFormed`。T-27） | `public struct LinkPlan: Equatable, Sendable { dailyNote: String?; adjacent: [String]; tags: [String]; raw: [String]; dropped: [String]; counted: Int; static let empty }`、`public enum LinkPlanner { static let forbiddenScalars: Set<Unicode.Scalar>; static func isLinkable(_ c: String, selfName: String) -> Bool; static func plan(config: ObsidianConfig, day: LocalDate, tags: [String], index: VaultIndex?, selfName: String, nameForDay: (LocalDate) -> String, rawNames: [String]) -> LinkPlan }` |
| `VaultCheck.swift` | `public enum VaultStatus: Equatable, Sendable { case notConfigured, missingRoot, notReadable(errno: Int32), missingMarker, available; var isAvailable: Bool; func message(path: String, marker: String) -> String }`、`public enum VaultCheck { static func evaluate(path: String?, marker: String) -> VaultStatus /* stat が EPERM / EACCES なら .notReadable */ }` |
| `NoteWriter.swift` | `public enum NoteWriter { static func write(_ content: String, to url: URL) throws(AtomicFileError) -> String /* sha256 */ }`、`public enum NoteFolder { static func ensure(relative: String, vault: URL) throws -> URL }`、`public enum NoteErrorText { static func describe(_ e: Error) -> String }` |
| `NoteVerifier.swift` | `public enum NoteKind: Sendable { case raw, daily }`、`public struct NoteRuleResult: Equatable, Sendable { rule: String /* "RN-5" 等 */; passed: Bool }`、`public struct NoteVerification: Equatable, Sendable { results: [NoteRuleResult]; var failedRules: [String]; var passed: Bool; var failureMessage: String /* "落ちた規則: RN-1, RN-5" */ }`、`public enum NoteVerifier { static func verify(url: URL, kind: NoteKind, sessionKey: String, expectedSHA256: String, expectedKeys: Set<String>, summaryHeading: String) -> NoteVerification }` |
| `OutputPathResolver.swift` | `public enum OutputPathResolver { static func resolve(folder: URL, baseName: String, existing: URL?, sessionKey: String, ownedPartkeys: Set<String>, kind: NoteKind) -> Result<URL, StageFailure>; static func mayOverwrite(_ url: URL, sessionKey: String, ownedPartkeys: Set<String>, kind: NoteKind) -> Bool /* F-75: type の一致と鍵の列が配列であることも見る */; static func keysLostByOverwrite(_ url: URL, protectedKeys: [String], newKeys: [String]) -> [String]? /* F-75: 書き直しで消える鍵。無ければ空、在るのに読めない・鍵の列が配列でなければ nil。Set<String> で受けない */ }` |

---

## 10. VDModels（T-23）

| ファイル | 公開宣言 |
|---|---|
| `ModelDownloader.swift` | `public protocol DownloadSessionFactory: Sendable { func configuration() -> URLSessionConfiguration }`、`public actor ModelDownloader { init(layout: HomeLayout, factory: any DownloadSessionFactory, log: AppLog, hashChunkBytes: Int); func download(_ e: ModelEntry, kind: ModelKind, progress: @escaping @Sendable (Int64, Int64) -> Void) async -> Result<URL, ModelError>; func cancel(id: String) }`、`public struct EphemeralDownloadSessionFactory: DownloadSessionFactory`（本番） |
| `ModelImporter.swift` | `public enum ModelImporter { static func importGGUF(from source: URL, layout: HomeLayout, chunkBytes: Int) -> Result<(id: String, url: URL), ModelError> }` |
| `ModelManager.swift` | `public actor ModelManager { init(layout: HomeLayout, catalog: ModelCatalog, downloader: ModelDownloader, cache: ModelVerificationCache, log: AppLog, hashChunkBytes: Int); func download(_ id: String, kind: ModelKind, progress:) async -> Result<URL, ModelError>; func cancel(id: String); func importCustomLLM(from: URL) async -> Result<(id: String, url: URL), ModelError>; static func meetsMemory(_ e: ModelEntry, physicalMemoryBytes: UInt64) -> Bool; func state(kind: ModelKind, id: String) -> ModelState; func isPresent(_ e: ModelEntry, kind: ModelKind) -> Bool; func verifySHA(kind: ModelKind, id: String) async -> Bool /* (path,size,mtime) で覚える */; func url(kind: ModelKind, id: String) -> URL? }`、`public enum ModelState: Equatable, Sendable { case absent, downloading(Double), present, failed(String) }`、`public enum ModelError: Error, Equatable, Sendable { case badHost, badFileName, sha256Mismatch, sizeMismatch, http(Int), network, cancelled, io(String); var logReason: String; var displayMessage: String }` |

---

## 11. VDPipeline（T-18 / T-22 / T-29 / T-32 / T-36〜T-41。T-33 は取り下げ）

| ファイル | 公開宣言 |
|---|---|
| `ConfigStore.swift` | `public actor ConfigStore { init(layout: HomeLayout, catalog: ModelCatalog, log: AppLog, observeReaperConf: @escaping @Sendable () async -> ReaperConfObservation, defaultTimeZone: @escaping @Sendable () -> String = { TimeZone.current.identifier }) /* LockEvaluator は T-36 で後から作られるのでクロージャで受ける。`defaultTimeZone` はテストの口で、本番は渡さない */; func load() async -> ConfigLoadResult /* 無ければ既定を書く */; func didCreateDefaults() -> Bool /* 初回起動の判定（パネルの自動表示） */; func setLock1Reconciler(_ r: @escaping @Sendable () async -> Bool) /* T-40 の reconcileLock1 を後から挿す */; func current() -> AppConfig?; func violations() -> [ConfigViolation]; func update(_ mutate: @Sendable (inout AppConfig) -> Void, reaperConfObservation: ReaperConfObservation? = nil /* nil = 今の値 */) async -> ConfigUpdateResult /* 書く前に検証 */ }`、`public enum ConfigUpdateResult: Sendable, Equatable { case success(AppConfig), failure([ConfigViolation]) }`（`Result` の失敗側は `Error` を要り配列は `Error` でないため包み型。ケース名は `Result` と同じ。利用者の決定 2026-09-22）。**引数ラベルに `reaperConf` を使わない**（PT-11 の語に当たる）。`ConfigLoader.load` / `ConfigValidator.validate` も `reaperConfObservation:` にする |
| `WorkerDependencies.swift` | `public struct WorkerDependencies: Sendable { layout, paths, store, config: ConfigStore, ingest: any IngestPort, runner: any ProcessRunning, llama: any LLMServerControl, chatTransportFactory: ChatTransportFactory, clock: any AppClock, sleeper: any Sleeper, log: AppLog, license: any LicenseGate, catalog: ModelCatalog, verificationCache: ModelVerificationCache, physicalMemoryBytes: UInt64, locks: LockEvaluator, volumeOpener: any VolumeOpener }`（**VDModels に依存しない**。モデルの在否は `ModelFiles`（VDCore）。`zone` は持たず tick ごとに設定のタイムゾーンから作る。`reaper` は持たず `locks.reaper` を使う）。**末尾に足す順はこの表が正**: T-18 が上の並びまで作り、その直後に T-36 が `locks: LockEvaluator` と `volumeOpener: any VolumeOpener` を足す（上の並びの `locks` / `volumeOpener` はこの 2 つ。T-33 の `importedKeys: ImportedKeysService` は取り下げ。PLAN F-60）。`public protocol IngestPort: Sendable`（IngestService が準拠。テストは FakeIngest）、`public protocol LLMServerControl: Sendable`（LlamaServerSupervisor が準拠。テストは FakeLLMServer）、`public typealias ChatTransportFactory = @Sendable (LlamaServerHandle, LLMConfig) -> any ChatTransport` |
| `Worker.swift` | `public actor Worker { init(deps: WorkerDependencies); func start() async; func tick() async; func run() async /* 待ち: 通知・要求・30 秒 */; func requestStop(); func requeue(_ reason: RequeueReason) async; func enqueue(_ job: WorkerJob) async; func status() -> WorkerStatus }`、`public enum RequeueReason: Sendable { case startup, connect, manual }`、`public enum WorkerJob: Sendable { case llmProbe(reply: @Sendable (DiagnosticResult) -> Void), backlog(BacklogAction), resolveAbsent(BacklogAction), summarizeNow(reply: @Sendable (Result<Int, SummarizeNowFailure>) -> Void) }`（`summarizeNow` は今すぐ要約。PLAN §5.4・F-66。`closeIdleSessions` の段で行い、返事は閉じた Session の数）、`public struct WorkerStatus: Sendable { activity: WorkerActivity; paused: [PauseReason] }` |
| `Recovery.swift` | `struct Recovery { func run() throws -> Int }`（PT-21） |
| `PartSteps.swift` | `struct PartSteps { func process(partkey: String) async -> PartStepResult; func ensureNormalized(_:) async -> Bool; func ensureTranscribed(_:) async -> Bool; func ensureRawNote(_:) async -> Bool }` |
| `SessionSteps.swift` | `struct SessionSteps { func groupNewParts() throws; func closeIdleSessions() throws; func process(sessionKey: String) async -> SessionStepResult; func ensureMerged…; ensureAnalysis…; ensureDailyNote… }` |
| `Guards.swift` | `public enum PauseReason: String, Sendable, CaseIterable { case diskSpaceLow = "disk_space_low", whisperMissing = "whisper_missing", modelMissing = "model_missing", vadModelMissing = "vad_model_missing", vaultNotConfigured = "vault_not_configured", vaultUnavailable = "vault_unavailable", llmNotSelected = "llm_not_selected", llmModelMissing = "llm_model_missing", llmInsufficientMemory = "llm_insufficient_memory", llamaServerMissing = "llama_server_missing", license }` |
| `InProcessRetry.swift` / `Requeue.swift` | internal |
| `InboxMaintenance.swift` | `struct InboxMaintenance { func removeOrphans() throws -> Int; func leftovers() throws -> (count: Int, bytes: Int64) }` |
| `LockObserving.swift`（**T-32 が作る**。Phase 7 の診断が Phase 8 の型に依存しないため） | `public protocol LockObserving: Sendable { func observe(config: AppConfig, snapshot: DeviceSnapshot?) async -> LockObservation; func reaperStatus() async -> ReaperStatus }`、`public struct DisabledLockObserver: LockObserving`（常に「削除は無効」を返す。Phase 7 の Bootstrap が注入する）。`LockObservation` / `LockDisplay` / `ReaperStatus` / `DeletionReadiness` / `DeviceWritability` もこのファイル（T-32）。`DeletionReadiness` は `configured` / `disabled(String)` / `unconfirmed`（F-76。ProcessRunner が閉じた後で reaper の版を観測できない。要求も削除せずの完了もしない）。**T-36 の `LockEvaluator` がこのプロトコルに準拠し、Bootstrap の注入を差し替える** |
| `LockEvaluator.swift` | `DeletionReadiness` / `DeviceWritability` の定義は `LockObserving.swift`（T-32）。`public actor LockEvaluator: LockObserving { init(layout: HomeLayout, verifier: any SignatureVerifier, runner: any ProcessRunning, log: AppLog); nonisolated let reaper: ReaperRunner; func observeReaperConf() -> ReaperConfObservation; func observe(config: AppConfig, snapshot: DeviceSnapshot?) async -> LockObservation /* LockObserving の証人。readiness・writability・表示を 1 回でまとめて */; func reaperStatus() async -> ReaperStatus /* 同上 */; func observe(config: AppConfig, snapshot: DeviceSnapshot?, useCache: Bool) async -> LockObservation /* 多重定義。T-38 が使う。`WorkerDependencies.locks` が具体型 `LockEvaluator` なのはこのため */; func readiness(config: AppConfig, useCache: Bool = true) async -> DeletionReadiness /* 署名と版は (inode,size,mtime) でキャッシュ */; func writability(deviceID: String, snapshot: DeviceSnapshot?) -> DeviceWritability; func allReleased(deviceID: String, config: AppConfig, snapshot: DeviceSnapshot?) async -> Bool }`（`display` は `LockObserving` の既定実装。`readiness(config:useCache:)` は多重定義で残す＝T-38 が使う） |
| `SignatureVerifier.swift` | `public protocol SignatureVerifier: Sendable { func verify(url: URL) -> Bool }`、`public struct CodeSignatureVerifier: SignatureVerifier { init(requirement: String) }`、`public enum ReaperSignature { static func requirement(bundleID: String, teamID: String) -> String }` |
| `DeletionPolicy.swift` | `public struct DeletionCandidate: Sendable`（Part とその Session・Part 群）、`public struct DeletionContext: Sendable`（設定・snapshot・ロックの観測・Vault・`VolumeOpener`・双子の引き方）、`public enum DeletionPolicy { static func canDeleteSource(_ c: DeletionCandidate, _ ctx: DeletionContext) -> Bool; static func deletionIsIdentified(…); static func textIsPreserved(…); static func nothingToPreserve(…); static func skipReasonIsBacked(…); static func preIdentityCheck(…) }`（§8.9.1 の形のまま。引数は 2 つに固定）。あわせて `TwinPart.load`・`RawNoteVerdict`・`DeletionReason`（T-36）。`LockDisplay` / `LockObservation` / `ReaperStatus` は `LockObserving.swift`（T-32）。事前確認のボリュームの親は reaper.conf の `VOLUMES_ROOT` から取る |
| `DeletionRequester.swift` / `SessionDeletionStage.swift` / `ResultCollector.swift` / `RequestExpirer.swift` / `SkippedSettler.swift` | T-38 / T-39 |
| `ReaperRunner.swift` | `public struct ReaperRunner: Sendable { init(layout: HomeLayout, runner: any ProcessRunning, verifier: any SignatureVerifier); func versionMatches() async -> Bool; func run() async -> ReaperRunOutcome }`（パスを引数に取らない。署名と版の検証は T-36、`run` は T-38 が足す）、`public enum ReaperRunOutcome: Equatable, Sendable`（終了コード・シグナル・タイムアウト・起動失敗。T-38） |
| `DeletionEnabler.swift` | `public actor DeletionEnabler { init(layout:paths:config:verifier:ingest:log:); func enable(confirmation: String) async -> Result<Void, EnableError>; func enableSkippedDeletion(confirmation: String) async -> Result<Void, EnableError>; func disable() async -> [String] /* 失敗した段の名前 */; func reconcileLock1() async -> Bool /* PLAN §6.1 */ }` |
| `SummarizeNow.swift` | `public struct SummarizeNowFailure: Error, Equatable, Sendable { let message: String; init(message:) }`（今すぐ要約を行わなかった理由の日本語。PLAN §5.4・F-66。内部の `struct SummarizeNow` が OPEN を日付を問わず閉じる） |
| `BacklogPlanner.swift` | `public struct BacklogPlan: Sendable, Equatable { eligible: [String]; skipped: [BacklogSkip] }`、`public struct BacklogSkip: Sendable, Equatable { partkey: String; reason: String }`、`public enum BacklogAction: Sendable { case preview(reply: @Sendable (Result<BacklogPlan, BacklogFailure>) -> Void), execute(preview: BacklogPlan, reply: @Sendable (Result<BacklogExecution, BacklogFailure>) -> Void) }`（`preview` はプレビューで見せた計画。実行はその対象と立て直した計画の対象の積だけ。F-72）、`public struct BacklogFailure: Error, Equatable, Sendable { message: String }`、`public enum BacklogKind: String, Sendable, Equatable { case backlog, resolveAbsent }`（2026-09-22 利用者の承認。T-41 §11 の 5）、`public struct BacklogExecution: Equatable, Sendable { previewed: Int; added: Int; done: Int }`（`Error` は Equatable にできないので専用の型。定義は T-41。F-72 で `plan` を `previewed`・`added` に替えた）。`WorkerJob` の 2 つの case は T-41 が足す |
| `LicenseGate.swift` | `public protocol LicenseGate: Sendable { func allowsProcessing() -> Bool }`、`public struct AlwaysAllowLicenseGate: LicenseGate` |
| `ImportedKeysScanner.swift` | — 取り下げ（T-33。PLAN §8.13・F-60）。作らない |
| `Diagnostics/Diagnostics.swift` | `public enum DiagnosticStatus: String, Sendable { case ok, notice, fail, skip }`、`public struct DiagnosticResult: Sendable, Equatable { id: String /* "DR-nn" */; status: DiagnosticStatus; label: String; details: [String] }`、`public struct Diagnostics: Sendable { func run(loginItemStatus: LoginItemStatus) async -> [DiagnosticResult] }`、`public enum LoginItemStatus: Sendable { case enabled, requiresApproval, notRegistered, notFound }` |
| `AttentionItems.swift` | `public enum AttentionItem: Equatable, Sendable { … §8.11 の表。case undeletableSources(Int)（F-69）、末尾に case rawNoteBlocked(Int)（F-75） }`、`public enum AttentionAction`（`case openDetails` を足す。F-69）、`public struct AttentionInput`（`var undeletableSources = 0`。F-69。`var rawNoteBlocked = 0`。F-75）、`public enum AttentionEvaluator { static func items(…) -> [AttentionItem]; static func sourcePresence(_ part: RecordingRow, snapshot: DeviceSnapshot?) -> SourcePresence; static func undeletableStillListed(_ parts: [RecordingRow], snapshot: DeviceSnapshot?) -> [RecordingRow] /* F-69 */; static func rawNoteBlockedSessions(_ parts: [RecordingRow]) -> Int /* F-75 */ }`、`public enum SourcePresence: Equatable, Sendable { case listed, notListed, unobserved }`（F-69） |
| `StatusReport.swift` | `public struct StatusReport: Sendable { … §8.12 の状態の詳細。var undeletable: [UndeletablePart] = []・var undeletableTotal = 0（F-69） }`、`public struct StatusReport.UndeletablePart: Equatable, Sendable { partkey: String; cause: String?; presence: SourcePresence; var detail: String }`（F-69）、`public enum StatusReporter { static func build(…) -> StatusReport }` |

---

## 12. VoiceDockApp（T-30 / T-31 / T-40 の UI）

| ファイル | 公開宣言（実行ファイルなので internal でよい） |
|---|---|
| `main.swift` | `NSApplication.shared` に `AppDelegate` を設定して `run()` |
| `AppDelegate.swift` | 起動手順（§8.15）、終了（`.terminateLater`） |
| `Bootstrap.swift` | 依存の組み立て（本番の実装を注入する唯一の場所） |
| `StatusItemController.swift` | `NSStatusItem` と `NSPopover` |
| `AppServices.swift` | `protocol AppServices: Sendable`（AppModel が外に触れる唯一の口。T-30 が `read(lastConnectedAt:)` / `requeueManual()` / `reloadConfig()` / `scanNow()` / `updates()` を作り、**T-31 が `importGGUF(from:)`**（UI の語。委譲先は `ModelManager.importCustomLLM(from:)`）・`download` 系、**T-32 が `enqueue(_:)`**、**T-40 が有効化・無効化の口**を足す）と `struct LiveServices: AppServices { let context: AppContext }` |
| `AppModel.swift` | `@MainActor @Observable final class AppModel` |
| `IconState.swift` | `enum IconState { idle, ingesting, processing, attention }` と `trash` の表示 |
| `Strings.swift` | 文言 |
| `LoginItem.swift` | `SMAppService.mainApp` の包み |
| `UIState.swift` | `ui-state.json` の読み書き（`UIState`・`UIStateStore`）。F-70 で `UIState.lastConnectedAt`（最終接続。鍵 `lastConnectedAt` は epoch ミリ秒の整数、任意）と、最終接続の決め方と書く頻度の純関数 `enum LastConnected { resolve(device:carried:persisted:); valueToSave(current:connected:written:) }` を足した（作り手 T-31 のファイル。使い手 T-30 の `LiveServices.read`・`AppModel.refresh`） |
| `Panel/*.swift` | SwiftUI のビュー（`PanelView`、`StatusSection`、`AttentionSection`、`OnboardingSection`、`VaultSection`、`ModelsSection`、`GeneralSection`、`DeletionSection`、`DetailsSection`）。F-65 で足した部品: `PanelStyle`（`SectionBox` のカード）、`SubScreen`（popover の中の別の画面の枠。「‹ 戻る」。スクロールはここだけ）、`PanelRow`（別の画面へ移る 1 行）、`HoldToConfirmButton`（3 秒の長押しで確かめる赤いボタン。`holdDuration`・`progress(elapsed:duration:)`・`Tracker`。作り手 T-40） |
| `PanelScreen.swift` | （F-65）`enum PanelScreen { main, attention, deletion, details, settings }`。`AppModel.screen` と `AppModel.show(_:)`（`AppModel+Navigation.swift`。作り手 T-30） |
| `AppModel+SummarizeNow.swift` | （F-66）`AppModel.SummarizeNowState { idle, running, succeeded(Int), failed(String) }`、`AppModel.requestSummarizeNow()`（`AppServices.enqueue(.summarizeNow(reply:))` を 1 回。実行中は入れない）、`summarizeNowNotice`（通知の文言）。状態の見出しの「今すぐ要約」ボタンが使う（PLAN §8.12 の 1。作り手 T-30） |

---

## 13. voicedock-reaper（T-37）— Foundation・Darwin・VDContract だけ

| ファイル | 役割 |
|---|---|
| `main.swift` | 引数を読み `ReaperMain.run(arguments:)` の終了コードで `exit`。`--version` の出力（`print` はここだけ） |
| `ReaperArguments.swift` | `--home <HOME>` / `--version` の解析 |
| `SelfLocation.swift` | RV-00（`_NSGetExecutablePath` → realpath） |
| `ReaperMain.swift` | 起動時の検査 → flock → 走査 → 1 件ずつ `RequestProcessor` |
| `RequestProcessor.swift` | RV-02〜RV-13 |
| `QueueFiles.swift` | 列挙・rejected への rename・結果の書き込み（AtomicFile） |
| `ProcessedLog.swift` | processed.log の照合と追記 |
| `ReaperLog.swift` | reaper.log の行と回転 |
| `ReaperClock.swift` | 時刻（PT-09 の許可場所） |
| `Unlinker.swift` | `unlinkat` と要求ファイルの削除（PT-01 の許可場所） |
| `Signals.swift` | SIGTERM で「今の 1 件の後に止まる」フラグ |

---

## 14. テスト（`Tests/`）

| ターゲット | 依存 | 主な中身 |
|---|---|---|
| `TestSupport`（`.target`） | すべての VD モジュール, Testing, Synchronization | §10.2 の偽物、`TempDirectory`、`PackageRoot`、`TestEnvironment`（環境変数を読む唯一の場所）、`Builders`（DB の行を作る）、golden（`Golden` / `GoldenCase` / `GoldenJSON` / `GoldenAssert` / `UnifiedDiff`）、`Markdown/MarkdownDocument`、`Spec/SpecDocument`。**作り手は下の §15 の表で一意に決める** |
| `VDContractTests` … `VDModelsTests`（`VDProcessTests` を含む） | 対応するモジュール, TestSupport | 単体・golden |
| `VoiceDockAppTests` | VoiceDockApp（`@testable`）, TestSupport | AppModel の単体 |
| `VDPipelineTests` | VDPipeline, TestSupport | Worker・工程・結合 |
| `NoDeleteTests` | VDPipeline, TestSupport | ND（層 A） |
| `ReaperTests` | VDContract, TestSupport, **voicedock-reaper（実行ファイルのターゲット）** | ND（層 R1・R2・R3） |
| `PolicyTests` | TestSupport, VDContract（`AppVersion.components` を使う。CR-06） | PT・SPEC 同期・文書テスト（`RunbookTests`（T-35）・`RunbookGateTests`（T-42）・`ReadmeTests`（T-43）・`ReleaseChecklistTests`（T-44）・`ReleaseBundleTests`（T-34）・`ConfigEffectCoverageTests`（T-09））。`Runbook` / `RunbookGate` / `Readme` / `ReleaseDoc` / `DocumentedCounts` は PolicyTests の中に置く（§15 に載せない） |
| `LLMAcceptance` | VDPipeline, VDLLM, TestSupport | §10.6（環境変数が無ければ全部無効） |

---

## 15. TestSupport の部品の作り手（一意。ほかのチケットは使うだけ。足したい機能は作り手のチケットの型に extension で足す）

| 部品 | 作るチケット | 使う主なチケット |
|---|---|---|
| `TempDirectory`、`PackageRoot`、`TestEnvironment` | T-01 | すべて（T-02〜T-05・T-25 が T-06 より前に使う） |
| `Markdown/MarkdownDocument` | T-04 | T-05 以降 |
| `Spec/SpecDocument`（`codeBlock(heading:language:)` を含む）。**issue #18 が extension `Spec/SpecDocument+ExtendedSections.swift` で読み取り口を足した**: `reasonWords()`（S8 の理由語の列）・`namePatterns()`（S10）・`whisperArgv()`（S11）・`noteRules(_:)`（S12。`SpecNoteKind`）・`tickStages()`（S13。`SpecTickStage`）・`panelSections()`（S20。`SpecPanelSection`）・`iconRows()`（S21。`SpecIconRow`）・`onboardingSteps()`（S22。`SpecOnboardingStep`）・`uiStateKeys()`（S23。`SpecJSONKey`）。PLAN F-68 | T-05 | T-08・T-10・T-17 など SPEC 同期のテスト。#18 の分は T-06・T-07（VDContractTests）、T-17（VDTranscribeTests）、T-18（VDPipelineTests）、T-28（VDNotesTests・PolicyTests）、T-30・T-31（VoiceDockAppTests・PolicyTests） |
| golden 一式（`Golden`、`GoldenCase`、`GoldenJSON`、`GoldenError`、`GoldenAssert`、`UnifiedDiff`） | T-25 | T-45・T-19・T-20・T-26・T-27 |
| `FakeVolume`（`StandardTree` の定数を含む）、`FakeVolumeOpener`、`DiskImageVolume`（**`/Volumes` の下には決して attach しない**） | T-07 | T-13・T-14・T-15・T-36〜T-38 |
| `FixedClock`、`SteppingClock`（`now()` と `uptime()` の両方を呼ばれるたびに進める）、`RecordingSleeper`、`CapturingLogSink` | T-10 | すべて |
| `GoldenConfig.make`（golden の設定の上書きから `AppConfig` を作る） | T-09 | T-26・T-27・T-19 |
| `FakeMountInspector`、`ScriptedProcessRunner` | T-13 | T-14・T-15・T-18 |
| `BWFWriter`（仕様は T-16 に書いたもの（make_wav と一致を確かめた版）を正とし、**T-14 が作る**） | T-14 | T-16・T-18 |
| `FakeChunkReader` | T-14 | T-14 |
| `FakeRemounter`、`FakeMountEventSource`、`SuspendingSleeper` | T-15 | T-18 |
| `FakeWhisper` | T-17 | T-18・T-29 |
| `FakeChatTransport` | T-19 | T-20・T-22・T-29 |
| `BlockingURLProtocol`、`LoopbackStub`、`FakeLlamaServer` | T-21 | T-22・T-23 |
| `FakeSignatureVerifier` | T-36 | T-38・T-40 |
| `Builders`（DB の行を作る） | T-11 | T-18 以降 |
| `FakeIngest`（`IngestPort`） | T-18 | T-22 以降 |
| `FakeLLMServer`（`LLMServerControl`） | T-22 | T-29 以降 |
| `DeletionScene`、`StorePaths`、`ScriptedProcessRunner.version` | T-36 | T-38〜T-41 |
| `ScriptedIngest`、`installRealReaper` | T-38 | T-39・T-41 |
| `ModelHostStub`、`ModelHostURLProtocol` | T-23 | T-31 |
| `BlockingURLProtocol`、`BlockingSessionFactory`（`LoopbackSessionFactory` と `DownloadSessionFactory` の両方に適合） | T-21 | T-23・T-31 |
| `AcceptanceFixture`、`AcceptanceHarness`、`AcceptanceJudge`、`AcceptanceReport`、`CountingChatTransport`（**`Tests/LLMAcceptance/` に置く**）と `TestEnvironment` の extension（`llmFixtureDirectory` / `llmReportURL(model:)`） | T-24 | — |
| `ReaperBinary`（`ReaperRun`・`ReaperProcess`・`ReaperBinaryError` を含む） | T-37 | T-38 |
| `AppServices` の偽物など UI 用の部品（**`Tests/VoiceDockAppTests/` に置く**。TestSupport ではない） | T-30 | T-31・T-32 |
| `Tags`（Swift Testing のタグ） | T-01 | すべて |
| `TestCatalogs`（テスト用の ModelCatalog） | T-09 | T-17・T-22・T-23・T-32 |
| `GoldenCase.orderedObject`（`PyJSONValue` を使う extension。**T-25 の `GoldenCase` 自体は VDCore に依存しない**） | T-45 | T-19 |

---

## 16. 整合修正（F2）で見つかった、地図に行の無い公開 API（各チケットが正。ここは索引）

| モジュール | 名前 | チケット |
|---|---|---|
| VDDevice | `DetectionResult` の `listingError` の扱い、`WorkspaceMountEventSource`（本番の `MountEventSource`）、`DiskutilRemounter` の定数 | T-13・T-15 |
| VDLLM | `PromptKind`、`AnalysisLimits`、`PromptsError`、`Prompts.system`、`Dedupe.strings` / `tasks`、`LoopbackEndpoint.host` / `port`、`LlamaServerHandle: Equatable` | T-19〜T-21 |
| VDNotes | `NoteFolderError`、`OutputPathResolver.maxSuffix`、`DailyNote` の定数 | T-27・T-28 |
| VDModels | `EphemeralDownloadSessionFactory`（本番）、`ModelHostStub` 一式（TestSupport。作り手 T-23）、`ModelError.logReason` / `displayMessage` | T-23 |
| VDPipeline | `StatusTexts`（T-30 が作る）、`InboxScan`（T-32）、`Diagnostics/LoginItemStatus`（T-30）、`LLMReadiness.check`（T-22 のガードを公開。DR-09 と共有）、`DeleteQueue.withdrawAllRequests`（T-40）、`ErrorText` は public | T-22・T-30・T-32・T-40（T-33 の `ImportedKeysService` / `ImportedKeysScanReason` は取り下げ。PLAN F-60） |
| VDCore | `ModelMemory`（T-30 が作る。メモリの条件を 1 か所に） | T-30 |
| VDStore | `ReadOnlyStore.inboxPaths(statuses:)`、`Store.migrationIdentifiers`（DR-02 が最新版を判定する） | T-32 |
| VoiceDockApp | `AppSnapshot` / `AppServices` / `StatusLine` / `StatusIconImage` / `PanelStyle` / `Onboarding` / `ModelChoices` / `FolderChooser` / `DownloadState` / `AppModel+*` / `AttentionTexts`、`Bootstrap.build() async -> Result<AppContext, BootFailure>`（単一起動のロックが取れなければ `.alreadyRunning`。F-76） | T-30・T-31・T-32 |
| voicedock-reaper | `ReaperIO.swift`（`PosixIO` が internal なので reaper 側に同じものを置く）、`main.swift` は `ReaperMain.run(arguments:)` の返す `ReaperExit` を出力して exit | T-37 |
| 資源 | `Resources/bundle-manifest.txt`（T-34。バンドルに入ってよいファイルの唯一の出所）、`Resources/AppIcon.icns`（**T-34（仮アイコン。利用者の決定）**） | T-34 |

