# T-09 VDCore: AppConfig・ConfigLoader（CV-01〜59）・ConfigMigrator・既定値・ModelCatalog

| 項目 | 値 |
|---|---|
| Phase | 2（記録の土台） |
| 前提 | T-04（PolicyTests の基盤。ConfigEffect の網羅テストを PolicyTests に置き、`SourceTree`・`SourceScanner` で読む）、T-05（SPEC 同期。CV の ID を SPEC から読む）、T-08（`ErrorCode`）、T-10（`logging.level`・`logging.unsafeLogContent` の `CE` テストが先に在ること。§9）、T-25（TestSupport の `GoldenCase`。§10 の `GoldenConfig` が使う）。T-06（`ReaperConfObservation`）は T-08 の前提として入っている |
| 見積もり | ソース約 900 行、テスト約 900 行（CV ごとのテストがあるため 600 行を超える。PLAN §12.1 の例外として「設定の表を割ると CV の順序の検査が割れる」ことを PR 本文に書く） |
| ブランチ | `feat/T-09-config` |

## 目的

`config.json` の型（`AppConfig`）・既定値・読み込み（4 段）・検証規則（CV）・移行器と、モデルカタログ（`ModelCatalog`）を VDCore に作る。
**既定値は `AppConfig.defaults(timeZone:)` の 1 か所だけ**。違反は例外にせず `ConfigViolation` の配列で返す（PLAN §6.1）。
あわせて「全キーに振る舞いのテストがあるか」を検査する仕組み（ConfigEffect の網羅テスト）を作る。各キーの振る舞いテストは、そのキーを使うチケットが書く。

## 参照

- PLAN §6 全体（§6.1 方針・§6.2 JSON の形・§6.4 CV の表）、§8.10（カタログ）、§3.2（`Resources/ModelCatalog.json`）
- voicedock@d3d595e: `src/voicedock/config.py`（V 規則の文言の型、`Violation.render`）、`config/config.example.yaml`、`tests/unit/test_config.py`
- 移植メモ V2 §6

## 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDCore/Config/AppConfig.swift` | `AppConfig` と入れ子の struct・`defaults(timeZone:)` |
| `Sources/VDCore/Config/ConfigViolation.swift` | `ConfigViolation`・`ConfigLoadResult` |
| `Sources/VDCore/Config/ConfigKeys.swift` | `ConfigKeys`（全葉のキーパス・子の名前） |
| `Sources/VDCore/Config/ConfigMigrator.swift` | `ConfigMigrator` |
| `Sources/VDCore/Config/ConfigLoader.swift` | `ConfigLoader`（4 段の読み込みと書き出し） |
| `Sources/VDCore/Config/ConfigValidator.swift` | `ConfigValidator`（CV-08〜59） |
| `Sources/VDCore/ModelCatalog.swift` | `ModelCatalog`・`ModelKind`・`ModelEntry`・`CatalogError`・`CatalogRejection`・`CustomModelID` |
| `Sources/VDCore/ModelFiles.swift` | モデルの置き場所と在否（§7.1） |
| `Resources/ModelCatalog.json` | PLAN §8.10 の JSON（値は逐語。T-24 で再確認する） |
| `Tests/VDCoreTests/AppConfigTests.swift` | 既定値・符号化 |
| `Tests/VDCoreTests/ConfigLoaderTests.swift` | 4 段の読み込み・CV-01・CV-39 |
| `Tests/VDCoreTests/ConfigValidatorTests.swift` | CV-08〜59 |
| `Tests/VDCoreTests/ModelCatalogTests.swift` | カタログ |
| `Tests/VDCoreTests/ModelFilesTests.swift` | `ModelFiles` の 3 つの関数（§7.1。中身の表は T-22 §6.9） |
| `Tests/PolicyTests/ConfigEffectCoverageTests.swift` | 全キーに `CE <keyPath>` のテストがあるか |
| `Tests/PolicyTests/ConfigEffectPending.swift` | まだ振る舞いテストの無いキーと、書く予定のチケット |
| `Tests/TestSupport/TestCatalogs.swift` | テスト用の小さなカタログ |
| `Tests/TestSupport/GoldenConfig.swift` | golden の設定の上書きから `AppConfig` を作る（00-api-map §15 の作り手はこのチケット。§10） |
| `Tests/VDCoreTests/GoldenConfigTests.swift` | `GoldenConfig.make` のテスト |
| `Tests/PolicyTests/SpecSync/SpecCoverage.swift`（変更） | `activated` に `.cv` を足す（T-05 §4。CV のテストが揃ったので SPEC の CV の集合 = テストの表示名の CV の集合を確かめる） |

`PackageRoot`・`TempDirectory`・`TestEnvironment`（TestSupport）は T-01 が作る（このチケットでは作らない）。

## 仕様

### 1. `Config/AppConfig.swift`

プロパティ名は §6.2 の JSON キーと**同じ綴り**（`CodingKeys` を書くのは `AnalysisSections` だけ）。すべて `public var`、`Codable, Equatable, Sendable`、メンバごとの `public init` を書く（synthesized の memberwise init は internal のため）。

```swift
public struct AppConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var timeZone: String
    public var vault: VaultConfig
    public var device: DeviceConfig
    public var audio: AudioConfig
    public var session: SessionConfig
    public var transcription: TranscriptionConfig
    public var llm: LLMConfig
    public var obsidian: ObsidianConfig
    public var cleanup: CleanupConfig
    public var retry: RetryConfig
    public var logging: LoggingConfig
}

public struct VaultConfig { public var path: String?; public var marker: String }
public struct DeviceConfig {
    public var includeVolumes: [String]; public var excludeVolumes: [String]; public var mountMode: String
    public var stabilityFastPathSeconds: Int; public var stabilityIntervalSeconds: Int; public var stabilityChecks: Int
    public var maxScanDepth: Int; public var scanIntervalSeconds: Int; public var snapshotMaxAgeSeconds: Int
    public enum MountMode: String, Sendable { case ro, rw }
    /// 検証済みなら `mountMode` の値。不正な値は安全側の `.ro`（CR-04）。
    public var mode: MountMode { MountMode(rawValue: mountMode) ?? .ro }
}
public struct AudioConfig {
    public var timeoutFactor: Double; public var minTimeoutSeconds: Int; public var durationToleranceSeconds: Double
    public var freeSpaceMultiplier: Double; public var freeSpaceMarginBytes: Int; public var stagingMaxBytes: Int
    public var hashChunkBytes: Int; public var inboxRetain: String
    public enum InboxRetain: String, Sendable { case normalized = "normalized"; case rawSaved = "raw_saved" }
    /// 不正な値は安全側（inbox を長く残す）の `.rawSaved`。
    public var retain: InboxRetain { InboxRetain(rawValue: inboxRetain) ?? .rawSaved }
}
public struct SessionConfig {
    public var blockGapSeconds: Int; public var idleCloseSeconds: Int; public var allowReopen: Bool
    public var maxParts: Int; public var maxDurationSeconds: Int
}
public struct TranscriptionConfig {
    public var whisperModelID: String; public var language: String; public var threads: Int
    public var timeoutFactor: Double; public var minTimeoutSeconds: Int; public var maxTimeoutSeconds: Int
    public var minChars: Int; public var vad: VADConfig
}
public struct VADConfig {
    public var enabled: Bool; public var modelID: String; public var threshold: Double
    public var minSpeechDurationMs: Int; public var minSilenceDurationMs: Int; public var speechPadMs: Int
}
public struct LLMConfig {
    public var modelID: String?; public var contextSize: Int; public var temperature: Double; public var topP: Double
    public var maxOutputTokens: Int; public var requestTimeoutSeconds: Int; public var maxCharsPerRequest: Int
    public var maxSecondsPerRequest: Int; public var chunkOverlapChars: Int; public var repairAttempts: Int
    public var analysis: AnalysisConfig
}
public struct AnalysisConfig { public var sections: AnalysisSections; public var order: [String]; public var customInstructions: String }
public struct AnalysisSections {
    public var summary: SectionConfig; public var timeline: SectionConfig; public var keyPoints: SectionConfig
    public var tasks: SectionConfig; public var decisions: SectionConfig; public var ideas: SectionConfig; public var tags: SectionConfig
    enum CodingKeys: String, CodingKey { case summary, timeline, keyPoints = "key_points", tasks, decisions, ideas, tags }
    /// 節名（JSON のキー。`SectionName.all` のどれか）で引く。無い名前は nil。
    public func section(named name: String) -> SectionConfig? { … }   // switch で 7 つ、default は nil
    /// F-54: `summary` と `timeline` の JSON には `maxItems` が無い（`maxItems` を持つのは 5 節だけ。PLAN §6.2）。
    /// この 2 つだけ `HeadingOnlySection` で符号化・復号し、`SectionConfig.maxItems` は常に nil になる。
    private struct HeadingOnlySection: Codable, Equatable, Sendable { var enabled: Bool; var heading: String?; func encode(to:) … }  // heading の nil も null で書く
    public init(from decoder: Decoder) throws { … }   // summary / timeline は HeadingOnlySection、残り 5 つは SectionConfig
    public func encode(to encoder: Encoder) throws { … } // 同上（summary / timeline に maxItems のキーを書かない）
}
/// `maxItems` は `key_points` / `tasks` / `decisions` / `ideas` / `tags` の 5 節だけが持つ（F-54）。
/// `summary` / `timeline` では常に nil（JSON に書いたら CV-01）。
public struct SectionConfig { public var enabled: Bool; public var heading: String?; public var maxItems: Int? }
public enum SectionName {
    /// LLM の JSON のキーと同じ節名。この順が CV-17 のメッセージと CV-56 の検査の順。
    public static let all: [String] = ["summary", "timeline", "key_points", "tasks", "decisions", "ideas", "tags"]
}
public struct ObsidianConfig { public var maxTitleBytes: Int; public var defaultTags: [String]; public var raw: RawNoteConfig; public var wiki: WikiNoteConfig }
public struct RawNoteConfig { public var folderTemplate: String; public var filenameTemplate: String; public var timestampIntervalSeconds: Int; public var partBoundaryHeading: Bool }
public struct WikiNoteConfig {
    public var folderTemplate: String; public var filenameTemplate: String
    public var linkDailyNote: Bool; public var linkAdjacentDays: Bool; public var linkTags: Bool; public var linkOnlyExisting: Bool
    public var vaultIndexCacheSeconds: Int; public var maxLinks: Int
}
public struct CleanupConfig {
    public var deleteSourceAudio: Bool; public var deleteSkippedSource: Bool; public var deleteNormalizedAfterTranscribe: Bool
    public var deleteEvaluationBackoffSeconds: [Int]; public var deleteResultTimeoutSeconds: Int
}
public struct RetryConfig { public var maxAttempts: Int; public var backoffSeconds: [Int] }
public struct LoggingConfig { public var level: String; public var unsafeLogContent: Bool }
```

