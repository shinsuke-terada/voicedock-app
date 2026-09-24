# T-48 VDTranscribe: argmax-cli の起動・RTTM の読み取り・話者の割り当て

| 項目 | 値 |
|---|---|
| ID | T-48 |
| Phase | 8.5（話者分離。F-89） |
| 前提 | T-46（`Tests/Fixtures/argmax-cli-diarize-help.txt`）、T-47（`TranscriptSegment.speaker`・`SpeakerLabel`・`AppPaths.argmaxCLI` / `speakerModels`）、T-17（`Transcriber`） |
| 見積もり | Sources 約 300 行、Tests 約 600 行（TestSupport の FakeArgmax を含む） |

## 1. 目的

`argmax-cli diarize` を子プロセスで起動し、出力の RTTM を読み、whisper の区間に話者を付ける（PLAN §8.4.1）。
`Transcriber` は `Diarizer` を渡されたときだけ、正規化 transcript を書く前に話者分離を行う。**話者分離の失敗で文字起こしを失敗させない。**
状態遷移・DB・ログはしない（呼び手 = T-49）。

## 2. 参照

- PLAN §8.4.1（全体）、§8.4（`Transcriber` の手順・F-82 の「止めた」の判定）、§8.2（`ProcessRunner`）
- 00-api-map §7（F-89 の行）・§15（`FakeArgmax`）
- docs/POC.md 16 章（RTTM の形・所要）

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDTranscribe/DiarizeArgs.swift` | `DiarizeArgs` |
| `Sources/VDTranscribe/RTTMParser.swift` | `SpeakerTurn` / `RTTMParser` |
| `Sources/VDTranscribe/SpeakerAssigner.swift` | `SpeakerAssigner` |
| `Sources/VDTranscribe/Diarizer.swift` | `Diarizer` / `DiarizeOutcome` / `DiarizationReport` |
| `Sources/VDTranscribe/Transcriber.swift`（変更） | `diarizer` 引数、`TranscribeMetrics.diarization` |
| `Tests/TestSupport/FakeArgmax.swift` | 偽 argmax-cli（シェルスクリプトを書く） |
| `Tests/VDTranscribeTests/DiarizeArgsTests.swift` | |
| `Tests/VDTranscribeTests/RTTMParserTests.swift` | |
| `Tests/VDTranscribeTests/SpeakerAssignerTests.swift` | |
| `Tests/VDTranscribeTests/DiarizerTests.swift` | |
| `Tests/VDTranscribeTests/TranscriberDiarizationTests.swift` | |
| `Tests/VDTranscribeTests/FakeArgmaxTests.swift` | 偽物自体のテスト（TEST-05） |

## 4. 仕様

パスの文字列化は `url.path(percentEncoded: false)`（`WhisperArgs.p`）。

### 4.1 `DiarizeArgs.swift`

```swift
// argmax-cli の argv（PLAN §8.4.1。F-89）。
import Foundation

public enum DiarizeArgs {
    /// `argmax-cli diarize --help` に在るべきフラグ（DR-18）。
    public static let requiredFlags = ["--audio-path", "--model-path", "--rttm-path", "--use-exclusive-reconciliation"]

    /// argv[0] を含まない引数の配列。先頭は "diarize"。
    public static func build(input: URL, models: URL, rttm: URL) -> [String] {
        [
            "diarize", "--audio-path", WhisperArgs.p(input), "--model-path", WhisperArgs.p(models),
            "--rttm-path", WhisperArgs.p(rttm), "--use-exclusive-reconciliation",
        ]
    }

    /// requiredFlags のうち help に語として無いもの（宣言順）。
    public static func missingFlags(helpOutput: String) -> [String]
}
```

`missingFlags` の「語として在る」: `WhisperHelpCheck.missingVADFlags` と同じ判定（フラグの直前が行頭・空白・`,`・`[`、直後が行末・空白・`,`・`=`・`]`・`<`）。同じ判定を 2 か所に書かないよう、`WhisperHelpCheck` の判定を `static func containsFlag(_ flag: String, in help: String) -> Bool`（internal）に切り出して両方から使う（`[` `]` `<` を足しても whisper の fixture の結果は変わらない）。

### 4.2 `RTTMParser.swift`

```swift
// argmax-cli の RTTM（PLAN §8.4.1）。
import Foundation

