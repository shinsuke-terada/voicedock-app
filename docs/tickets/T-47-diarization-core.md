# T-47 VDCore: 話者の型・設定キーと schemaVersion 2・ログ・AppPaths

| 項目 | 値 |
|---|---|
| ID | T-47 |
| Phase | 8.5（話者分離。F-89） |
| 前提 | T-09（設定）、T-10（`Transcript`・`SessionTranscript`・`AppPaths`・`Log`） |
| 見積もり | Sources 約 150 行、Tests 約 300 行 |

## 1. 目的

話者分離（PLAN §8.4.1）のために VDCore の型を広げる。区間に `speaker` を持たせ、正規化 transcript と指紋に「値があるときだけ」書く。
設定 `transcription.diarization.enabled` を足して `schemaVersion` を 2 にし、1 からの移行を入れる。
ログのイベント 2 つとキー `speakers`、`AppPaths` の 2 つのパス、ラベルの規則 `SpeakerLabel` を足す。**話者の無い入力の出力はバイト単位で変えない。**

## 2. 参照

- PLAN §8.4.1（transcript・指紋・ラベル）、§6.1（移行）、§6.2（既定値の JSON）、§6.4（CV-39）、付録 A.4（`diarization_completed` / `diarization_failed`）、付録 D X-45、付録 F F-89
- 00-api-map §2.2・§2.3（F-89 の行）

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDCore/Transcript.swift`（変更） | `TranscriptSegment.speaker`、codec |
| `Sources/VDCore/SessionTranscript.swift`（変更） | `AbsoluteSegment.speaker`、指紋 |
| `Sources/VDCore/SpeakerLabel.swift` | `SpeakerLabel` |
| `Sources/VDCore/Config/AppConfig.swift`（変更） | `DiarizationConfig`、`TranscriptionConfig.diarization`、既定値、`schemaVersion: 2` |
| `Sources/VDCore/Config/ConfigKeys.swift`（変更） | `transcription.diarization.enabled` |
| `Sources/VDCore/Config/ConfigMigrator.swift`（変更） | 1 → 2 |
| `Sources/VDCore/AppPaths.swift`（変更） | `argmaxCLI`・`speakerModels` |
| `Sources/VDCore/Log.swift`（変更） | `LogEvent.diarizationCompleted`・`.diarizationFailed`、`LogKey.speakers` |
| `docs/PLAN.md`（変更） | 付録 A.4 のイベントの列とフィールド（PLAN §8.4.1 の「ログのイベントと診断」の値をそのまま写す。SPEC 同期と `SpecMatchesPlanTests` のため、コード・SPEC と同じ PR で直す） |
| `docs/SPEC.md`（変更） | S4 のイベントの列とフィールド、S5 の CV-39 |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | `"transcription.diarization.enabled": "T-49"` |
| `Tests/VDCoreTests/SpeakerLabelTests.swift` | |
| `Tests/VDCoreTests/TranscriptSpeakerCodecTests.swift` | |
| `Tests/VDCoreTests/SessionTranscriptSpeakerTests.swift` | |
| `Tests/VDCoreTests/ConfigMigratorV2Tests.swift` | |

既存のテストで `schemaVersion` 1 を前提にしたもの（`AppConfigTests`・`ConfigLoaderTests`・golden の設定など）は 2 に直す。1 の JSON を読む既存のテストは「移行して読める」に意味が変わるので、期待を 2 に直す。

## 4. 仕様

### 4.1 `SpeakerLabel.swift`

```swift
// 話者のラベルと表示（PLAN §8.4.1。F-89）。ラベルの規則を 1 か所に置く（CR-06）。
import Foundation

public enum SpeakerLabel {
    /// 表示の前置き（`話者A`）。
    public static let prefix = "話者"

    /// 0→"A" … 25→"Z"、26 以上→"S<index+1>"（27 人目は "S27"）。負は "A"。
    public static func label(index: Int) -> String {
        if index < 26 { return String(UnicodeScalar(UInt8(65 + max(0, index)))) }
        return "S\(index + 1)"
    }