（上は宣言の要約。各 struct に `Codable, Equatable, Sendable` と memberwise の `public init` を付ける。）

- `mountMode` / `inboxRetain` / `level` を enum にしないのは、型にすると不正な値が CV-48 / CV-29 / CV-54 ではなく CV-39（型違い）になり、規則の ID が変わるため
- **null を JSON に書き出すための `encode(to:)`**: `VaultConfig`・`LLMConfig`・`SectionConfig` の 3 つ（と private の `HeadingOnlySection`。summary / timeline の `heading` を nil にして書き出すと、キーが消えて読み直しが CV-39 になるため）だけ手で書く。`CodingKeys` は synthesized のものを使う（`init(from:)` を synthesized のままにすると `CodingKeys` も合成される）。synthesized は nil を省くので、`container.encode(path, forKey: .path)` の形で**Optional をそのまま** encode する（nil は `null` になる）。decode は synthesized のまま（キーの有無は読み込みの 2 段目が先に保証する）

`AppConfig.defaults(timeZone:)`: §6.2 の JSON と**同じ値**を 1 か所に書く:

```swift
public static func defaults(timeZone: String) -> AppConfig {
    AppConfig(
        schemaVersion: 1,
        timeZone: timeZone,
        vault: VaultConfig(path: nil, marker: ".obsidian"),
        device: DeviceConfig(includeVolumes: [], excludeVolumes: ["Macintosh HD", "com.apple.TimeMachine.*", ".*"], mountMode: "ro",
                             stabilityFastPathSeconds: 60, stabilityIntervalSeconds: 3, stabilityChecks: 2,
                             maxScanDepth: 3, scanIntervalSeconds: 300, snapshotMaxAgeSeconds: 900),
        audio: AudioConfig(timeoutFactor: 0.5, minTimeoutSeconds: 180, durationToleranceSeconds: 1.0,
                           freeSpaceMultiplier: 2.0, freeSpaceMarginBytes: 2_147_483_648, stagingMaxBytes: 5_368_709_120,
                           hashChunkBytes: 1_048_576, inboxRetain: "normalized"),
        session: SessionConfig(blockGapSeconds: 3600, idleCloseSeconds: 1800, allowReopen: true, maxParts: 64, maxDurationSeconds: 86_400),
        transcription: TranscriptionConfig(whisperModelID: "large-v3-turbo-q5_0", language: "ja", threads: 0,
                                           timeoutFactor: 3.0, minTimeoutSeconds: 600, maxTimeoutSeconds: 21_600, minChars: 1,
                                           vad: VADConfig(enabled: true, modelID: "silero-v5.1.2", threshold: 0.5,
                                                          minSpeechDurationMs: 250, minSilenceDurationMs: 1000, speechPadMs: 200)),
        llm: LLMConfig(modelID: nil, contextSize: 32_768, temperature: 0.1, topP: 0.9, maxOutputTokens: 4096,
                       requestTimeoutSeconds: 1800, maxCharsPerRequest: 20_000, maxSecondsPerRequest: 3600,
                       chunkOverlapChars: 500, repairAttempts: 1,
                       analysis: AnalysisConfig(
                           sections: AnalysisSections(
                               summary: SectionConfig(enabled: true, heading: "## Summary", maxItems: nil),   // F-54: JSON に maxItems は無い
                               timeline: SectionConfig(enabled: true, heading: "## Timeline", maxItems: nil), // 同上
                               keyPoints: SectionConfig(enabled: true, heading: "## Key Points", maxItems: 20),
                               tasks: SectionConfig(enabled: true, heading: "## Tasks", maxItems: 50),
                               decisions: SectionConfig(enabled: true, heading: "## Decisions", maxItems: 30),
                               ideas: SectionConfig(enabled: true, heading: "## Ideas", maxItems: 30),
                               tags: SectionConfig(enabled: true, heading: nil, maxItems: 15)),
                           order: ["summary", "timeline", "key_points", "tasks", "decisions", "ideas"],
                           customInstructions: "")),
        obsidian: ObsidianConfig(maxTitleBytes: 180, defaultTags: ["voice", "voicedock"],
                                 raw: RawNoteConfig(folderTemplate: "Daily/Voice/Raw/{yyyymmdd}", filenameTemplate: "{date} raw",
                                                    timestampIntervalSeconds: 300, partBoundaryHeading: true),
                                 wiki: WikiNoteConfig(folderTemplate: "Daily/Voice/Wiki/{yyyymmdd}", filenameTemplate: "{date} Voice",
                                                      linkDailyNote: true, linkAdjacentDays: true, linkTags: true, linkOnlyExisting: true,
                                                      vaultIndexCacheSeconds: 300, maxLinks: 20)),
        cleanup: CleanupConfig(deleteSourceAudio: false, deleteSkippedSource: false, deleteNormalizedAfterTranscribe: true,
                               deleteEvaluationBackoffSeconds: [60, 300, 900, 3600], deleteResultTimeoutSeconds: 3600),
        retry: RetryConfig(maxAttempts: 3, backoffSeconds: [3, 10, 30]),
        logging: LoggingConfig(level: "INFO", unsafeLogContent: false))
}
```

### 2. `Config/ConfigViolation.swift`

```swift
public struct ConfigViolation: Error, Equatable, Sendable {   // Error は ConfigMigrator.migrate の Result の失敗側に置くため（投げない）
    public let rule: String      // "CV-nn"
    public let code: ErrorCode
    public let keyPath: String   // "device.stabilityChecks"、配列の要素は "device.includeVolumes.0"、ファイル全体は "<file>"
    public let message: String
    public init(rule: String, code: ErrorCode, keyPath: String, message: String)
    /// voicedock config.py:67-69 と同じ 1 行表記（区切りは空白 2 つ）。
    public var rendered: String { "\(rule)  \(code.rawValue)  \(keyPath): \(message)" }
}
public enum ConfigLoadResult: Equatable, Sendable {
    case valid(AppConfig)
    case invalid([ConfigViolation])
}
```

### 3. `Config/ConfigKeys.swift`

```swift
public enum ConfigKeys {
    /// 全葉のキーパス（§6.2 の JSON の出現順）。配列は葉。ConfigEffect の網羅テストと、読み込みの 2 段目が使う。
    public static let allKeyPaths: [String] = [ … 下の 93 個をこの順で … ]
    /// 葉でない（オブジェクトの）キーパス。`allKeyPaths` の各要素の真の接頭辞（`.` 区切り）から作る。
    public static let objectPaths: Set<String>
    /// あるオブジェクトの直下の子の名前。ルートは "" で引く。
    public static func children(of objectPath: String) -> Set<String>
    public static func isObject(_ path: String) -> Bool { objectPaths.contains(path) }
}
```

`allKeyPaths`（この順で 93 個。§6.2 の JSON の出現順）:

```text
schemaVersion, timeZone, vault.path, vault.marker,
device.includeVolumes, device.excludeVolumes, device.mountMode, device.stabilityFastPathSeconds, device.stabilityIntervalSeconds,
device.stabilityChecks, device.maxScanDepth, device.scanIntervalSeconds, device.snapshotMaxAgeSeconds,
audio.timeoutFactor, audio.minTimeoutSeconds, audio.durationToleranceSeconds, audio.freeSpaceMultiplier, audio.freeSpaceMarginBytes,
audio.stagingMaxBytes, audio.hashChunkBytes, audio.inboxRetain,
session.blockGapSeconds, session.idleCloseSeconds, session.allowReopen, session.maxParts, session.maxDurationSeconds,
transcription.whisperModelID, transcription.language, transcription.threads, transcription.timeoutFactor, transcription.minTimeoutSeconds,
transcription.maxTimeoutSeconds, transcription.minChars, transcription.vad.enabled, transcription.vad.modelID, transcription.vad.threshold,
transcription.vad.minSpeechDurationMs, transcription.vad.minSilenceDurationMs, transcription.vad.speechPadMs,
llm.modelID, llm.contextSize, llm.temperature, llm.topP, llm.maxOutputTokens, llm.requestTimeoutSeconds, llm.maxCharsPerRequest,
llm.maxSecondsPerRequest, llm.chunkOverlapChars, llm.repairAttempts,
llm.analysis.sections.summary.enabled, llm.analysis.sections.summary.heading,
llm.analysis.sections.timeline.enabled, llm.analysis.sections.timeline.heading,
llm.analysis.sections.key_points.enabled, llm.analysis.sections.key_points.heading, llm.analysis.sections.key_points.maxItems,
llm.analysis.sections.tasks.enabled, llm.analysis.sections.tasks.heading, llm.analysis.sections.tasks.maxItems,
llm.analysis.sections.decisions.enabled, llm.analysis.sections.decisions.heading, llm.analysis.sections.decisions.maxItems,
llm.analysis.sections.ideas.enabled, llm.analysis.sections.ideas.heading, llm.analysis.sections.ideas.maxItems,
llm.analysis.sections.tags.enabled, llm.analysis.sections.tags.heading, llm.analysis.sections.tags.maxItems,
llm.analysis.order, llm.analysis.customInstructions,
obsidian.maxTitleBytes, obsidian.defaultTags, obsidian.raw.folderTemplate, obsidian.raw.filenameTemplate,
obsidian.raw.timestampIntervalSeconds, obsidian.raw.partBoundaryHeading, obsidian.wiki.folderTemplate, obsidian.wiki.filenameTemplate,
obsidian.wiki.linkDailyNote, obsidian.wiki.linkAdjacentDays, obsidian.wiki.linkTags, obsidian.wiki.linkOnlyExisting,
obsidian.wiki.vaultIndexCacheSeconds, obsidian.wiki.maxLinks,
cleanup.deleteSourceAudio, cleanup.deleteSkippedSource, cleanup.deleteNormalizedAfterTranscribe,
cleanup.deleteEvaluationBackoffSeconds, cleanup.deleteResultTimeoutSeconds,
retry.maxAttempts, retry.backoffSeconds, logging.level, logging.unsafeLogContent
```

