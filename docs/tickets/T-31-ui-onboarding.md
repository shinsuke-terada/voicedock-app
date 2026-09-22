# T-31 UI: はじめに・保存先（Vault）・モデル・ログイン項目

| 項目 | 内容 |
|---|---|
| ID | T-31 |
| Phase | 7（UI と配布） |
| 前提 | T-30（`AppModel`・`AppSnapshot`・`AppServices`・`Strings`・`StatusItemController.runModal`・`LoginItem`・空の 4 節）、T-23（`ModelDownloader`・`ModelImporter`・`ModelManager`・`ModelError`・`ModelState`） |
| 見積もり | 本体 約 900 行（うち SwiftUI 約 320 行）、テスト 約 700 行 |

## 1. 目的

「使える状態にするまで」をパネルの中で完結させる。**はじめに**（5 項目）、**保存先（Vault）**の選択、**モデル**の入手と選択、**一般**（ログイン時に起動）を作る。
GUI で変えられる設定は 4 つだけ（PLAN §6.3）——Vault の場所・Whisper モデル・LLM モデル・ログイン時に起動——という約束をここで守る。

「今はしない」の選択は `<HOME>/ui-state.json` に記録する（`UserDefaults` を使わない。PR-03）。

## 2. 参照

- PLAN §8.12 の 3〜6（はじめに・保存先・モデル・一般）、§6.3（GUI に出すのは 4 つだけ）、§8.10（VDModels。メモリの条件・ファイルから読み込む・進捗）、§8.7（Vault の確認）、§2.3（`ui-state.json`）、§8.1 の規則 8・9（`mount_name_mismatch` / `invalid_device_id`）、付録 C DEV-10（**アプリはデバイスに書かない**）、付録 A.4（`model_downloaded` / `model_download_failed`）
- 00-api-map.md §12（`UIState.swift`・`LoginItem.swift`・`Panel/*`）、§10（VDModels）、§2.2（`ModelCatalog` / `ModelEntry` / `ModelFiles` / `CustomModelID`）、§9（`VaultCheck`）、§11（`ConfigStore`）
- 先行チケット: T-30 §4.7〜§4.14（`AppSnapshot` / `AppServices` / `AppModel` / `Strings` / `LoginItem`）、T-09（`AppConfig.vault` / `transcription.whisperModelID` / `llm.modelID`・CV-40〜45）、T-23（`ModelManager` / `ModelDownloader` / `ModelImporter`）、T-28（`VaultCheck` と `VaultStatus.message`）
- voicedock@d3d595e: 該当なし（voicedock には GUI が無い。「はじめに」は本計画の新規）

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VoiceDockApp/UIState.swift` | `UIState`、`UIStateStore` |
| `Sources/VoiceDockApp/Onboarding.swift` | `OnboardingStep`、`OnboardingItem`、`OnboardingEvaluator` |
| `Sources/VoiceDockApp/ModelChoices.swift` | `LLMChoice`、`ModelChoices` |
| `Sources/VoiceDockApp/FolderChooser.swift` | `FolderChooser`（プロトコル）、`OpenPanelFolderChooser`、`FileChooser`・`OpenPanelFileChooser`（拡張子の絞り込みは private の `ExtensionFilter`） |
| `Sources/VoiceDockApp/DownloadState.swift` | `DownloadState`、`ModelSlot` |
| `Sources/VoiceDockApp/AppModel+Vault.swift` | Vault の選択 |
| `Sources/VoiceDockApp/AppModel+Models.swift` | モデルの入手・選択・取り込み・キャンセル |
| `Sources/VoiceDockApp/AppModel+LoginItem.swift` | ログイン項目 |
| 変更 `Sources/VoiceDockApp/Panel/OnboardingSection.swift` | §8.12 の 3（T-30 が作った空の節の本体を書く） |
| 変更 `Sources/VoiceDockApp/Panel/VaultSection.swift` | §8.12 の 4（T-30 が作った空の節の本体を書く） |
| 変更 `Sources/VoiceDockApp/Panel/ModelsSection.swift` | §8.12 の 5（T-30 が作った空の節の本体を書く） |
| 変更 `Sources/VoiceDockApp/Panel/GeneralSection.swift` | §8.12 の 6（T-30 が作った空の節の本体を書く） |
| 変更 `Sources/VoiceDockApp/LoginItem.swift` | `LoginItemResult`、`register` / `unregister` / `openSystemSettingsLoginItems` を足す |
| 変更 `Sources/VoiceDockApp/AppSnapshot.swift` | §4.1 のフィールドを足す |
| 変更 `Sources/VoiceDockApp/AppServices.swift` | §4.2 の口を足す |
| 変更 `Sources/VoiceDockApp/AppModel.swift` | `downloads`・`vaultError`・`modelError`・`modelNotice`・`loginItemError`・`uiStateSaveFailed` と、init の `catalog`・`chooser`・`fileChooser`・`presentModal` を足す |
| 変更 `Sources/VoiceDockApp/Bootstrap.swift` | `AppContext` に `downloader`・`uiState`・`physicalMemoryBytes` を足す |
| 変更 `Sources/VoiceDockApp/Strings.swift` | §4.10 の文言 |
| 変更 `Sources/VoiceDockApp/AppDelegate.swift` | `AppModel` の init に `catalog`・`OpenPanelFolderChooser()`・`OpenPanelFileChooser()`・`presentModal`（`StatusItemController.runModal`）を渡す（§4.6） |
| 変更 `Tests/VoiceDockAppTests/FakeServices.swift` | §4.2 の口の偽物（呼び出しの記録・結果の差し替え・ダウンロードの保留）と `FakeFolderChooser` / `FakeFileChooser` |
| 変更 `Tests/VoiceDockAppTests/AppModelTests.swift` | `AppModel` / `AppContext` の init に足した引数を渡す（T-30 のテストの中身は変えない） |
| `Tests/PolicyTests/PanelPolicyTests.swift` | §7 の `PanelPolicyTests` |
| `Tests/VoiceDockAppTests/UIStateTests.swift` | |
| `Tests/VoiceDockAppTests/OnboardingTests.swift` | |
| `Tests/VoiceDockAppTests/ModelChoicesTests.swift` | |
| `Tests/VoiceDockAppTests/AppModelVaultTests.swift` | |
| `Tests/VoiceDockAppTests/AppModelModelsTests.swift` | |
| `Tests/VoiceDockAppTests/AppModelLoginItemTests.swift` | |

## 4. 仕様

T-30 §4.0 の全体の規則を適用する。**このチケットのコードは `<HOME>/ui-state.json` 以外に書き込まない**（設定は `ConfigStore.update`、モデルは VDModels）。

### 4.1 `AppSnapshot` に足すフィールド

```swift
    // T-31
    /// カタログに載る whisper / vad の選択中の項目（設定の ID から引いたもの。CV-44 / CV-45 が保証する）
    var whisperEntry: ModelEntry? = nil
    var vadEntry: ModelEntry? = nil
    var whisperPresent = false
    var vadPresent = false
    var vadEnabled = true
    var llmModelID: String? = nil
    var llmPresent = false
    var llmChoices: [LLMChoice] = []
    var physicalMemoryBytes: UInt64 = 0
    var loginItem: LoginItemStatus = .notFound
    var uiState = UIState()
    /// 改名の案内を出すデバイス名（snapshot の devices と unavailable を合わせて集める）
    var renameCandidates: [String] = []
