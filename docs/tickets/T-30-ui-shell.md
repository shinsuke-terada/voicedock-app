# T-30 UI: メニューバーとパネルの骨組み・AppModel

> （F-65 でパネルをカード型に作り直した。2026-09-23、利用者の決定）主画面は**スクロールしない**。長い中身（元音声の削除・詳細と診断・要対応の多数・一般）は popover の中の別の画面（`PanelScreen`・`AppModel.show(_:)`。§4.11b）に切り替え、見出しに「‹ 戻る」を置く（`SubScreen`）。
> 高さは中身に合わせる（`NSHostingController.sizingOptions = .preferredContentSize`。固定の 640pt と `PanelStyle.maxHeight` をやめた。§4.6）。§4.13 のコードは F-65 の形に直した。主画面に ScrollView が無いことは `PanelLayoutPolicyTests` が固定する。

> （F-61 で共存ガードは外した。2026-09-22、利用者の決定）`CoexistenceGuard(...)` の注入・`StatusLine` の最優先の分岐・`Strings.statusCoexistenceBlocked`・`coexistenceWinsOverEverything` は外した。以下の本文の共存ガードの記述は記録として残す。

| 項目 | 内容 |
|---|---|
| ID | T-30 |
| Phase | 7（UI と配布） |
| 前提 | T-29（`Worker` の全段が揃い `stageRefreshVaultIndex` まで動く）。間接に T-09（`ConfigStore` が読む `AppConfig`・`ModelCatalog`）、T-10（`AppLog`・`AppPaths`・`SystemClock`・`ZonedTime`）、T-11（`Store`・`ReadOnlyStore`）、T-12（`ProcessRunner`）、T-15（`IngestService`・`DeviceSnapshot`・`IngestActivity`）、T-18（`WorkerDependencies`・`WorkerStatus`・`PauseReason`）、T-21（`LlamaServerSupervisor`）、T-28（`VaultCheck`） |
| 見積もり | 本体 約 1,150 行（うち SwiftUI 約 300 行）、テスト 約 700 行 |

## 1. 目的

メニューバーのアイコンとパネル（`NSStatusItem` ＋ `NSPopover` ＋ SwiftUI）という**唯一の画面**（D-7）を作り、
本番の依存を 1 か所（`Bootstrap`）で組み立て、UI が見る唯一の値である `AppModel` を作る。
**見た目はテストしない。`AppModel` が計算する状態と、`AppModel` が行う操作はすべて単体テストする。**

後続のチケットが中身を書く節（「はじめに」「保存先」「モデル」「一般」= T-31、「元音声の削除」= T-40、「詳細」と「要対応」= T-32）は、
**空のビューと 1 行のコメントだけ**をこのチケットで置く（T-18 の「空の段」と同じやり方）。

## 2. 参照

- PLAN §8.12（UI の全体・アイコン・パネルの 9 節・状態の 1 行）、§8.15（起動・終了・スリープ・アイドル時の CPU）、§6.3（GUI に出すのは 4 つだけ）、§8.11（要対応。アイコンの優先順位だけここで使う）、§8.9.8（`trash` の常時表示）、§11.1（`.app` の組み立てと `LSUIElement`）、§2.3（`<HOME>` の配置）、§5.4（Worker のループ・ガード）、付録 A.4（`service_stopping`）
- 00-api-map.md §12（`VoiceDockApp` のファイル）、§11（`ConfigStore`・`Worker`・`WorkerStatus`・`PauseReason`）、§5（`IngestService`）、§3（`Store` / `ReadOnlyStore`）、§0（全体の約束）
- 先行チケット: T-18 §4.5（`WorkerActivity`）・§4.8（`Worker`）、T-15 §4.2（`DeviceSnapshot` / `IngestActivity`）
- **後続**チケット（本チケットが空けた場所を埋める側）: T-32 §4.10（`Bootstrap` の `locks` と `diagnostics`・`AppModel` への追加）、T-36 §4.9（`Bootstrap` の `LockEvaluator` への差し替え）、T-41 §4.4（`AppModel` への追加）
- voicedock@d3d595e: `src/voicedock/status.py:326-348`（未処理の 1 行）、`src/voicedock/status.py:175-194`（観測の表示語）

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VoiceDockApp/main.swift` | 入口（T-01 の仮置きを置き換える） |
| `Sources/VoiceDockApp/AppDelegate.swift` | `AppDelegate`（起動手順・終了の `.terminateLater`） |
| `Sources/VoiceDockApp/Bootstrap.swift` | `AppContext`、`BootFailure`、`Bootstrap` |
| `Sources/VoiceDockApp/StatusItemController.swift` | `StatusItemController` |
| `Sources/VoiceDockApp/StatusIconImage.swift` | `StatusIconImage`（アイコンの合成） |
| `Sources/VoiceDockApp/IconState.swift` | `IconState` |
| `Sources/VoiceDockApp/AppSnapshot.swift` | `AppSnapshot`（`BacklogCounts` は T-32 が VDPipeline の `StatusReport.swift` に移した。T-32 §4.9） |
| `Sources/VoiceDockApp/AppServices.swift` | `AppServices`（プロトコル）、`LiveServices` |
| `Sources/VoiceDockApp/AppModel.swift` | `@MainActor @Observable final class AppModel` |
| `Sources/VoiceDockApp/StatusLine.swift` | `StatusLine`（1 行の文言の計算。純関数） |
| `Sources/VoiceDockApp/Strings.swift` | 文言（逐語） |
| `Sources/VoiceDockApp/Panel/PanelView.swift` | `PanelView`（9 節の並び） |
| `Sources/VoiceDockApp/Panel/StatusSection.swift` | `StatusSection`（§8.12 の 1） |
| `Sources/VoiceDockApp/Panel/AttentionSection.swift` | 空（T-32） |
| `Sources/VoiceDockApp/Panel/OnboardingSection.swift` | 空（T-31） |
| `Sources/VoiceDockApp/Panel/VaultSection.swift` | 空（T-31） |
| `Sources/VoiceDockApp/Panel/ModelsSection.swift` | 空（T-31） |
| `Sources/VoiceDockApp/Panel/GeneralSection.swift` | 空（T-31） |
| `Sources/VoiceDockApp/Panel/DeletionSection.swift` | 空（T-40） |
| `Sources/VoiceDockApp/Panel/DetailsSection.swift` | 空（T-32） |
| `Sources/VoiceDockApp/Panel/PanelStyle.swift` | 幅・余白・カードの体裁（`SectionBox`）・状態の色（F-65） |
| `Sources/VoiceDockApp/PanelScreen.swift` | （F-65）`enum PanelScreen`（パネルの中の 5 つの画面） |
| `Sources/VoiceDockApp/AppModel+Navigation.swift` | （F-65）`AppModel.show(_:)`（§4.11b） |
| `Sources/VoiceDockApp/Panel/SubScreen.swift` | （F-65）別の画面の枠（「‹ 戻る」と題。中身が長いときだけスクロール） |
| `Sources/VoiceDockApp/Panel/PanelRow.swift` | （F-65）押すと別の画面へ移る 1 行 |
| `Sources/VDPipeline/StatusTexts.swift` | 未処理の 1 行・観測の表示語・GiB の整形（T-32 の `StatusReporter` と共有） |
| `Sources/VDCore/ModelMemory.swift` | `ModelMemory`（メモリの条件。T-31 の `Picker` と T-32 の DR-08 が共有。§4.10b） |
| `Sources/VoiceDockApp/LoginItem.swift` | `LoginItemControlling`、`SystemLoginItem`（このチケットは `status()` だけ。操作は T-31 が足す） |
| `Sources/VDPipeline/Diagnostics/LoginItemStatus.swift` | `LoginItemStatus`（T-32 の `Diagnostics` が使う。§4.14） |
| 変更 `Sources/VDPipeline/ErrorText.swift` | `ErrorText` を `public` にする（T-18 が internal で作った。§4.0） |
| `Tests/VoiceDockAppTests/AppModelTests.swift` | |
| `Tests/VoiceDockAppTests/StatusLineTests.swift` | |
| `Tests/VoiceDockAppTests/IconStateTests.swift` | |
| `Tests/VoiceDockAppTests/FakeServices.swift` | `AppServices` の偽物（`VoiceDockAppTests` の中だけ。TestSupport には置かない） |
| `Tests/VoiceDockAppTests/BootstrapTests.swift` | 起動の順（`Bootstrap.startServices`。§4.2 の 15） |
| `Tests/VoiceDockAppTests/StringsTests.swift` | `Strings` の全項目を §4.12 の表と逐語で固定する（§7 の受け入れ条件） |
| `Tests/VoiceDockAppTests/AppModelNavigationTests.swift` | （F-65）画面の切り替えと状態の詳細の読み書き（§5.5） |
| `Tests/VoiceDockAppTests/PanelPartsTests.swift` | （F-65）要対応の件数の切り方・Vault の名前・状態の色（§5.6） |
| `Tests/PolicyTests/PanelLayoutPolicyTests.swift` | （F-65）主画面（`PanelView.swift`）に ScrollView・List・Form が無く、パネルで ScrollView を使うのは `SubScreen.swift` だけ（§5.7） |
| `Tests/VDPipelineTests/StatusTextsTests.swift` | |
| `Tests/VDCoreTests/ModelMemoryTests.swift` | §4.10b |

**削除**: `Sources/VoiceDockApp/ModuleMarker.swift` は無い（T-01 は `main.swift` にコメントだけ置いた）。その `main.swift` を置き換える。T-01 の目印 `Tests/VoiceDockAppTests/TargetMarker.swift` は消す（実ファイルが入ったため）。

## 4. 仕様

### 4.0 全体の規則

- `import` は Foundation, AppKit, SwiftUI, ServiceManagement, os と VD モジュール（§3.4）。`VoiceDockApp` は実行ファイルなので宣言は `internal` でよい（`public` を付けない）
- **例外の文言は `ErrorText.describe(_:)`**（`"<型名>: <説明>"`）。T-18 はこれを VDPipeline の internal にしているので、**このチケットで `public` にする**（§10 の提案 9）。VoiceDockApp に同じ整形を書き直さない（CR-06）
- **UI は `AppModel` しか見ない。**ビューから `ConfigStore` / `Store` / `Worker` / `IngestService` を直接触らない（PLAN §8.12 の最後の箇条）
- `AppModel` の**導出値はすべて計算プロパティか純関数**にする（状態を 2 か所に持たない。CR-06）。テストは純関数を直接呼ぶ
- 文言は `Strings`（VoiceDockApp）と `StatusTexts`（VDPipeline。VDPipeline 側も使うもの）だけに書く。ビューに文字列リテラルを書かない
- `print` は使わない（PT-08）。`Date()` は使わない（PT-09。時刻は `AppSnapshot.now`）

---

### 4.1 `main.swift`

```swift
// VoiceDock アプリの入口（PLAN §8.12 / §8.15）。SwiftUI の App ではなく AppKit のライフサイクルを自分で回す
// （MenuBarExtra はプログラムから開けないため。PLAN §8.12）。
import AppKit

let appDelegate = AppDelegate()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)  // Dock に出ない（Info.plist の LSUIElement と二重に効かせる）
application.delegate = appDelegate
application.run()
```

- トップレベルの `let appDelegate` がデリゲートを保持する（`NSApplication.delegate` は弱参照）
- このファイルに他の宣言を置かない（トップレベルのコードが書けるのは `main.swift` だけ）

---

### 4.2 `Bootstrap.swift`

```swift
// 本番の依存を組み立てる唯一の場所（PLAN §8.15 の起動手順）。ここ以外で本番の実装を new しない。
import AppKit
import Foundation
import VDContract
import VDCore
import VDDevice
import VDLLM
import VDModels
import VDPipeline
import VDProcess
import VDStore