（内訳: トップ 2・vault 2・device 9・audio 8・session 5・transcription 13・llm 10・sections 19（`summary` と `timeline` は `enabled` と `heading` の 2 つずつ。`maxItems` を持つのは残り 5 節だけ。F-54）・order と customInstructions 2・obsidian 2・raw 4・wiki 8・cleanup 5・retry 2・logging 2。テストでは件数を直書きせず、`allKeyPathsMatchDefaultsEncoding` が既定値の符号化の葉の集合と一致することで固定する。TEST-01）

### 4. `Config/ConfigMigrator.swift`

```swift
public enum ConfigMigrator {
    public static let currentVersion = 1
    /// v1 は「1 ならそのまま」だけ（PLAN §6.1）。
    public static func migrate(_ object: [String: Any]) -> Result<[String: Any], ConfigViolation>
}
```

手順（keyPath はすべて `schemaVersion`、rule は `CV-39`、code は `configInvalidValue`）:
1. `object["schemaVersion"]` が無い → 失敗「キーがありません」
2. 値が `NSNumber` でない、bool（`CFGetTypeID(n) == CFBooleanGetTypeID()`）、浮動小数（`CFNumberIsFloatType(n)`）のどれか → 失敗「整数であること」
3. 値 `== 1` → `.success(object)`
4. 値 `> 1` → 失敗「この版のアプリより新しい設定です（schemaVersion <v>）。アプリを更新してください」
5. 値 `< 1` → 失敗「不正な schemaVersion（<v>）」

### 5. `Config/ConfigLoader.swift`

```swift
public enum ConfigLoader {
    public static func load(data: Data, catalog: ModelCatalog, reaperConfObservation: ReaperConfObservation) -> ConfigLoadResult
    /// config.json の書き出し。JSONEncoder（[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]）＋ 末尾 "\n"。
    public static func encode(_ config: AppConfig) -> Data
}
```

**PT-11**: 引数ラベル・仮引数名・ローカル変数名に識別子 `reaperConf` を使わない（`VDCore/Config/` は PT-11 の許可場所ではない）。ラベルは `reaperConfObservation:`、`.valid(...)` から取り出した値は `observed` のような名前にする（`reaperConfObservation` は前後が識別子の文字なので PT-11 に当たらない。PLAN §9.4 の照合はトークン単位）。00-api-map §11 の `ConfigStore` の行の決定に合わせている。

`load` の手順（PLAN §6.1 の 4 段。段ごとに違反があればそこで `.invalid` を返し、次の段へ進まない。4 段目だけは全 CV を評価する）:

1. **JSON として読む**: `JSONSerialization.jsonObject(with: data)`。失敗 → `[CV-39, "<file>", "JSON として読めません"]`。辞書でない → `[CV-39, "<file>", "JSON のオブジェクトではありません"]`
2. **移行**: `ConfigMigrator.migrate(dict)`。失敗 → その 1 件
3. **キー集合の照合**（全階層）: `checkKeys(dict, prefix: "")` を再帰で行う:
   ```text
   checkKeys(object, prefix):
     expected = ConfigKeys.children(of: prefix)
     for key in object.keys.sorted():                          // String の < で昇順
       path = prefix.isEmpty ? key : prefix + "." + key
       if !expected.contains(key): 違反(CV-01, configUnknownKey, path, "未知のキーです"); continue
       if ConfigKeys.isObject(path):
         guard let child = object[key] as? [String: Any] else { 違反(CV-39, configInvalidValue, path, "オブジェクトであること"); continue }
         checkKeys(child, path)
     for key in expected.sorted() where object[key] == nil:    // JSON の null は NSNull なので「在る」
       違反(CV-39, configInvalidValue, prefix.isEmpty ? key : prefix + "." + key, "キーがありません")
   ```
   違反の並びは「そのオブジェクトの未知キー・型（昇順、子の再帰を含む）→ そのオブジェクトの欠けたキー（昇順）」。1 件以上あれば `.invalid`
4. **型に写す**: `JSONDecoder().decode(AppConfig.self, from: data)`（v1 では移行で値を変えないので**元の `data` を渡す**）。`DecodingError` を 1 件の違反（CV-39、configInvalidValue）に写す:
   - keyPath: `codingPath` の各キーを、`intValue` があれば `String(intValue)`、無ければ `stringValue` にして `.` でつなぐ（`keyNotFound(key, ctx)` は `ctx.codingPath + [key]`）。空なら `"<file>"`
   - message: `typeMismatch` →「型が違います」、`valueNotFound` →「null にできません」、`keyNotFound` →「キーがありません」、`dataCorrupted` →「値が不正です」、それ以外 →「読めません」
   - **整数の位置の `1.5`**: JSONDecoder（macOS 15 以降の Foundation）は `typeMismatch` ではなく **codingPath が空の `dataCorrupted`**（「Number 1.5 is not representable in Swift.」）を投げる。PLAN §6.1「型違い → CV-39、キーのパスを添える」を満たすため、`dataCorrupted` で codingPath が空のときだけ `unrepresentableNumberPath(in: 2 段目の辞書)` でパスを補う: `ConfigKeys.allKeyPaths` の順に葉（配列なら各要素、パスは末尾に添字）を見て、bool でない浮動小数の `NSNumber` で `Int(exactly:)` が nil のものについて、既定値の JSON の同じ位置に `1.5`（配列なら `[1.5]`）を置いて `AppConfig` に復号できなければ（= 整数の位置）そのパス。見つからなければ `"<file>"`（型の情報を 2 か所に書かないため、既定値を型の見本にする）
5. **意味の検証**: `ConfigValidator.validate(config, catalog:, reaperConfObservation:)`。空なら `.valid(config)`、そうでなければ `.invalid(violations)`

`encode`: `JSONEncoder` の `outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]` で符号化し、`"\n"` を足す。符号化は失敗しない型なので、失敗したら（到達しない）空の `Data()` を返す（`try!` を使わない。PT-19）。

### 6. `Config/ConfigValidator.swift`

```swift
public enum ConfigValidator {
    /// PLAN §6.4 の CV-08〜59 を表の順に全部評価する（CV-14 だけ CV-13 より先）。1 つ目で止めない。
    public static func validate(_ c: AppConfig, catalog: ModelCatalog, reaperConfObservation: ReaperConfObservation) -> [ConfigViolation]
}
```

評価の順と、違反のときの `(keyPath, message)`（code は表の「コード」。`<v>` は値、数は Swift の `description`、文字列はそのまま）。1 つの CV の中で複数のキーを見るものは、**この表の行の順に**、違反するキーごとに 1 件ずつ出す:

| 順 | CV | 条件（偽なら違反） | keyPath | message |
|---|---|---|---|---|
| 1 | CV-08 | `session.blockGapSeconds >= 0` | `session.blockGapSeconds` | `0 以上であること（<v>）` |
| 2 | CV-09 | `retry.backoffSeconds.count >= retry.maxAttempts` | `retry.backoffSeconds` | `maxAttempts と同数以上の要素が必要（<count> < <maxAttempts>）` |
| 3 | CV-10 | `llm.maxCharsPerRequest > llm.chunkOverlapChars * 2` | `llm.maxCharsPerRequest` | `chunkOverlapChars の 2 倍より大きいこと（<max> <= <overlap×2>）` |
| 4 | CV-11 | raw の folderTemplate が `/` で始まらない | `obsidian.raw.folderTemplate` | `相対パスであること（<t>）` |
| | | かつ（前が真のときだけ）`/` で分けた要素（空要素は除く）に `..` が無い | 同上 | `'..' を含んではならない（<t>）` |
| | | wiki の folderTemplate も同じ 2 つ | `obsidian.wiki.folderTemplate` | 同上 |
| 5 | CV-12 | `raw.folderTemplate != wiki.folderTemplate` | `obsidian.wiki.folderTemplate` | `raw.folderTemplate と同一にできない（<t>）` |
| 6 | CV-14 | `wiki.filenameTemplate` に `{title}` を含まない | `obsidian.wiki.filenameTemplate` | `{title} を含んではならない（再生成のたびにファイルが増殖する）` |
| 7 | CV-13 | 各テンプレートのプレースホルダ（下記）がすべて `yyyymmdd` / `date` / `time`。raw.folderTemplate → raw.filenameTemplate → wiki.folderTemplate → wiki.filenameTemplate の順。**CV-14 で違反した wiki.filenameTemplate は見ない** | `obsidian.raw.folderTemplate` など | `未知のプレースホルダ {<name>}（使えるのは {yyyymmdd} {date} {time}）`（テンプレートごとに最初の 1 つだけ） |
| 8 | CV-16 | `1 <= obsidian.maxTitleBytes <= 255` | `obsidian.maxTitleBytes` | `1〜255 であること（<v>）` |
| 9 | CV-17 | `order` の各要素が `SectionName.all` に在る | `llm.analysis.order` | `sections に無い項目 [<名前>, …]`（出現順・重複除去。`, ` でつなぐ） |
| | | かつ重複が無い | 同上 | `重複がある [<名前>, …]`（2 回目以降に現れた名前を出現順・重複除去） |
| 10 | CV-18 | `sections.summary.enabled == true` | `llm.analysis.sections.summary.enabled` | `true でなければならない（要約の中核）` |
| 11 | CV-19 | `order` の各要素のうち `SectionName.all` に在る名前 `n` について、`sections[n].heading` が nil でない | `llm.analysis.sections.<n>.heading` | `order に載っている項目は heading を持つこと` |
| | | かつ `#` で始まり、`\n` も `\r` も含まない | 同上 | `'#' で始まる 1 行であること` |
| 12 | CV-22 | `audio.stagingMaxBytes > audio.freeSpaceMarginBytes` | `audio.stagingMaxBytes` | `freeSpaceMarginBytes より大きいこと（<a> <= <b>）` |
| 13 | CV-29 | `audio.inboxRetain` が `normalized` か `raw_saved` | `audio.inboxRetain` | `normalized か raw_saved であること（<v>）` |
| 14 | CV-30 | `reaperConfObservation` が `.valid(observed)` のときだけ評価: `cleanup.deleteSourceAudio == observed.deleteSourceAudio` | `cleanup.deleteSourceAudio` | `reaper.conf の DELETE_SOURCE_AUDIO（<true\|false>）と食い違っている。片方だけの解除は事故のため処理を止める`（code は configLockMismatch） |
| 15 | CV-32 | `TimeZone(identifier: timeZone) != nil` | `timeZone` | `解決できないタイムゾーン（<v>）` |
| 16 | CV-33 | `!(cleanup.deleteSourceAudio && device.mountMode == "ro")` | `cleanup.deleteSourceAudio` | `device.mountMode が ro のままでは削除は 1 件も行われない（ロック 2-B）`（code は configLockMismatch） |
| 17 | CV-40 | `vault.path == nil` か `vault.path` が `/` で始まる | `vault.path` | `絶対パスであること（<v>）` |
| 18 | CV-41 | `vault.marker` が空でなく、`/` を含まず、`.` でも `..` でもない | `vault.marker` | `空でなく、/ を含まず、. と .. 以外であること（<v>）` |
| 19 | CV-42 | `llm.modelID == nil` か、`catalog.entry(kind: .llm, id:) != nil` か、`CustomModelID.sha256(of:) != nil` | `llm.modelID` | `カタログに無い ID（<v>）` |
| 20 | CV-43 | `!cleanup.deleteSkippedSource \|\| cleanup.deleteSourceAudio` | `cleanup.deleteSkippedSource` | `deleteSourceAudio が false のときは true にできない` |
| 21 | CV-44 | `catalog.entry(kind: .whisper, id: transcription.whisperModelID) != nil` | `transcription.whisperModelID` | `カタログに無い Whisper モデル（<v>）` |
| 22 | CV-45 | `!vad.enabled \|\| catalog.entry(kind: .vad, id: vad.modelID) != nil` | `transcription.vad.modelID` | `カタログに無い VAD モデル（<v>）` |
| 23 | CV-46 | `device.snapshotMaxAgeSeconds > device.scanIntervalSeconds` | `device.snapshotMaxAgeSeconds` | `scanIntervalSeconds より大きいこと（<a> <= <b>）` |
| 24 | CV-47 | `includeVolumes` の各要素 `i` が空文字でない、続いて `excludeVolumes` も | `device.includeVolumes.<i>` / `device.excludeVolumes.<i>` | `空文字にできない` |
| 25 | CV-48 | `device.mountMode` が `ro` か `rw` | `device.mountMode` | `ro か rw であること（<v>）` |
| 26 | CV-49 | `stabilityFastPathSeconds >= 1` → `stabilityIntervalSeconds >= 1` → `stabilityChecks >= 1` → `maxScanDepth >= 1` | `device.<名前>` | `1 以上であること（<v>）` |
| 27 | CV-50 | `device.scanIntervalSeconds >= 60` | `device.scanIntervalSeconds` | `60 以上であること（<v>）` |
| 28 | CV-51 | `llm.contextSize >= llm.maxCharsPerRequest + llm.maxOutputTokens + 2048` | `llm.contextSize` | `maxCharsPerRequest + maxOutputTokens + 2048（<sum>）以上であること（<v>）` |
| 29 | CV-52 | `cleanup.deleteEvaluationBackoffSeconds` が空でない | `cleanup.deleteEvaluationBackoffSeconds` | `空にできない` |
| | | その各要素 `i` が `>= 0` | `cleanup.deleteEvaluationBackoffSeconds.<i>` | `0 以上であること（<v>）` |
| | | `cleanup.deleteResultTimeoutSeconds >= 60` | `cleanup.deleteResultTimeoutSeconds` | `60 以上であること（<v>）` |
| 30 | CV-53 | `retry.maxAttempts >= 1` | `retry.maxAttempts` | `1 以上であること（<v>）` |
| | | `retry.backoffSeconds` の各要素 `i` が `>= 0` | `retry.backoffSeconds.<i>` | `0 以上であること（<v>）` |
| 31 | CV-54 | `logging.level` が `DEBUG` / `INFO` / `WARNING` / `ERROR` のどれか（大小区別） | `logging.level` | `DEBUG / INFO / WARNING / ERROR のどれかであること（<v>）` |
| 32 | CV-55 | `threads >= 0` | `transcription.threads` | `0 以上であること（<v>）` |
| | | `timeoutFactor > 0` | `transcription.timeoutFactor` | `0 より大きいこと（<v>）` |
| | | `minTimeoutSeconds >= 1` | `transcription.minTimeoutSeconds` | `1 以上であること（<v>）` |
| | | `maxTimeoutSeconds >= minTimeoutSeconds` | `transcription.maxTimeoutSeconds` | `minTimeoutSeconds 以上であること（<max> < <min>）` |
| | | `minChars >= 1` | `transcription.minChars` | `1 以上であること（<v>）` |
| | | `0 < vad.threshold < 1` | `transcription.vad.threshold` | `0 より大きく 1 より小さいこと（<v>）` |
| | | `vad.minSpeechDurationMs >= 0` → `vad.minSilenceDurationMs >= 0` → `vad.speechPadMs >= 0` | `transcription.vad.<名前>` | `0 以上であること（<v>）` |
| | | `language` が空でない | `transcription.language` | `空にできない` |
| 33 | CV-56 | `0 <= temperature <= 2` | `llm.temperature` | `0〜2 であること（<v>）` |
| | | `0 < topP <= 1` | `llm.topP` | `0 より大きく 1 以下であること（<v>）` |
| | | `maxOutputTokens >= 1` → `requestTimeoutSeconds >= 1` → `maxSecondsPerRequest >= 1` | `llm.<名前>` | `1 以上であること（<v>）` |
| | | `chunkOverlapChars >= 0` → `repairAttempts >= 0` | `llm.<名前>` | `0 以上であること（<v>）` |
| | | `SectionName.all` の順のうち **`maxItems` を持つ 5 節**（`key_points` / `tasks` / `decisions` / `ideas` / `tags`。F-54）の `maxItems` が nil か `>= 1` | `llm.analysis.sections.<n>.maxItems` | `null か 1 以上であること（<v>）` |
| 34 | CV-57 | `idleCloseSeconds >= 1` → `maxParts >= 1` → `maxDurationSeconds >= 1` | `session.<名前>` | `1 以上であること（<v>）` |
| 35 | CV-58 | `timeoutFactor > 0` | `audio.timeoutFactor` | `0 より大きいこと（<v>）` |
| | | `minTimeoutSeconds >= 1` | `audio.minTimeoutSeconds` | `1 以上であること（<v>）` |
| | | `durationToleranceSeconds >= 0` | `audio.durationToleranceSeconds` | `0 以上であること（<v>）` |
| | | `freeSpaceMultiplier >= 1` | `audio.freeSpaceMultiplier` | `1 以上であること（<v>）` |
| | | `freeSpaceMarginBytes >= 0` | `audio.freeSpaceMarginBytes` | `0 以上であること（<v>）` |
| | | `hashChunkBytes >= 4096` | `audio.hashChunkBytes` | `4096 以上であること（<v>）` |
| 36 | CV-59 | `raw.timestampIntervalSeconds >= 0` | `obsidian.raw.timestampIntervalSeconds` | `0 以上であること（<v>）` |
| | | `wiki.vaultIndexCacheSeconds >= 0` → `wiki.maxLinks >= 0` | `obsidian.wiki.<名前>` | `0 以上であること（<v>）` |
| | | `defaultTags` の各要素 `i` が空でない | `obsidian.defaultTags.<i>` | `空文字にできない` |

- code は CV-30・CV-33 が `configLockMismatch`、それ以外はすべて `configInvalidValue`（CV-01 は読み込みの 3 段目だけが出す）
- **プレースホルダの走査**（CV-13。voicedock の正規表現 `\{([^}]*)\}` と同じ結果）: 位置 0 から `{` を探す → 見つからなければ終わり → その後ろで最初の `}` を探す → 見つからなければ終わり → 間の文字列が名前（`{` を含みうる）→ 名前が許可の 3 つに無ければそのテンプレートの違反を 1 件出して終わり → `}` の次から続ける。Swift の Regex は使わない（PT-20）
- `(<v>)` の Double は `description`（`0.5`・`2.0`）、Int は 10 進、Bool は `true` / `false`

### 7. `ModelCatalog.swift`