```

`LiveServices.read` に足す手順（T-30 §4.8 の 3 と 4 の間）:
- `s.physicalMemoryBytes = context.physicalMemoryBytes`、`s.loginItem = context.loginItem.status()`、`s.uiState = context.uiState.load()`
- `if let c = config`:
  - `s.whisperEntry = catalog.entry(kind: .whisper, id: c.transcription.whisperModelID)`、`s.whisperPresent = s.whisperEntry.map { ModelFiles.isPresent($0, kind: .whisper, layout: layout) } ?? false`
  - `s.vadEnabled = c.transcription.vad.enabled`、`s.vadEntry = catalog.entry(kind: .vad, id: c.transcription.vad.modelID)`、`s.vadPresent = …`（同じ形）
  - `s.llmModelID = c.llm.modelID`
  - `s.llmPresent = ModelChoices.llmIsPresent(id: c.llm.modelID, catalog: catalog, layout: layout)`
  - `s.llmChoices = ModelChoices.llm(catalog: catalog, physicalMemoryBytes: s.physicalMemoryBytes, currentID: c.llm.modelID, layout: layout)`
- 4 の後: `s.renameCandidates = ModelChoices.renameCandidates(s.device)`（置き場所は `Onboarding.swift` の方が自然なので **`OnboardingEvaluator.renameCandidates(_:)`** にする）

### 4.2 `AppServices` に足す口

```swift
    /// 設定の 1 つのキーを変えて保存する（GUI で変えてよい 4 つだけ。PLAN §6.3）。
    func updateConfig(_ mutate: @Sendable (inout AppConfig) -> Void) async -> ConfigUpdateResult
    /// モデルを 1 件ダウンロードする（進捗は progress に。取り消しは cancelDownload）。
    func download(kind: ModelKind, entry: ModelEntry, progress: @escaping @Sendable (Int64, Int64) -> Void) async -> Result<URL, ModelError>
    func cancelDownload(id: String) async
    /// 利用者が選んだ .gguf を読み込む（PLAN §8.10「ファイルから読み込む」）。
    func importGGUF(from source: URL) async -> Result<(id: String, url: URL), ModelError>
    /// ログイン項目の操作（PLAN §8.12 の 6）。
    func registerLoginItem() -> LoginItemResult
    func unregisterLoginItem() -> LoginItemResult
    func openSystemSettingsLoginItems()
    /// 「今はしない」などの記録。
    func saveUIState(_ state: UIState) -> Bool
```

`LiveServices` の実装:
- `updateConfig` = `await context.config.update(mutate)`
- `download` = `await context.models.download(entry.id, kind: kind, progress: progress)`（UI は `ModelManager` だけを使う。00-api-map §10・T-23 §10。`ModelManager` が状態（`downloading` / `failed`）を動かす）
- `cancelDownload` = `await context.models.cancel(id: id)`
- `importGGUF` = `await context.models.importCustomLLM(from: source)`（**T-23 が正**: `ModelManager.importCustomLLM(from:)` が `ModelImporter.importGGUF(from:layout:chunkBytes:)` を包む。`chunkBytes` は `ModelManager.init(… hashChunkBytes:)` に渡した値（設定の `audio.hashChunkBytes`）で、Bootstrap（T-30 手順 14）が `ModelDownloader(layout:factory:log:hashChunkBytes:)` と `ModelManager(layout:catalog:downloader:cache:log:hashChunkBytes:)` に渡す）
- `registerLoginItem` / `unregisterLoginItem` / `openSystemSettingsLoginItems` = `context.loginItem` へ委譲
- `saveUIState` = `context.uiState.save(_:)`

### 4.3 `UIState.swift`

```swift
// パネルの記憶（PLAN §2.3 / §8.12 の 3-④）。UserDefaults を使わない（PR-03）。<HOME>/ui-state.json だけに書く。
import Foundation
import VDContract

struct UIState: Codable, Equatable, Sendable {
    var schema: Int = UIState.currentSchema
    /// 「ログイン時に起動」をオンにしたか「今はしない」を選んだか（どちらでも true）
    var loginItemDecided: Bool = false
    static let currentSchema = 1
}

struct UIStateStore: Sendable {
    let url: URL                                  // HomeLayout.uiState
    init(url: URL)
    /// 無い・読めない・JSON でない・schema が 1 でない → 既定（例外を投げない）
    func load() -> UIState
    /// AtomicFile.write（0644）。失敗したら false（パネルは「記録できませんでした」と出す）
    func save(_ state: UIState) -> Bool
}
```

- 書式: `JSONEncoder`（`outputFormatting = [.sortedKeys, .prettyPrinted]`、`\n` で終える）。キーは `schema`・`loginItemDecided` の 2 つだけ
- `load()`: `Data(contentsOf:)` が投げたら既定。`JSONDecoder().decode(UIState.self, from:)` が投げたら既定。`decoded.schema != currentSchema` なら既定（**将来の版が書いた値を解釈しない**）
- 未知のキーは `Codable` が黙って捨てる（設定と違い CV を持たない。UI の記憶であって振る舞いを決める設定ではない）

### 4.4 `Onboarding.swift`

```swift
// 「はじめに」の 5 項目（PLAN §8.12 の 3）。純関数。未完了が 1 つでもあれば節を出す。
import VDDevice

enum OnboardingStep: String, CaseIterable, Sendable, Equatable {
    case vault, whisperModel, llmModel, loginItem, deviceName
}

struct OnboardingItem: Equatable, Sendable, Identifiable {
    let step: OnboardingStep
    let title: String
    let detail: String?
    let done: Bool
    /// 偽ならこの項目は出さない（deviceName は改名が要るデバイスが在るときだけ）
    let visible: Bool
    var id: OnboardingStep { step }
}

enum OnboardingEvaluator {
    static func items(_ s: AppSnapshot) -> [OnboardingItem]
    static var isComplete: (AppSnapshot) -> Bool { …items に未完了かつ visible が 1 つも無いこと… }
    /// snapshot の devices の鍵と unavailable の鍵のうち、改名の案内が要る名前（バイト順・重複なし）
    static func renameCandidates(_ snapshot: DeviceSnapshot?) -> [String]
    static let renameName = "NO NAME"
}
```

`items(_:)`（**この順**。番号は PLAN §8.12 の 3 の ①〜⑤）:

| # | `step` | `title` | `done` の条件 | `visible` |
|---|---|---|---|---|
| ① | `vault` | `Strings.onboardingVault` | `s.vault == .available` | 常に真 |
| ② | `whisperModel` | `Strings.onboardingWhisper` | `s.whisperPresent && (!s.vadEnabled \|\| s.vadPresent)` | 常に真 |
| ③ | `llmModel` | `Strings.onboardingLLM` | `s.llmModelID != nil && s.llmPresent` | 常に真 |
| ④ | `loginItem` | `Strings.onboardingLoginItem` | `s.loginItem == .enabled \|\| s.uiState.loginItemDecided` | 常に真 |
| ⑤ | `deviceName` | `Strings.onboardingDeviceName` | 常に偽 | `!s.renameCandidates.isEmpty` |

- `detail`: ①〜④ は nil、⑤ は `Strings.renameInstructions(s.renameCandidates)`
- ⑤ は**「完了」にできない**（アプリは改名を検知するしかなく、改名されれば `renameCandidates` が空になって `visible` が偽になる）。`done` を真にする経路を作らない
- `renameCandidates(_:)`: `snapshot == nil` → `[]`。`Set(snapshot.devices.keys).union(snapshot.unavailable.keys)` から `name == renameName` のものだけを取り、UTF-8 のバイト順に並べる
  （`unavailable` にも見るのは、`invalid_device_id` や `mount_name_mismatch` で `devices` に載らない場合があるため。PLAN §8.1 の規則 8・9）
- `NO NAME` 以外の名前は案内しない（DJI Mic 3 の工場出荷時の名前が `NO NAME`。PLAN §8.12 の 3-⑤ の逐語）

### 4.5 `ModelChoices.swift`

```swift
// LLM の選択肢と、モデルの在否（PLAN §8.10 / §8.12 の 5）。純関数。
import Foundation
import VDContract
import VDCore