/// 起動でできた長生きの部品。AppDelegate と LiveServices が持つ。
@MainActor
final class AppContext {
    let layout: HomeLayout
    let paths: AppPaths
    let clock: any AppClock
    let log: AppLog
    let catalog: ModelCatalog
    let config: ConfigStore
    let store: Store
    let runner: ProcessRunner
    // locks は本チケットでは持たない（T-32 が `locks: any LockObserving` と `diagnostics: DiagnosticsDependencies` を足し、T-36 が LockEvaluator に替える）
    let llama: LlamaServerSupervisor
    let ingest: IngestService
    let worker: Worker
    let models: ModelManager
    let loginItem: any LoginItemControlling
    /// Worker.run() を回しているタスク（終了で待つ）
    var workerTask: Task<Void, Never>?
    init(…上の順に全フィールド…)
}

/// 起動できなかった理由（パネルを出さずに知らせて終わる。設定エラーはここに来ない）。
enum BootFailure: Error, Equatable {   // Result の Failure なので Error に準拠する
    case directories(String)      // HomeLayout.createDirectories() が投げた
    case catalog(String)          // バンドルの ModelCatalog.json が読めない
    case database(String)         // Store(url:clock:zone:) が投げた
    var message: String { get }   // Strings.bootFailure(…)
}

enum Bootstrap {
    static let useMountPoint = false
    /// os.Logger の subsystem（= BUNDLE_ID。identity.env と同じ値）。T-36 が AppIdentity.bundleID に替える
    static let logSubsystem = "io.github.shinsuke-terada.VoiceDock"
    /// 本番の組み立て。PLAN §8.15 の順に行う。
    @MainActor static func build() async -> Result<AppContext, BootFailure>
    /// 起動の順（15）。復旧を待ってから Worker のループを作り、最後に走査を始める。戻り値は run() のタスク
    static func startServices(
        workerStart: @escaping @Sendable () async -> Void,
        workerRun: @escaping @Sendable () async -> Void,
        ingestStart: @escaping @Sendable () async -> Void
    ) async -> Task<Void, Never>
}
```

**`build()` の手順**（この順。番号は PLAN §8.15 の起動手順に対応する）:

1. `let layout = HomeLayout.production()`、`let paths = AppPaths.fromMainBundle()`
2. `<HOME>` と下位ディレクトリ: `do { try layout.createDirectories() } catch { return .failure(.directories(ErrorText.describe(error))) }`（`bin/` は作らない）
3. カタログ: `do { catalogData = try Data(contentsOf: paths.modelCatalog) } catch { return .failure(.catalog(ErrorText.describe(error))) }` → `switch ModelCatalog.load(catalogData) { case .success(let c): catalog = c; case .failure(let e): return .failure(.catalog(ErrorText.describe(e))) }`（`try?` で理由を捨てない）
4. 時計とログ（**設定を読む前のログは既定のレベルで出す**）:
   - `let clock: any AppClock = SystemClock()`
   - `let bootZone = ZonedTime(timeZone: TimeZone.current)`
   - `let sink = TeeSink([OSLogSink(subsystem: logSubsystem), LogFile(url: layout.appLog)])`（`TeeSink` の init は T-10 の `init(_ sinks: [any LogSink])`。`AppIdentity` は T-36 が作るので、ここでは `Bootstrap.logSubsystem` の文字列を使う。T-36 §4 の「os.Logger の subsystem が文字列で書かれていれば `AppIdentity.bundleID` に替える」が拾う）
   - `var log = AppLog(sink: sink, level: .info, unsafeContent: false, zone: bootZone, clock: clock, category: "app")`
5. 子プロセス: `let runner = ProcessRunner()`
6. **ロックの評価器はまだ作らない**（Phase 8 の T-36 が `LockEvaluator` をここに入れる。T-36 §4.9）。本チケットは Phase 7 の型だけで組む: `LockEvaluator`・`CodeSignatureVerifier`・`ReaperSignature`・`SystemVolumeOpener` を**使わない**
7. 設定: `let config = ConfigStore(layout: layout, catalog: catalog, log: log.withCategory("pipeline"), observeReaperConf: { .missing })` → `let loaded = await config.load()`（無ければ既定を書く）
   - 引数は 00-api-map §11 の `ConfigStore.init(layout:catalog:log:observeReaperConf:)`（T-18 §4.2）。**`reaperConf` という語のラベルを使わない**（PT-11）
   - `observeReaperConf: { .missing }` は T-18 §11 の想定どおりの Phase 7 の形。T-36 が `{ await locks.observeReaperConf() }` に替える
8. ログを設定で作り直す（**ここから後のログだけが設定のレベルに従う**）:
   `if case .valid(let c) = loaded { log = AppLog(sink: sink, level: LogLevel(configValue: c.logging.level) ?? .info, unsafeContent: c.logging.unsafeLogContent, zone: ZonedTime(timeZone: TimeZone(identifier: c.timeZone) ?? .current), clock: clock, category: "app") }`
9. DB: `let store: Store`。`do { store = try Store(url: layout.database, clock: clock, zone: zone) } catch { return .failure(.database(ErrorText.describe(error))) }`
   （`zone` は 8 で作ったもの。設定が無効なら `ZonedTime(timeZone: .current)`）
10. LLM: `let llama = LlamaServerSupervisor(runner: runner, paths: paths, layout: layout, clock: clock, sleeper: TaskSleeper(), log: log.withCategory("llm"), factory: EphemeralSessionFactory())`
11. 取り込み:
    ```swift
    let ingest = IngestService(deps: IngestDependencies(
        layout: layout,
        configProvider: { await config.current() },
        store: store,
        inspector: SystemMountInspector(),
        remounter: DiskutilRemounter(runner: runner, inspector: SystemMountInspector(), useMountPoint: Bootstrap.useMountPoint),
        mountEvents: WorkspaceMountEventSource(),
        reader: DeviceReader(),
        coexistence: CoexistenceGuard(runner: runner, uid: getuid()),
        clock: clock, sleeper: TaskSleeper(), zone: zone,
        log: log.withCategory("device"), volumesRoot: Contract.volumesRoot))
    ```
    `static let useMountPoint = false`（P0-02 で確定。実機では `-mountPoint` が使えない。`docs/POC.md` 章 3）
12. Worker（`verificationCache` は 14 のモデルと共有するので先に名前を付ける。**`WorkerDependencies` にはまだ `verificationCache` のフィールドが無い**（誰が足すかは未決。§10 の 11）ので、T-30 では渡さず 14 の `ModelManager` にだけ渡す）:
    ```swift
    let verificationCache = ModelVerificationCache()
    let worker = Worker(deps: WorkerDependencies(
        layout: layout, paths: paths, store: store, config: config, ingest: ingest,
        runner: runner, llama: llama,
        chatTransportFactory: { handle, cfg in LoopbackChatTransport(endpoint: handle.endpoint, apiKey: handle.apiKey, modelID: handle.modelID, config: cfg, factory: EphemeralSessionFactory()) },
        clock: clock, sleeper: TaskSleeper(), log: log.withCategory("pipeline"),
        license: AlwaysAllowLicenseGate(), catalog: catalog,
        // verificationCache: verificationCache,   ← フィールドが足されたら渡す（§10 の 11）
        physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory))
    ```
    **末尾の `importedKeys`（T-33）・`locks`・`volumeOpener`（T-36）はまだ渡さない**（00-api-map §11 の `WorkerDependencies` の行が足す順の正。T-18 の並び → T-33 の `importedKeys` → T-36 の `locks` と `volumeOpener`）
13. ロック 1 の修復をつなぐ: `await config.setLock1Reconciler { await enabler.reconcileLock1() }`（`enabler` は T-40 が作る。**このチケットでは行 1 行のコメントだけ置き、T-40 が本体を書く**）
14. モデル（引数は 00-api-map §10 ＝ T-23 §4 のとおり。`clock:` は無い）:
    ```swift
    let hashChunkBytes = (loadedConfig?.audio.hashChunkBytes) ?? AppConfig.defaults(timeZone: "UTC").audio.hashChunkBytes
    let downloader = ModelDownloader(layout: layout, factory: EphemeralDownloadSessionFactory(),
                                     log: log.withCategory("models"), hashChunkBytes: hashChunkBytes)
    let models = ModelManager(layout: layout, catalog: catalog, downloader: downloader,
                              cache: verificationCache, log: log.withCategory("models"), hashChunkBytes: hashChunkBytes)
    ```
    `verificationCache` は 12 の `WorkerDependencies` に渡したのと**同じ** `ModelVerificationCache`（診断と共有する。00-api-map §2.2）。`loadedConfig` は 8 の `.valid(let c)` の `c`（無ければ既定値）。**このチケットでは `ModelManager` を作るところまで**
15. `let ctx = AppContext(…)`。`ctx.workerTask = await startServices(workerStart: { await worker.start() }, workerRun: { await worker.run() }, ingestStart: { await ingest.start() })`
    - `startServices` の本体: `await workerStart()` → `let task = Task { await workerRun() }` → `await ingestStart()` → `return task`
16. `return .success(ctx)`

- **Phase 8 で T-36 が差し替えるところ**（T-36 §4.9。本チケットでは書かない）: 6 に `LockEvaluator` を作る行、7 の `observeReaperConf`、12 の末尾の `locks`・`volumeOpener`。本チケットの Bootstrap は `VDPipeline` の削除まわりの型（`LockEvaluator`・`SignatureVerifier`・`ReaperSignature`・`VolumeOpener`）を 1 つも参照しない
- **順序の理由**: `Worker.start()`（復旧）を `IngestService.start()`（走査）より先に**終える**（PLAN §8.15）。`Task { await worker.run() }` を作っただけでは、Task の開始順が保証されないので `run()` 先頭の `start()` が走査より先に走るとは限らない。だから `await worker.start()` を先に済ませる。`run()` 先頭の 2 回目の `start()` は 1 回目の完了を待って即座に戻る（T-18 §4.8）
- 順序を偽物で固定できるよう、15 は `startServices`（internal。3 つのクロージャを受ける）に切り出す（`BootstrapTests`）
- T-23 はマージ済みなので `EphemeralDownloadSessionFactory` と `ModelManager` はある。`AppContext.models` は `ModelManager`（Optional にしない）
- 14 の `hashChunkBytes` の行は 120 桁を超えるので `let hashChunkBytes =` の後で改行する（swift-format）

---

### 4.3 `AppDelegate.swift`

```swift
// アプリのライフサイクル（PLAN §8.15）。起動・パネルの生成・終了。
import AppKit
import VDCore
import VDPipeline
import VDProcess

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var context: AppContext?
    private var model: AppModel?
    private var statusItem: StatusItemController?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply
    /// パネルの「終了」ボタンから呼ぶ
    func requestTerminate()

    static let terminateTimeout: Duration = .seconds(10)
    static let terminateKillGrace: Duration = ProcessRunner.killGrace   // 同じ値を 2 か所に書かない（CR-06。import VDProcess）
}
```

**`applicationDidFinishLaunching`**:
1. `Task { @MainActor [weak self] in`（中の `quit:` の `[weak self]` と揃える。外側が暗黙の強参照だと Swift 6.4 は `ImplicitStrongCapture` でエラーにする）
2. `switch await Bootstrap.build()`:
   - `.failure(let f)`: `NSApp.activate()`（アクセサリのアプリは前面に出ていないので、警告が背面に隠れないように）→ `NSAlert` を出す（`messageText = Strings.bootFailureTitle`、`informativeText = f.message`、ボタン `Strings.ok`）→ `runModal()` → `NSApp.terminate(nil)`
   - `.success(let ctx)`: **すぐに `self?.context = ctx`**（以降の組み立ての途中で終了が来ても `applicationShouldTerminate` が部品を止められるように）→ 続ける
3. `let model = AppModel(services: LiveServices(context: ctx), openFinder: NSWorkspaceFinder(), layout: ctx.layout, now: ctx.clock.now(), quit: { [weak self] in self?.requestTerminate() })`（§4.11 の init。`layout` は Finder に渡す URL の元、`now` は最初の `AppSnapshot` の時刻）
4. `let controller = StatusItemController(model: model)`
5. `model.start()`（購読と最初の `refresh()` を始める）
6. `if await ctx.config.didCreateDefaults() { controller.open() }`（**初回起動だけ自動で開く**。PLAN §8.12）
7. `self?.model = model; self?.statusItem = controller`（`context` は 2 で持った）
8. `}`

- 2 で失敗したときは `StatusItemController` を作らない（アイコンの出ないゾンビにしない）

**`applicationShouldTerminate(_:)`**（PLAN §8.15 の終了）:
1. `if terminating { return .terminateCancel }`（`reply` を待つ間の 2 度目は取り消す。1 度目の後始末が終われば `reply` で終了する）
2. `terminating = true`
3. `guard let ctx = context else { return .terminateNow }`
4. `Task { @MainActor in`
   1. `await ctx.worker.requestStop()`（新しい工程を始めない。`service_stopping` はここで 1 回出る）
   2. `await ctx.ingest.stop()`
   3. `await ctx.llama.stop()`
   4. `await ctx.runner.terminateAll(grace: Self.terminateKillGrace)`（**実行中の子プロセスをプロセスグループごと**。PLAN §8.2）
   5. `if let t = ctx.workerTask { _ = await withTimeout(Self.terminateTimeout) { await t.value } }`（**最大 10 秒**）
   6. `NSApp.reply(toApplicationShouldTerminate: true)`
   5. `}`
5. `return .terminateLater`

- `withTimeout(_:_:) -> Bool`（このファイルの private な自由関数）: 「本体」と「`try? await Task.sleep(for: timeout)`」を**構造化しないタスク 2 つ**で競わせ、先に `AsyncStream`（`bufferingOldest(1)`。最初に流れた方を残す）へ流した方で抜ける（本体が先なら真）。**`withTaskGroup` は使わない**: グループは抜ける前に子の終わりを待ち、`await t.value` は取り消しに応じないので、時間切れにならない。**待ち切れなくても終了する**（中途の状態は次回起動の復旧が戻す。PLAN §5.3）
- **`beginActivity` との関係**: スリープの抑止は `Worker` が持つ（`ActivityBoard` → `ProcessInfoSleepAssertion`。T-18 §4.7）。AppDelegate は何も足さない。
  `requestStop()` で tick が中断した場合は `board.set(.idle)` が呼ばれず（T-18 §4.8）トークンが残るが、**プロセスの終了でトークンは消える**ので追加の後始末をしない。
  `.suddenTerminationDisabled` を持っている間も `NSApp.terminate` による通常の終了は妨げられない（突然の終了だけを止めるオプションである）
- `requestTerminate()`: `NSApp.terminate(nil)` を呼ぶだけ

---

### 4.4 `IconState.swift`

```swift
// メニューバーのアイコンの状態（PLAN §8.12 の表）。値と記号の対応をここだけに持つ。
enum IconState: String, Equatable, CaseIterable, Sendable {
    case idle, ingesting, processing, attention