```swift
public enum ModelKind: String, Sendable, CaseIterable, Hashable { case whisper, vad, llm }

public struct ModelEntry: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let file: String
    public let url: String
    public let sha256: String
    public let bytes: Int64
    public let license: String
    public let minMemoryGB: Int?     // llm だけ（必須）。whisper / vad は nil
    public let verified: Bool?       // llm だけ（必須）。whisper / vad は nil
}

public struct CatalogRejection: Equatable, Sendable { public let kind: ModelKind; public let index: Int; public let reason: String }
public enum CatalogError: Error, Equatable, Sendable { case notJSONObject, badSchema, missingKind(String), unknownKey(String) }

public struct ModelCatalog: Equatable, Sendable {
    public let schema: Int
    public let whisper: [ModelEntry]
    public let vad: [ModelEntry]
    public let llm: [ModelEntry]
    /// 読み込みで捨てた項目（OPS-19。診断とログに出す）。
    public let rejected: [CatalogRejection]
    public static func load(_ data: Data) -> Result<ModelCatalog, CatalogError>
    public func entries(kind: ModelKind) -> [ModelEntry]
    public func entry(kind: ModelKind, id: String) -> ModelEntry?
    /// パネルの一覧に出す LLM（`verified == true` だけ。PLAN §8.10）。
    public var listedLLMs: [ModelEntry] { llm.filter { $0.verified == true } }
}

public enum CustomModelID {
    public static let prefix = "custom:"
    public static func make(sha256: String) -> String { prefix + sha256 }
    /// `custom:<64 桁の小文字 16 進>` なら 16 進の部分、そうでなければ nil。
    public static func sha256(of id: String) -> String?
    /// `custom-<sha256 の先頭 16>.gguf`
    public static func fileName(sha256: String) -> String
}
```

`load` の手順:
1. `JSONSerialization` で辞書にする（`ModelCatalog.json` は本アプリだけが読む同梱の資源で、PLAN §5.7 の内部 JSON（Python 互換で読む transcript・analysis など）に当たらない。config.json と同じ扱い。真偽値と数の区別は下の `wrong_type` の検査で行う）。失敗・辞書でない → `.notJSONObject`
2. トップのキーは `schema`・`whisper`・`vad`・`llm` だけ。ほかがあれば（昇順で最初のもの）`.unknownKey(<key>)`
3. `schema` が整数（bool でない・浮動小数でない）の 1 でなければ `.badSchema`
4. `whisper` → `vad` → `llm` の順に、配列でなければ `.missingKind(<kind>)`
5. 各要素を順に検査し、合格したものだけ残す。不合格は `CatalogRejection(kind, index（0 始まり）, reason)` に記録して捨てる。reason と判定（この順に、最初に当たったもの）:
   - `not_object`: 辞書でない
   - `unknown_key`: キーが許可の集合（共通 `id, displayName, file, url, sha256, bytes, license`、llm はさらに `minMemoryGB, verified`）以外を含む
   - `missing_key`: 許可の集合のキーが欠けている
   - `wrong_type`: 文字列の 6 つ（`id`・`displayName`・`file`・`url`・`sha256`・`license`）が文字列でない、`bytes`・`minMemoryGB` が整数（bool・浮動小数でない `NSNumber`）でない、`verified` が bool でない
   - `bad_id`: `id` が空、または `[a-z0-9]` で始まり `[a-z0-9._-]` だけでない
   - `bad_file_name`: `file` が `[A-Za-z0-9._-]` 以外を含む、空、`.` で始まる、`..` を含む（OPS-19）
   - `bad_url`: `url` が `https://huggingface.co/` で始まらない、`/resolve/` の直後が 40 桁の小文字 16 進 + `/` でない、`"/" + file` で終わらない
   - `bad_sha256`: 64 桁の小文字 16 進でない
   - `bad_bytes`: `bytes <= 0`
   - `bad_min_memory`: llm で `minMemoryGB < 1`
   - `duplicate_id`: 同じ kind で先に合格した項目と同じ `id`（後のものを捨てる）
6. `.success(ModelCatalog(…))`

`CustomModelID.sha256(of:)`: `id.hasPrefix("custom:")` かつ残りが 64 文字で各文字が `0-9a-f` なら残り、そうでなければ nil。`fileName(sha256:)`: `"custom-" + String(sha256.prefix(16)) + ".gguf"`。

### 7.1 `ModelFiles.swift`（00-api-map §2.2。モデルの置き場所と在否。T-17・T-18・T-22・T-32 が使う）

```swift
// モデルファイルの置き場所と在否（PLAN §8.10。VDPipeline のガードと診断が使う。VDModels に依存しない）。
import Darwin
import Foundation
import VDContract

public enum ModelFiles {
    /// models/<kind>/<entry.file>
    public static func url(kind: ModelKind, entry: ModelEntry, layout: HomeLayout) -> URL
    /// custom:<sha256> なら models/llm/custom-<sha256 の先頭 16>.gguf。形が違えば nil。
    public static func customLLMURL(id: String, layout: HomeLayout) -> URL?
    /// stat（symlink を辿る）が成功し S_ISREG で st_size == entry.bytes。
    public static func isPresent(_ e: ModelEntry, kind: ModelKind, layout: HomeLayout) -> Bool
}
```

- `url` = `layout.modelFile(kind: kind.rawValue, file: entry.file)`
- `customLLMURL` = `CustomModelID.sha256(of: id).map { layout.modelFile(kind: ModelKind.llm.rawValue, file: CustomModelID.fileName(sha256: $0)) }`
- `isPresent` は**サイズまで見る**（途中で止まったダウンロードを「在る」と言わない）。SHA-256 の照合はしない（ダウンロード時と診断 DR-05 / DR-08 だけ。§8.10）
- テストは `Tests/VDCoreTests/ModelFilesTests.swift`: 3 つの関数、サイズ違い・0 バイト・symlink・カスタム ID の形違い（nil）

### 8. `Resources/ModelCatalog.json`

PLAN §8.10 の JSON を**値を変えずに**書く（キーの並びも §8.10 のとおり。インデントは 2 空白、末尾改行 1 つ）。このチケットでは値を確かめ直さない（T-24 の仕事）。

### 9. ConfigEffect の網羅（`Tests/PolicyTests/`）

PLAN §6.2「全キーに振る舞いのテストを 1 本以上」（CR-14）を機械で確かめる仕組み。**各キーの振る舞いテストはそのキーを使うチケットが書く**。

- **振る舞いテストの印**: 表示名を `CE <keyPath> ` で始める（例 `@Test("CE device.stabilityChecks 回数を 3 にすると再取得が 3 回になる")`）。`<keyPath>` は `ConfigKeys.allKeyPaths` の 1 つ
- `ConfigEffectPending.swift`: まだ振る舞いテストの無いキーと、書く予定のチケット。**テストを書いたチケットはここから自分のキーを消す**

```swift
/// まだ ConfigEffect のテストが無いキー → 書く予定のチケット。空になったら網羅完了（T-43 の受け入れ条件）。
enum ConfigEffectPending {
    static let owners: [String: String] = [ … 下の表 … ]
}
```

初期値（`schemaVersion` はこのチケット、`logging.level`・`logging.unsafeLogContent` は T-10 が書くので載せない）。
**チケットの列は「そのキーの `CE` のテストが実際に書いてあるチケット」**（各チケットの「テスト」の節に行がある。自分の PR でここから消す）:

| キー | チケット |
|---|---|
| `timeZone`、`session.*`（5 個）、`llm.modelID` | T-22 |
| `vault.path`、`vault.marker` | T-28 |
| `device.includeVolumes`、`device.excludeVolumes` | T-13 |
| `device.maxScanDepth`、`device.stabilityFastPathSeconds`、`device.stabilityIntervalSeconds`、`device.stabilityChecks`、`audio.hashChunkBytes` | T-14 |
| `device.mountMode`、`device.scanIntervalSeconds` | T-15 |
| `device.snapshotMaxAgeSeconds`、`cleanup.deleteSourceAudio`、`cleanup.deleteEvaluationBackoffSeconds`、`cleanup.deleteResultTimeoutSeconds` | T-38 |
| `audio.timeoutFactor`、`audio.minTimeoutSeconds`、`audio.durationToleranceSeconds`、`audio.freeSpaceMultiplier`、`audio.freeSpaceMarginBytes`、`audio.stagingMaxBytes` | T-16 |
| `audio.inboxRetain`、`cleanup.deleteNormalizedAfterTranscribe`、`retry.maxAttempts`、`retry.backoffSeconds` | T-18 |
| `transcription.*`（`vad.*` を含む 13 個） | T-17 |
| `llm.contextSize`、`llm.temperature`、`llm.topP`、`llm.maxOutputTokens`、`llm.requestTimeoutSeconds` | T-21 |
| `llm.maxCharsPerRequest`、`llm.maxSecondsPerRequest`、`llm.chunkOverlapChars` | T-20 |
| `llm.repairAttempts`、`llm.analysis.customInstructions`、`llm.analysis.sections.<summary\|key_points\|tasks\|decisions\|ideas\|tags>.enabled`（6 個）、`llm.analysis.sections.<key_points\|tasks\|decisions\|ideas\|tags>.maxItems`（5 個） | T-19 |
| `llm.analysis.sections.*.heading`（7 個）、`llm.analysis.sections.timeline.enabled`、`llm.analysis.order`、`obsidian.defaultTags`、`obsidian.wiki.*`（`vaultIndexCacheSeconds` を除く 7 個） | T-27 |
| `obsidian.wiki.vaultIndexCacheSeconds` | T-29 |
| `obsidian.maxTitleBytes`、`obsidian.raw.filenameTemplate`、`obsidian.raw.timestampIntervalSeconds`、`obsidian.raw.partBoundaryHeading` | T-26 |
| `obsidian.raw.folderTemplate` | T-33 |
| `cleanup.deleteSkippedSource` | T-39 |

（表の `*` はコードでは 1 つずつ書く。`owners` は 90 個 = 93 − 3。件数はテストで直書きせず 4 条件で確かめる）