    /// `話者` + label
    public static func display(_ label: String) -> String { prefix + label }
}
```

### 4.2 `Transcript.swift`

- `TranscriptSegment` に `public let speaker: String?` を足す。init は `init(start: Double, end: Double, text: String, speaker: String? = nil)`
- `encode`: 区間のオブジェクトは `start, end, text` の後に、`speaker` が非 nil のときだけ `("speaker", .string(s))` を足す。nil なら今と同じ 3 つ（バイト単位で同じ）
- `decode`: 区間に `speaker` キーが在れば `String` であること（そうでなければ全体を nil）。無ければ nil。`requiredKeys` は変えない

### 4.3 `SessionTranscript.swift`

- `AbsoluteSegment` に `public let speaker: String?`、init は `init(at: Instant, endAt: Instant, text: String, speaker: String? = nil)`
- `TranscriptFingerprint.payload`: 区間のオブジェクトに、`speaker` が非 nil のときだけ `("speaker", .string(s))` を足す（sortKeys で並ぶ）。nil の区間は今と同じ

### 4.4 設定

```swift
/// 話者分離（PLAN §8.4.1。F-89）。
public struct DiarizationConfig: Codable, Equatable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}
```

- `TranscriptionConfig` の最後のプロパティに `public var diarization: DiarizationConfig`、init の最後の引数 `diarization: DiarizationConfig`
- `defaults(timeZone:)`: `schemaVersion: 2`、`transcription` に `diarization: DiarizationConfig(enabled: false)`
- `ConfigKeys.allKeyPaths`: `"transcription.vad.speechPadMs"` の直後に `"transcription.diarization.enabled"`
- CV は足さない（Bool なので型の検査（CV-39）だけ）

### 4.5 `ConfigMigrator.swift`

```swift
public static let currentVersion = 2
```

`migrate` の手順（版の読み方・「新しい」「不正」の文言は今のまま）:
1. `version == 2` → そのまま成功
2. `version == 1` → `var object = object`。`object["transcription"]` が `[String: Any]` で `"diarization"` を持たなければ `["enabled": false]` を入れる（持っていれば触らない。辞書でなければ触らない）。`object["schemaVersion"] = 2`。成功
3. `version > 2` → 今の「この版のアプリより新しい設定です…」
4. それ以外 → 今の「不正な schemaVersion（<n>）」

ファイルは書き換えない（PLAN §6.1）。

### 4.6 `AppPaths.swift`

```swift
    /// helpers/argmax-cli（話者分離。PLAN §8.4.1。F-89）
    public var argmaxCLI: URL { helpers.appendingPathComponent("argmax-cli", isDirectory: false) }
    /// resources/SpeakerModels（話者分離のモデル。同梱。PLAN §11.2）
    public var speakerModels: URL { resources.appendingPathComponent("SpeakerModels", isDirectory: true) }