    var symbolName: String {
        switch self {
        case .idle: "waveform"
        case .ingesting: "arrow.down.circle"
        case .processing: "text.bubble"
        case .attention: "exclamationmark.triangle"
        }
    }
    static let trashSymbolName = "trash"

    /// PLAN §8.12「要対応あり（上の 3 つより優先）」。
    static func compute(hasAttention: Bool, ingesting: Bool, processing: Bool) -> IconState {
        if hasAttention { return .attention }
        if ingesting { return .ingesting }
        if processing { return .processing }
        return .idle
    }
}
```

| 状態 | シンボル | 条件（`AppSnapshot` から） |
|---|---|---|
| `attention` | `exclamationmark.triangle` | `hasAttention`（T-32 が要対応から立てる。T-30 では常に偽） |
| `ingesting` | `arrow.down.circle` | `ingestActivity.scanning` |
| `processing` | `text.bubble` | `worker.activity != .idle` |
| `idle` | `waveform` | 上のどれでもない |

---

### 4.5 `StatusIconImage.swift`

```swift
// メニューバーに出す画像（PLAN §8.12 のアイコン ＋ §8.9.8 の trash の常時表示）。
import AppKit

enum StatusIconImage {
    static let pointSize: CGFloat = 16
    static let height: CGFloat = 18
    static let gap: CGFloat = 3

    /// state の記号 1 つ、showsTrash なら右に trash を並べた 1 枚のテンプレート画像を作る。
    static func make(state: IconState, showsTrash: Bool) -> NSImage
}
```

**`make` の手順**:
1. `let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)`
2. `guard let main = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: Strings.iconDescription(state))?.withSymbolConfiguration(config) else { return NSImage() }`
3. `showsTrash == false` → `main.isTemplate = true`、`return main`
4. `guard let trash = NSImage(systemSymbolName: IconState.trashSymbolName, accessibilityDescription: Strings.iconTrashDescription)?.withSymbolConfiguration(config) else { main.isTemplate = true; return main }`
5. `let width = main.size.width + gap + trash.size.width`
6. `let composed = NSImage(size: NSSize(width: width, height: height))`、`composed.lockFocus()` → `main` を `(0, (height - main.size.height)/2)` に、`trash` を `(main.size.width + gap, (height - trash.size.height)/2)` に `draw(at:from:operation: .sourceOver, fraction: 1)` → `unlockFocus()`
7. `composed.isTemplate = true`、`return composed`

- **1 つの `NSStatusItem` に 2 つの記号を並べる**（`NSStatusItem` を 2 つ作らない）。2 つ作ると他のアプリの項目が間に入り、「隣に出す」という約束（PLAN §8.9.8）が守れないため
- テンプレート画像にする（ダークモード・メニューバーの色に自動で合う。PLAN §8.12）

---

### 4.6 `StatusItemController.swift`

```swift
// メニューバーの項目とパネル（PLAN §8.12）。MenuBarExtra を使わない（プログラムから開けないため）。
import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover: NSPopover
    private let model: AppModel
    private var iconObserver: Task<Void, Never>?
    private var reopenAfterModal = false

    init(model: AppModel)
    func open()
    func close()
    /// NSOpenPanel など modal を出す前後で使う（PLAN §8.12「popover が閉じたら、終わった後に開き直す」）。
    func runModal<T>(_ body: @MainActor () -> T) -> T
    @objc private func toggle(_ sender: Any?)
}
```

**`init(model:)`**:
1. `item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)`
2. `popover = NSPopover()`、`popover.behavior = .transient`、`popover.animates = false`、
   `let hosting = NSHostingController(rootView: PanelView(model: model))`、`hosting.sizingOptions = .preferredContentSize`、`popover.contentViewController = hosting`（**F-65**: 高さは中身に合わせる。`popover.contentSize` を設定しない。以前は高さ 1 と `frame(maxHeight:)` の組み合わせで ScrollView が自分の高さを持たず popover が 1pt に潰れた（PR #100）ので 640pt に固定していたが、主画面から ScrollView を外し、別の画面の ScrollView は中身を測った高さを持つので潰れない）
3. `super.init()`、`popover.delegate = self`
4. `item.button?.target = self`、`item.button?.action = #selector(toggle(_:))`、`item.button?.setButtonType(.momentaryChange)`
5. `applyIcon()` を 1 回呼ぶ
6. `iconObserver = Task { @MainActor [weak self] in for await _ in model.iconChanges { self?.applyIcon() } }`

`applyIcon()`: `item.button?.image = StatusIconImage.make(state: model.iconState, showsTrash: model.showsTrash)`、`item.button?.toolTip = model.statusLine`

**`toggle(_:)`**: `popover.isShown ? close() : open()`

**`open()`**:
1. `guard let button = item.button else { return }`
2. `model.panelDidOpen()`
3. `popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)`
4. `NSApp.activate()`（パネルの操作に最初のクリックから反応させるため。PLAN §8.12。`Menu`・トグル・長押しのボタンが効かなくなるのを防ぐ）

**`close()`**: `popover.performClose(nil)`（`popoverDidClose` が `model.panelDidClose()` を呼ぶ）

**`runModal(_:)`**（`NSOpenPanel` などを出す唯一の入口）:
1. `let wasShown = popover.isShown`
2. `if wasShown { reopenAfterModal = true; popover.performClose(nil) }`
3. `let result = body()`
4. `if reopenAfterModal { reopenAfterModal = false; open() }`
5. `return result`

- `popoverDidClose(_:)`（`NSPopoverDelegate`）: `model.panelDidClose()`。`reopenAfterModal` はここで消さない（3 の後に 4 で開き直す）
- `.transient` の popover は、`NSOpenPanel` を出すと自動で閉じる。`runModal` を通さずに modal を出さない（T-31 / T-40 もこれを使う）

---

### 4.7 `AppSnapshot.swift`

```swift
// パネルが見る観測の写し（PLAN §8.12「AppModel は … から来る値の写し」）。値だけで、I/O もアクターも持たない。
import Foundation
import VDContract     // AppVersion
import VDCore
import VDDevice
import VDNotes
import VDPipeline

// BacklogCounts（count / seconds / unknownDuration / empty）は VDPipeline の StatusReport.swift（T-32 §4.9 で移した。public）

struct AppSnapshot: Equatable, Sendable {
    var now: Instant
    /// 設定が読めているか（偽 = 設定エラー状態。PLAN §6.1）
    var configPresent: Bool = false
    var configViolations: [ConfigViolation] = []
    var timeZone: String = TimeZone.current.identifier
    var ingestState: IngestState = .idle
    var ingestActivity: IngestActivity = .idle
    var device: DeviceSnapshot? = nil
    /// devices が空でない snapshot を最後に見た時刻（AppModel が覚える。起動で忘れる）
    var lastConnectedAt: Instant? = nil
    var worker: WorkerStatus = WorkerStatus(activity: .idle, paused: [])
    var backlog: BacklogCounts = .empty
    var vault: VaultStatus = .notConfigured
    var vaultPath: String? = nil
    var deletionEnabled: Bool = false
    var version: String = AppVersion.string
    // T-31 が models…、T-32 が attention / statusReport / diagnostics、T-40 が lockDisplay を足す
    init(now: Instant)
}
```

- **すべて `Equatable`**（`refresh()` で前回と等しければ何も書き換えない → SwiftUI の再描画とアイコンの張り替えを起こさない）
- `VaultStatus` は VDNotes（T-28）。`IngestState` / `IngestActivity` / `DeviceSnapshot` は VDDevice。`WorkerStatus` / `ConfigViolation` は VDPipeline / VDCore

---

### 4.8 `AppServices.swift`

```swift
// AppModel が外の世界に触れる唯一の口（テストは FakeServices で差し替える）。
import Foundation
import VDCore
import VDNotes        // VaultCheck
import VDPipeline
import VDStore        // ReadOnlyStore

protocol AppServices: Sendable {
    /// 現在の観測をまとめて 1 つ読む（アクターへの await はここに閉じる）。
    func read(lastConnectedAt: Instant?) async -> AppSnapshot
    /// パネルの「再試行」（PLAN §5.4 の契機 3）。
    func requeueManual() async
    /// パネルの「設定を読み直す」（PLAN §6.3）。
    func reloadConfig() async -> ConfigLoadResult
    /// 走査を促す（Vault やモデルを変えた後に使う。T-31 / T-40）。
    func scanNow() async
    /// IngestService からの更新の通知（走査の終わり）。
    func updates() async -> AsyncStream<Void>
    // T-32 が enqueue(_ job: WorkerJob) を足す
}

struct LiveServices: AppServices {
    let context: AppContext      // init は合成されたもの（swift-format の UseSynthesizedInitializer）
}
```