public struct SpeakerTurn: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String

    public init(start: Double, end: Double, speaker: String) { … }
}

public enum RTTMParser {
    /// 1 行でも不正なら nil。0 行は []。
    public static func parse(_ text: String) -> [SpeakerTurn]?
}
```

手順: `text` を `\n` で分け、各行の末尾の `\r` を落として `PyText.strip`。空なら飛ばす。空白（`" "` と `\t`、連続は 1 つ）で分けた列が 8 未満・1 列目が `SPEAKER` でない → nil。
4 列目 `start = Double(col[3])`、5 列目 `duration = Double(col[4])` が nil・有限でない・`start < 0`・`duration < 0` → nil。8 列目 `col[7]` が空 → nil（空白で分けるので空にはならないが検査は残す）。`SpeakerTurn(start: start, end: start + duration, speaker: col[7])`。行の順を保つ。

### 4.3 `SpeakerAssigner.swift`

```swift
// whisper の区間に話者を付ける（PLAN §8.4.1）。
import Foundation
import VDCore

public enum SpeakerAssigner {
    /// 重なりが無いとき、この秒数以内の最も近い区間の話者を付ける。
    public static let nearestToleranceSeconds = 1.0

    /// 各区間に話者を付け、区間の順に初めて出た順で SpeakerLabel.label に付け替える。区間の数と順・start・end・text は変えない。
    public static func assign(_ segments: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment]
}
```

1. RTTM の話者の順位 = `turns` の中で初めて出た位置（同点の決め手）
2. 各区間 `s` について:
   - 話者ごとの重なり `Σ max(0, min(s.end, t.end) − max(s.start, t.start))`（その話者の全行の和）。最大が 0 より大きければ最大の話者（同点は順位の小さい話者）
   - 0 なら、各行の隔たり `max(t.start − s.end, s.start − t.end, 0)` が `nearestToleranceSeconds` 以下の行のうち最小の行の話者（同点は先の行）
   - どれも無ければ nil
3. 付けた RTTM の話者名を、区間の順に初めて出た順で `SpeakerLabel.label(index: 0, 1, …)` に置き換える（RTTM の `A`・`B` の名前はそのまま使わない。区間に付かなかった話者はラベルを消費しない）
4. `turns` が空なら全区間 nil。`segments` が空なら `[]`

### 4.4 `Diarizer.swift`

```swift
// argmax-cli で話者の区間を得る（PLAN §8.4.1。F-89）。状態遷移・DB・ログはしない。
import Foundation
import VDContract
import VDCore
import VDProcess

public enum DiarizeOutcome: Equatable, Sendable {
    case diarized([SpeakerTurn])
    /// reason は付録 A.4 の語（helper_missing・spawn_failed・timeout・exit_<n>・signal_<n>・rttm_unreadable）
    case failed(reason: String)
    /// アプリの終了で止めた・閉じた後の拒否（Transcriber.wasStopped と同じ判定）
    case stopped
}

public enum DiarizationReport: Equatable, Sendable {
    case completed(speakers: Int, elapsedSeconds: Double)
    case failed(reason: String)
}

public struct Diarizer: Sendable {
    public static let timeoutFactor = 0.5
    public static let minTimeoutSeconds = 120
    public static let rttmFileName = "diarization.rttm"

    public init(runner: any ProcessRunning, paths: AppPaths, layout: HomeLayout, maxTimeoutSeconds: Int)

    /// 欠けている部品（宣言順）: "argmax-cli"（通常ファイルで実行権が無い）、"SpeakerModels"（ディレクトリでない）。
    public func missingParts() -> [String]

    public func diarize(input: URL, slug: String, durationSeconds: Double?) async -> DiarizeOutcome

