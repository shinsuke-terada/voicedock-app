# T-49 VDPipeline: 話者分離の配線・統合・Raw の Part・ログ・DR-18

| 項目 | 値 |
|---|---|
| ID | T-49 |
| Phase | 8.5（話者分離。F-89） |
| 前提 | T-48（`Diarizer`・`TranscribeMetrics.diarization`・`DiarizeArgs.missingFlags`・`FakeArgmax`） |
| 見積もり | Sources 約 120 行、Tests 約 350 行 |

## 1. 目的

設定 `transcription.diarization.enabled` がオンのとき、文字起こしの段で `Diarizer` を `Transcriber` に渡し、結果をログに出す。
Session の統合と Raw ノートの Part に `speaker` を運ぶ。診断に DR-18 を足す。**オフのときは何も変わらない。**

## 2. 参照

- PLAN §8.4.1（起動する場所・ログ）、§8.4（呼び手の手順 10）、§8.5（統合）、§8.6（Raw に載せる Part）、§8.11（DR-18）、付録 A.4
- 00-api-map §7・§11

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDPipeline/PartSteps+Transcribe.swift`（変更） | `Diarizer` を渡す・ログ |
| `Sources/VDPipeline/SessionSteps+Merge.swift`（変更） | `AbsoluteSegment.speaker` |
| `Sources/VDPipeline/PartSteps+RawNote.swift`（変更） | `RawPart` の区間の `speaker` |
| `Sources/VDPipeline/Diagnostics/DiagnosticCheck.swift`（変更） | `DiagnosticID.diarization = "DR-18"` |
| `Sources/VDPipeline/Diagnostics/DiagnosticChecks.swift`（変更） | `dr18` |
| `Sources/VDPipeline/Diagnostics/Diagnostics.swift`（変更） | DR-06 の後に DR-18 |
| `Sources/VDPipeline/Diagnostics/DiagnosticTexts.swift`（変更） | ラベルと文言 |
| `docs/PLAN.md`（変更） | §8.11 の表に DR-18 の行と件数の注記（PLAN §8.4.1 の「ログのイベントと診断」の値をそのまま写す。`SpecMatchesPlanTests` のため SPEC・コードと同じ PR で直す） |
| `docs/SPEC.md`（変更） | S6 に DR-18 |
| `README.md`（変更） | 診断の件数（17 件）、話者分離の説明と出典 |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | `transcription.diarization.enabled` を消す |
| `Tests/PolicyTests/ReadmeTests.swift`（変更） | `expectedHeadings` の末尾に `"## 出典"`（§4.4 で README に足す見出し） |
| `Tests/VDPipelineTests/PartStepsDiarizationTests.swift` | |
| `Tests/VDPipelineTests/SessionMergeSpeakerTests.swift` | |
| `Tests/VDPipelineTests/DiagnosticDR18Tests.swift` | |
| `Tests/VDPipelineTests/DiagnosticsRunTests.swift`（変更） | 16 件・順 |
| `Tests/VDPipelineTests/DiagnosticsNoWriteTests.swift`（変更） | `diagnosticsChangeNothingInHome` の件数を 16 に |

## 4. 仕様

### 4.1 `PartSteps+Transcribe.swift`

- `Transcriber` を作るところで、`cfg.transcription.diarization.enabled` なら
  `Diarizer(runner: deps.runner, paths: deps.paths, layout: layout, maxTimeoutSeconds: cfg.transcription.maxTimeoutSeconds)` を `diarizer:` に渡す。オフなら nil
- `.transcribed(_, let metrics)` の分岐で、`transcription_completed` の後（16 kHz の削除の前）に:

```swift
switch metrics.diarization {
case .completed(let speakers, let elapsed):
    log.info(
        .diarizationCompleted,
        [(.recordingKey, .string(pk)), (.speakers, .of(speakers)), (.elapsedS, .double(PyRound.round(elapsed, digits: 1)))])
case .failed(let reason):
    log.warning(.diarizationFailed, [(.recordingKey, .string(pk)), (.reason, .string(reason))])
case nil:
    break
}
```

- 話者分離はガード（`missingPrerequisites`）に入れない（部品が無くても文字起こしは進む。PLAN §8.4.1）

### 4.2 `SessionSteps+Merge.swift` と `PartSteps+RawNote.swift`

`AbsoluteSegment(at:endAt:text:)` を作る 2 か所に `speaker: seg.speaker`（`$0.speaker`）を足す。ほかは変えない。

### 4.3 DR-18

- `DiagnosticID.diarization = "DR-18"`、`Diagnostics.checks` の `vadModel` の直後に `DiagnosticCheck(id: DiagnosticID.diarization, fatal: false, always: false, run: DiagnosticChecks.dr18)`
- ラベル: `"話者分離"`
- `dr18`:
  1. `ctx.config?.transcription.diarization.enabled != true` → `.skip`、詳細 `["オフです"]`
  2. `let d = Diarizer(runner: ctx.deps.runner, paths: ctx.deps.paths, layout: ctx.deps.layout, maxTimeoutSeconds: 1)`、`var missing = d.missingParts()`
  3. `argmax-cli` が在れば `ProcessSpec(executable: paths.argmaxCLI, arguments: ["diarize", "--help"], environment: ProcessEnvironment.cLocale)` を `helpTimeout` で 1 回。終了 0 でなければ `missing.append("argmax-cli diarize --help")`、0 なら `DiarizeArgs.missingFlags(helpOutput: stdout + stderr)` を `missing` に足す
  4. `missing` が空 → `.ok`、詳細 `["argmax-cli とモデルが揃っています"]`。空でない → `.notice`、詳細 `["話者分離の部品がありません（\(missing.joined(separator: "、"))）。話者なしで文字起こしします"]`

### 4.4 README

- 「診断は **16 件**」→ `DocumentedCounts` の文（**17 件**、うち **1 件**）
- 「使い方」の節（ノートの説明の近く）に 1 段落:「パネルの ⚙ →「一般」の「話者分離（誰が話したか）」をオンにすると、その後に文字起こしする録音の Raw ノートが `**話者A**: …` の行になります（既定はオフ）。話者の名前は付けず、録音（約 30 分）ごとに A・B… を振り直します。精度は録音の条件で変わるので、使うかどうかは試して決めてください。」
- 出典の節（無ければ末尾に「## 出典」）: 「話者分離のモデルは pyannote の speaker-diarization-community-1（CC-BY-4.0）を Argmax が Core ML に変換したもの（argmaxinc/speakerkit-coreml、CC-BY-4.0）、実行ファイルは argmax-oss-swift（MIT）です。アプリの中の `Contents/Resources/SpeakerModels/NOTICE.txt` にも書いてあります。」
- `ReadmeTests` の見出しの表（`expectedHeadings`）を変える場合はテストも同じ PR で直す

## 5. テスト

`Tests/VDPipelineTests/PartStepsDiarizationTests.swift`（既存の Part の工程のテストと同じ世界。FakeWhisper + FakeArgmax を helpers に置く）:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `offDoesNotLaunch` | CE transcription.diarization.enabled false なら argmax-cli を起動しない | 既定の設定 | TRANSCRIBED、argmax の argv が無い、`diarization_*` のログが無い、transcript に speaker が無い |
| `onLogsCompleted` | CE transcription.diarization.enabled true なら話者を付けて diarization_completed | enabled = true、偽の RTTM が 2 人 | TRANSCRIBED、`diarization_completed recording_key=… speakers=2 elapsed_s=…` が `transcription_completed` の後、transcript の区間に speaker |
| `onFailureLogsWarning` | 失敗しても TRANSCRIBED で diarization_failed | enabled = true、偽物が終了 2 | TRANSCRIBED、WARNING `diarization_failed … reason=exit_2`、エラーコードは NULL |
| `onMissingHelper` | argmax-cli が無くても止まらない | enabled = true、helpers に argmax を置かない | TRANSCRIBED、`reason=helper_missing`、`pipeline_paused` が出ない |
| `stagingIsRemovedAfterDiarization` | 話者分離の後に 16 kHz を消す | enabled = true、`deleteNormalizedAfterTranscribe` 既定 | 16 kHz が無い、偽物は 16 kHz のパスを受け取っている |
| `noSpeechDoesNotLog` | 無音の Part は話者分離のログを出さない | whisper の text が空 | SKIPPED、`diarization_*` のログが無い |

`Tests/VDPipelineTests/SessionMergeSpeakerTests.swift`:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `mergeCarriesSpeaker` | 統合結果の区間に speaker が運ばれる | 話者つきの transcript の Part | `AbsoluteSegment.speaker` が transcript と同じ |
| `rawPartCarriesSpeaker` | Raw の Part の区間に speaker が運ばれる | 同上 | `rawParts` の区間の speaker |
| `withoutSpeakerIsUnchanged` | 話者なしの統合結果は今と同じ | 話者なし | 全区間 nil、指紋が F-89 の前の期待と同じ |
| `emptySession` | 区間 0 の Session（TEST-28） | transcript の区間が空 | `buildSessionTranscript` が nil |

`Tests/VDPipelineTests/DiagnosticDR18Tests.swift`:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `offIsSkip` | DR-18 オフなら skip | 既定の設定 | `.skip`、「オフです」 |
| `allPresentIsOK` | DR-18 揃っていれば ok | enabled、FakeArgmax と空でない SpeakerModels | `.ok` |
| `missingModelsIsNotice` | DR-18 モデルが無ければ notice | enabled、SpeakerModels なし | `.notice`、詳細に `SpeakerModels` |
| `missingFlagIsNotice` | DR-18 --help にフラグが無ければ notice | FakeArgmax の help から `--rttm-path` を消す | `.notice`、詳細に `--rttm-path` |
| `emptyHelpIsNotice` | DR-18 空の help（TEST-28） | help が空 | `.notice`、4 つのフラグ |

`DiagnosticsRunTests`（変更）: 順は `…"DR-06", "DR-18", "DR-07"…`、件数は 16（表示名も「16 件が…」「DR-09 を除いて 16 件」に、関数名 `countIs15` も `countIs16` に直す）。

## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| 設定を見ずに常に `Diarizer` を渡す | `offDoesNotLaunch` |
| `diarization_completed` を出さない | `onLogsCompleted` |
| 16 kHz を話者分離の前に消す（削除を上に移す） | `stagingIsRemovedAfterDiarization` |
| 統合で `speaker` を渡さない | `mergeCarriesSpeaker` |
| DR-18 をオフでも実行する | `offIsSkip` |
| `Diagnostics.checks` の DR-18 を末尾に移す | `orderIsTheSpecOrder` |

## 7. 受け入れ条件

- [ ] オフ（既定）の Part の工程・ログ・transcript・Raw・指紋が変わらない（既存のテストが通る）
- [ ] オンで argmax-cli が無くても、文字起こしとノートが止まらない
- [ ] `ConfigEffectPending` が空に戻る
- [ ] README の件数の文書テストが通る
- [ ] `make lint && make test` が通る

## 8. SPEC の変更

- PLAN §8.11 にも同じ行と注記を足す（`tmp/witty-gliding-clover.md` は写し直す）
- S6（診断）: DR-06 の行の後に PLAN §8.11 の DR-18 の行を逐語で。件数の注記を「16 + DR-09 = 17」に

## 9. マージ後にやること

なし