**`LiveServices.read(lastConnectedAt:)` の手順**（この順。どれも読むだけ。**DB は `ReadOnlyStore` で開き、無ければ作らない**）:
1. `var s = AppSnapshot(now: context.clock.now())`
2. `let config = await context.config.current()`。`s.configPresent = (config != nil)`、`s.configViolations = await context.config.violations()`
3. `if let c = config`:
   - `s.timeZone = c.timeZone`、`s.deletionEnabled = c.cleanup.deleteSourceAudio`
   - `s.vaultPath = c.vault.path`、`s.vault = VaultCheck.evaluate(path: c.vault.path, marker: c.vault.marker)`
4. `s.ingestState = await context.ingest.state()`、`s.ingestActivity = await context.ingest.activity()`、`s.device = await context.ingest.latestSnapshot()`
5. `s.lastConnectedAt = (s.device?.devices.isEmpty == false) ? s.device?.completedAt : lastConnectedAt`
6. `s.worker = await context.worker.status()`
7. `if let ro = ReadOnlyStore.open(url: context.layout.database), let b = try? ro.backlog() { s.backlog = BacklogCounts(count: b.count, seconds: b.seconds, unknownDuration: b.unknownDuration) }`（開けない・投げたら `.empty` のまま。**DB が無ければ全 0**。PLAN §8.12）
8. `return s`

- 3 の `VaultCheck.evaluate` は `stat` と `opendir` だけで、**何も作らない**（NOTE-16）
- `requeueManual()` = `await context.worker.requeue(.manual)`、`reloadConfig()` = `await context.config.load()`、`scanNow()` = `_ = await context.ingest.scanNow()`、`updates()` = `await context.ingest.updates()`

---

### 4.9 `StatusLine.swift`

```swift
// パネル上端の 1 行の文言（PLAN §8.12 の 1）。純関数。AppModel はこれを呼ぶだけ。
import VDCore
import VDDevice
import VDPipeline

enum StatusLine {
    static func make(_ s: AppSnapshot) -> String
    /// 「最終接続: …」の右側
    static func lastConnected(_ s: AppSnapshot, zone: ZonedTime) -> String
    /// 「デバイスの空き容量: …」の右側。観測が 1 台も無ければ nil（行を出さない）
    static func deviceFree(_ s: AppSnapshot) -> String?
    /// 「未処理: …」の右側（StatusTexts に委ねる）
    static func backlog(_ s: AppSnapshot) -> String
}
```

**`make(_:)`**（この順に判定し、最初に当たったものを返す）:

| # | 条件 | 文言 |
|---|---|---|
| 1 | `s.ingestState == .coexistenceBlocked` | `Strings.statusCoexistenceBlocked` |
| 2 | `!s.configPresent` | `Strings.statusConfigInvalid` |
| 3 | `s.ingestActivity.scanning && s.ingestActivity.total > 0` | `Strings.statusIngesting(device: s.ingestActivity.deviceID ?? Strings.unknownDevice, copied: s.ingestActivity.copied, total: s.ingestActivity.total)` |
| 4 | `s.ingestActivity.scanning` | `Strings.statusScanning` |
| 5 | `s.worker.activity != .idle` | 下の表 |
| 6 | `!s.worker.paused.isEmpty` | `Strings.statusPaused(s.worker.paused)` |
| 7 | それ以外 | `Strings.statusIdle` |

`WorkerActivity` → 文言（5）:

| `WorkerActivity` | 文言 |
|---|---|
| `.normalizing(_, startedAt)` | `Strings.statusNormalizing(ISOWallClock.hhmm(startedAt) ?? Strings.unknownTime)` |
| `.transcribing(_, startedAt)` | `Strings.statusTranscribing(ISOWallClock.hhmm(startedAt) ?? Strings.unknownTime)` |
| `.writingRawNote` | `Strings.statusWritingRawNote` |
| `.merging` | `Strings.statusMerging` |
| `.analyzing(_, dayDate)` | `Strings.statusAnalyzing(dayDate)` |
| `.writingDailyNote(_, dayDate)` | `Strings.statusWritingDailyNote(dayDate)` |
| `.idle` | 起こらない（5 の条件） |

**`lastConnected(_:zone:)`**:
- `s.device?.devices.isEmpty == false` → `Strings.connectedNow(名前)`。名前 = `devices.keys` を UTF-8 のバイト順に並べ `"、"` で連結
- そうでなく `s.lastConnectedAt != nil` → `zone.localDateTime(at)` を `yyyy-MM-dd HH:mm` に整形した文字列（`ZonedTime.iso` の先頭 16 文字の `T` を空白に替える。voicedock `status.py:104` と同じ作り方）
- どちらでもない → `Strings.neverConnected`

**`deviceFree(_:)`**: `s.device?.devices` を鍵のバイト順に並べ、`freeBytes != nil` のものだけ `"<id> " + StatusTexts.gib(bytes)` にして `"、"` で連結。1 つも無ければ nil

**`backlog(_:)`** = `StatusTexts.backlogLine(count: s.backlog.count, seconds: s.backlog.seconds, unknownDuration: s.backlog.unknownDuration)`

---

### 4.10 `Sources/VDPipeline/StatusTexts.swift`

```swift
// 状態の表示に使う整形（PLAN §8.12。voicedock status.py:96-134, 175-194）。
// パネルの上端（VoiceDockApp）と「状態の詳細」（StatusReporter。T-32）が同じ関数を使う。
import Foundation     // String(format:)。PauseReason は同じ VDPipeline。VDCore / VDDevice は使わないので import しない

public enum StatusTexts {
    public static let gibBytes: Double = 1024 * 1024 * 1024

    /// 「<x.x> GiB」（小数 1 桁。負の値は 0 として扱う）
    public static func gib(_ bytes: Int64) -> String
    /// PLAN §8.12「未処理 <h 小数 1 桁> 時間ぶん（<n> 件）」／「、うち <k> 件は長さ不明」／「未処理なし」
    public static func backlogLine(count: Int, seconds: Double, unknownDuration: Int) -> String
    // writabilityWord(_ w: DeviceWritability) は T-32 が足す（DeviceWritability は T-32 の LockObserving.swift が作る。00-api-map §11）
    /// ガードの理由の日本語（PLAN §5.4）。パネルの 1 行（T-30）・要対応（T-32）・DR-09（T-32）が共有する
    public static func pauseWord(_ r: PauseReason) -> String
}
```

- `gib(_:)`: `String(format: "%.1f GiB", max(0, Double(bytes)) / gibBytes)`
- `backlogLine`:
  1. `count == 0` → `"未処理なし"`
  2. `var t = "未処理 " + String(format: "%.1f", max(0, seconds) / 3600) + " 時間ぶん（" + String(count) + " 件）"`
  3. `unknownDuration > 0` → `t += "、うち " + String(unknownDuration) + " 件は長さ不明"`
  4. `return t`
- **`writabilityWord` は T-30 では作らない。**引数の `DeviceWritability` は 00-api-map §11 で T-32 の `LockObserving.swift` が作る型で、T-30 の時点では存在しない（地図 ＞ チケット）。T-32 が `LockObserving.swift` と一緒に `StatusTexts` に足す（**T-32 §4.12・§5.11・§6 の 34 に反映済み**）。中身:
  - `.absent` → `"デバイス未接続"`、`.unknown` → `"不明"`、`.readOnly` → `"読み取り専用"`、`.writable` → `"読み書き可能"`
  - **`nil` を「読み書き可能」に丸めない。0 台を観測扱いにしない**（#107 / #148。voicedock `status.py:175-194`）
  - テスト `writabilityWords`（「#107 / #148 観測の 4 語」）と破壊による証明の 11 も T-32 に移す

### 4.10b `Sources/VDCore/ModelMemory.swift`

```swift
// モデルを選べるかのメモリの条件（PLAN §8.10「ProcessInfo.physicalMemory < minMemoryGB × 1024³ のモデルは選べない」）。
// パネルの Picker（T-31）・DR-08（T-32）・解析のガード（T-22）が同じ式を使う（CR-06）。
public enum ModelMemory {
    public static let bytesPerGB: UInt64 = 1024 * 1024 * 1024
    /// minMemoryGB が nil なら常に真。等号は足りる側（>=）。
    public static func hasEnough(minMemoryGB: Int?, physicalMemoryBytes: UInt64) -> Bool {
        guard let g = minMemoryGB, g > 0 else { return true }
        // 掛け算が溢れる大きさは足りない側。`*` で trap させない（CR-16）
        let (need, overflow) = UInt64(g).multipliedReportingOverflow(by: bytesPerGB)
        if overflow { return false }
        return physicalMemoryBytes >= need
    }
    /// 表示用の GB（切り捨て）
    public static func gb(_ bytes: UInt64) -> Int { Int(bytes / bytesPerGB) }
}
```

テストは `Tests/VDCoreTests/ModelMemoryTests.swift`（`@Suite("ModelMemory")`）:

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `nilRequirementIsAlwaysEnough` / 「minMemoryGB が無ければ足りる」 | `nil`、0 バイト | 真 |
| `exactIsEnough` / 「ちょうどは足りる」 | `16`、16 GiB ちょうど | 真 |
| `oneByteShortIsNotEnough` / 「1 バイト足りなければ足りない」 | `16`、16 GiB − 1 | 偽 |
| `overflowingRequirementIsNotEnough` / 「掛け算が溢れる大きさは足りない（trap しない）」 | `Int.max`、`UInt64.max` | 偽 |
| `gbTruncates` / 「GB は切り捨て」 | 17 GiB − 1 | `16` |

---

### 4.11 `AppModel.swift`

```swift
// UI が見る唯一の値（PLAN §8.12）。IngestService / Worker / ConfigStore から来る値の写しで、DB を直接触らない。
import AppKit
import Foundation
import SwiftUI        // @Observable は SwiftUI が再輸出する。`import Observation` は PLAN §3.4 の許可リストに無い（PT-07）
import VDContract     // HomeLayout
import VDCore
import VDDevice
import VDPipeline

@MainActor
@Observable
final class AppModel {
    /// 観測の写し（refresh で入れ替える。等しければ入れ替えない）
    private(set) var snapshot: AppSnapshot
    /// 要対応があるか（T-32 が refresh の中で立てる。T-30 では常に false）
    private(set) var hasAttention = false
    /// パネルが開いているか（速い更新に切り替える）
    private(set) var isPanelOpen = false
    /// 「設定を読み直す」の結果（nil = まだ押していない）
    private(set) var reloadResult: ReloadResult?

    @ObservationIgnored private let services: any AppServices
    @ObservationIgnored private let openFinder: any FinderOpening
    @ObservationIgnored private let layout: HomeLayout
    @ObservationIgnored private let quitHandler: @MainActor () -> Void
    @ObservationIgnored private let sleeper: any Sleeper
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var updatesLoop: Task<Void, Never>?   // 走査の通知を待つタスク（stop で止める）
    @ObservationIgnored private var wakeContinuation: AsyncStream<Void>.Continuation?   // 周期の眠りを途中で起こす
    @ObservationIgnored private var iconContinuation: AsyncStream<Void>.Continuation?

    init(services: any AppServices, openFinder: any FinderOpening, layout: HomeLayout,
         sleeper: any Sleeper = TaskSleeper(), now: Instant,
         quit: @escaping @MainActor () -> Void)   // snapshot = AppSnapshot(now: now)

    // 導出（すべて計算プロパティ。状態を 2 か所に持たない）
    var iconState: IconState { IconState.compute(hasAttention: hasAttention, ingesting: snapshot.ingestActivity.scanning, processing: snapshot.worker.activity != .idle) }
    var showsTrash: Bool { snapshot.deletionEnabled }
    var statusLine: String { StatusLine.make(snapshot) }
    var lastConnectedLine: String { StatusLine.lastConnected(snapshot, zone: zone) }
    var deviceFreeLine: String? { StatusLine.deviceFree(snapshot) }
    var backlogLine: String { StatusLine.backlog(snapshot) }
    var versionLine: String { Strings.versionLine(snapshot.version) }
    var zone: ZonedTime { ZonedTime(timeZone: TimeZone(identifier: snapshot.timeZone) ?? .current) }
    /// アイコンの張り替えの通知（StatusItemController が待つ）。受け手は 1 つ:
    /// 取るたびに `AsyncStream.makeStream(of: Void.self)` を作り、前の continuation を finish して差し替える
    var iconChanges: AsyncStream<Void> { get }

    // 操作
    func start()
    func stop()
    func refresh() async
    func panelDidOpen()
    func panelDidClose()
    func requeueManual() async
    func reloadConfig() async
    func revealConfigInFinder()
    func revealLogsInFinder()
    func quit()

    enum ReloadResult: Equatable {   // 1 行 1 case（swift-format の OneCasePerLine）
        case ok
        case invalid([ConfigViolation])
    }

    static let fastIntervalSeconds = 1    // パネルが開いている間
    static let slowIntervalSeconds = 30   // 閉じている間（Worker の周期と同じ。PLAN §8.15「常時ポーリングしない」）
}
```