    /// Int(min(max(duration × 0.5, 120), maxTimeoutSeconds))。duration 不明なら maxTimeoutSeconds。
    static func timeoutSeconds(duration: Double?, maxTimeoutSeconds: Int) -> Int
}
```

`diarize` の手順:
1. `missingParts()` が空でなければ `.failed(reason: "helper_missing")`（起動しない）
2. `rttm = layout.stagingDirectory(slug: slug).appendingPathComponent(rttmFileName, isDirectory: false)`。`SafeUnlink.remove(rttm, under: .staging, layout: layout, missingOK: true)` が投げたら `.failed(reason: "rttm_unreadable")`（起動しない）
3. ここから先はどの経路でも `defer { try? SafeUnlink.remove(rttm, under: .staging, layout: layout, missingOK: true) }`
4. `runner.run(ProcessSpec(executable: paths.argmaxCLI, arguments: DiarizeArgs.build(input: input, models: paths.speakerModels, rttm: rttm), environment: ProcessEnvironment.standard), timeout: .seconds(timeoutSeconds(…)))`
5. `Transcriber.wasStopped(result)` なら `.stopped`
6. `termination`: `.spawnFailed` → `"spawn_failed"`、`.timedOut` → `"timeout"`、`.exited(n)` で n ≠ 0 → `"exit_<n>"`、`.signaled(n)` → `"signal_<n>"`
7. `Data(contentsOf: rttm)` が読めない・UTF-8 でない・`RTTMParser.parse` が nil → `"rttm_unreadable"`
8. `.diarized(turns)`

### 4.5 `Transcriber.swift` の変更

- プロパティ `let diarizer: Diarizer?`、init の最後に `diarizer: Diarizer? = nil`
- `TranscribeMetrics` に `public let diarization: DiarizationReport?`、init の最後に `diarization: DiarizationReport? = nil`
- `transcribe` の手順: F-82 の「直した transcript」の判定の後、`PartTranscript` を作る前に:
  1. `var segments = parsed.segments`、`var report: DiarizationReport? = nil`
  2. `diarizer` が非 nil かつ `TextLimit.scalarCount(parsed.text) >= config.minChars` かつ `!segments.isEmpty` のとき: `let begin = clock.uptime()` → `await diarizer.diarize(input: req.input, slug: req.slug, durationSeconds: req.durationSeconds)`
     - `.stopped` → `return .stopped`（transcript を書かない）
     - `.failed(let r)` → `report = .failed(reason: r)`
     - `.diarized(let turns)` → `segments = SpeakerAssigner.assign(segments, turns: turns)`、`report = .completed(speakers: Set(segments.compactMap(\.speaker)).count, elapsedSeconds: <begin からの秒>)`
  3. `PartTranscript(…, segments: segments)`。text は変えない（話者のラベルを text に入れない）
  4. 成功（手順 13）の `metrics` に `diarization: report` を載せる。無音（手順 12）・冪等（手順 1）では載せない（冪等は nil）

## 5. テスト

`Tests/TestSupport/FakeArgmax.swift`（`FakeWhisper` と同じ作り）:

```swift
public enum FakeArgmaxOutput: Sendable { case rttm([String]), none, custom(String) }