**割り当ての根拠のうち、素直でないもの**:
- `llm.analysis.sections.timeline.enabled` は LLM のスキーマに出ない節（§4.1 手順 5 の `NOT_A_SECTION`）なので、効くのは Daily ノートの描画だけ。T-19 ではなく **T-27** が書く
- `obsidian.raw.folderTemplate` は T-33（乗り換えの取り込み元）に、`obsidian.wiki.vaultIndexCacheSeconds` は T-29（索引の作り直し）に、すでに `CE` のテストがある。二重には書かない
- **`llm.analysis.sections.summary.maxItems` と `llm.analysis.sections.timeline.maxItems` は設定から無くなった**（F-54。どちらも読む場所が 1 か所も無い「効かない設定」だったため、PLAN §6.2 の JSON からキーごと消えた）。
  この 2 つは `ConfigKeys.allKeyPaths` にも `owners` にも載せない。JSON に書いたら CV-01（未知のキー）になる（§3・§5 手順 3）。
  よって `owners` は**すべてのキーに担当チケットが付いた状態**で始まり、各チケットが自分の行を消していけば**空にできる**（T-43 の「`owners` が空」の受け入れ条件は、もう決着待ちではない）

- `ConfigEffectCoverageTests.swift`（`@Suite("ConfigEffect coverage") struct ConfigEffectCoverageTests`）:
  1. `Tests/` 配下の全 `.swift` を T-04 の `SourceTree.load(root: PackageRoot.file("Tests"))` で読み、各ファイルの**文字列リテラルの一覧** `scanned.literals`（`SourceScanner.scan(_:)` の結果。`StringLiteral.raw` は区切りの間のソースそのもの）から、`raw` が `^CE ([A-Za-z0-9_.]+) ` に一致するもののキーパスを集める（= covered。コメントの中は拾わない）。本テストは PolicyTests（T-04 の `SourceTree` と同じターゲット）に置き、`ConfigKeys` は `import VDCore` で読む（PolicyTests は TestSupport 経由で VDCore をビルドしている。テストのターゲットは他のテストのターゲットを import できないので、VDCoreTests には置かない）
  2. `all = Set(ConfigKeys.allKeyPaths)`、`pending = Set(ConfigEffectPending.owners.keys)`
  3. 期待: `covered ⊆ all`（知らないキーの CE テストは誤り）、`pending ⊆ all`、`covered ∩ pending == ∅`（テストを書いたのに pending に残っている）、`covered ∪ pending == all`（誰も持っていないキー）
  4. 失敗時のメッセージにキーの一覧を昇順で出す

### 10. `Tests/TestSupport/GoldenConfig.swift`（golden の設定の上書き。00-api-map §15 の作り手）

golden のケース（T-25 の `GoldenCase`）の `timeZone` と `overrides` から `AppConfig` を作る。**全文は T-25 §4.12 のとおり**（`public enum GoldenConfig { public enum Failure; public static func make(_ item: GoldenCase) throws -> AppConfig; static func set(_:path:value:) }`。ここで書き換えない）。T-19・T-26・T-27 の golden のテストが使う。

- 手順（T-25 §4.12）: `AppConfig.defaults(timeZone: item.string("timeZone"))` → `ConfigLoader.encode` → `JSONSerialization` で辞書（config.json と同じ扱い。PLAN §5.7 の例外）→ `item.overrides()`（キーの昇順）を 1 つずつキーパスの位置に置く → `JSONDecoder` で `AppConfig` に戻す
- 途中のキーが無い・オブジェクトでない → `Failure.missingPath`、戻せない → `Failure.undecodable`、`overrides` の無いケースは `AppConfig.defaults(timeZone:)` と等しい

## テスト

`import Testing`、`@testable import VDCore`、`import VDContract`、`import TestSupport`。

### `Tests/TestSupport/TestCatalogs.swift`

```swift
public enum TestCatalogs {
    /// 既定の ID（large-v3-turbo-q5_0 / silero-v5.1.2）と LLM 1 つ（id "test-llm"）を持つ最小のカタログ。値は形式を満たす架空のもの。
    public static let minimal: ModelCatalog
}
```
`minimal` は JSON 文字列を `ModelCatalog.load` で読んで作る（失敗したら `fatalError("TestCatalogs.minimal")`。テスト支援なので PT-19 の対象外）。URL は `https://huggingface.co/x/y/resolve/<"0" × 40>/<file>`、sha256 は `"a" × 64`、bytes は 1。

### `Tests/VDCoreTests/AppConfigTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `defaultsMatchSection62` | `既定値は PLAN §6.2 の JSON と同じ` | テストに §6.2 の JSON を逐語で埋め込み（timeZone だけ `"Asia/Tokyo"`）、`ConfigLoader.load` の結果が `.valid(AppConfig.defaults(timeZone: "Asia/Tokyo"))` |
| `encodeWritesNullsExplicitly` | `符号化は null を省かない` | `encode(defaults)` の文字列に `"path" : null`、`"modelID" : null`、`"heading" : null` を含む（`maxItems` は既定値では null にならない。F-54 で summary / timeline からキーごと消えた） |
| `summaryAndTimelineHaveNoMaxItems` | `F-54 summary と timeline に maxItems のキーが無い` | `encode(defaults)` を `JSONSerialization` で読み、`llm.analysis.sections.summary` と `.timeline` のキーが `["enabled", "heading"]` だけ、残り 5 節は `["enabled", "heading", "maxItems"]`。`ConfigKeys.allKeyPaths` に `llm.analysis.sections.summary.maxItems` と `.timeline.maxItems` が無い |
| `encodeEndsWithNewlineAndSortsKeys` | `符号化はキーの昇順で末尾改行 1 つ` | 先頭が `{\n  "audio" : {`、末尾が `}\n`、`\n\n` で終わらない |
| `encodeDoesNotEscapeSlashes` | `符号化は / をエスケープしない` | `Daily/Voice/Raw/{yyyymmdd}` をそのまま含む |
| `roundTrip` | `書いて読むと同じ値` | `load(encode(defaults))` が `.valid(defaults)` |
| `sectionNamedLooksUpAllSeven` | `section(named:) は 7 つの節を引ける` | `SectionName.all` の各名前で nil でない、`"unknown"` で nil |
| `modeAccessorsFallBackToSafeSide` | `不正な mountMode / inboxRetain は安全側に倒す` | `mountMode = "x"` の `mode == .ro`、`inboxRetain = "x"` の `retain == .rawSaved` |
| `allKeyPathsMatchDefaultsEncoding` | `allKeyPaths は既定値の符号化の葉と一致する` | `encode(defaults)` を `JSONSerialization` で読み、オブジェクトは降り、配列・スカラー・null を葉とした「葉のパスの集合」== `Set(ConfigKeys.allKeyPaths)`、かつ `allKeyPaths` に重複が無い |
| `ceSchemaVersion` | `CE schemaVersion 2 にすると CV-39 で読めない` | schemaVersion だけ 2 にした JSON が `.invalid([CV-39, schemaVersion, "この版のアプリより新しい設定です（schemaVersion 2）。アプリを更新してください"])` |

### `Tests/VDCoreTests/ConfigLoaderTests.swift`

準備: `valid()` = `defaults(timeZone: "Asia/Tokyo")` を符号化した JSON を `[String: Any]` にしたもの。各テストはその辞書を 1 か所だけ変えて `JSONSerialization.data` に戻し、`load(data:catalog: TestCatalogs.minimal, reaperConfObservation: .missing)` を呼ぶ。

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `cv39NotJSON` | `CV-39 JSON でなければ読めない` | `Data("{".utf8)` → `[CV-39, "<file>", "JSON として読めません"]` |
| `cv39EmptyData` | `CV-39 空のデータは JSON として読めない` | `Data()` → `[CV-39, "<file>", "JSON として読めません"]`（TEST-28） |
| `cv39NotObject` | `CV-39 トップが配列なら読めない` | `Data("[]".utf8)` → `[CV-39, "<file>", "JSON のオブジェクトではありません"]` |
| `cv39SchemaVersionMissing` | `CV-39 schemaVersion が無い` | keyPath `schemaVersion`、「キーがありません」 |
| `cv39SchemaVersionNotInteger` | `CV-39 schemaVersion が 1.5 や true` | どちらも「整数であること」 |
| `cv39SchemaVersionZero` | `CV-39 schemaVersion 0` | 「不正な schemaVersion（0）」 |
| `cv01UnknownTopLevelKey` | `CV-01 トップの未知のキー` | `"extra": 1` を足す → `[CV-01, configUnknownKey, "extra", "未知のキーです"]` |
| `cv01UnknownNestedKey` | `CV-01 入れ子の未知のキー` | `llm.analysis.sections.summary2` を足す → keyPath `llm.analysis.sections.summary2` |
| `cv01UnknownKeysAreSorted` | `CV-01 複数の未知キーは昇順` | `device.zz` と `device.aa` → `aa` が先 |
| `cv01SummaryMaxItemsIsUnknown` | `CV-01 summary と timeline の maxItems は未知のキー（F-54）` | `llm.analysis.sections.summary.maxItems = 10` を足す → `[CV-01, configUnknownKey, "llm.analysis.sections.summary.maxItems", "未知のキーです"]`。`timeline.maxItems` も同じ。`key_points.maxItems = 10` は `.valid` |
| `cv39MissingKey` | `CV-39 欠けたキー` | `device.stabilityChecks` を消す → `[CV-39, "device.stabilityChecks", "キーがありません"]`。さらに `device.maxScanDepth` も消す → 2 件（`device.maxScanDepth`・`device.stabilityChecks` の順。1 件だけなら JSONDecoder の `keyNotFound` と同じ違反になり、3 段目の検査を消しても落ちないため） |
| `cv39MissingOptionalKeyStillMissing` | `CV-39 null を許すキーでも欠けたら違反` | `vault.path` を消す → keyPath `vault.path`、「キーがありません」 |
| `nullForOptionalIsValid` | `null を許すキーは null でよい` | 既定のまま（`vault.path` は null）→ `.valid` |
| `cv39ObjectExpected` | `CV-39 オブジェクトの位置に数値` | `"vault": 1` → `[CV-39, "vault", "オブジェクトであること"]` |
| `cv39TypeMismatch` | `CV-39 型違いはキーのパス付き` | `device.stabilityChecks = "2"` → keyPath `device.stabilityChecks`、「型が違います」 |
| `cv39TypeMismatchInArray` | `CV-39 配列の要素の型違い` | `cleanup.deleteEvaluationBackoffSeconds = [60, "x"]` → keyPath `cleanup.deleteEvaluationBackoffSeconds.1` |
| `cv39NullForNonOptional` | `CV-39 null にできないキー` | `device.mountMode = null` → 「null にできません」 |
| `cv39FloatForInt` | `CV-39 整数のキーに 1.5` | `session.maxParts = 1.5` → keyPath `session.maxParts` |
| `stopsBeforeValidationWhenKeysWrong` | `キーの段で違反があれば意味の検証をしない` | 未知キーと `session.blockGapSeconds = -1` を同時に入れる → 違反は CV-01 の 1 件だけ |
| `validationCollectsAll` | `意味の検証は 1 つ目で止めない` | `session.blockGapSeconds = -1` と `obsidian.maxTitleBytes = 0` → CV-08 と CV-16 の 2 件（この順） |
| `renderedFormat` | `違反の 1 行表記は空白 2 つ区切り` | `ConfigViolation(rule: "CV-08", code: .configInvalidValue, keyPath: "session.blockGapSeconds", message: "0 以上であること（-1）").rendered == "CV-08  CONFIG_INVALID_VALUE  session.blockGapSeconds: 0 以上であること（-1）"` |