`FinderOpening`（同じファイルに置く。テストで差し替える）:
```swift
protocol FinderOpening: Sendable { func reveal(_ url: URL) }
struct NSWorkspaceFinder: FinderOpening { func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
```

**`start()`**（周期の眠りは wake と競わせる。Worker.run と同じ形）:
1. `guard loop == nil else { return }`
2. `let sleeper = self.sleeper`、`let (wake, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))`、`wakeContinuation = continuation`
3. `loop = Task { @MainActor [weak self] in`
   1. `await self?.refresh()`
   2. `guard let updates = await self?.services.updates() else { return }`
   3. `guard !Task.isCancelled, self != nil else { return }`（`stop()` が先に来ていたら購読を作らない。stop の後に `updatesLoop` を代入しない。self を強く掴んだ局所変数を作らない）
   4. `self?.updatesLoop = Task { @MainActor [weak self] in for await _ in updates { await self?.refresh() } }`（走査の終わりで 1 回）
   5. `var waiting = wake.makeAsyncIterator()`
   6. `while !Task.isCancelled {`
      - `guard let open = self?.isPanelOpen else { break }`（self が無くなったら抜ける）
      - `let seconds = open ? Self.fastIntervalSeconds : Self.slowIntervalSeconds`
      - `let timer = Task { do { try await sleeper.sleep(seconds: seconds) } catch { return }; continuation.yield(()) }`（取り消された眠りは起こさない）
      - `let woke = await waiting.next() != nil`、`timer.cancel()`
      - `if !woke || Task.isCancelled { break }`
      - `await self?.refresh()`
      - `}`
   7. `}`

- **アイドル時の CPU を 0 に近く保つ**（PLAN §8.15）: パネルが閉じている間は 30 秒周期＋走査の通知だけ。開いている間だけ 1 秒周期にする
- `stop()`: `loop?.cancel()`、`loop = nil`、`updatesLoop?.cancel()`、`updatesLoop = nil`、`wakeContinuation?.finish()`、`wakeContinuation = nil`、`iconContinuation?.finish()`

**`refresh()`**:
1. `let next = await services.read(lastConnectedAt: snapshot.lastConnectedAt)`
2. `let before = (iconState, showsTrash)`
3. `if next != snapshot { snapshot = next }`
4. （T-32 がここに `hasAttention = !attention.isEmpty` を足す）
5. `if (iconState, showsTrash) != before { iconContinuation?.yield(()) }`

**`panelDidOpen()`**: `isPanelOpen = true` → `if let wake = wakeContinuation { wake.yield(()) } else { Task { await refresh() } }`（開いた瞬間に最新にする。ループが回っていれば 30 秒の眠りを起こし、読み直して 1 秒周期へ切り替える。回っていなければ 1 回だけ読む）
**`panelDidClose()`**: `isPanelOpen = false`、`reloadResult = nil`（次に開いたときに古い結果を出さない）。F-65: `screen = .main`、`detailsExpanded` が真なら偽にして `setStatusReport(nil)`（次は主画面から開く）

**`requeueManual()`**: `await services.requeueManual()` → `await refresh()`
**`reloadConfig()`**: `switch await services.reloadConfig() { case .valid: reloadResult = .ok; case .invalid(let v): reloadResult = .invalid(v) }` → `await refresh()`
**`revealConfigInFinder()`** / **`revealLogsInFinder()`**: `openFinder.reveal(layout.configFile)` / `openFinder.reveal(layout.appLog)`。`layout` は `AppSnapshot` に持たせず、`init(…layout:…)` で受けて `@ObservationIgnored private let` で持つ（`HomeLayout` は `Sendable` な値）
**`setAttentionForTesting(_:)`**（internal。`@testable` のテスト用）: `hasAttention = value`。T-32 が `refresh` で立てるまでアイコンの優先順位を試す口
**`quit()`**: `quitHandler()`

### 4.11b `PanelScreen.swift` と `AppModel+Navigation.swift`（F-65）

```swift
enum PanelScreen: String, CaseIterable, Sendable, Equatable {
    case main, attention, deletion, details, settings
}
// AppModel.swift に: var screen: PanelScreen = .main（書くのは show と panelDidClose だけ）
extension AppModel {
    /// 画面を切り替える。details に入ったら状態の詳細を読み、出たら捨てる
    func show(_ next: PanelScreen) async
}
```

**`show(_:)`**: `screen = next` → `next == .details` なら `if !detailsExpanded { await toggleDetails() }`、そうでなく `detailsExpanded` なら `await toggleDetails()`（「詳細・診断」の画面にいる間だけ inbox と staging を走査する。T-32 の `toggleDetails` をそのまま使う）

- 要対応の操作（T-32 の `perform`）: `.openModels` は `modelsHighlighted = true` と `show(.main)`、`.openDeletionFlow` は `deletionHighlighted = true` と `show(.deletion)`、`.runDiagnostics` は `show(.details)` の後に `runDiagnostics()`
- 画面は popover の中だけで切り替える（窓を作らない。D-7）

---

### 4.12 `Strings.swift`（逐語。**このチケットが作る分**）

```swift
// パネルの文言（日本語のみ。PLAN §8.12「文言は Strings.swift に集める」）。
// 後続のチケット（T-31 / T-32 / T-40 / T-41）はこのファイルに自分の節の文言を足す。
import VDPipeline

enum Strings {
```

| 名前 | 値（逐語） |
|---|---|
| `ok` | `OK` |
| `unknownDevice` | `デバイス` |
| `unknownTime` | `時刻不明` |
| `bootFailureTitle` | `VoiceDock を起動できませんでした` |
| `bootFailureDirectories(_:)` | `作業フォルダを作れません: <e>` |
| `bootFailureCatalog(_:)` | `モデルの一覧を読めません: <e>` |
| `bootFailureDatabase(_:)` | `データベースを開けません: <e>` |
| `statusIdle` | `待機中` |
| `statusScanning` | `デバイスを調べています` |
| `statusIngesting(device:copied:total:)` | `<device> から取り込み中 <copied>/<total> — コピーが終われば抜いて大丈夫です` |
| `statusNormalizing(_:)` | `変換中 <hh:mm> の録音` |
| `statusTranscribing(_:)` | `文字起こし中 <hh:mm> の録音` |
| `statusWritingRawNote` | `Raw ノートを書いています` |
| `statusMerging` | `文字起こしをまとめています` |
| `statusAnalyzing(_:)` | `要約中 <yyyy-MM-dd>` |
| `statusWritingDailyNote(_:)` | `ノートを書いています <yyyy-MM-dd>` |
| `statusCoexistenceBlocked` | `取り込みを止めています（voicedock の Helper が登録されています）` |
| `statusConfigInvalid` | `設定にエラーがあります` |
| `statusPaused(_:)` | `停止中: ` ＋ `StatusTexts.pauseWord(_:)` を `PauseReason.allCases` の順に `"、"` でつないだもの |
| `connectedNow(_:)` | `接続中（<名前>）` |
| `neverConnected` | `まだありません` |
| `labelLastConnected` | `最終接続` |
| `labelBacklog` | `未処理` |
| `labelDeviceFree` | `デバイスの空き容量` |
| `sectionStatus` | `状態` |
| `sectionAttention` | `要対応` |
| `sectionOnboarding` | `はじめに` |
| `sectionVault` | `保存先（Vault）` |
| `sectionModels` | `モデル` |
| `sectionGeneral` | `一般` |
| `sectionDeletion` | `元音声の削除` |
| `sectionDetails` | `詳細` |
| `buttonRetry` | `再試行` |
| `buttonReloadConfig` | `設定を読み直す` |
| `buttonRevealConfig` | `設定ファイルを Finder で表示` |
| `buttonRevealLogs` | `ログを Finder で表示` |
| `buttonQuit` | `VoiceDock を終了` |
| `reloadOK` | `設定を読み直しました` |
| `reloadInvalid(_:)` | `設定にエラーがあります（<n> 件）` |
| `versionLine(_:)` | `版 <version>` |
| `iconDescription(_:)` | `IconState` ごとに `待機中` / `取り込み中` / `処理中` / `要対応` |
| `iconTrashDescription` | `元音声の削除が有効です` |

F-65 で足した文言（カード型のパネルと長押しの有効化。`holdSeconds` は `HoldToConfirmButton.holdDuration` から作る。CR-06）:

| 名前 | 文言 |
|---|---|
| `holdSeconds` | `3` |
| `holdToEnableHint` | `赤いボタンを 3 秒長押しすると有効になります。途中で離すと取り消します` |
| `holdKeepPressing` | `そのまま押し続けてください…` |
| `deletionUnavailable` | `設定を読み込めていないため、いまは操作できません` |
| `buttonBack` | `戻る` |
| `screenSettings` | `設定` |
| `rowDeletion` | `元音声の削除` |
| `rowDetails` | `詳細・診断` |
| `sectionDiagnostics` | `診断` |
| `sectionBacklog` | `後追い` |
| `deletionOn` / `deletionOff` | `有効` / `無効` |
| `attentionMore(_:)` | `ほか <n> 件` |
| `onboardingProgress(done:total:)` | `<done>/<total>` |
| `statusDetailLine(lastConnected:backlog:)` | `最終接続 <lastConnected> · <backlog>` |
| `deviceFreeLine(_:)` | `デバイスの空き容量 <value>` |

`PauseReason` の表示語（**`StatusTexts.pauseWord(_:)`（VDPipeline。§4.10）に置く**。VDPipeline 側（要対応・DR-09）も同じ語を使うため。`Strings` に写さない）:

| `PauseReason` | 表示語 |
|---|---|
| `diskSpaceLow` | `空き容量不足` |
| `whisperMissing` | `whisper-cli がありません` |
| `modelMissing` | `Whisper モデルがありません` |
| `vadModelMissing` | `VAD モデルがありません` |
| `vaultNotConfigured` | `Vault が未設定` |
| `vaultUnavailable` | `Vault が使えません` |
| `llmNotSelected` | `LLM が未選択` |
| `llmModelMissing` | `LLM モデルがありません` |
| `llmInsufficientMemory` | `メモリ不足` |
| `llamaServerMissing` | `llama-server がありません` |
| `license` | `ライセンス` |