```

### 4.7 `Log.swift`

- `LogEvent`: `transcriptionFailed` の直後に `case diarizationCompleted = "diarization_completed"`、`case diarizationFailed = "diarization_failed"`（付録 A.4 の順）
- `LogKey`: `speechRatio` の直後に `case speakers`（本文ではないので redact の対象にしない）

## 5. テスト

`Tests/VDCoreTests/SpeakerLabelTests.swift`:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `firstLabels` | 0〜25 は A〜Z | index 0, 1, 25 | `"A"`・`"B"`・`"Z"` |
| `beyondZ` | 27 人目からは S27 | index 26, 27 | `"S27"`・`"S28"` |
| `negativeIsA` | 負の index は A | -1 | `"A"` |
| `display` | 表示は 話者 + ラベル | `"A"`・`""` | `"話者A"`・`"話者"` |

`Tests/VDCoreTests/TranscriptSpeakerCodecTests.swift`:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `withoutSpeakerIsByteIdentical` | 話者なしの transcript は F-89 の前とバイト単位で同じ | 区間 2 つ（speaker nil） | 期待のバイト列（`start`・`end`・`text` の 3 キーだけ。indent 2・末尾改行）と一致 |
| `speakerIsWrittenAfterText` | speaker は text の後に書く | 区間 1 つ（speaker `"A"`） | 区間の中が `"start": …, "end": …, "text": "…", "speaker": "A"` の順 |
| `mixedSpeakers` | 話者のある区間とない区間が混ざる | `"A"` と nil | 1 つ目だけ `speaker` キー |
| `roundTrip` | 書いて読むと同じ | 話者つき | decode(encode(t)) == t |
| `nonStringSpeakerIsUnreadable` | speaker が文字列でなければ読めない | `"speaker": 1` / `null` | nil |
| `emptySegments` | 区間 0 の transcript（TEST-28） | segments `[]` | 今と同じバイト列で、読み戻せる |

`Tests/VDCoreTests/SessionTranscriptSpeakerTests.swift`:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `fingerprintWithoutSpeakerUnchanged` | 話者なしの指紋は F-89 の前と同じ | 既存の golden の Session（`GoldenCoreTests` と同じ入力） | 既存の期待の payload と同じ文字列 |
| `fingerprintIncludesSpeaker` | 話者があると payload に speaker が入る | 区間 1 つ speaker `"B"` | payload に `"speaker":"B"` を含み、speaker nil のときと指紋が違う |
| `fingerprintEmpty` | 区間 0 の指紋（TEST-28） | segments `[]` | 既存の空の payload と同じ |

`Tests/VDCoreTests/ConfigMigratorV2Tests.swift`:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `v1GetsDiarizationOff` | 1 の設定は diarization.enabled=false を足して 2 にする | 既定値を 1 に書き換え diarization を消した辞書 | 成功。`schemaVersion == 2`、`transcription.diarization.enabled == false` |
| `v1KeepsExistingDiarization` | 1 でも diarization が在れば触らない | 1 で `enabled: true` を持つ | `enabled == true` のまま |
| `v1NonDictTranscriptionIsLeftToCV39` | transcription が辞書でなければ版だけ上げる | `"transcription": 3` | 成功し `schemaVersion == 2`、`ConfigLoader.decodeStructure` は CV-39 |
| `v2PassesThrough` | 2 はそのまま | 既定値 | 入力と同じ |
| `v3IsTooNew` | 3 は新しすぎる | `schemaVersion: 3` | CV-39「この版のアプリより新しい設定です（schemaVersion 3）。アプリを更新してください」 |
| `v1FileLoadsThroughLoader` | 1 の config.json（F-89 の前の既定値）が ConfigLoader で読める | 既定値の JSON を 1 にし diarization を消した Data | `ConfigLoader.load` が `.valid`、`transcription.diarization.enabled == false` |
| `emptyObjectIsRejected` | 空の辞書（TEST-28） | `[:]` | CV-39「キーがありません」 |

`AppPathsTests`（既存に追加）: `argmaxCLI` が `helpers/argmax-cli`、`speakerModels` が `resources/SpeakerModels`。
`SpecSyncLogEventsTests`（既存）: SPEC の S4 を直すので、そのまま通ること。

## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| encode で speaker nil のときも `"speaker": null` を書く | `withoutSpeakerIsByteIdentical` |
| 指紋の payload に speaker nil のとき `"speaker": null` を足す | `fingerprintWithoutSpeakerUnchanged` |
| 移行で `diarization` を足さない | `v1GetsDiarizationOff`・`v1FileLoadsThroughLoader` |
| 移行で既存の `diarization` を上書きする | `v1KeepsExistingDiarization` |
| `SpeakerLabel.label` の 26 を `"AA"` にする | `beyondZ` |
| `LogEvent` の 2 つの順を入れ替える | `SpecSyncLogEventsTests` |

## 7. 受け入れ条件

- [ ] 話者の無い transcript・指紋・設定以外の golden が 1 バイトも変わらない（既存の golden のテストが通る）
- [ ] F-89 の前の `config.json`（schemaVersion 1）が読め、アプリは設定エラーにならない
- [ ] `ConfigEffectPending` に `transcription.diarization.enabled` が T-49 で載り、`ConfigEffectCoverageTests` が通る
- [ ] `make lint && make test` が通る

## 8. SPEC の変更

- PLAN 付録 A.4 にも同じ行を足す（`tmp/witty-gliding-clover.md` は `cp docs/PLAN.md` で写し直す）
- S4（ログイベント）: イベントの列の `transcription_completed transcription_failed` の行の後に `diarization_completed diarization_failed` の行。フィールドの一覧に付録 A.4 の `diarization_completed` / `diarization_failed` の行（PLAN と逐語）
- S5（CV）: CV-39 の条件を PLAN §6.4 と逐語に（「`schemaVersion` が 2 であること（1 は §6.1 の移行で 2 にする）を含む」）

## 9. マージ後にやること

なし