struct LLMChoice: Equatable, Sendable, Identifiable {
    let id: String              // カタログの ID か custom:<sha256>
    let displayName: String
    let minMemoryGB: Int?
    let present: Bool
    let selectable: Bool
    /// 選べない理由、または custom の注意書き。選べて注意も無ければ nil
    let note: String?
    let isCustom: Bool
}

enum ModelChoices {
    static func llm(catalog: ModelCatalog, physicalMemoryBytes: UInt64, currentID: String?, layout: HomeLayout) -> [LLMChoice]
    static func llmIsPresent(id: String?, catalog: ModelCatalog, layout: HomeLayout) -> Bool
}
```

**メモリの条件は自分で書かない**。`ModelMemory.hasEnough(minMemoryGB:physicalMemoryBytes:)` と `ModelMemory.gb(_:)`（VDCore。T-30 §4.10b）を呼ぶ（CR-06。DR-08（T-32）と解析のガード（T-22）が同じ式を使う）。

**`llm(catalog:physicalMemoryBytes:currentID:layout:)`**:
1. `catalog.listedLLMs`（`verified == true` のものだけ。PLAN §8.10）をカタログの並び順のまま写す。各項目:
   - `present = ModelFiles.isPresent(entry, kind: .llm, layout: layout)`
   - `selectable = ModelMemory.hasEnough(minMemoryGB: entry.minMemoryGB, physicalMemoryBytes: physicalMemoryBytes)`
   - `note = selectable ? nil : Strings.notEnoughMemory(required: entry.minMemoryGB ?? 0, actual: ModelMemory.gb(physicalMemoryBytes))`
   - `isCustom = false`
2. `currentID` が `CustomModelID.sha256(of:) != nil`（`custom:<64 桁>`）なら**末尾に 1 件足す**:
   - `displayName = Strings.customModelName(sha 先頭 8)`、`minMemoryGB = nil`、`present = ModelFiles.customLLMURL(id:layout:)` のファイルが在る、`selectable = true`、`note = Strings.customModelUnsupported`、`isCustom = true`
- **`verified == false` のものは一覧に出さない**（PLAN §8.10）
- **メモリ不足のものは「選べない」だけで、一覧から消さない**（理由を表示する。PLAN §8.10）
- `llmIsPresent(id:catalog:layout:)`: `id == nil` → 偽。`custom:` なら `ModelFiles.customLLMURL(id:layout:)` のファイルが在るか。そうでなければ `catalog.entry(kind: .llm, id:)` を引いて `ModelFiles.isPresent`

### 4.6 `FolderChooser.swift`

```swift
// NSOpenPanel の包み（テストで差し替える）。popover を閉じてから出し、終わったら開き直す（PLAN §8.12）。
import AppKit

protocol FolderChooser: Sendable {
    /// 選ばれたフォルダの URL。取り消しなら nil
    @MainActor func chooseFolder(message: String, prompt: String) -> URL?
}

protocol FileChooser: Sendable {
    @MainActor func chooseFile(message: String, prompt: String, allowedExtensions: [String]) -> URL?
}

@MainActor
struct OpenPanelFolderChooser: FolderChooser { … }
@MainActor
struct OpenPanelFileChooser: FileChooser { … }
```

`OpenPanelFolderChooser.chooseFolder`:
1. `let panel = NSOpenPanel()`
2. `panel.canChooseFiles = false`、`panel.canChooseDirectories = true`、`panel.allowsMultipleSelection = false`、
   `panel.canCreateDirectories = false`（**Vault を作らせない**。DEL-06）、`panel.showsHiddenFiles = false`、
   `panel.message = message`、`panel.prompt = prompt`
3. `return panel.runModal() == .OK ? panel.url : nil`

`OpenPanelFileChooser.chooseFile`: `canChooseFiles = true`、`canChooseDirectories = false`、`allowsMultipleSelection = false`、`canCreateDirectories = false`、`showsHiddenFiles = false`、`message` / `prompt`、
拡張子の絞り込みは下の実装の注記（`UTType` は使わない）

- **`runModal` を呼ぶ側**（`AppModel`）は `StatusItemController.runModal { … }`（T-30 §4.6）で包む。popover が閉じて、選び終わったら開き直る
- `AppModel` には `catalog: ModelCatalog`（§4.7 の `entryFor`）、`chooser: any FolderChooser` / `fileChooser: any FileChooser` と、`presentModal: @MainActor (@MainActor () -> URL?) -> URL?`（`StatusItemController.runModal` を差す）を注入する。テストは全部偽物
  - init: `AppModel(services:openFinder:layout:catalog:chooser:fileChooser:presentModal:sleeper:now:quit:)`（新しい 4 つに既定値を置かない。テストが本物の `NSOpenPanel` を出さないため）
  - `presentModal` の型を `URL?` を返す形にするのは、`@MainActor` の関数型が `Sendable` で、Void の本体に選んだ値を捕まえた `var` で持ち出せないため（Swift 6。実装時に確認）。呼び出しは `let picked = presentModal { … }` のまま
  - `AppDelegate` は `presentModal: { [weak self] body in guard let controller = self?.statusItem else { return body() }; return controller.runModal(body) }` を渡す（`StatusItemController` は `AppModel` の後に作るので、呼ばれた時点のものを使う）
- **実装の注記**: `UTType` は `UniformTypeIdentifiers` の型で、VoiceDockApp の import 許可リスト（PT-07）に無く、AppKit / SwiftUI からは見えない。`allowedContentTypes` の代わりに `NSOpenSavePanelDelegate` の `panel(_:shouldEnable:)` でディレクトリと指定の拡張子（大小を区別しない）だけを選べるようにする（private の `ExtensionFilter`。`panel.delegate` は weak なので `runModal` の間 `withExtendedLifetime` で生かす）。`allowedExtensions` が空なら絞らない

### 4.7 `DownloadState.swift` と `AppModel+Models.swift`

```swift
// 進行中のダウンロード・取り込みの状態（画面にだけ在る値。AppSnapshot には入れない）。
enum ModelSlot: Hashable, Sendable { case whisper, vad, llm(String) }

enum DownloadState: Equatable, Sendable {
    case idle
    case running(received: Int64, total: Int64)   // total <= 0 なら不定
    case importing                                // ファイルから読み込む（SHA を計算中。進捗は出ない）
    case failed(String)
    var fraction: Double? { get }                 // total > 0 のときだけ received/total（0…1 に丸める）
}
```

`AppModel` に足す状態と操作:
```swift
    // 別ファイルの拡張（AppModel+Vault / +Models / +LoginItem）が書くので private(set) にできない（Swift の private は同じファイルの中だけ）
    var downloads: [ModelSlot: DownloadState] = [:]
    var vaultError: String?
    var modelError: String?
    var modelNotice: String?
    var loginItemError: String?
    var uiStateSaveFailed = false

    // Vault
    func chooseVault() async
    // モデル
    func fetchModel(_ slot: ModelSlot) async
    func cancelModel(_ slot: ModelSlot) async
    func selectLLM(_ id: String) async
    func importLLMFromFile() async
    // ログイン項目
    func setLoginItem(_ on: Bool) async
    func openLoginItemSettings()
    func dismissLoginItem() async          // 「今はしない」