- `StatusTexts.pauseWord` は `switch` で全ケースを書く（`default` を置かない。ケースが増えたらコンパイルで落ちる）。テストは `StatusTextsTests` に 1 本（`PauseReason.allCases` の 11 語を逐語で固定）。`StatusTextsTests` は公開 API だけを使うので `@testable` を付けない

---

### 4.13 `Panel/PanelStyle.swift` と `Panel/PanelView.swift`（F-65 でカード型・画面の切り替えに直した）

```swift
// パネルの体裁（PLAN §8.12「幅 380pt 前後、カード型。主画面はスクロールしない」。F-65）。
enum PanelStyle {
    static let width: CGFloat = 380
    static let maxScreenHeight: CGFloat = 560   // 別の画面の中身の高さの上限（超えたときだけその画面でスクロール）
    static let padding: CGFloat = 12
    static let sectionSpacing: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let cardSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 10
    static func headerSymbol(_ state: IconState) -> String   // waveform.circle.fill などの塗りつぶし版
    static func tint(_ state: IconState) -> Color           // 待機＝緑、取り込み・処理中＝青、要対応＝橙
}

/// カード（見出し ＋ 右肩の小さな文字 ＋ 中身）。角丸 10 の `.quaternary.opacity(0.5)` の背景、余白 12。
struct SectionBox<Content: View>: View {
    init(title: String? = nil, trailing: String? = nil, @ViewBuilder content: () -> Content)
}
```

```swift
// パネル本体（PLAN §8.12 の 1〜9 をこの順に）。主画面はスクロールしない。長い中身は popover の中の別の画面へ（F-65）。
struct PanelView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .main: main
            case .attention: SubScreen(title: Strings.sectionAttention, model: model) { AttentionSection(model: model, limit: nil) }
            case .deletion: SubScreen(title: Strings.sectionDeletion, model: model) { DeletionSection(model: model) }
            case .details: SubScreen(title: Strings.rowDetails, model: model) { DetailsSection(model: model) }
            case .settings: SubScreen(title: Strings.screenSettings, model: model) { /* 一般のカードと版 */ }
            }
        }
        .padding(PanelStyle.padding)
        .frame(width: PanelStyle.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)   // 高さは中身に合わせる
    }

    private var main: some View {   // ScrollView を置かない
        VStack(alignment: .leading, spacing: PanelStyle.sectionSpacing) {
            StatusSection(model: model)       // 1（⚙ で設定の画面）
            AttentionSection(model: model)    // 2  T-32（先頭の 2 件と「ほか n 件 ›」）
            OnboardingSection(model: model)   // 3  T-31（6 のトグルもここ。完了後は ⚙ の画面）
            VaultSection(model: model)        // 4  T-31
            ModelsSection(model: model)       // 5  T-31
            // 7  T-40: DeletionSection.isAvailable(model) のときだけ PanelRow「元音声の削除  有効／無効」→ show(.deletion)
            // 8  T-32: PanelRow「詳細・診断」→ show(.details)
            Button(Strings.buttonQuit) { model.quit() }   // 9
        }
    }
}
```

- **節の順を変えない**（PLAN §8.12 の番号がそのまま並び）。節を足すときは PLAN を先に直す
- **主画面に ScrollView・List・Form を置かない**（F-65。`PanelLayoutPolicyTests`）。スクロールは `SubScreen` の中だけで、中身の高さを `onGeometryChange` で測り `min(中身, PanelStyle.maxScreenHeight)` の高さを与える（測る前は上限。0 から始めない）
- `SubScreen(title:model:content:)`: 見出しは「‹ 戻る」（`Strings.buttonBack`。`show(.main)`。Esc でも戻る）と題
- `PanelRow(systemImage:tint:title:value:action:)`: 押すと別の画面へ移る 1 行（左にアイコン、右に値と「›」）

`Panel/StatusSection.swift`（状態の見出しのカード）: `PanelStyle.headerSymbol(model.iconState)` を `PanelStyle.tint` の色で大きめに、1 行目に `model.statusLine`（headline。削除が有効なら赤い `trash` を並べる）、
2 行目に `Strings.statusDetailLine(lastConnected: model.lastConnectedLine, backlog: model.backlogLine)`（caption・secondary）、観測があれば `Strings.deviceFreeLine(model.deviceFreeLine)`。右上に ⚙（`show(.settings)`）

---

### 4.14 `LoginItem.swift`（このチケットは状態だけ）

```swift
// ログイン項目（PLAN §8.12 の 6・§8.11 の DR-12）。SMAppService を触る唯一の場所。
// このチケットは status() だけを作る。register / unregister / openSystemSettingsLoginItems は T-31 が足す。
import ServiceManagement
import VDPipeline

protocol LoginItemControlling: Sendable {
    func status() -> LoginItemStatus
}

struct SystemLoginItem: LoginItemControlling {
    func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}
```

`LoginItemStatus` は VDPipeline に置く（DR-12 が使うため。§3.4「DR-12 だけは VoiceDockApp から値を注入する」）。**このチケットが先に置く**:

```swift
// Sources/VDPipeline/Diagnostics/LoginItemStatus.swift
// ログイン項目の状態（PLAN §8.11 の DR-12）。値は VoiceDockApp が SMAppService から作って渡す。
public enum LoginItemStatus: String, Sendable, Equatable, CaseIterable {
    case enabled, requiresApproval, notRegistered, notFound
}
```
1 ファイル 1 型の規則に従い `Diagnostics.swift` とは別のファイルにする（T-32 が `Diagnostics` からこれを使う）。

---

## 5. テスト

`Tests/VoiceDockAppTests/` は `@testable import VoiceDockApp`。**ビューは作らない**（`PanelView` を初期化するテストを書かない）。
`FakeServices` は `VoiceDockAppTests` の中に置く（TestSupport に置かない。VoiceDockApp は実行ファイルのターゲットで、TestSupport から import できない）。

### 5.0 `FakeServices.swift`

```swift
// AppServices の偽物（T-30。VoiceDockAppTests の中だけ）。read が返す値を差し替え、呼ばれた操作を記録する。
@testable import VoiceDockApp
final class FakeServices: AppServices {
    // Mutex<State> で持つ（@unchecked Sendable を使わない。PT-14）
    init(_ snapshot: AppSnapshot)
    func set(_ snapshot: AppSnapshot)
    func setReload(_ result: ConfigLoadResult)
    var requeueCount: Int { get }
    var reloadCount: Int { get }
    var scanCount: Int { get }
    var lastConnectedSeen: [Instant?] { get }   // read に渡された値
    var readCount: Int { get }                   // read が呼ばれた回数
    var subscriberCount: Int { get }             // updates() が呼ばれた回数
    func push()                                  // updates() のストリームに 1 件流す
}
final class FakeFinder: FinderOpening { var revealed: [URL] { get } }
```

### 5.1 `StatusLineTests.swift`（`@Suite("StatusLine")`）

`AppSnapshot(now: Instant(epochMillis: 1_756_000_000_000))` に `configPresent = true` を入れたものを作り、必要なフィールドだけ差し替える（`AppSnapshot` の既定は `configPresent = false` = 設定エラー状態。§4.7）。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `coexistenceWinsOverEverything` / 「共存ガード中は他の何より先に出す」 | `ingestState = .coexistenceBlocked`、`configPresent = false`、`ingestActivity` は取り込み中 | `Strings.statusCoexistenceBlocked` |
| `configInvalidBeatsActivity` / 「設定エラーは取り込み・処理より先」 | `configPresent = false`、`worker.activity = .transcribing(…)` | `Strings.statusConfigInvalid` |
| `ingestingShowsProgress` / 「取り込み中は件数と『抜いて大丈夫です』を出す」 | `ingestActivity = IngestActivity(scanning: true, deviceID: "DJIMIC3", copied: 3, total: 12, lastActivityAt: now)` | `DJIMIC3 から取り込み中 3/12 — コピーが終われば抜いて大丈夫です` |
| `scanningWithoutCandidates` / 「候補 0 件の走査中は『調べています』」 | `scanning: true, total: 0` | `デバイスを調べています` |
| `transcribingShowsWallClock` / 「文字起こし中は保存文字列の壁時計を出す」 | `worker.activity = .transcribing(partkey: "k", startedAt: "2026-08-29T07:12:33+09:00")` | `文字起こし中 07:12 の録音` |
| `normalizingShowsWallClock` / 「変換中も同じ形」 | `.normalizing(partkey: "k", startedAt: "2026-08-29T07:12:33+09:00")` | `変換中 07:12 の録音` |
| `badStartedAtFallsBackToUnknown` / 「壊れた startedAt は『時刻不明』」 | `startedAt: "x"` | `文字起こし中 時刻不明 の録音` |
| `analyzingShowsDay` / 「要約中は日付」 | `.analyzing(sessionKey: "s", dayDate: "2026-08-29")` | `要約中 2026-08-29` |
| `writingDailyNoteShowsDay` / 「Daily の書き込み中」 | `.writingDailyNote(sessionKey: "s", dayDate: "2026-08-29")` | `ノートを書いています 2026-08-29` |
| `mergingAndRawNote` / 「まとめ中・Raw の書き込み中」 | 2 つの activity | 逐語 2 つ |
| `pausedListsReasonsInDeclarationOrder` / 「停止中の理由は PauseReason の宣言順」 | `paused = [.llmNotSelected, .diskSpaceLow]` | `停止中: 空き容量不足、LLM が未選択` |
| `idleIsIdle` / 「何もしていなければ待機中」 | 既定 | `待機中` |
| `lastConnectedShowsConnectedNames` / 「接続中は名前を並べる」 | `device` に 2 台（`B`・`A`） | `接続中（A、B）`（バイト順） |
| `lastConnectedShowsTimestamp` / 「切れていれば最後に見た時刻」 | `device.devices` が空、`lastConnectedAt` あり | `2026-08-29 07:12`（`zone` は `Asia/Tokyo`） |
| `lastConnectedNever` / 「一度も見ていなければ『まだありません』」 | どちらも無い | `まだありません` |
| `deviceFreeSkipsUnknown` / 「空き容量が観測できない台は出さない」 | 2 台のうち 1 台だけ `freeBytes` | `DJIMIC3 4.2 GiB` |
| `deviceFreeNilWhenNoObservation` / 「1 台も観測が無ければ行を出さない」 | `device == nil` | `nil` |
| `emptySnapshotIsIdle` / 「TEST-28 何も無い観測」 | `AppSnapshot(now:)` のまま（1 行は `configPresent = true` にしたものでも見る） | 1 行はそのままなら `設定にエラーがあります`、`configPresent = true` なら `待機中`。`未処理なし`・`まだありません`・`deviceFree == nil` |

### 5.2 `IconStateTests.swift`（`@Suite("IconState")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `attentionWins` / 「要対応は取り込み・処理より優先」 | `hasAttention: true, ingesting: true, processing: true` | `.attention`・`exclamationmark.triangle` |
| `ingestingBeatsProcessing` / 「取り込み中は処理中より先」 | `false, true, true` | `.ingesting` |
| `processingWhenWorkerBusy` / 「Worker が動いていれば処理中」 | `false, false, true` | `.processing`・`text.bubble` |
| `idleOtherwise` / 「何も無ければ待機中」 | `false, false, false` | `.idle`・`waveform` |
| `symbolNamesAreDistinct` / 「4 つの記号名が全部違う」 | `IconState.allCases` | `Set(symbolName).count == 4`、`trash` はそのどれとも違う |

### 5.3 `AppModelTests.swift`（`@Suite("AppModel")`）