### `Tests/VDCoreTests/ConfigValidatorTests.swift`

`ConfigValidator.validate(c, catalog: TestCatalogs.minimal, reaperConfObservation: .missing)` を直接呼ぶ（既定値を 1 か所だけ変える）。**各 CV に「違反の例（違反が 1 件で rule・keyPath・message が逐語で一致）」と「境界で通る例（違反 0 件）」の 2 本以上**。表示名は ID で始める:

| CV | 違反の例 → 期待 | 境界で通る例 |
|---|---|---|
| CV-08 | `blockGapSeconds = -1` → `0 以上であること（-1）` | `0` |
| CV-09 | `maxAttempts = 4`（backoff 3 個）→ `maxAttempts と同数以上の要素が必要（3 < 4）` | `maxAttempts = 3` |
| CV-10 | `chunkOverlapChars = 10000` → `chunkOverlapChars の 2 倍より大きいこと（20000 <= 20000）` | `9999` |
| CV-11 | raw folder `/abs/{yyyymmdd}` → `相対パスであること（/abs/{yyyymmdd}）`、wiki folder `a/../b` → `'..' を含んではならない（a/../b）` | `a/..b/c`（要素が `..b` なので通る） |
| CV-12 | wiki folder = raw folder → `raw.folderTemplate と同一にできない（Daily/Voice/Raw/{yyyymmdd}）` | 既定 |
| CV-14 | wiki filename `{title}` → 違反 1 件、**CV-13 は出ない** | 既定 |
| CV-13 | raw filename `{date} {part}` → `未知のプレースホルダ {part}（使えるのは {yyyymmdd} {date} {time}）`、`{a{b}` → 名前 `a{b`、`{date` （閉じない）→ 違反 0 件 | `{time}` |
| CV-16 | `0` と `256` → `1〜255 であること（…）` | `1`・`255` |
| CV-17 | order `["summary","x","x"]` → `sections に無い項目 [x]` と `重複がある [x]` の 2 件（この順） | order `[]` |
| CV-18 | summary.enabled false → 違反 | 既定 |
| CV-19 | timeline.heading nil → `order に載っている項目は heading を持つこと`、`"Timeline"` → `'#' で始まる 1 行であること`、`"# a\nb"` → 同 | order から timeline を外し heading nil → 通る |
| CV-22 | `stagingMaxBytes = 2147483648`（margin と同じ）→ `freeSpaceMarginBytes より大きいこと（2147483648 <= 2147483648）` | `+1` |
| CV-29 | `"none"` → `normalized か raw_saved であること（none）` | `raw_saved` |
| CV-30 | deleteSourceAudio true・mountMode rw・`reaperConfObservation` `.valid(DELETE_SOURCE_AUDIO=false)` → code configLockMismatch、`… （false）と食い違っている…`。逆向き（config false・観測 true）も違反 | `reaperConfObservation` `.missing` と `.invalid(…)` では評価しない（違反 0 件）、両方 true で通る |
| CV-32 | `"Mars/Base"` → `解決できないタイムゾーン（Mars/Base）` | `"UTC"` |
| CV-33 | deleteSourceAudio true・mountMode ro（`reaperConfObservation` `.missing`）→ configLockMismatch | mountMode rw |
| CV-40 | `"relative/vault"`・`""` → `絶対パスであること（…）` | nil・`"/Users/x/Vault"` |
| CV-41 | `""`・`"a/b"`・`"."`・`".."` → 違反 | `".obsidian"`・`"obsidian"` |
| CV-42 | `"nope"` → `カタログに無い ID（nope）`、`"custom:ABC…"`（大文字）→ 違反 | nil・`"test-llm"`・`"custom:" + "0"×64` |
| CV-43 | skipped true・source false → 違反 | 両方 true（mountMode rw） |
| CV-44 | `"tiny"` → `カタログに無い Whisper モデル（tiny）` | 既定 |
| CV-45 | vad.modelID `"x"` → 違反 | `vad.enabled = false` で `"x"` は通る |
| CV-46 | `snapshotMaxAgeSeconds = 300`（scanInterval 300）→ `scanIntervalSeconds より大きいこと（300 <= 300）` | `301` |
| CV-47 | include `["", "DJI*"]` → keyPath `device.includeVolumes.0` | `[" "]`（空白 1 つは空文字ではない） |
| CV-48 | `"RO"` → `ro か rw であること（RO）` | `rw` |
| CV-49 | 4 つを 1 つずつ `0` → keyPath がそれぞれの名前 | `1` |
| CV-50 | `59` → `60 以上であること（59）` | `60`（snapshotMaxAge 900 > 60 なので CV-46 も通る） |
| CV-51 | `contextSize = 26143` → `maxCharsPerRequest + maxOutputTokens + 2048（26144）以上であること（26143）` | `26144` |
| CV-52 | backoff `[]` → `空にできない`、`[60, -1]` → keyPath `….1`、timeout `59` → `60 以上であること（59）` | `[0]`・`60` |
| CV-53 | maxAttempts `0` → 違反（CV-09 は `3 >= 0` で通る）、backoff `[3,-1,30]` → keyPath `retry.backoffSeconds.1` | `maxAttempts 1` |
| CV-54 | `"info"` → 違反（大小区別） | `"DEBUG"` |
| CV-55 | threads `-1`、timeoutFactor `0`、minTimeout `0`、max < min（600 と 599）、minChars `0`、threshold `0` と `1`、3 つの ms `-1`、language `""` → keyPath と message が表どおり | threads `0`、threshold `0.5` |
| CV-56 | temperature `-0.1` と `2.1`、topP `0` と `1.1`、maxOutputTokens `0`、requestTimeout `0`、maxSecondsPerRequest `0`、overlap `-1`、repair `-1`、key_points.maxItems `0` → 表どおり | temperature `0` と `2`、topP `1`、maxItems nil |
| CV-57 | 3 つを 1 つずつ `0` | `1` |
| CV-58 | 6 つを境界の外へ（`0`・`0`・`-0.1`・`0.9`・`-1`・`4095`） | `4096`・`freeSpaceMultiplier 1.0` |
| CV-59 | timestampInterval `-1`、vaultIndexCache `-1`、maxLinks `-1`、defaultTags `["voice", ""]` → keyPath `obsidian.defaultTags.1` | timestampInterval `0`、maxLinks `0` |

追加:

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `defaultsHaveNoViolations` | `既定値は違反 0 件` | `validate(defaults, TestCatalogs.minimal, .missing).isEmpty` |
| `evaluationOrderFollowsTable` | `違反は表の順に並ぶ（CV-14 は CV-13 より先）` | CV-08・CV-14・CV-13（raw filename）・CV-59 を同時に起こし、rule の列が `["CV-08","CV-14","CV-13","CV-59"]` |
| `everyCVHasATest` | `CV の表の全 ID にテストがある` | このファイルの `@Test` の表示名の先頭の `CV-nn` の集合 ⊇ {08,09,10,11,12,13,14,16,17,18,19,22,29,30,32,33,40,…,59} と、ConfigLoaderTests の 01・39（SPEC 同期（T-05）が SPEC の表と突き合わせるので、ここでは集合を直書きせず T-05 の `SpecDocument` から CV の ID を読む） |