```

**`fetchModel(_:)`**（PLAN §8.10 のダウンロード）:
AppModel の状態に、枠ごとの世代 `downloadGenerations: [ModelSlot: Int]` と、まだ返っていない download `downloadTasks: [ModelSlot: Task<Result<URL, ModelError>, Never>]` を足す（どちらも internal・`@ObservationIgnored`）。

1. `guard !isBusy(slot) else { return }`（進行中——`.running` か `.importing`——なら始めない。**`.failed` の後はもう一度始められる**）
2. `guard let (kind, entry) = entryFor(slot) else { return }`（`entryFor`: `.whisper` → `snapshot.whisperEntry`、`.vad` → `snapshot.vadEntry`、`.llm(id)` → `catalog.entry(kind: .llm, id: id)`。custom は入手できないので nil）
3. `let generation = (downloadGenerations[slot] ?? 0) + 1`、`downloadGenerations[slot] = generation`、`downloads[slot] = .running(received: 0, total: entry.bytes)`、`modelError = nil`
4. `if let previous = downloadTasks[slot] { _ = await previous.value }`（やめた直後の入手し直し: 前の download が `ModelManager` から抜けるまで待つ。抜ける前に呼ぶと `ModelManager` が内部の文字列 `already_downloading` で断り、それが利用者に出る）→ `guard downloadGenerations[slot] == generation else { return }`
5. `let task = Task { await services.download(kind: kind, entry: entry) { received, total in Task { @MainActor in self.progress(slot, generation, received, total) } } }`、`downloadTasks[slot] = task`、`let r = await task.value`、`if downloadTasks[slot] == task { downloadTasks[slot] = nil }`
6. `downloadGenerations[slot] == generation` かつ `downloads[slot]` が `.running` のときだけ `switch r`:
   - `.success`: `downloads[slot] = .idle`
   - `.failure(let e)`: `downloads[slot] = .failed(Strings.modelError(e))`、`modelError = Strings.modelError(e)`
7. `await refresh()`（在否を読み直す）

- `progress(_:_:_:_:)`（private）: `guard downloadGenerations[slot] == generation, case .running(let shown, _) = downloads[slot] else { return }`（やめた後・前の入手の遅れた通知を捨てる）→ `guard received >= shown else { return }`（通知ごとの Task の実行順が入れ替わっても値を戻さない）→ `downloads[slot] = .running(received:total:)`
- `entryFor(_:)`・`isBusy(_:)` も private
- `cancelModel(_:)`: `guard case .running = downloads[slot], let (_, entry) = entryFor(slot) else { return }` → `downloads[slot] = .idle` → 世代を 1 進める → `await services.cancelDownload(id: entry.id)`
  （**先に `.idle` にして世代を進めてから取り消す**。`download` の返り値 `.failure(.cancelled)` は 6 の `.failed` を書かない——世代が違えば 6 を飛ばす）
- 失敗の文言 `Strings.modelError(_ e: ModelError)`（逐語。§4.10）

**`selectLLM(_:)`**:
1. `guard let choice = snapshot.llmChoices.first(where: { $0.id == id }), choice.selectable else { return }`
2. `let r = await services.updateConfig { $0.llm.modelID = id }`
3. `.failure(let v)` → `modelError = Strings.configRejected(v)`。`.success` → `modelError = nil`、`modelNotice = nil`
4. `await refresh()`

**`importLLMFromFile()`**（PLAN §8.10「ファイルから読み込む」）:
0. `guard !isBusy(.customImport) else { return }`（取り込み中はもう一度読み込まない）
1. `let picked = presentModal { fileChooser.chooseFile(message: Strings.chooseGGUFMessage, prompt: Strings.chooseGGUFPrompt, allowedExtensions: ["gguf"]) }`
2. `guard let url = picked else { return }`
3. `downloads[.llm(CustomModelID.make(sha256: ""))]` は使えない（ID が決まる前）。**取り込み中は専用の枠 `ModelSlot.llm("custom")` を使う**（定数 `ModelSlot.customImport`）。`downloads[.customImport] = .importing`
4. `let r = await services.importGGUF(from: url)`
5. `.failure(let e)` → `downloads[.customImport] = .failed(Strings.modelError(e))`、`modelError = …`、`return`
6. `.success(let got)` → `downloads[.customImport] = .idle` → `await services.updateConfig { $0.llm.modelID = got.id }`（CV-42 が `custom:<64 桁>` を通す）。`.failure(let v)` なら捨てずに `modelError = Strings.configRejected(v)` → `await refresh()` → `return`（7 の注意は出さない）。成功なら `modelError = nil` → 7 → `await refresh()`
7. メモリの確認は**警告だけ**（PLAN §8.10）: 取り込んだ後、`modelError` ではなく `modelNotice = Strings.customModelUnsupported` を出す（`modelNotice` も `AppModel` の状態。`selectLLM` の成功と `panelDidClose()` で消す）

### 4.8 `AppModel+Vault.swift`

**`chooseVault()`**（PLAN §8.12 の 4）:
1. `let picked = presentModal { chooser.chooseFolder(message: Strings.chooseVaultMessage, prompt: Strings.chooseVaultPrompt) }`
2. `guard let url = picked else { return }`
3. `var trimmed = url.path(percentEncoded: false)`、`while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }`、`let path = trimmed`（NSOpenPanel が返すディレクトリの URL は末尾に `/` が付く。設定と文言には付けない。ルートの `/` は残す）
4. `let marker = snapshot.vaultMarker`（`AppSnapshot` に `var vaultMarker = ".obsidian"` を足す。設定から写す）
5. `let status = VaultCheck.evaluate(path: path, marker: marker)`
6. `guard status == .available else { vaultError = status.message(path: path, marker: marker); return }`（**`.available` でなければ拒否し、設定を書かない**。PLAN §8.12 の 4）
7. `let r = await services.updateConfig { $0.vault.path = path }`
8. `.failure(let v)` → `vaultError = Strings.configRejected(v)`、`return`
9. `vaultError = nil`
10. `await services.scanNow()`（Vault が使えるようになったので、止まっていた工程を進める。ガードは次の tick で外れる）
11. `await refresh()`

- 6 の判定は `VaultCheck` を**そのまま**使う（判定関数は 1 つ。PLAN §8.7）。パネル独自の条件を足さない
- `vaultError` は `panelDidClose()` で消す（T-30 §4.11 の `reloadResult` と同じ）

### 4.9 `LoginItem.swift`（T-30 のファイルへの追加）と `AppModel+LoginItem.swift`

```swift
/// `Result` の失敗側は `Error` を要り String は `Error` でないため包み型にする（ConfigUpdateResult と同じ形。ケース名は `Result` と同じ）
enum LoginItemResult: Equatable, Sendable {
    case success
    case failure(String)
}

protocol LoginItemControlling: Sendable {
    func status() -> LoginItemStatus
    /// 成功なら .success、失敗なら表示する文言
    func register() -> LoginItemResult
    func unregister() -> LoginItemResult
    func openSystemSettings()
}