すべて `@MainActor`。`AppModel(services: fake, openFinder: finder, layout: layout, sleeper: RecordingSleeper(), now: fixed, quit: { quits += 1 })` を作り、`refresh()` を直接呼ぶ（`start()` のループは別に試す）。`layout` は `HomeLayout(root: /tmp/voicedock-t30-layout)`（ファイルは作らない）。`fake` の観測は `configPresent = true` を入れたもの。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `refreshCopiesTheSnapshot` / 「refresh は観測をそのまま写す」 | `fake.set(s)` | `model.snapshot == s` |
| `refreshPassesLastConnectedBack` / 「前回の最終接続を read に渡す」 | `s.lastConnectedAt = t` → refresh → refresh | `fake.lastConnectedSeen == [nil, t]` |
| `iconChangesOnlyWhenIconChanges` / 「アイコンが変わらなければ通知しない」 | 同じ観測で 2 回 refresh（2 回目の前に `withObservationTracking { _ = model.snapshot }` を張る）、その後 `deletionEnabled = true` で 1 回 | 2 回目で `onChange` が呼ばれない。通知は 1 回だけ（`trash` が付いたときの 1 件） |
| `showsTrashFollowsDeletionEnabled` / 「削除が有効なら trash を常時出す」 | `deletionEnabled = true` | `model.showsTrash == true` |
| `iconIsAttentionWhenFlagged` / 「要対応が立てばアイコンが変わる」 | `hasAttention` を `setAttentionForTesting(true)`（`@testable` の internal 関数） | `model.iconState == .attention` |
| `panelOpenSwitchesToFastInterval` / 「パネルが開いている間だけ 1 秒周期」 | `start()` → `panelDidOpen()` → `RecordingSleeper` の記録を見る | 眠りの秒数に 1 が現れ、閉じると 30 に戻る |
| `panelOpenWakesTheSlowSleep` / 「閉じた 30 秒の眠りの途中で開くと、すぐ読み直して 1 秒の眠りに切り替わる」 | 待ち秒を記録して止められるまで戻らない Sleeper（テストファイル内の `SuspendingRecordingSleeper`）で `start()` → 記録が `[30]` になるのを待つ → `panelDidOpen()` | 記録が `[30, 1]` になり、`read` が 1 回増える |
| `panelCloseClearsReloadResult` / 「閉じたら『読み直しました』を消す」 | `reloadConfig()`（`.valid`）→ `panelDidClose()` | `reloadResult == nil` |
| `requeueManualCallsWorkerAndRefreshes` / 「再試行は Worker に渡して読み直す」 | `requeueManual()` | `fake.requeueCount == 1`、`read` が 1 回増える |
| `reloadConfigOK` / 「読み直しが通れば ok」 | `setReload(.valid(config))` | `reloadResult == .ok`、`fake.reloadCount == 1` |
| `reloadConfigInvalidKeepsViolations` / 「違反はそのまま持つ」 | `setReload(.invalid([v1, v2]))` | `reloadResult == .invalid([v1, v2])` |
| `revealOpensFinderWithTheRightURL` / 「Finder に渡す URL は HomeLayout から取る」 | `revealConfigInFinder()`・`revealLogsInFinder()` | `finder.revealed == [layout.configFile, layout.appLog]` |
| `quitCallsTheHandler` / 「終了はハンドラを呼ぶだけ」 | `quit()` | `quits == 1`（AppModel は `NSApp` を触らない） |
| `startRefreshesOnIngestUpdate` / 「走査の通知で読み直す」 | `SuspendingSleeper()`（周期の眠りが戻らない）で `start()` → `read` 1 回と購読 1 つを待つ → `fake.push()` | `read` の回数が 2 になる |
| `stopCancelsTheLoop` / 「stop で周期を止める」 | `start()` → `stop()` → 時間を進める | それ以上 `read` が呼ばれない |
| `emptyServicesProduceIdlePanel` / 「TEST-28 何も無い観測でも落ちない」 | `configPresent = true` 以外は `AppSnapshot(now:)` のまま | `statusLine == 待機中`、`iconState == .idle`、`showsTrash == false`、`backlogLine == 未処理なし` |
| `bootWithoutDatabaseShowsZero` / 「DB が無ければ未処理は全 0（LiveServices は DB を作らない）」 | `TempDirectory` の `HomeLayout` で `AppContext` を組む（`Store` は `layout.database` とは別の場所に開く。取り込みは `FakeMountInspector`・`FakeRemounter`・`FakeMountEventSource`・一時ディレクトリの `volumesRoot`。どれも start しない）→ `LiveServices.read(lastConnectedAt: nil)` | `backlog` が全 0、`configPresent == false`、`device == nil`、`layout.database` が作られていない。`AppModel` を通すと `backlogLine == 未処理なし` |

### 5.3b `BootstrapTests.swift`（`@Suite("Bootstrap")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `startServicesAwaitsRecoveryBeforeScan` / 「起動は復旧（Worker.start）を待ってから走査（IngestService.start）を始める」 | `startServices` に 3 つの偽物を渡す（`workerStart` は 50 ms 眠ってから記録）→ 返ったタスクを待つ | 記録の先頭が `start`、3 つとも 1 回ずつ |

### 5.5 `AppModelNavigationTests.swift`（`@Suite("AppModel+Navigation")`。F-65）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `startsOnTheMainScreen` / 「TEST-28 何もしなければ主画面で、状態の詳細は読まない」 | 作っただけ | `screen == .main`、`detailsExpanded == false`、`statusReportCount == 0` |
| `detailsScreenLoadsAndDropsTheReport` / 「「詳細・診断」に入ると状態の詳細を 1 回読み、戻ると捨てる」 | `show(.details)` → `show(.main)` | 入ると `statusReport != nil`・読み 1 回、戻ると nil・読みは 1 回のまま |
| `otherScreensDoNotLoadTheReport` / 「「詳細・診断」以外の画面では状態の詳細を読まない」 | attention・deletion・settings・main へ順に | `statusReportCount == 0` |
| `leavingDetailsForAnotherScreenDropsTheReport` / 「「詳細・診断」から別の画面へ直接移っても状態の詳細を捨てる」 | `show(.details)` → `show(.deletion)` | `detailsExpanded == false`、`statusReport == nil` |
| `closingThePanelReturnsToMain` / 「パネルを閉じたら次は主画面から（状態の詳細も捨てる）」 | `show(.details)` → `panelDidClose()` | `screen == .main`、`statusReport == nil` |
| `attentionActionsNavigate` / 「要対応の「有効化フローを開く」は「元音声の削除」の画面へ、「モデルの節を開く」は主画面へ」 | `perform(.openDeletionFlow)` → `perform(.openModels)` | `.deletion`・`deletionHighlighted`、`.main`・`modelsHighlighted` |
| `runDiagnosticsOpensTheDetailsScreen` / 「要対応の「診断を実行」は「詳細・診断」の画面へ移ってから診断する」 | `perform(.runDiagnostics)` | 診断 1 回、`screen == .details`、読み 1 回 |
| `fiveScreens` / 「画面は 5 つ」 | `PanelScreen.allCases` | `main, attention, deletion, details, settings` |

### 5.6 `PanelPartsTests.swift`（`@Suite("PanelParts")`。F-65）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `mainShowsTheFirstTwo` / 「主画面の要対応は先頭の 2 件と「ほか n 件」」 | 3 件、`limit: mainLimit` | 先頭 2 件、残り 1、`mainLimit == 2` |
| `twoOrFewerAreAllShown` / 「2 件以下なら全部出し、「ほか」は出さない」 | 2 件 | 2 件、残り 0 |
| `attentionScreenShowsAll` / 「要対応の画面（limit なし）は全件」 | 3 件、`limit: nil` | 3 件、残り 0 |
| `noAttention` / 「TEST-28 要対応が 0 件なら何も出さない」 | 0 件 | `[]`、0 |
| `vaultDisplayName` / 「Vault の行はフォルダ名、未選択は「まだ選ばれていません」」 | パス・末尾 `/`・nil・空 | フォルダ名・`まだ選ばれていません` |
| `tintFollowsTheState` / 「状態の色」 | 4 状態 | 緑・青・青・橙 |
| `sizes` / 「幅は 380pt、別の画面の高さの上限は 560pt」 | — | 380・560 |

### 5.7 `Tests/PolicyTests/PanelLayoutPolicyTests.swift`（`@Suite("PanelLayoutPolicy")`。F-65）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `mainScreenDoesNotScroll` / 「主画面（PanelView.swift）に ScrollView・List・Form が無い」 | `SourceTree.load()` の `VoiceDockApp/Panel/PanelView.swift` の識別子のトークン（コメントと文字列は数えない） | `VStack`・`StatusSection` が在り（空振りしない）、`ScrollView`・`List`・`Form` が 1 つも無い |
| `onlySubScreenScrolls` / 「パネルの中で ScrollView を使ってよいのは SubScreen.swift だけ」 | `VoiceDockApp/Panel/` の全ファイル | `SubScreen.swift` には `ScrollView` が在り（陽性対照）、ほかのファイルには 3 つとも無い |

### 5.4 `Tests/VDPipelineTests/StatusTextsTests.swift`（`@Suite("StatusTexts")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `backlogNone` / 「0 件は『未処理なし』」 | `count: 0, seconds: 0, unknownDuration: 0` | `未処理なし` |
| `backlogHoursOneDecimal` / 「時間は小数 1 桁」 | `count: 6, seconds: 11_520, unknown: 0` | `未処理 3.2 時間ぶん（6 件）` |
| `backlogUnknownDuration` / 「長さ不明の件数を併記する」 | `count: 6, seconds: 11_520, unknown: 1` | `未処理 3.2 時間ぶん（6 件）、うち 1 件は長さ不明` |
| `backlogZeroSecondsButParts` / 「全部長さ不明なら 0.0 時間」 | `count: 2, seconds: 0, unknown: 2` | `未処理 0.0 時間ぶん（2 件）、うち 2 件は長さ不明` |
| `gibOneDecimal` / 「GiB は小数 1 桁」 | `4_509_715_660` | `4.2 GiB` |
| `gibZeroAndNegative` / 「0 と負の値は 0.0 GiB」 | `0`・`-1` | どちらも `0.0 GiB` |
| `pauseWords` / 「ガードの理由の 11 語」 | `PauseReason.allCases` | §4.12 の表と逐語で一致（11 件） |

## 6. 破壊による証明

