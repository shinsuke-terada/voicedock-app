# T-51 UI: 「一般」の話者分離のトグル

| 項目 | 値 |
|---|---|
| ID | T-51 |
| Phase | 8.5（話者分離。F-89） |
| 前提 | T-47（`transcription.diarization.enabled`・`AppPaths.argmaxCLI` / `speakerModels`）、T-48（`Diarizer.missingParts`） |
| 見積もり | Sources 約 80 行、Tests 約 150 行 |

## 1. 目的

パネルの「一般」（⚙ の設定の画面と、「はじめに」の④が未完了の間のカード）に「話者分離（誰が話したか）」のトグルを置き、`transcription.diarization.enabled` を `ConfigStore.update` で書く（PLAN §6.3・§8.12 の 6）。
オンで部品が欠けていれば注意を出す。

## 2. 参照

- PLAN §8.12 の 6、§6.3、§8.4.1
- 00-api-map §12（`AppModel+*`・`AppSnapshot`・`Panel/*.swift`）
- 型の手本: `AppModel.selectLLM`（`Sources/VoiceDockApp/AppModel+Models.swift`）、`GeneralSection` のログイン項目のトグル

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VoiceDockApp/AppSnapshot.swift`（変更） | `diarizationEnabled`・`diarizationMissing` |
| `Sources/VoiceDockApp/AppServices.swift`（変更） | 上の 2 つを埋める |
| `Sources/VoiceDockApp/AppModel+Diarization.swift` | `setDiarization(_:)` |
| `Sources/VoiceDockApp/Panel/GeneralSection.swift`（変更） | トグルと注意 |
| `Sources/VoiceDockApp/Strings.swift`（変更） | 文言 |
| `Tests/VoiceDockAppTests/AppModelDiarizationTests.swift` | |

## 4. 仕様

### 4.1 `AppSnapshot`

```swift
    // T-51（F-89）
    /// 設定の transcription.diarization.enabled の写し（設定エラー中は false）
    var diarizationEnabled = false
    /// オンのときに欠けている部品（Diarizer.missingParts()。オフなら常に空）
    var diarizationMissing: [String] = []
```

`AppServices` のスナップショットを作るところ（`LiveServices.read` の設定が読めている分岐。`s.vadEntry` などを埋める所）で、
`s.diarizationEnabled = c.transcription.diarization.enabled`、オンなら
`s.diarizationMissing = Diarizer(runner: context.runner, paths: context.paths, layout: layout, maxTimeoutSeconds: 1).missingParts()`（起動はしない。stat だけ）。
`runner` と `paths` は `LiveServices` には無く `AppContext` が持つので `context.` を付ける（`layout` はその分岐の `let layout = context.layout`）。`AppServices.swift` に `import VDTranscribe` を足す。

### 4.2 `AppModel+Diarization.swift`

```swift
// 話者分離のトグル（PLAN §8.12 の 6。F-89）。
import Foundation

extension AppModel {
    /// 設定に書く。違反なら書かずに modelError に出す（selectLLM と同じ）。
    func setDiarization(_ on: Bool) async {
        let r = await services.updateConfig { $0.transcription.diarization.enabled = on }
        switch r {
        case .failure(let v): modelError = Strings.configRejected(v)
        case .success: modelError = nil
        }
        await refresh()
    }
}
```

### 4.3 `GeneralSection`

ログイン時に起動のトグル（とその注意）の後、`uiStateSaveFailed` の前に:

```swift
            Toggle(
                Strings.labelDiarization,
                isOn: Binding(
                    get: { model.snapshot.diarizationEnabled },
                    set: { on in Task { await model.setDiarization(on) } })
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!model.snapshot.configPresent)
            Text(Strings.diarizationNote).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.snapshot.diarizationEnabled && !model.snapshot.diarizationMissing.isEmpty {
                Text(Strings.diarizationMissing(model.snapshot.diarizationMissing))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 書けなかったときの modelError は主画面ではモデルの節が出す。⚙ の画面にはモデルの節が無いのでここで出す
            if model.screen == .settings, let error = model.modelError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
```

`modelError` を出すのは主画面の `ModelsSection` だけで、⚙ の「設定」の画面（`PanelView` の `.settings`）にはモデルの節が無い。
そのままでは ⚙ の画面でトグルが弾かれても何も出ないので、`GeneralSection` が ⚙ の画面の間だけ `modelError` を出す（主画面では二重に出さない）。

### 4.4 `Strings`（逐語）

```swift
    static let labelDiarization = "話者分離（誰が話したか）"
    static let diarizationNote = "オンにした後に文字起こしする録音から、Raw ノートを「話者A: …」の行に分けます。精度は録音の条件で変わります。"
    static func diarizationMissing(_ parts: [String]) -> String {
        "話者分離の部品がありません（\(parts.joined(separator: "、"))）。話者なしで文字起こしします"
    }
```

## 5. テスト

`Tests/VoiceDockAppTests/AppModelDiarizationTests.swift`（既存の `AppModel` のテストと同じ services）。
`FakeServices` は `config.json` を書かず、`read` も設定から snapshot を作らないので、書く・読むの 4 本（`turnOnWritesConfig`・`turnOffWritesConfig`・`missingPartsShown`・`offHasNoMissing`）は
`AppModelTests.liveServices(tmp)`（一時ディレクトリの `LiveServices`。helpers と resources は空の一時ディレクトリ）に `layout.createDirectories()` と `config.load()` で既定の設定を書かせて使う。
`rejectedShowsError` だけ `FakeServices.setUpdateViolations` を使う:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `turnOnWritesConfig` | オンにすると設定に true を書く | 既定の設定 | `config.json` の `transcription.diarization.enabled == true`、`snapshot.diarizationEnabled` |
| `turnOffWritesConfig` | オフにすると false を書く | true の設定 | false |
| `rejectedShowsError` | 書けなければ modelError | updateConfig が違反を返す偽物 | `modelError` が `Strings.configRejected` の文 |
| `missingPartsShown` | オンで部品が欠ければ snapshot に載る | enabled、helpers が空 | `diarizationMissing == ["argmax-cli", "SpeakerModels"]` |
| `offHasNoMissing` | オフなら欠けを見ない（TEST-28: 空） | 既定、helpers が空 | `diarizationMissing == []` |
| `stringsAreVerbatim` | 文言が逐語 | — | 4.4 の 3 つと一致 |

## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| `setDiarization` で `on` を反転して書く | `turnOnWritesConfig` |
| オフでも `missingParts` を載せる | `offHasNoMissing` |
| 文言を変える | `stringsAreVerbatim` |

## 7. 受け入れ条件

- [ ] パネルの ⚙ →「一般」でトグルでき、`config.json` に反映される（手で 1 回。PR 本文にスクリーンショット）
- [ ] 設定エラー中はトグルが押せない
- [ ] `make lint && make test` が通る

## 8. SPEC の変更

なし（S20 のパネルの節と画面は変えない）

## 9. マージ後にやること

- 【利用者が行う】`make vendor && make app` の後、実機（または退避済みの録音）で話者分離をオンにして 2〜3 人の会話を取り込み、Raw ノートに `**話者A**:` の行が出ること、オフに戻すと次の録音が今の書式に戻ることを確かめる