### `Tests/VDCoreTests/ModelCatalogTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `bundledCatalogLoads` | `同梱のカタログは捨てる項目なしで読める` | `PackageRoot.url/Resources/ModelCatalog.json` を読み、`rejected` が空、whisper 1・vad 1・llm 2 |
| `bundledCatalogHasDefaultIDs` | `既定の ID がカタログに在る` | `entry(kind: .whisper, id: "large-v3-turbo-q5_0")` と `entry(kind: .vad, id: "silero-v5.1.2")` が nil でない |
| `bundledURLsArePinned` | `URL はコミット SHA で固定されている（PT-13 と同じ条件）` | 全項目の url が `bad_url` の条件を満たさない（= 合格している）ことは `rejected` が空で示されるので、ここでは `/resolve/main/` を含まないことを直接見る |
| `listedLLMsExcludeUnverified` | `verified が false の LLM は一覧に出ない` | 同梱（2 つとも false）で `listedLLMs.isEmpty` |
| `emptyListsLoad` | `空のカタログは項目 0 件で読める` | 3 つの kind が `[]` → 項目も `rejected` も `listedLLMs` も空（TEST-28） |
| `rejectsEachRule` | `不合格の理由ごとに捨てる（OPS-19）` | 1 項目ずつ壊した JSON（12 通り: not_object・unknown_key・missing_key・wrong_type（bytes が文字列）・wrong_type（verified が 1）・bad_id（大文字）・bad_file_name（`../x`）・bad_file_name（`.x`）・bad_url（`resolve/main`）・bad_url（ホスト違い）・bad_sha256（63 桁）・bad_bytes（0））→ `rejected` の reason が一致し、その項目が無い |
| `duplicateIDKeepsFirst` | `同じ ID は先のものを残す` | reason `duplicate_id`、index 1 |
| `catalogErrors` | `カタログ全体の不正` | `[]` → `.notJSONObject`、schema 2 → `.badSchema`、`vad` 無し → `.missingKind("vad")`、`"x": 1` → `.unknownKey("x")` |
| `customModelID` | `custom:<sha256> の作り方と読み方` | `make("ab…")`、`sha256(of: "custom:" + "a"×64) == "a"×64`、`"custom:" + "A"×64` → nil、63 桁 → nil、`fileName(sha256: "0123456789abcdef" + …) == "custom-0123456789abcdef.gguf"` |

### `Tests/VDCoreTests/GoldenConfigTests.swift`（`@Suite("GoldenConfig") struct GoldenConfigTests`）

`@testable import TestSupport`（`GoldenConfig.set` は internal）と `import VDCore`。golden は T-25 の `Tests/Golden/inputs/` を読む。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `overridesLandOnKeyPaths` | `golden の上書きは設定の同じキーパスに入る` | `Golden.groupNames()` の全グループの全ケースのうち `overrides()` が空でないもの | 各ケースで `make` が投げない。`ConfigLoader.encode(結果)` を `JSONSerialization` で読んだ辞書を各キーパスで辿った値を `GoldenJSON(any:)` にしたものが上書きの値と等しい |
| `noOverridesEqualsDefaults` | `上書きの無いケースは既定値と同じ` | `sanitize` の最初のケース（`overrides` 無し） | `make(item) == AppConfig.defaults(timeZone: "Asia/Tokyo")` |
| `someCasesHaveOverrides` | `上書きのあるケースが在る（空で緑にしない）` | 同上の全ケース | `overrides()` が空でないケースが 1 件以上 |
| `missingPathThrows` | `途中のキーが無ければ missingPath` | `GoldenConfig.set` に `["obsidian", "nope", "x"]` のパス | `Failure.missingPath("nope.x")` |
| `emptyPathThrows` | `空のパスは missingPath（空文字）` | `GoldenConfig.set` に空のパス | `Failure.missingPath("")`（TEST-28） |

### `Tests/VDCoreTests/ModelFilesTests.swift`（`@Suite("ModelFiles") struct ModelFilesTests`）

`ModelEntry` は `@testable import VDCore` の memberwise init で作る（`file: "w.bin"`、`bytes: 4`）。ファイルは `TempDirectory` の中の `HomeLayout` に置く。

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `urlIsUnderKindDirectory` | `url は models/<kind>/<file>` | root `/tmp/vd-home` で `/tmp/vd-home/models/whisper/w.bin` |
| `customLLMURL` | `customLLMURL は custom-<先頭 16>.gguf、形が違えば nil` | `custom:0123456789abcdef…` → `models/llm/custom-0123456789abcdef.gguf`。大文字・短い・`custom:` で始まらない・空文字は nil |
| `isPresentChecksSize` | `サイズが bytes と一致する通常ファイルだけ在る` | 無い → false、4 バイト → true、別の kind → false、3 バイト → false |
| `zeroByteFileIsNotPresent` | `0 バイトのファイルは在ると言わない` | false |
| `symlinkIsFollowed` | `symlink は辿って判定し、ディレクトリは在ると言わない` | 4 バイトの実体への symlink → true、同名のディレクトリ → false |

### `Tests/PolicyTests/ConfigEffectCoverageTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `everyKeyIsCoveredOrPending` | `全キーに CE テストがあるか、予定のチケットが決まっている（CR-14）` | §9 の 3 の 4 条件 |
| `extractorFindsCELiterals` | `CE の印を拾える（検査自体の陽性対照）` | 文字列のソース `@Test("CE device.mountMode x") func a() {}` を `SourceScanner.scan(_:)` にかけて `device.mountMode` を拾い、`// @Test("CE vault.path x")`（コメント）からは拾わない |

## 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| `defaults` の `stabilityChecks` を 3 にする | `defaultsMatchSection62` |
| `VaultConfig.encode(to:)` を消して synthesized に戻す | `encodeWritesNullsExplicitly`、`allKeyPathsMatchDefaultsEncoding`、`roundTrip` |
| `checkKeys` の欠けたキーの検査を消す | `cv39MissingKey`、`cv39MissingOptionalKeyStillMissing` |
| `checkKeys` の再帰をやめる（トップだけ見る） | `cv01UnknownNestedKey` |
| CV-14 と CV-13 の評価の順を入れ替える | `evaluationOrderFollowsTable` |
| CV-14 に該当したテンプレートを CV-13 から外す処理を消す | CV-14 のテスト（「CV-13 は出ない」） |
| CV-30 で `.missing` のときも比較する（missing を false 扱い） | CV-30 の「評価しない」のテスト |
| CV-51 の `+ 2048` を消す | CV-51 の違反の例（境界で通る例 `26144` は条件を緩めても通るので落ちない） |
| `ModelCatalog.load` の `bad_url` の 40 桁検査を消す | `rejectsEachRule`（resolve/main） |
| `ConfigEffectPending.owners` から `device.mountMode` を消す | `everyKeyIsCoveredOrPending` |
| `GoldenConfig.set` の `path.count == 1` の分岐で `object[key] = value` を消す | `overridesLandOnKeyPaths` |
| `AnalysisSections` の `encode(to:)` / `init(from:)` を synthesized に戻す（summary と timeline にも `maxItems` を書く） | `summaryAndTimelineHaveNoMaxItems`、`allKeyPathsMatchDefaultsEncoding`、`roundTrip`（`defaultsMatchSection62` は落ちない。synthesized の復号は `maxItems` の無い JSON も nil として読むので、§6.2 の JSON は読めてしまう。壊れるのは符号化の側） |

## 受け入れ条件

- [ ] 上のファイルがあり、`make lint` と `make test` が通る
- [ ] 既定値を書いているのが `AppConfig.defaults(timeZone:)` だけ（ほかのファイルに `1_048_576` のような既定の数を書いていない）
- [ ] `ConfigValidator` の評価順が §6.4 の表の順（CV-14 だけ CV-13 の前）
- [ ] すべての CV に違反と境界のテストがあり、表示名が ID で始まる
- [ ] `Resources/ModelCatalog.json` が PLAN §8.10 と逐語で一致する（`diff` の結果を PR に貼る）
- [ ] ConfigEffect の網羅テストが緑（pending の表が §9 のとおり。90 キーすべてに担当チケットが付いている。「未定」のキーは無い）
- [ ] `GoldenConfig.make` が golden の全ケースの `overrides` で投げない（T-19・T-26・T-27 の golden のテストの前提）
- [ ] 破壊による証明の結果を PR 本文に貼った

## SPEC の変更

- `docs/SPEC.md` に PLAN §6.4 の CV の表を T-05 が写していなければ、このチケットで写す（表の形は PLAN と同じ。先頭の列が ID）
- `llm.analysis.sections.summary.maxItems` と `llm.analysis.sections.timeline.maxItems` は**決着済み**（PLAN v1.1 の F-54 でこの 2 つのキーを無くした。`maxItems` を持つのは 5 節だけ）。本チケットはそれに従うだけで、`docs/SPEC.md` への追加の変更は無い

## マージ後にやること

なし

## API 地図への変更提案

- `ModelCatalog` に `rejected: [CatalogRejection]`・`entries(kind:)`・`listedLLMs` を、`CatalogError` に `unknownKey(String)` を足す（00-api-map §2.2 には無い） → 00-api-map に反映済み（2026-09-18）。ただし地図は `rejected` をタプルの配列 `[(index: Int, kind: ModelKind, reason: String)]` と書いている。タプルは `Equatable` にならず `ModelCatalog: Equatable` の合成が壊れるので、本チケットは同じ 3 つのフィールドを持つ `CatalogRejection`（struct）のままにする（地図を `[CatalogRejection]` に直すことを提案する）
- （実装で追記）00-api-map §2.2 の `ConfigViolation` の行は `Equatable, Sendable` だけだが、同じ地図の `ConfigMigrator.migrate` が `Result<[String: Any], ConfigViolation>` を返すので `ConfigViolation` は `Error` でなければコンパイルできない。本チケットは `ConfigViolation: Error, Equatable, Sendable` にした（投げはしない）。地図の `ConfigViolation` の行に `Error` を足すことを提案する
- `DeviceConfig.MountMode` / `.mode`、`AudioConfig.InboxRetain` / `.retain` を足す（検証済みの値を型で使うため。不正値は安全側） → 00-api-map に反映済み（2026-09-18）
- PolicyTests の `SourceScanner` の公開 API（「文字列リテラルの一覧」を返す関数の名前）が 00-api-map に無い。T-04 のチケットで確定したら、この網羅テストはその名前を使う。本チケットでは `SourceScanner(source: String).stringLiterals: [(line: Int, text: String)]` を仮定した → T-04 の API（`SourceTree.load(root:)` の各 `SourceFile.scanned.literals`、`SourceScanner.scan(_:)`・`StringLiteral.raw`）に合わせて §9 を直した（整合修正。PolicyTests の中の型なので地図の対象外）
- （整合修正で追記）00-api-map §15 の `GoldenConfig.make`（作り手 T-09）を §10 に足した（全文は T-25 §4.12）