| # | 壊し方（1 か所） | 落ちるべきテスト |
|---|---|---|
| 1 | `IconState.compute` の `hasAttention` の判定を最後に移す | `attentionWins` |
| 2 | `IconState.compute` の `ingesting` と `processing` の順を入れ替える | `ingestingBeatsProcessing` |
| 3 | `StatusLine.make` の 1 と 2 を入れ替える | `coexistenceWinsOverEverything` |
| 4 | `statusIngesting` の「— コピーが終われば抜いて大丈夫です」を消す | `ingestingShowsProgress` |
| 5 | `ISOWallClock.hhmm` の nil を空文字にする | `badStartedAtFallsBackToUnknown` |
| 6 | `Strings.statusPaused` を `paused` の渡された順で出す | `pausedListsReasonsInDeclarationOrder` |
| 7 | `StatusLine.lastConnected` の並べ替えを消す | `lastConnectedShowsConnectedNames` |
| 8 | `StatusLine.deviceFree` で `freeBytes == nil` を 0 にする | `deviceFreeSkipsUnknown` |
| 9 | `StatusTexts.backlogLine` の `count == 0` の分岐を消す | `backlogNone` |
| 10 | `backlogLine` の `unknownDuration` の節が効かないようにする（`if unknownDuration > 0` を `< 0` に。節を消すと `var t` が変更されない警告＝エラーでビルドが通らない） | `backlogUnknownDuration`、`backlogZeroSecondsButParts` |
| 11b | `ModelMemory.hasEnough` の `>=` を `>` にする | `exactIsEnough` |
| 12 | `AppModel.refresh` の `next != snapshot` を外して常に代入する | **落ちるテストが無い**（T-30 の実装で確認）。`@Observable` の setter は `Equatable` の値が等しければ観測者に知らせない（Swift 6.4 で確認）ので、この比較は再描画の抑止を二重にしているだけで、外しても観測できる違いが無い。比較は意図を明示するために残す |
| 13 | `refresh` が `lastConnectedAt` に `nil` を渡す | `refreshPassesLastConnectedBack` |
| 14 | `panelDidClose` の `reloadResult = nil` を消す | `panelCloseClearsReloadResult` |
| 15 | `AppModel.slowIntervalSeconds` を 1 にする | `panelOpenSwitchesToFastInterval` |
| 16 | `requeueManual` の `refresh()` を消す | `requeueManualCallsWorkerAndRefreshes` |
| 17 | `revealLogsInFinder` が `layout.reaperLog` を渡す | `revealOpensFinderWithTheRightURL` |
| 19 | `Bootstrap.startServices` の `await workerStart()` を `Task { await workerStart() }` にする（start の await を外す） | `startServicesAwaitsRecoveryBeforeScan` |
| 20 | `panelDidOpen` が wake を流さない（`Task { await refresh() }` だけにする） | `panelOpenWakesTheSlowSleep` |
| 21 | `ModelMemory.hasEnough` を `UInt64(g) * bytesPerGB` に戻す | `overflowingRequirementIsNotEnough`（trap で落ちる） |
| 22 | （F-65）主画面（`PanelView` の `main`）を `ScrollView { … }` で包む | `mainScreenDoesNotScroll` |
| 23 | （F-65）`show(_:)` で details を出るときに `toggleDetails()` を呼ばない | `detailsScreenLoadsAndDropsTheReport`、`leavingDetailsForAnotherScreenDropsTheReport` |
| 24 | （F-65）`panelDidClose` の `screen = .main` を消す | `closingThePanelReturnsToMain` |
| 25 | （F-65）`AttentionSection.split` で `limit` を無視する | `mainShowsTheFirstTwo` |
| 18 | `LiveServices.read` で `ReadOnlyStore.open` の nil のとき `BacklogCounts(count: 1, …)` を返す | `bootWithoutDatabaseShowsZero`（`emptyServicesProduceIdlePanel` は `FakeServices` を通すので `LiveServices` を見ない） |

## 7. 受け入れ条件

- [ ] `swift build` が通り、`.app` を組まずに `swift run VoiceDockApp` でメニューバーにアイコンが出る（【利用者が行う】目視。CI では行わない）
- [ ] `make test` が通る。`VoiceDockAppTests` が §5 の全テストを持つ
- [ ] `make lint` が通る（`swift format`）
- [ ] PT-08（`print` / `Logger(` が `Log.swift` 以外に無い）、PT-09（`Date()`）、PT-14、PT-18、PT-19 が通る。**`Bootstrap.swift` に `ProcessInfo.processInfo.environment` を書かない**（PT-18。`physicalMemory` は環境変数ではないので可）
- [ ] `Strings` の全項目が §4.12 の表と逐語で一致する（`StringsTests` で 1 本ずつ固定する。表示名は日本語）
- [ ] `PanelView` の節の並びが PLAN §8.12 の 1〜9 と同じで、空の節に `// T-nn が中身を書く（PLAN §8.12 の <n>）。` が在る
- [ ] （F-65）主画面に ScrollView が無く（`PanelLayoutPolicyTests`）、popover の高さが中身に合う（`sizingOptions = .preferredContentSize`。【利用者が行う】目視で 1pt に潰れないこと）
- [ ] AppModel に DB・`ConfigStore`・`Worker`・`IngestService` への直接の参照が無い（`AppServices` 経由だけ）
- [ ] `Bootstrap.build()` が `await worker.start()`（復旧の完了）→ `Worker.run()` のタスク → `ingest.start()` の順に呼んでいる（§8.15 の順。`startServices` と `BootstrapTests`）

## 8. SPEC の変更

`docs/SPEC.md` に次の 2 つの表を足す（T-05 の `make-spec.py` の表に見出しを登録する）:

1. `## S20. パネルの節の並び` — PLAN §8.12 の 1〜9 を `| # | 節 | チケット |` の 3 列で写す（`PanelStructureTests`（PolicyTests）が `PanelView.swift` の呼び出し順と突き合わせる）
2. `## S21. メニューバーのアイコン` — PLAN §8.12 の表を `| 状態 | シンボル |` で写し、`trash` の行を足す（`IconStateTests` が SPEC から読んで `IconState.symbolName` と突き合わせる）

**実装の注記（T-30 の実装時）**: この節は T-30 の PR では実装していない。issue #18（SPEC 同期の拡張）に切り出した。S20 は PLAN §8.12 のパネルが箇条書きで「チケット」の列が PLAN に無く、写し方の判断が要る。当面は `IconStateTests` がシンボル名を固定値で照合する

## 9. マージ後にやること

1. （T-23 はマージ済み。`AppContext.models` は最初から `ModelManager`）
2. T-32 が `DeviceWritability` と一緒に `StatusTexts.writabilityWord(_:)`（§4.10 の申し送り）を足し、`LockDisplay.lines` の 4 語をそれに置き換える（CR-06。`LockDisplay` を作るのは T-32 §4.11。T-32 §4.12）
7. `WorkerDependencies.verificationCache` を足すチケットが決まったら（§10 の 11。未決）、`Bootstrap` の 12 で同じ `verificationCache` を渡す
3. T-40 のマージで `Bootstrap` の 13（`setLock1Reconciler`）の本体を入れる
4. P0-02 の結果で `Bootstrap.useMountPoint` の値を確定する（T-15 §マージ後と同じ項目）
5. README の一覧の T-30 の行の前提を `T-29` のままにする（変更なし）
6. `LLMGuard`（T-22）と `ModelManager.meetsMemory`（T-23）の同じメモリの式（`UInt64(g) * 1024³`）を `ModelMemory.hasEnough` に置き換える（溢れで trap しない。CR-06・CR-16。どちらも他チケットのファイルなので T-30 では触らない）

## 10. API 地図への変更提案

1. §12（VoiceDockApp）の表に次のファイルを足す: `AppSnapshot.swift`（`AppSnapshot` / `BacklogCounts`）、`AppServices.swift`（`AppServices` / `LiveServices`）、`StatusLine.swift`、`StatusIconImage.swift`、`Panel/PanelStyle.swift`（`PanelStyle` / `SectionBox`）
2. §12 の `Bootstrap.swift` の説明を `AppContext`・`BootFailure`・`Bootstrap.build() async -> Result<AppContext, BootFailure>` に具体化する
3. §12 の `IconState.swift` を `enum IconState: String { idle, ingesting, processing, attention }`（`symbolName`・`trashSymbolName`・`compute(hasAttention:ingesting:processing:)`）にする
4. §12 の `LoginItem.swift` を `protocol LoginItemControlling { func status() -> LoginItemStatus }` と `SystemLoginItem` にし、「操作は T-31 が足す」と注記する
5. §11（VDPipeline）に `StatusTexts.swift`（`public enum StatusTexts { gibBytes / gib / backlogLine / pauseWord }`。**作り手 T-30**、使い手 T-32。`writabilityWord(_: DeviceWritability)` は型を作る T-32 が足す）を足す。§2.3（VDCore）に `ModelMemory.swift`（`public enum ModelMemory { bytesPerGB / hasEnough(minMemoryGB:physicalMemoryBytes:) / gb(_:) }`。**作り手 T-30**、使い手 T-22・T-31・T-32）を足す
6. §11 の `Diagnostics/` に `LoginItemStatus.swift`（`public enum LoginItemStatus`。**作り手 T-30**、T-32 が使う）を足し、`Diagnostics.swift` の行から `LoginItemStatus` を外す（1 ファイル 1 型）
7. §14 の `VoiceDockAppTests` の「主な中身」に「`FakeServices` / `FakeFinder`（このターゲットの中だけ。TestSupport には置かない）」を注記する
8. §11 の `LockObserving.display`（T-32）が返す `LockDisplay.lines` は `StatusTexts.writabilityWord` を使う、と注記する（`LockEvaluator` は T-36 でこのプロトコルに準拠する）
9. （整合修正 M-4 / M-5 / H-2）`Bootstrap` の呼び出しを地図に合わせた: `ConfigStore(layout:catalog:log:observeReaperConf:)`（§11。`log:` を渡す。`observeReaperConf` は Phase 7 では `{ .missing }`）、`ModelDownloader(layout:factory:log:hashChunkBytes:)` と `ModelManager(layout:catalog:downloader:cache:log:hashChunkBytes:)`（§10。`clock:` は無い）、`WorkerDependencies` の末尾（`importedKeys`・`locks`・`volumeOpener`）は渡さない。地図側の修正は不要
10. §11 に `ErrorText.swift`（`public enum ErrorText { static func describe(_ e: any Error) -> String }`。T-18 が internal で作ったものを **T-30 が public にする**。VoiceDockApp の `Bootstrap` / `LoginItem` が使う）を足す。`DurationSeconds` は internal のまま
11. **`WorkerDependencies.verificationCache` を誰が足すか未決**。地図 §11 の `WorkerDependencies` の行は T-18 の並びに `verificationCache: ModelVerificationCache` を含めて書いているが、**実装（T-18・T-22 のマージ後の `WorkerDependencies.swift`）には無い**（地図と実装の食い違い）。チケットの記述も割れている（T-18 §4.4 の注は T-22、T-18 §10 の 4 は T-32）。T-30 の `Bootstrap` は `ModelManager` にだけ渡している。足すチケットを決め、地図の行に作り手を注記したい
12. `AppIdentity`（T-36）ができるまで、`Bootstrap.logSubsystem`（`"io.github.shinsuke-terada.VoiceDock"`）を os.Logger の subsystem に使う、と §12 の `Bootstrap.swift` の行に注記する

## 11. 仕様の問題（PLAN に直したいこと）

1. **（反映済み）§8.15 の「起動に失敗したとき」**: PLAN §8.15 に既にある。本チケットは「`NSAlert` を 1 枚出して終了する」（パネルを出さない）
2. **§8.12 の「最終接続」の出どころが決まっていない**: snapshot は最新の 1 つしか持たず、接続の履歴を残す場所が無い。本チケットは「AppModel が `devices` が空でない snapshot を見た時刻を覚える（起動で忘れる）」とした。DB の `recordings.started_at` を使う案もあるが、取り込みが 0 件の接続を拾えない
3. **§8.12 の `trash` の「並べて常時表示」の実現手段が決まっていない**: `NSStatusItem` を 2 つにすると他アプリの項目が間に入る。本チケットは 1 枚の画像に合成する方式にした
4. **§8.15 の「アイドル時の CPU は 0 に近く保つ」と、パネルの 1 行の鮮度の両立**: 本チケットは「パネルが開いている間だけ 1 秒、閉じていれば 30 秒＋走査の通知」とした。PLAN に周期を明記したい
5. **`requestStop()` で tick を中断したとき `ActivityBoard` が `.idle` に戻らない**（T-18 §4.8）。プロセスが終わるので実害は無いが、「終了の 10 秒」と `.suddenTerminationDisabled` の関係を PLAN §8.15 に 1 行書きたい
6. **`ConfigStore` のログが起動時のレベルのまま**: `Bootstrap` は設定を読む前に `ConfigStore(log: log.withCategory("pipeline"))` を作るので、`ConfigStore` のログは設定の `logging.level` / `unsafeLogContent` ではなく起動時の既定（INFO・遮断あり）に従う。設定を読み直しても作り直さない。`ConfigStore` にログを差し替える口を足すか、PLAN §8.15 に「設定のログは既定のレベル」と書くか、判断が要る