public enum FakeArgmax {
    public static let help: String  // Tests/Fixtures/argmax-cli-diarize-help.txt と同じフラグを持つ短い help
    @discardableResult
    public static func write(
        to script: URL, output: FakeArgmaxOutput = .rttm(["SPEAKER audio16k 1 0.000 2.000 <NA> <NA> A <NA> <NA>"]),
        exitCode: Int32 = 0, sleepSeconds: Double = 0, selfSignal: Int32? = nil
    ) throws -> URL
    public static func recordedArgv(_ script: URL) -> [String]
}
```

スクリプトは argv を `<script>.argv` に書き、`--help` で help を出して 0、`--rttm-path` の次の値へ出力を書く（`.none` は書かない）。

`Tests/VDTranscribeTests/DiarizeArgsTests.swift`:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `argvOrder` | argv は PLAN §8.4.1 の並び | 入力・モデル・RTTM の URL | `["diarize","--audio-path",<in>,"--model-path",<models>,"--rttm-path",<rttm>,"--use-exclusive-reconciliation"]` |
| `fixtureHasAllFlags` | 固定した版の --help に 4 つのフラグが在る | `Tests/Fixtures/argmax-cli-diarize-help.txt` | `missingFlags` が `[]` |
| `missingFlagReported` | 無いフラグを宣言順に返す | `--rttm-path` を消した help | `["--rttm-path"]` |
| `prefixIsNotAFlag` | 長いフラグの一部は在ると見なさない | `--model-path-x` だけの help | `--model-path` を返す |
| `emptyHelp` | 空の help（TEST-28） | `""` | 4 つ全部 |

`Tests/VDTranscribeTests/RTTMParserTests.swift`:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `readsLines` | RTTM の行を読む | P0-13 の 2 行 | `[(0.0, 2.224, "A"), (2.326, 13.531, "A")]`（end = start + duration） |
| `emptyTextIsNoTurns` | 空の RTTM は 0 件（TEST-28） | `""`・`"\n\n"` | `[]` |
| `crlfAndBlankLines` | CRLF と空行を許す | `"SPEAKER…\r\n\r\n"` | 1 件 |
| `wrongTypeIsUnreadable` | 1 列目が SPEAKER でなければ全体が読めない | 2 行目が `LEXEME …` | nil |
| `tooFewColumns` | 8 列未満は読めない | 7 列 | nil |
| `negativeOrNonFinite` | 負・nan・inf は読めない | start `-1`、duration `nan`、`inf` | それぞれ nil |
| `tabsSeparate` | タブ区切りも読める | タブ区切り 10 列 | 1 件 |

`Tests/VDTranscribeTests/SpeakerAssignerTests.swift`:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `maxOverlapWins` | 重なりの最も長い話者を付ける | 区間 [0,10]、X:[0,3]・Y:[3,10] | speaker `"A"`（Y が最初に付いた話者なので A） |
| `labelsFollowSegmentOrder` | ラベルは区間の順に初めて出た順 | RTTM は B が先の行、区間は A の発話が先 | 区間の順に A, B |
| `tieGoesToEarlierRTTMSpeaker` | 同点は RTTM で先に出た話者 | 区間 [0,4]、X:[0,2]・Y:[2,4]（X が先の行） | X の側 |
| `nearestWithinTolerance` | 重なりが無ければ 1 秒以内の最も近い話者 | 区間 [5,6]、X:[6.5,8] | X の側 |
| `beyondToleranceIsNil` | 1 秒より離れていれば話者なし | 区間 [5,6]、X:[7.1,8] | nil |
| `sumsAcrossTurns` | 同じ話者の複数の行の重なりを足す | 区間 [0,10]、X:[0,3]・[7,10]、Y:[3,7] | X の側（6 > 4） |
| `zeroLengthSegment` | 長さ 0 の区間は近さで決める | 区間 [2,2]、X:[1,3] | X の側 |
| `emptyTurns` | RTTM が空なら全部話者なし（TEST-28） | turns `[]` | 全区間 nil、text・時刻は同じ |
| `emptySegments` | 区間が空なら空（TEST-28） | segments `[]` | `[]` |
| `unusedSpeakerConsumesNoLabel` | 区間に付かなかった話者はラベルを使わない | RTTM に X・Y・Z、区間は X と Z だけ | A と B |

`Tests/VDTranscribeTests/DiarizerTests.swift`（`TempDirectory`・`HomeLayout`・FakeArgmax・本物の `ProcessRunner`）:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `diarizes` | 成功で RTTM の区間を返し、RTTM を消す | 偽物が 2 行を書く | `.diarized` 2 件、staging の `diarization.rttm` が無い |
| `missingHelper` | argmax-cli が無ければ起動せず helper_missing | helpers に何も置かない | `.failed(reason: "helper_missing")`、`missingParts() == ["argmax-cli"]` |
| `missingModels` | SpeakerModels が無ければ helper_missing | resources にフォルダを作らない | `["SpeakerModels"]` |
| `exitNonZero` | 終了 3 は exit_3 | `exitCode: 3` | `.failed(reason: "exit_3")` |
| `signaled` | 自分を SIGKILL すると signal_9 | `selfSignal: 9` | `"signal_9"` |
| `timeout` | タイムアウトは timeout | `maxTimeoutSeconds` を小さくした Diarizer と `sleepSeconds` | `"timeout"` |
| `noRTTM` | 終了 0 で RTTM が無ければ rttm_unreadable | `.none` | `"rttm_unreadable"` |
| `brokenRTTM` | 読めない RTTM は rttm_unreadable | `.custom("garbage")` | `"rttm_unreadable"` |
| `emptyRTTM` | 空の RTTM は 0 件の成功（TEST-28） | `.rttm([])` | `.diarized([])` |
| `staleRTTMIsRemovedFirst` | 前回の RTTM を起動の前に消す | 前回の RTTM を置き、偽物は書かない | `"rttm_unreadable"`（前回の中身で成功にしない） |
| `argvIsRecorded` | 起動の argv が PLAN どおり | 成功 | `FakeArgmax.recordedArgv` が `DiarizeArgs.build` と一致 |
| `timeoutFormula` | タイムアウトの式 | duration nil・10・1000・100000、max 21600 | 21600・120・500・21600 |

`Tests/VDTranscribeTests/TranscriberDiarizationTests.swift`（FakeWhisper + FakeArgmax）:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `withoutDiarizerIsUnchanged` | diarizer が nil なら今と同じ transcript を書く | FakeWhisper 既定 | 書いた transcript に `speaker` キーが無い、`metrics.diarization == nil`、argmax の argv が無い |
| `diarizedTranscriptHasSpeakers` | 成功すると区間に speaker を書く | 偽物の RTTM が区間を 2 人に分ける | transcript の区間の speaker が `"A"`・`"B"`、`metrics.diarization == .completed(speakers: 2, …)` |
| `failureStillTranscribes` | 話者分離が失敗しても文字起こしは成功する | 偽 argmax が終了 1 | `.transcribed`、speaker なし、`.failed(reason: "exit_1")` |
| `noSpeechSkipsDiarization` | 無音には起動しない | whisper の text が minChars 未満 | `.noSpeech`、argmax の argv が無い |
| `stoppedDoesNotWrite` | 話者分離が止められたら transcript を書かずに stopped | `ProcessRunner` を terminateAll で閉じてから（`TranscriberStoppedTests` と同じ作り） | `.stopped`、transcript が無い |
| `idempotentSkipsDiarization` | 読める transcript が在れば起動しない | transcript を先に置く | argmax の argv が無い、`diarization == nil` |
| `textIsUnchanged` | 話者分離しても text は変わらない | 成功 | `t.text` が diarizer nil のときと同じ |

`Tests/VDTranscribeTests/FakeArgmaxTests.swift`: help を出す・argv を記録する・`--rttm-path` に書く・`.none` で書かない・終了コードを返す（各 1 本）。

## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| `DiarizeArgs.build` から `--use-exclusive-reconciliation` を外す | `argvOrder`・`argvIsRecorded` |
| `RTTMParser` で不正な行を飛ばして続ける | `wrongTypeIsUnreadable` |
| 重なりの比較で最小を取る | `maxOverlapWins` |
| `nearestToleranceSeconds` を使わず常に最も近い話者を付ける | `beyondToleranceIsNil` |
| ラベルを RTTM の名前のまま使う | `labelsFollowSegmentOrder` |
| `.failed` で `.failure(StageFailure)` を返す | `failureStillTranscribes` |
| `.stopped` を無視して書く | `stoppedDoesNotWrite` |
| 起動の前に前回の RTTM を消さない | `staleRTTMIsRemovedFirst` |
| 無音の判定の前に話者分離を起動する | `noSpeechSkipsDiarization` |

## 7. 受け入れ条件

- [ ] diarizer が nil のときの `Transcriber` の出力（transcript のバイト列・outcome）が変わらない（既存の `TranscriberTests` が通る）
- [ ] 話者分離のどの失敗でも `.transcribed` のまま（`.stopped` だけが例外）
- [ ] VDTranscribe の import は PLAN §3.4 のまま（PT-07）
- [ ] `make lint && make test` が通る

## 8. SPEC の変更

なし（argv は PLAN §8.4.1 が正。S11 は whisper-cli だけ）

## 9. マージ後にやること

なし