extension SystemLoginItem {
    func register() -> LoginItemResult {
        do { try SMAppService.mainApp.register(); return .success }
        catch { return .failure(ErrorText.describe(error)) }
    }
    func unregister() -> LoginItemResult { …同じ形で SMAppService.mainApp.unregister()… }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
```

**`setLoginItem(_ on: Bool)`**:
1. `let r = on ? services.registerLoginItem() : services.unregisterLoginItem()`
2. `.failure(let m)` → `loginItemError = m`、`await refresh()`、`return`
3. `loginItemError = nil`
4. `await markLoginItemDecided()`（オンにしたら「はじめに」の ④ も完了にする）
5. `await refresh()`

**`dismissLoginItem()`**（「今はしない」）= `await markLoginItemDecided()` → `await refresh()`

`markLoginItemDecided()`（private）: `var st = snapshot.uiState; st.loginItemDecided = true; uiStateSaveFailed = !services.saveUIState(st)`

**`openLoginItemSettings()`** = `services.openSystemSettingsLoginItems()`（`SMAppService.openSystemSettingsLoginItems()`）

- **`.requiresApproval` のときだけ**「システム設定を開く」ボタンを出す（PLAN §8.12 の 6）
- `register()` が成功しても状態が `.requiresApproval` になることがある（利用者の承認待ち）。エラーにしない

### 4.10 `Strings.swift` に足す文言（逐語）

| 名前 | 値 |
|---|---|
| `onboardingVault` | `Vault を選ぶ` |
| `onboardingWhisper` | `Whisper モデルを入手する` |
| `onboardingLLM` | `LLM を選んで入手する` |
| `onboardingLoginItem` | `ログイン時に起動する` |
| `onboardingDeviceName` | `デバイスの名前を変える` |
| `onboardingLater` | `今はしない` |
| `renameInstructions(_:)` | `<名前> という名前のデバイスがつながっています。VoiceDock はデバイスに一切書き込みません。次の手順で利用者が名前を変えてください。` ＋ 改行 ＋ `1. Finder のサイドバーでデバイスを選び、名前をゆっくり 2 回クリックして「DJIMIC3」などに変えます` ＋ 改行 ＋ `2. 変えたらデバイスを取り外して、もう一度つなぎ直してください` |
| `chooseVaultMessage` | `Obsidian の Vault のフォルダ（.obsidian があるフォルダ）を選んでください` |
| `chooseVaultPrompt` | `この Vault を使う` |
| `buttonChangeVault` | `変更…` |
| `vaultNotChosen` | `まだ選ばれていません` |
| `chooseGGUFMessage` | `読み込む .gguf ファイルを選んでください` |
| `chooseGGUFPrompt` | `読み込む` |
| `buttonImportGGUF` | `ファイルから読み込む…` |
| `buttonFetchModel` | `入手する` |
| `buttonCancelDownload` | `やめる` |
| `modelPresent` | `入手済み` |
| `modelAbsent` | `未入手` |
| `modelProgress(received:total:)` | `<x.x> GiB / <y.y> GiB`（`StatusTexts.gib`）。`total <= 0`（全体が不明）なら `<x.x> GiB` だけ |
| `labelWhisperModel` | `Whisper モデル` |
| `labelVADModel` | `VAD モデル` |
| `labelLLMModel` | `LLM モデル` |
| `vadDisabled` | `VAD は無効です（無音から幻覚が生成され、13 倍以上遅くなります）` |
| `llmNotSelected` | `選ばれていません` |
| `notEnoughMemory(required:actual:)` | `メモリが足りません（<required> GB 以上が必要。この Mac は <actual> GB）` |
| `customModelName(_:)` | `読み込んだモデル（<sha 先頭 8>）` |
| `customModelUnsupported` | `動作保証外のモデルです` |
| `labelLoginItem` | `ログイン時に起動` |
| `buttonOpenLoginItemSettings` | `システム設定を開く` |
| `loginItemRequiresApproval` | `システム設定で許可が要ります` |
| `loginItemNotFound` | `アプリの場所が不明です（/Applications に置いてから試してください）` |
| `uiStateSaveFailed` | `選択を記録できませんでした（<HOME>/ui-state.json に書けません）` |
| `configRejected(_:)` | `設定に書けませんでした: ` ＋ 違反の `rendered` を `"、"` でつないだもの |
| `modelError(_:)` | 下の表 |

`Strings.modelError(_ e: ModelError)`（逐語。PLAN §8.10 の `model_download_failed` の reason に対応）:

| `ModelError` | 文言 |
|---|---|
| `.badHost` | `配布元の URL が想定外です` |
| `.badFileName` | `ファイル名が使えません` |
| `.sha256Mismatch` | `SHA-256 が一致しません（壊れています。もう一度入手してください）` |
| `.sizeMismatch` | `サイズが一致しません（壊れています。もう一度入手してください）` |
| `.http(let code)` | `配布元が HTTP <code> を返しました` |
| `.network` | `ネットワークに接続できません` |
| `.cancelled` | `取り消しました` |
| `.io(let m)` | `ファイルを扱えません: <m>` |

### 4.11 4 つの節のビュー

`OnboardingSection`（§8.12 の 3）:
- `let items = OnboardingEvaluator.items(model.snapshot)`。`items.contains { $0.visible && !$0.done }` が偽なら `EmptyView()`
- `SectionBox(title: Strings.sectionOnboarding)` の中に、`visible` の項目を順に 1 行ずつ。`done` なら `checkmark.circle.fill`、未完了なら `circle`
- ④ の行に、未完了のときだけ `Button(Strings.onboardingLater) { Task { await model.dismissLoginItem() } }`
- ⑤ の行は `detail` を `Text` で複数行（`.fixedSize(horizontal: false, vertical: true)`）。**ボタンを置かない**（アプリは改名しない。DEV-10）

`VaultSection`（§8.12 の 4）:
- `SectionBox(title: Strings.sectionVault)`。1 行目にパス（`model.snapshot.vaultPath ?? Strings.vaultNotChosen`）と、`.available` でなければ `VaultStatus.message` を赤で
- `Button(Strings.buttonChangeVault) { Task { await model.chooseVault() } }`
- `model.vaultError` を出す

`ModelsSection`（§8.12 の 5）:
- `SectionBox(title: Strings.sectionModels)`
- Whisper: `labelWhisperModel` ＋ 表示名 ＋ `modelPresent` / `modelAbsent`。未入手なら `buttonFetchModel`、`downloads[.whisper]` が `.running` なら `ProgressView(value:)` と `modelProgress` と `buttonCancelDownload`
- VAD: 同じ形（`snapshot.vadEnabled` が偽なら `vadDisabled` を注意として出し、入手のボタンは出す）
- LLM: `Picker(Strings.labelLLMModel, selection:)` に `snapshot.llmChoices`。`选択` の変更で `model.selectLLM(id)`。
  `choice.selectable == false` の行は `.disabled(true)` にし、`choice.note` を同じ行に小さく出す（**一覧から消さない**）
- `Button(Strings.buttonImportGGUF) { Task { await model.importLLMFromFile() } }`
- 選択中の LLM が未入手なら `buttonFetchModel`、進行中なら進捗とキャンセル
- `model.modelError` / `model.modelNotice`

`GeneralSection`（§8.12 の 6）:
- `Toggle(Strings.labelLoginItem, isOn: Binding(get: { model.snapshot.loginItem == .enabled }, set: { on in Task { await model.setLoginItem(on) } }))`
- `snapshot.loginItem == .requiresApproval` のとき `Text(Strings.loginItemRequiresApproval)` と `Button(Strings.buttonOpenLoginItemSettings) { model.openLoginItemSettings() }`
- `snapshot.loginItem == .notFound` のとき `Text(Strings.loginItemNotFound)`
- `model.uiStateSaveFailed` なら `Text(Strings.uiStateSaveFailed)`

## 5. テスト

### 5.1 `UIStateTests.swift`（`@Suite("UIState")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `missingFileGivesDefaults` / 「ファイルが無ければ既定」 | 空の `TempDirectory` | `UIState(schema: 1, loginItemDecided: false)`、**ファイルを作らない** |
| `roundTrip` / 「書いて読める」 | `save(UIState(schema: 1, loginItemDecided: true))` → `load()` | `loginItemDecided == true` |
| `brokenJSONGivesDefaults` / 「壊れた JSON は既定」 | `"{"` を書く | 既定 |
| `futureSchemaGivesDefaults` / 「将来の schema は解釈しない」 | `{"schema": 2, "loginItemDecided": true}` | 既定（`loginItemDecided == false`） |
| `unknownKeysAreIgnored` / 「未知のキーは無視する」 | `{"schema":1,"loginItemDecided":true,"x":1}` | `loginItemDecided == true` |
| `savedFileHasOnlyTwoKeys` / 「書くのは 2 キーだけ」 | `save` の後に JSON を読む | 鍵集合が `["loginItemDecided", "schema"]` |
| `saveFailureReturnsFalse` / 「書けなければ false」 | 読み取り専用のディレクトリ（`chmod 0o500`） | `save == false`（投げない） |

### 5.2 `OnboardingTests.swift`（`@Suite("Onboarding")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `orderIsTheSpecOrder` / 「5 項目は PLAN の ①〜⑤ の順」 | 既定の `AppSnapshot` | `items.map(\.step) == [.vault, .whisperModel, .llmModel, .loginItem, .deviceName]` |
| `vaultDoneWhenAvailable` / 「Vault は .available で完了」 | `vault = .available` | ① が `done` |
| `vaultNotDoneWhenMarkerMissing` / 「目印が無ければ未完了」 | `vault = .missingMarker` | ① が未完了 |
| `whisperDoneNeedsVADWhenEnabled` / 「VAD 有効なら VAD も要る」 | `whisperPresent: true, vadEnabled: true, vadPresent: false` | ② 未完了 |
| `whisperDoneWithoutVADWhenDisabled` / 「VAD 無効なら Whisper だけで完了」 | `whisperPresent: true, vadEnabled: false, vadPresent: false` | ② 完了 |
| `llmNeedsSelectionAndFile` / 「LLM は選択と入手の両方」 | `llmModelID: "a", llmPresent: false` / `nil, true` | どちらも未完了 |
| `loginItemDoneWhenEnabled` / 「オンなら完了」 | `loginItem = .enabled` | ④ 完了 |
| `loginItemDoneWhenDecided` / 「今はしないでも完了」 | `loginItem = .notRegistered`、`uiState.loginItemDecided = true` | ④ 完了 |
| `deviceNameHiddenWithoutCandidates` / 「改名が要らなければ出さない」 | `renameCandidates = []` | ⑤ の `visible == false` |
| `deviceNameNeverDone` / 「⑤ は完了にならない」 | `renameCandidates = ["NO NAME"]` / `[]` | `["NO NAME"]` なら ⑤ の `visible == true`、`done == false`。`[]` でも `done == false`（破壊による証明 6 を落とすため） |
| `renameCandidatesFromBothMaps` / 「devices と unavailable の両方から集める」 | `devices: ["NO NAME": …]`、`unavailable: ["NO NAME": "invalid_device_id"]` | `["NO NAME"]`（重複なし） |
| `renameCandidatesIgnoreOtherNames` / 「NO NAME 以外は案内しない」 | `devices: ["DJIMIC3": …]` | `[]` |
| `completeWhenAllDone` / 「全部終われば節を出さない」 | 4 項目 done、`renameCandidates` 空 | `isComplete == true` |
| `emptySnapshotShowsFourItems` / 「TEST-28 何も無い観測」 | 既定 | `visible` が 4 件、すべて未完了 |

### 5.3 `ModelChoicesTests.swift`（`@Suite("ModelChoices")`）

カタログは `ModelCatalog.load` に §8.10 の JSON の抜粋（`verified` を差し替えたもの）を渡して作る。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `onlyVerifiedAreListed` / 「verified が真のものだけ出す」 | 2 件のうち 1 件が `verified: false` | 選択肢は 1 件 |
| `catalogOrderIsKept` / 「カタログの順のまま」 | 2 件 | `map(\.id)` がカタログの順 |
| `insufficientMemoryIsNotSelectable` / 「メモリ不足は選べない」 | `minMemoryGB: 32`、`physicalMemoryBytes = 16 GiB` | `selectable == false`、`note == メモリが足りません（32 GB 以上が必要。この Mac は 16 GB）` |
| `exactMemoryIsSelectable` / 「ちょうどなら選べる」 | `minMemoryGB: 16`、`16 GiB` ちょうど | `selectable == true`、`note == nil` |
| `noMinMemoryIsSelectable` / 「minMemoryGB が無ければ選べる」 | `minMemoryGB: nil`、`0` バイト（カタログの llm は `minMemoryGB` が必須なので、nil になる custom の行で見る） | `selectable == true` |
| `insufficientStaysInTheList` / 「選べなくても一覧から消さない」 | 全件メモリ不足 | 件数が減らない |
| `customIsAppendedLast` / 「custom は末尾に足す」 | `currentID = "custom:<64 hex>"` | 最後の要素が `isCustom`、`note == 動作保証外のモデルです` |
| `customNameShowsShortSHA` / 「custom の名前は SHA 先頭 8」 | 同上 | `読み込んだモデル（<先頭 8>）` |
| `customIsNotAddedForCatalogID` / 「カタログの ID では custom を足さない」 | `currentID = カタログの ID` | `isCustom` が 1 件も無い |
| `presenceFollowsTheFile` / 「在否はファイルの有無と size」 | `TempDirectory` に `bytes` ちょうどのファイルを置く / 置かない | `present` が真 / 偽 |
| `emptyCatalogGivesNoChoices` / 「TEST-28 空のカタログ」 | `llm: []` | `[]` |

（`ModelMemory.hasEnough` / `gb` そのものの単体テストは T-30 §4.10b が持つ。ここでは `llm()` が正しく呼んでいることだけを見る。）

### 5.4 `AppModelVaultTests.swift`（`@Suite("AppModel の Vault")`）

`FakeFolderChooser`（返す URL を差し替え）、`FakeServices`（T-30）を使う。実際の Vault は `TempDirectory` に `.obsidian/` を作って用意する。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `cancelChangesNothing` / 「取り消したら何もしない」 | chooser が nil | `updateConfig` が呼ばれない、`vaultError == nil` |
| `rejectsFolderWithoutMarker` / 「目印が無いフォルダは拒否する」 | `.obsidian` を作らない | `updateConfig` が呼ばれない、`vaultError == <path> に .obsidian/ がありません（Vault が未マウントか、別の場所を指しています）` |
| `rejectsUnreadableFolder` / 「読めないフォルダは拒否する」 | `chmod 0o000` のディレクトリ | `vaultError` が `を読めません（errno ` を含む、`updateConfig` が呼ばれない |
| `acceptsVaultAndWritesConfig` / 「目印が在れば設定に書く」 | `.obsidian/` 在り | `updateConfig` が 1 回、`vault.path` が選んだパス |
| `scansAfterChoosing` / 「選んだら走査を促す」 | 同上 | `fake.scanCount == 1` |
| `configRejectionIsShown` / 「設定に弾かれたら文言を出す」 | `updateConfig` が `.failure([v])` | `vaultError` が `設定に書けませんでした: ` で始まる |
| `closingClearsMessages` / 「閉じたら消える」 | 失敗の後 `panelDidClose()` | `vaultError == nil` |
| `directoryURLIsStoredWithoutTrailingSlash` / 「フォルダの URL の末尾の / を設定に書かない」 | chooser が `URL(fileURLWithPath: path, isDirectory: true)`（本番と同じ形）、`.obsidian/` 在り | `vault.path` が末尾に `/` の無い `path` |
| `directoryURLErrorHasNoTrailingSlash` / 「フォルダの URL でも文言に末尾の / を付けない」 | 同じ形の URL、`.obsidian` 無し | `vaultError == <path> に .obsidian/ がありません（…）`（`path` は末尾の `/` 無し） |
| `modalIsWrapped` / 「popover を閉じてから開き直す」 | `presentModal` の呼び出しを記録する偽物 | `presentModal` が 1 回呼ばれ、その中で chooser が呼ばれる |

### 5.5 `AppModelModelsTests.swift`（`@Suite("AppModel のモデル")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `fetchReportsProgress` / 「進捗を出す」 | `download` が `(1, 10)` `(5, 10)` を進捗に流してから成功 | 途中で `downloads[.whisper] == .running(received: 5, total: 10)`、終わりで `.idle` |
| `fetchIsNotStartedTwice` / 「二重に始めない」 | 進行中にもう一度 `fetchModel` | `download` の呼び出しは 1 回 |
| `fetchFailureShowsMessage` / 「失敗の文言」 | `.failure(.sha256Mismatch)` | `downloads[.whisper] == .failed(SHA-256 が一致しません（壊れています。もう一度入手してください）)` |
| `httpFailureShowsCode` / 「HTTP のコードを出す」 | `.failure(.http(404))` | `配布元が HTTP 404 を返しました` |
| `cancelStopsAndDoesNotShowError` / 「やめたらエラーにしない」 | 進行中に `cancelModel` → `download` が `.failure(.cancelled)` を返す | `downloads[.whisper] == .idle`、`modelError == nil`、`cancelDownload` が `entry.id` で 1 回 |
| `lateProgressAfterCancelIsDropped` / 「取り消し後の遅れた進捗を捨てる」 | `cancelModel` の後に進捗を流す | `downloads[.whisper]` は `.idle` のまま |
| `fetchRefreshesPresence` / 「入手の後に在否を読み直す」 | 成功 | `read` の回数が増える |
| `selectLLMWritesConfig` / 「選ぶと設定に書く」 | `llmChoices` に選べる 1 件 | `updateConfig` の変更後の `llm.modelID` が一致 |
| `selectLLMRejectsUnselectable` / 「選べないものは書かない」 | `selectable == false` の ID | `updateConfig` が呼ばれない |
| `selectLLMRejectsUnknownID` / 「一覧に無い ID は書かない」 | `"x"` | 同上 |
| `importSetsCustomID` / 「読み込んだら custom の ID を設定に書く」 | `importGGUF` が `("custom:<64 hex>", url)` | `updateConfig` の `llm.modelID` が同じ、`modelNotice == 動作保証外のモデルです` |
| `importFailureShowsMessage` / 「読み込みの失敗」 | `.failure(.io("EIO"))` | `ファイルを扱えません: EIO` |
| `importCancelChangesNothing` / 「ファイルを選ばなければ何もしない」 | `fileChooser` が nil | `importGGUF` が呼ばれない |
| `emptyChoicesDoNothing` / 「TEST-28 選択肢が 0 件」 | `llmChoices == []` | `selectLLM("a")` で `updateConfig` が呼ばれない |
| `fetchCanBeRetriedAfterFailure` / 「失敗の後にもう一度入手できる」 | 1 回目 `.failure(.network)`、2 回目成功 | 1 回目の後 `.failed(ネットワークに接続できません)`、2 回目で `download` が計 2 回・`.idle`・`modelError == nil` |
| `refetchRightAfterCancelShowsNoInternalText` / 「やめて直後に入手し直しても内部の文字列が出ない」 | 偽物は `ModelManager` と同じく、同じ ID の download が返る前の 2 本目を `.io("already_downloading")` で断る。1 本目を止めたまま `cancelModel` → すぐ `fetchModel` → 1 本目を `.failure(.cancelled)` で返す | `modelError == nil`、`downloads[.whisper] == .idle`、`download` が計 2 回 |
| `staleProgressDoesNotLeakIntoNewDownload` / 「古い progress が新しい枠に混ざらない」 | 1 本目をやめて返させた後、2 本目を止めたまま 1 本目の progress に `(9, 10)` を流す | `downloads[.whisper] == .running(received: 0, total: entry.bytes)` のまま |
| `progressNeverGoesBackwards` / 「進捗は小さくならない」 | progress に `(5, 10)` `(3, 10)` の順 | `.running(received: 5, total: 10)` |
| `importRejectedByConfigShowsMessage` / 「読み込んだ ID が設定に弾かれたら文言を出す」 | `importGGUF` 成功、`updateConfig` が `.failure([v])` | `modelError` が `設定に書けませんでした: ` で始まる、`modelNotice == nil` |
| `noticeIsClearedBySelectingOrClosing` / 「注意書きは選び直すか閉じると消える」 | 読み込み → `selectLLM`（選べる 1 件）／読み込み → `panelDidClose()` | どちらも `modelNotice == nil` |

### 5.6 `AppModelLoginItemTests.swift`（`@Suite("AppModel のログイン項目")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `turningOnRegisters` / 「オンで register」 | `setLoginItem(true)` | `registerLoginItem` が 1 回、`unregisterLoginItem` が 0 回 |
| `turningOffUnregisters` / 「オフで unregister」 | `setLoginItem(false)` | 逆 |
| `turningOnMarksDecided` / 「オンにしたら『はじめに』も完了にする」 | `setLoginItem(true)` | `saveUIState` に `loginItemDecided == true` |
| `laterMarksDecidedWithoutRegistering` / 「今はしないは登録しない」 | `dismissLoginItem()` | `saveUIState` が 1 回、`registerLoginItem` が 0 回 |
| `registerFailureIsShown` / 「失敗の文言をそのまま出す」 | `.failure("Operation not permitted")` | `loginItemError == "Operation not permitted"`、`saveUIState` は呼ばれない |
| `saveFailureIsShown` / 「記録できなければ知らせる」 | `saveUIState` が false | `uiStateSaveFailed == true` |
| `openSettingsIsForwarded` / 「システム設定を開く」 | `openLoginItemSettings()` | `openSystemSettingsLoginItems` が 1 回 |
| `requiresApprovalIsNotAnError` / 「承認待ちはエラーにしない」 | `register` は成功、その後 `status` が `.requiresApproval` | `loginItemError == nil` |

## 6. 破壊による証明

| # | 壊し方（1 か所） | 落ちるべきテスト |
|---|---|---|
| 1 | `UIStateStore.load` の `schema` の判定を消す | `futureSchemaGivesDefaults` |
| 2 | `UIStateStore.load` が読めないときに既定でない値（`loginItemDecided: true`）を返すようにする（`load()` は投げない型なので、投げる代わりに） | `missingFileGivesDefaults` |
| 3 | `OnboardingEvaluator.items` の ③ と ④ を入れ替える | `orderIsTheSpecOrder` |
| 4 | ② の条件から `vadPresent` を外す | `whisperDoneNeedsVADWhenEnabled` |
| 5 | ④ の条件から `uiState.loginItemDecided` を外す | `loginItemDoneWhenDecided` |
| 6 | ⑤ の `done` を `renameCandidates.isEmpty` にする | `deviceNameNeverDone` |
| 7 | `renameCandidates` が `unavailable` を見ないようにする | `renameCandidatesFromBothMaps` |
| 8 | `ModelChoices.llm` が `catalog.llm`（`listedLLMs` ではない）を使う | `onlyVerifiedAreListed` |
| 9 | `ModelChoices.llm` が `ModelMemory.hasEnough` の結果を反転して使う | `exactMemoryIsSelectable`・`insufficientMemoryIsNotSelectable` |
| 10 | 選べない選択肢を一覧から取り除く | `insufficientStaysInTheList` |
| 11 | `chooseVault` の `VaultCheck` の判定を消す | `rejectsFolderWithoutMarker`・`rejectsUnreadableFolder` |
| 12 | `chooseVault` の `scanNow()` を消す | `scansAfterChoosing` |
| 13 | `fetchModel` の二重起動の番人を外す | `fetchIsNotStartedTwice` |
| 14 | `cancelModel` の後に `.failed` を書くようにする | `cancelStopsAndDoesNotShowError` |
| 15 | `progress` の `guard case .running` を外す | `lateProgressAfterCancelIsDropped` |
| 16 | `selectLLM` の `selectable` の番人を外す | `selectLLMRejectsUnselectable` |
| 17 | `setLoginItem(true)` の `markLoginItemDecided()` を消す | `turningOnMarksDecided` |
| 18 | `register` が失敗しても `markLoginItemDecided()` するようにする | `registerFailureIsShown` |
| 19 | `OpenPanelFolderChooser` の `canCreateDirectories = true` にする | （自動テストでは落ちない）**受け入れ条件のチェックリストと `PanelPolicyTests`（§7）で守る** |
| 20 | `fetchModel` の結果を書く条件から世代の比較を外す | `refetchRightAfterCancelShowsNoInternalText` |
| 21 | `progress` の世代の比較を外す | `staleProgressDoesNotLeakIntoNewDownload` |
| 22 | `fetchModel` の「前の download を待つ」を外す | `refetchRightAfterCancelShowsNoInternalText` |
| 23 | `chooseVault` の末尾の `/` を落とす処理を消す | `directoryURLIsStoredWithoutTrailingSlash`・`directoryURLErrorHasNoTrailingSlash` |
| 24 | `fetchModel` の番人を `nil \|\| .idle` に戻す | `fetchCanBeRetriedAfterFailure` |

## 7. 受け入れ条件

- [ ] `make test` が通り、§5 の全テストが在る
- [ ] `make lint` が通る
- [ ] `PanelPolicyTests`（PolicyTests に 1 本足す）: `Sources/VoiceDockApp/` のコードに `canCreateDirectories = true` が無い（Vault も `.gguf` の選択も作らせない。DEL-06）
- [ ] PT-02（`URLSession` は VDModels だけ）が通る。**`VoiceDockApp` はダウンロードを自分で書かない**（`AppServices.download` 越しに VDModels を呼ぶだけ）
- [ ] PT-12（書き込み）が通る。VoiceDockApp が書くのは `UIStateStore.save` の `AtomicFile.write` だけ
- [ ] 「はじめに」の 5 項目が PLAN §8.12 の 3 の ①〜⑤ と逐語で一致する（`OnboardingTests` が固定）
- [ ] `ModelsSection` が `verified == false` のモデルを出さない（`ModelChoicesTests` が固定）
- [ ] 【利用者が行う】`.app` を作ってメニューバーから Vault を選び、`.obsidian` の無いフォルダを選ぶと拒否されることを目視する（E2E-01 の前段）

## 8. SPEC の変更

`docs/SPEC.md` に足す:

1. `## S22. はじめに（オンボーディング）` — `| # | 項目 | 完了の条件 |` の 3 列で ①〜⑤ を写す。`OnboardingTests` が SPEC から読んで `OnboardingStep.allCases` と件数・順を突き合わせる
2. `## S23. ui-state.json` — 鍵と型の表（`schema: 整数（1）`、`loginItemDecided: 真偽`）。`UIStateTests` が `savedFileHasOnlyTwoKeys` で突き合わせる

**実装の注記（T-31 の実装時）**: この節は T-31 の PR では実装していない。`docs/SPEC.md` は `tools/spec/make-spec.py` が PLAN から作る（手で直さない）もので、見出しの登録・`SpecDocument` の読み手はどれも T-05 の持ち物で §3 に無い。T-30 の S20 / S21 と同じく issue #18（SPEC 同期の拡張）に回す。当面は `OnboardingTests.orderIsTheSpecOrder` が 5 項目の順と題を、`UIStateTests.savedFileHasOnlyTwoKeys` が鍵を固定値で照合する

## 9. マージ後にやること

1. T-24（カタログの確定）のマージで `verified` が真になった LLM が `ModelsSection` に出ることを確かめる
2. README の一覧の T-31 の前提はそのまま（T-30・T-23）

## 10. API 地図への変更提案

1. §12 に `Onboarding.swift`（`OnboardingStep` / `OnboardingItem` / `OnboardingEvaluator`）、`ModelChoices.swift`（`LLMChoice` / `ModelChoices`）、`FolderChooser.swift`（`FolderChooser` / `FileChooser` / `OpenPanelFolderChooser` / `OpenPanelFileChooser`）、`DownloadState.swift`（`DownloadState` / `ModelSlot`）、`AppModel+Vault.swift` / `AppModel+Models.swift` / `AppModel+LoginItem.swift` を足す
2. §12 の `UIState.swift` を `UIState`（`schema` / `loginItemDecided`）と `UIStateStore`（`load` / `save`）にする
3. §12 の `LoginItem.swift` の `LoginItemControlling` に `register() -> LoginItemResult` / `unregister() -> LoginItemResult` / `openSystemSettings()` と `enum LoginItemResult { case success, failure(String) }` を足す（T-31。`Result<Void, String>` は String が `Error` でないのでコンパイルできない）
4. `ModelManager` の取り込みの口の名前は **T-23 が正**の `importCustomLLM(from:)`（`ModelImporter` を `layout` と `chunkBytes` 付きで呼ぶ包み）。`AppServices` 側の名前は `importGGUF(from:)` のままにする（UI の語） → 00-api-map §10 に反映済み（整合修正 M-5）
5. §10 の `ModelDownloader.download` の `progress` が `@escaping` であることを明記する（`AppServices.download` が転送するため）
7. （T-31 のレビュー）`ModelManager.download` が同じ ID の実行中に返す `.io(ModelDownloader.alreadyRunningMessage)` は、`alreadyRunningMessage` が internal で UI から見分けられず、そのまま出すと内部の文字列 `already_downloading` が利用者に見える。本チケットは VDModels に手を入れず、AppModel が枠ごとに前の download の Task を待ってから始めることで回避した。VDModels に `ModelError.alreadyRunning`（または `cancel(id:)` が download の終わりまで待つこと）を足し、§10 の行に載せたい
6. （整合修正 M-5）`ModelDownloader.init(layout:factory:log:hashChunkBytes:)` と `ModelManager.init(layout:catalog:downloader:cache:log:hashChunkBytes:)`（T-23 §4 が正。`clock:` は無い）を前提にする → 00-api-map §10 に反映済み

## 11. 仕様の問題（PLAN に直したいこと）

1. **§8.12 の 3 の「未完了の項目がある間だけ**最上部**に出す」と、同じ節の並び（1 状態 → 2 要対応 → 3 はじめに）が食い違う**。本チケットは並びを 3 のままにした（「要対応」の方が急ぎであるため）。PLAN のどちらかを直したい
2. **§8.12 の 3-⑤ の「デバイス名が `NO NAME` なら」だけが具体名で、§8.1 の規則 8・9（`mount_name_mismatch` / `invalid_device_id`）との関係が書かれていない**。本チケットは「`NO NAME` という名前が `devices` か `unavailable` に在れば出す」とし、規則 8・9 の一般の案内は「要対応」（T-32 の `deviceNeedsReplug` / `deviceNameInvalid`）に任せた
3. **「ファイルから読み込む」の後のメモリ確認が「警告だけ」とあるが、警告の文言が無い**。本チケットは `動作保証外のモデルです` だけを出し、メモリの数値は出さないことにした（custom は `minMemoryGB` が不明なため）
4. **`SMAppService.mainApp.status` が `.notFound` のときの案内が無い**。`.app` が `/Applications` に無いと起こる。文言 `loginItemNotFound` を新設した
5. **Whisper / VAD モデルの「入手」の口が §8.12 に無い**（§8.10 はダウンロードの仕組みだけ）。本チケットは「モデル」の節に `入手する` ボタンと進捗・キャンセルを置いた。PLAN §8.12 の 5 に Whisper / VAD の入手ボタンを明記したい
