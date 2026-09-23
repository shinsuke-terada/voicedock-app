# T-40 VDPipeline: 削除の有効化・無効化・ロック 1 の修復と常時表示

> （F-84・issue #119。2026-09-23。マージ後の追記）(1) 削除が有効（`DeletionPanelState.showsSkippedToggle`＝アプリの設定が有効）で要対応に `reaperUpdateRequired` がある間は、「元音声の削除」の画面に赤いボタンの 3 秒長押し「更新する」（`Strings.buttonUpdateReaper`・`holdToUpdateHint`、読み上げは `holdToUpdateAccessibilityHint`）を出し、完了で `AppModel.enableDeletion()`（有効化フローをもう一度通す。PLAN §8.9.3 の 5）を呼ぶ（`AppModel.showsReaperUpdate`）。reaper.conf だけが有効な中途の状態では出さない。「更新する」の間は根拠 B のカードを出さない（`AppModel.showsSkippedDeletionCard`）。(2) 無効化の実行中は `AppModel.deletionDisabling` を立て、「無効にする」の下に進行の印と「読み取り専用へ戻しています…」（`Strings.disablingDeletion`）を出す（最後の再マウントの観測を待つ間）。途中の読み直しで条件が偽になってもカードを残す（`AppModel.showsDisableSection`）。(3) `enableError` はパネルを閉じたら戻し、閉じる前に始めた有効化・根拠 B が閉じた後に失敗しても立てない（T-30 の `panelDidClose`。`disableFailedStages` は戻さない）

> （F-65 で有効化の UI を長押しに変えた。2026-09-23、利用者の決定）「`ENABLE` の入力欄」をやめ、赤いボタンを 3 秒長押しさせる（`HoldToConfirmButton`。§4.7b）。
> `DeletionEnabler.enable(confirmation:)` と完全一致の判定はそのまま残し、UI は長押しの完了で定数 `DeletionStrings.confirmationWord` を渡す（`AppModel.enableDeletion()`・`enableSkippedDeletion()` は引数を持たない。§4.5）。
> `.notConfirmed` の文言は「赤いボタンを 3 秒長押ししてください」。「元音声の削除」は主画面の行から開く別の画面になった（T-30 §4.13）。以下の本文は F-65 に合わせて直した。

> （F-72・issue #112、2026-09-23。マージ後の追記）無効化の段 5 は、`scanNow()` の後の snapshot（`latestSnapshot()`。返った generation 以上）で接続中（`devices`）の全デバイスが `DeviceWritability` で `.readOnly` と観測できなければ `remount` の失敗にする（見送り・`.writable`・`.unknown` は失敗、0 台は成功。§4 の段 5 の本文はこれに合わせて直した。PLAN §8.9.8）。
> `EnablerBench` の既定の走査は読み取り専用の snapshot を返す（再マウントが通った観測）。有効化の事前確認の「最新の診断結果」は、パネルを閉じたら捨てる（`AppModel.panelDidClose`・`diagnosticsGeneration`。PLAN §8.9.8 の 1）。テストは `DisableRemountCheckTests`・`AppModelConsentTests`。

| 項目 | 値 |
|---|---|
| ID | T-40 |
| Phase | 8（削除） |
| 前提 | T-38（`DeleteQueue`・`ScriptedIngest`・`DeletionScene+Reaper`）、T-30（`AppModel`・`Bootstrap`・`IconState`）。間接に T-36（`LockEvaluator`・`LockDisplay`・`ReaperStatus`・`SignatureVerifier`・`FakeSignatureVerifier`・`DeletionScene`・`DeletionReason`）、T-18（`ConfigStore`・`setLock1Reconciler`・`IngestPort`）、T-10（`AppPaths.bundledReaperURL`）、T-06（`ReaperConf`・`AtomicFile`・`HomeLayout`） |
| 見積もり | Sources 約 330 行、Tests 約 620 行 |
| ブランチ | `feat/T-40-deletion-enabler` |
| 後続 | T-41（後追いのボタンが同じパネルに並ぶ）、T-42（実機 E2E の ON / OFF とゲート） |

## 1. 目的

三重ロックを**まとめて**外し、**まとめて**掛け直す 1 か所を作る（PLAN §8.9.8）。
赤いボタンの 3 秒の長押し（`DeletionEnabler` は確認語 `ENABLE` の完全一致）を求める有効化は全段が成功するか 1 つも変えないかのどちらかにし、無効化は確認を求めず消す能力に近いものから順に止める。
起動時に片方だけ有効な状態を無効側へ揃える `reconcileLock1()`（PLAN §6.1。CV-30 の自動修復）を `ConfigStore` に挿す。
パネルに出す 3 行のロック表示と注意書き、メニューバーの `trash` の表示条件を値として決め、T-30 の `AppModel` が読めるようにする。

## 2. 参照

- PLAN **§8.9.8（全体。有効化・無効化・ロック 1 の修復・常時表示）**、**§6.1（ロック 1 の食い違いの自動修復）**、§8.9.3（ロック 2-A。複製の手順 6・版の一致）、§8.9.2（三重ロックと readiness）、§6.4（CV-30・CV-33・CV-43・CV-48）、§8.12（パネル）、§9.4（PT-01・PT-11・PT-12）、付録 A.4（`deletion_enabled`・`deletion_disabled`・`config_warning`）、付録 B.3（E2E-17）、付録 F の **F-37**（無効化が自分の CV-30 に阻まれた）・F-51・F-52
- 00-api-map §11（`DeletionEnabler.swift`・`ConfigStore.swift`・`LockEvaluator.swift`・`DeleteQueue`）・§12（`AppModel`・`IconState`・`Strings`・`Panel/DeletionSection.swift`）・§15
- 先行チケット: T-36 §4.5・§4.6（`LockEvaluator`・`LockDisplay`・`ReaperStatus`）、T-36 §4.10（`FakeSignatureVerifier`・`DeletionScene`）、T-38 §4.3（`DeleteQueue`）・§4.11（`ScriptedIngest`・`installRealReaper`）、T-18 §4.2（`ConfigStore`）、T-09 §4（`AppConfig`・CV の表）
- voicedock@d3d595e: `scripts/enable-deletion.sh`（`ENABLE` の入力・`--disable` の順）、`helper/install.sh`（`--enable-deletion` / `--disable-deletion`）、`tests/unit/test_enable_deletion.py`（`test_enable_releases_both_systems`・`test_a_wrong_reply_changes_nothing`・`test_disable_puts_everything_back`・`test_disable_does_not_ask`）
- 移植メモ V1 §4.4（reaper.conf の書式）、V2（設定）、V3 §9（削除フロー）

## 3. 作るもの

| パス | 中身 |
|---|---|
| `Sources/VDPipeline/DeletionEnabler.swift` | `DeletionEnabler`（actor）・`EnableError`・`DeletionStage`（PT-01・PT-11・PT-12 の許可場所） |
| `Sources/VDPipeline/DeletionPanelState.swift` | `DeletionStrings`・`DeletionPanelState` |
| `Sources/VDPipeline/LockObserving.swift`（変更） | `LockDisplay`（T-32 のこのファイル。00-api-map §11）の行 2 の「削除モジュールの更新が必要です」を `DeletionStrings.reaperUpdateNotice` から取る（CR-06） |
| `Sources/VDPipeline/DeleteQueue.swift`（変更） | `withdrawAllRequests(layout:)` を足す |
| `Sources/VoiceDockApp/Bootstrap.swift`（変更） | `DeletionEnabler` を作り `ConfigStore.setLock1Reconciler` に挿す。`AppContext.enabler`・`LateBoundIngest` |
| `Sources/VoiceDockApp/AppModel.swift`（変更） | `deletion: DeletionPanelState?` と 3 つの操作の口 |
| `Sources/VoiceDockApp/AppServices.swift`（変更） | 有効化・無効化の 3 つの口（00-api-map §12「T-40 が有効化・無効化の口を足す」）と、`read` での `DeletionPanelState` の組み立て |
| `Sources/VoiceDockApp/AppSnapshot.swift`（変更） | `deletionEnabled` を `deletion: DeletionPanelState?` に置き換える（T-30 の「T-40 が lockDisplay を足す」） |
| `Sources/VoiceDockApp/IconState.swift`（変更） | `trash` を出す条件を `DeletionPanelState.showsTrash` から取る |
| `Sources/VoiceDockApp/Strings.swift`（変更） | 「元音声の削除」の節のボタン・無効化の失敗・`EnableError` の文言（§4.5 の表） |
| `Sources/VoiceDockApp/Panel/DeletionSection.swift`（変更） | 「元音声の削除」の節の中身（T-30 が「T-40 が中身を書く」とした。§4.7。F-65 で別の画面の中身に） |
| `Sources/VoiceDockApp/Panel/HoldToConfirmButton.swift` | （F-65 で追加）長押しで確かめる赤いボタン `HoldToConfirmButton`（internal）。§4.7b |
| `Tests/VoiceDockAppTests/FakeServices.swift`（変更） | `AppServices` に足した 3 つの口の偽物 |
| `Tests/VoiceDockAppTests/AppModelTests.swift`（変更） | `deletionEnabled` を `deletion` に、`AppContext` に `enabler` を渡す |
| `Tests/VDPipelineTests/EnablerBench.swift` | テストの舞台（`DeletionScene` ＋ 本物の `ConfigStore`） |
| `Tests/VDPipelineTests/DeletionEnablerTests.swift` | 有効化・無効化・`enableSkippedDeletion` |
| `Tests/VDPipelineTests/ReconcileLock1Tests.swift` | `reconcileLock1` と `ConfigStore.load` との配線（F-37 の回帰） |
| `Tests/VDPipelineTests/DeletionPanelStateTests.swift` | 3 行の逐語・`trash`・注意書き |
| `Tests/VDPipelineTests/DisableStopsDeletionTests.swift` | E2E-17 に対応する単体 |
| `Tests/VoiceDockAppTests/DeletionTextsTests.swift` | 節の文言と `EnableError` の文言の逐語 |
| `Tests/VoiceDockAppTests/AppModelDeletionTests.swift` | `AppModel` の 3 つの口（押したら `services` が呼ばれる・結果が画面の値になる） |
| `Tests/VoiceDockAppTests/HoldToConfirmButtonTests.swift` | （F-65 で追加）長押しの時間の計算（§6.9） |
| `Tests/PolicyTests/BootstrapOrderTests.swift` | `Bootstrap.build()` で修復口が最初の `config.load()` より前にあることのトークン検査 |
| `Tests/PolicyTests/ReaperInstallOrderTests.swift` | `installReaper` の本体が fsync → 署名検証 → chmod → rename の順で、書き込みの `open(` に `O_NOFOLLOW` があることのトークン検査 |

## 4. 仕様

共通: `p(url)` は `url.path(percentEncoded: false)`。ログのキーは `LogKey`、値は `LogValue`。
**`bundledReaperURL`・`binDirectory`・`reaperExecutable`・`reaperConf` の語を書いてよいのは `DeletionEnabler.swift` だけ**（`ReaperRunner.swift`・`LockEvaluator.swift`・`HomeLayout.swift` を除く。PT-11）。
`unlink(`（PT-01）と `O_CREAT`・`rename(`（PT-12）も `DeletionEnabler.swift` が許可場所。

### 4.1 `DeletionPanelState.swift`（「// パネルの「元音声の削除」に出す値と文言（PLAN §8.9.8）。逐語はここだけ（CR-06）。」）

```swift
import Foundation

public enum DeletionStrings {
    /// 有効化の事前確認（PLAN §8.9.8 の 1）
    public static let confirmVerified = "1 日以上の運用で Raw ノートが正しく作られていることを確かめましたか"
    public static let confirmIrreversible = "消した録音は戻りません"
    /// PLAN §8.9.8 の 2。完全一致でしか通さない
    public static let confirmationWord = "ENABLE"
    /// PLAN §8.9.8 の 5
    public static let reinsertNotice = "読み書きできるようになるのはデバイスを挿し直した後です"
    /// PLAN §8.9.3 の 5 / §8.9.8 のロック 2-A の行
    public static let reaperUpdateNotice = "削除モジュールの更新が必要です"
}

/// パネルとメニューバーが読む値（T-30 の AppModel が持つ）。
public struct DeletionPanelState: Equatable, Sendable {
    /// PLAN §8.9.8 の 3 行（LockDisplay.lines のまま）
    public let lines: [String]
    /// メニューバーのアイコンの横に `trash` を常に出すか
    public let showsTrash: Bool
    /// 3 行の下に足す注意書き（この順）
    public let notices: [String]
    /// 根拠 B が有効か
    public let skippedEnabled: Bool
    /// 「無音・重複も消す」を出すか
    public let showsSkippedToggle: Bool
    public init(display: LockDisplay, deleteSkippedSource: Bool)
}
```

`init(display:deleteSkippedSource:)`:
1. `lines = display.lines`
2. `showsTrash = display.appEnabled || display.confState == .enabled`
   （**片方だけ有効な中途の状態でも出す**。「消える可能性がある間はいつでも見える」。`readiness` では判定しない: デバイスが未接続なだけで消えてしまう）
3. `notices`（この順。当てはまるものだけ）:
   1. `display.reaper` が `.versionMismatch` → `DeletionStrings.reaperUpdateNotice`
   2. `showsTrash` が真で、`display.devices` に `writability` が `.readOnly` か `.unknown` のデバイスが 1 台以上 → `DeletionStrings.reinsertNotice`
4. `skippedEnabled = deleteSkippedSource`
5. `showsSkippedToggle = display.appEnabled`（PLAN §8.9.8「削除が有効なときだけ出し」。CV-43 と同じ条件）

`LockDisplay.swift` の変更: 行 2 の `versionMismatch` の文言を
`"導入済み（署名 OK, 版 " + (f ?? "不明") + "）。" + DeletionStrings.reaperUpdateNotice` にする（同じ文字列を 2 か所に書かない。CR-06）。

### 4.2 `DeleteQueue.swift` の変更

```swift
extension DeleteQueue {
    /// 無効化のときに `queue/delete` の要求を全部取り下げる（PLAN §8.9.8）。
    /// `.` で始まらない `*.json` を全部消す（中身は読まない。読めない要求も消す）。
    /// 戻り値は (消した数, 消せなかった数)
    static func withdrawAllRequests(layout: HomeLayout) -> (removed: Int, failed: Int)
}
```

`names(in: layout.queueDelete)` の各名前について `try? SafeUnlink.remove(layout.queueDelete.appendingPathComponent($0), under: .queueDelete, layout: layout)`。
投げなければ `removed += 1`、投げたら `failed += 1`。

- 結果（`queue/result`）は**消さない**（回収がまだ済んでいない DELETED を捨てない）
- DB の `delete_request_id` はここでは触らない。要求ファイルが無くなれば `RequestExpirer`（T-38）が期限で取り下げる（`DeletionEnabler` は `Store` を持たない）

### 4.3 `DeletionEnabler.swift`

```swift
// 三重ロックをまとめて外す・掛け直す唯一の場所（PLAN §8.9.8）。
// バンドル内の reaper を参照してよいのも <HOME>/bin/ へ書いてよいのもこのファイルだけ（D-5・PT-11）。
import Darwin
import Foundation
import Security
import VDContract
import VDCore

/// 段の名前（`disable()` の戻り値と `EnableError` が使う。逐語。ここ以外に書かない）
public enum DeletionStage {
    public static let copyReaper = "copy_reaper"
    public static let reaperConfFile = "reaper_conf"
    public static let config = "config"
    public static let removeReaper = "remove_reaper"
    public static let withdrawRequests = "withdraw_requests"
    public static let remount = "remount"
}

public enum EnableError: Error, Equatable, Sendable {
    /// `ENABLE` の完全一致でない（何も変えていない）
    case notConfirmed
    /// 複製に失敗した（段の説明。日本語）
    case install(String)
    /// 複製したファイルの署名検証に失敗した
    case signature
    /// bin/reaper.conf を書けない
    case reaperConfWrite(String)
    /// config.json の検証に落ちた・書けない
    case config([ConfigViolation])
    /// 設定が読み込まれていない（設定エラー中）
    case configNotLoaded
    /// 巻き戻しにも失敗した（`stages` は戻せなかった段の名前）
    case rollback(stages: [String])
}

public actor DeletionEnabler {
    public init(layout: HomeLayout, paths: AppPaths, config: ConfigStore,
                verifier: any SignatureVerifier, ingest: any IngestPort, log: AppLog)

    /// PLAN §8.9.8 の有効化。すべて成功するか、1 つも変えないか
    public func enable(confirmation: String) async -> Result<Void, EnableError>
    /// 根拠 B（無音・重複も消す）。削除が有効なときだけ通る
    public func enableSkippedDeletion(confirmation: String) async -> Result<Void, EnableError>
    /// PLAN §8.9.8 の無効化。**確認を求めない**。失敗した段の名前を順に返す（空なら全部成功）
    public func disable() async -> [String]
    /// PLAN §6.1。reaper.conf を無効側（DELETE_SOURCE_AUDIO=false）に揃える。揃えたら true
    public func reconcileLock1() async -> Bool
    /// 消す能力が残っているか（reaper.conf が DELETE_SOURCE_AUDIO=true で読めるか、bin/ に reaper の通常ファイルが在る）。
    /// 設定エラー中の常時表示（§4.5）に使う
    public func hasRemainingCapability() -> Bool

    static let confirmationWord = DeletionStrings.confirmationWord
    /// 複製の読み込みの上限（reaper は数 MB。壊れた入力で巨大な確保をしない）
    static let maxReaperBytes = 64 * 1024 * 1024
}
```

#### 4.3.0 操作の直列化（actor の再入）

actor は `await`（`config.current()`・`config.update`・`ingest.scanNow()`）の間に別の呼び出しを受け付ける。
有効化が `config.current()` で止まっている間に無効化が最後まで走り、その後で有効化が再開して全部有効になる経路を塞ぐため、
4 つの公開の操作（`enable`・`enableSkippedDeletion`・`disable`・`reconcileLock1`）は**受け付けた順に 1 本ずつ**実行する:

```swift
private var last: Task<Void, Never>?
private func serially<T: Sendable>(_ operation: @escaping @Sendable (DeletionEnabler) async -> T) async -> T {
    let previous = last
    let task = Task { [self] () -> T in
        await previous?.value
        return await operation(self)
    }
    last = Task { _ = await task.value }
    return await task.value
}
```

- `last` の差し替えは `await` を挟まずに行う（受け付けた順が保たれる）。有効化の実行中に来た無効化は、有効化の後に必ず走る（**無効化が勝つ**）
- 本体は `performEnable`・`performEnableSkipped`・`performDisable`・`performReconcile`（private）。以下の手順はその本体のもの
- `ConfigStore.load()` が `reconcileLock1()` を待っている間も `ConfigStore` は再入できるので、実行中の `enable` の `config.update` は進む（行き詰まらない）

#### 4.3.1 確認語の照合

`private func isConfirmed(_ s: String) -> Bool` = `PyText.scalarsEqual(s, Self.confirmationWord)`（VDCore。Swift の `==` は正準等価で比べるので使わない。00-api-map §0）。
`"enable"`・`"ENABLE "`・`" ENABLE"`・`"Y"`・`""`・`"ＥＮＡＢＬＥ"`（全角）はすべて偽。

#### 4.3.2 `enable(confirmation:)`（PLAN §8.9.8 の 3・4。書き込み順: 複製 → reaper.conf → config）

1. `guard isConfirmed(confirmation) else { return .failure(.notConfirmed) }`
2. `guard await config.current() != nil else { return .failure(.configNotLoaded) }`（設定エラー中は有効化しない）
3. **控える**（巻き戻しのため。ここではまだ何も書かない）:
   - `beforeConf: Data? = DeleteQueue.readSmallFile(layout.reaperConf)`
   - `beforeVolumesRoot: String` = `ReaperConf.observe(at: layout.reaperConf)` が `.valid(c)` なら `c.volumesRoot`、それ以外は `Contract.volumesRoot`
   - `reaperExisted: Bool` = `lstat(p(layout.reaperExecutable))` が成功して `S_IFREG`
4. **段 1「複製」** `installReaper()`（§4.3.3）。`.failure(e)` → **何も戻すものが無い**（`installReaper` が自分の tmp を消す）→ `.failure(e)`
5. **段 2「reaper.conf」** `writeReaperConf(deleteSourceAudio: true, volumesRoot: beforeVolumesRoot)`（§4.3.5）。
   失敗 → `rollback(to: beforeConf, reaperExisted: reaperExisted, stages: [.copyReaper])` → `.failure(.reaperConfWrite(説明))`（巻き戻しも失敗したら `.rollback(stages:)`）
6. **段 3「config」**
   ```swift
   let observation = ReaperConfObservation.valid(ReaperConf(deleteSourceAudio: true, volumesRoot: beforeVolumesRoot))
   let r = await config.update({ c in
       c.cleanup.deleteSourceAudio = true
       c.device.mountMode = DeletionEnabler.mountModeRW
   }, reaperConfObservation: observation)
   ```
   `.failure(v)` → `rollback(to: beforeConf, reaperExisted: reaperExisted, stages: [.reaperConfFile, .copyReaper])` → `.failure(.config(v))`
7. `log.info(.deletionEnabled, [(.reason, .string(DeletionStage.copyReaper))])` は**出さない**。`log.info(.deletionEnabled, [])` を 1 件だけ出す
8. `.success(())`

定数: `static let mountModeRW = "rw"`、`static let mountModeRO = "ro"`（`AppConfig` の `device.mountMode` は String。T-09 §4）。

`rollback(to:reaperExisted:stages:)`（**書いた順の逆に戻す**。戻せなかった段の名前を返す）:
1. `stages` に `.reaperConfFile` が在るとき: `beforeConf` が在れば `AtomicFile.write(beforeConf, to: layout.reaperConf, permissions: 0o644)`、
   無ければ `unlink(p(layout.reaperConf))`（`ENOENT` は成功）。失敗 → 戻せなかった段に足す
2. `stages` に `.copyReaper` が在り `reaperExisted == false` のとき: `unlink(p(layout.reaperExecutable))`（`ENOENT` は成功）。失敗 → 足す
   （**元から在ったなら消さない**。上書きしたのは同じバンドルの同じ実行ファイルなので戻す必要が無い）
3. 戻せなかった段が空でなければ、呼び手はその一覧で `.rollback(stages:)` を返す

#### 4.3.3 `installReaper()`（PLAN §8.9.3 の 6。複製の手順）

```swift
/// `.voicedock-reaper.tmp` → fsync → 署名検証 → chmod 0755 → rename
private func installReaper() -> Result<Void, EnableError>
```

1. `src = paths.bundledReaperURL`（**このファイルだけが参照してよい**。PT-11。ここから実行はしない）
2. 読む: `fd = open(p(src), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)` → `fstat` が `S_IFREG` → `st_size <= Self.maxReaperBytes` → 全部読む。
   どれかが偽 → `.failure(.install("同梱の削除モジュールを読めません"))`。どの経路でも `close`
3. `try? FileManager.default.createDirectory(at: layout.binDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])`
   （`bin/` は `HomeLayout.createDirectories()` が作らない。ロック 2-A のため既定では存在しない）
4. `tmp = AtomicFile.tmpURL(for: layout.reaperExecutable)`（= `bin/.voicedock-reaper.tmp`。同じ名前を 2 か所に書かない。CR-06）
5. 書く: `out = open(p(tmp), O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o700)` → 全部書く → `fsync(out)` → `close(out)`。
   失敗 → `unlink(p(tmp))`（失敗は無視）→ `.failure(.install("削除モジュールを書けません"))`
6. **署名検証** `verifier.verify(url: tmp)` が偽 → `unlink(p(tmp))` → `.failure(.signature)`
   （**実行できる場所に置く前に確かめる**。`chmod 0755` も `rename` もまだしていない）
7. `chmod(p(tmp), 0o755) == 0` でなければ → `unlink(p(tmp))` → `.failure(.install("削除モジュールの権限を設定できません"))`
8. `rename(p(tmp), p(layout.reaperExecutable)) == 0` でなければ → `unlink(p(tmp))` → `.failure(.install("削除モジュールを配置できません"))`
9. `bin/` を `open(O_RDONLY | O_DIRECTORY | O_CLOEXEC)` → `fsync` → `close`（どの失敗も無視）
10. `.success(())`

- `AtomicFile.write` を使わない: この手順は「tmp を作る」と「rename」の**間に署名検証と chmod を挟む**必要があり、`AtomicFile` の手順（書く → fsync → rename）に割り込めないため。PT-12 は `DeletionEnabler.swift` を許可場所に含む
- 検証するのは**複製した方**（`tmp`）であって同梱の元ではない（実際に置くバイト列を確かめる）

#### 4.3.4 `enableSkippedDeletion(confirmation:)`

1. `guard isConfirmed(confirmation) else { return .failure(.notConfirmed) }`
2. `guard let c = await config.current() else { return .failure(.configNotLoaded) }`
3. `guard c.cleanup.deleteSourceAudio else { return .failure(.config([])) }`（削除が無効なら通さない。CV-43 と同じ条件を先に見る。違反の配列は空 = 「前提が無い」）
4. `await config.update({ $0.cleanup.deleteSkippedSource = true })`（`reaperConfObservation` は渡さない = 今の値で検証する）。`.failure(v)` → `.failure(.config(v))`
5. `log.info(.deletionEnabled, [(.reason, .string(DeletionEnabler.skippedScope))])`、`.success(())`

定数: `static let skippedScope = "skipped_source"`。

#### 4.3.5 `disable()`（PLAN §8.9.8。確認を求めない。途中で失敗しても残りを続ける）

`var failed: [String] = []`

1. **reaper.conf を false**（reaper 側のロック 1 を先に掛ける）: `writeReaperConf(deleteSourceAudio: false, volumesRoot: 今の値)`。失敗 → `failed.append(DeletionStage.reaperConfFile)`
2. **reaper を削除**: `unlink(p(layout.reaperExecutable))`。`0` か `errno == ENOENT` なら成功。それ以外 → `failed.append(DeletionStage.removeReaper)`
3. **config を無効側**:
   ```swift
   let observation = ReaperConfObservation.valid(ReaperConf(deleteSourceAudio: false, volumesRoot: 今の値))
   let r = await config.update({ c in
       c.cleanup.deleteSourceAudio = false
       c.cleanup.deleteSkippedSource = false
       c.device.mountMode = DeletionEnabler.mountModeRO
   }, reaperConfObservation: observation)
   ```
   `.failure` → `failed.append(DeletionStage.config)`
   - **`observation` は「今の観測」ではなく「これから揃える先（false）」を渡す**（F-37。段 1 が失敗して reaper.conf が `true` のままでも、CV-30 に阻まれて止められない状態を作らない）。
     段 1 が失敗したままなら片方だけ無効になるが、次の `ConfigStore.load()` が CV-30 を見て `reconcileLock1()` で reaper.conf 側を揃える
4. **要求の取り下げ**: `let (_, f) = DeleteQueue.withdrawAllRequests(layout: layout)`。`f > 0` → `failed.append(DeletionStage.withdrawRequests)`
5. **再マウント**（F-72 で判定を観測にした）: `if await !remountedReadOnly() { failed.append(DeletionStage.remount) }`。
   `private func remountedReadOnly() async -> Bool` は
   `guard let generation = await ingest.scanNow(), let snapshot = await ingest.latestSnapshot(), snapshot.generation >= generation else { return false }`、
   `return snapshot.devices.keys.allSatisfy { DeviceWritability.observe(deviceID: $0, snapshot: snapshot) == .readOnly }`
   （走査が見送られた・走査の後の snapshot が無いか古い・読み書きできる・観測できない（`.unknown`。読み取り専用に丸めない）＝読み取り専用に戻せていない。0 台は真。`unavailable` の名前は観測が無いので見ない。§8.9.2 と同じ statfs の `MNT_RDONLY` の観測）
   - 呼ぶのは **`scanNow()` に統一する**（仕様 §8.9.8 の逐語も `ingest.scanNow()`）。かつて在った `IngestService.remountAllReadOnly()` は `_ = await scanNow()` の包みで戻り値（generation）を捨て、再マウントできたかを判定できないため、T-15 と地図から**消した**（呼び口を 2 つ持たない。§11 の提案 8）
6. ログ: `failed.isEmpty` なら `log.info(.deletionDisabled, [])`、
   そうでなければ `log.warning(.deletionDisabled, [(.reason, .string(failed.joined(separator: ",")))])`
7. `return failed`（段の順のまま）

`writeReaperConf(deleteSourceAudio:volumesRoot:)`:
`AtomicFile.write(ReaperConf(deleteSourceAudio: v, volumesRoot: r).render(), to: layout.reaperConf, permissions: 0o644)`。
`volumesRoot` の「今の値」= `ReaperConf.observe(at: layout.reaperConf)` が `.valid(c)` なら `c.volumesRoot`、それ以外は `Contract.volumesRoot`（**テストの `VOLUMES_ROOT` を消さない**）。

#### 4.3.6 `reconcileLock1()`（PLAN §6.1・§8.9.8）

1. `volumesRoot` = 上と同じ「今の値」
2. `writeReaperConf(deleteSourceAudio: false, volumesRoot:)`。失敗 →
   `log.warning(.configWarning, [(.rule, .string("CV-30")), (.message, .string("reaper.conf を無効側に揃えられません: " + ErrorText.describe(e)))])` → `false`
3. `true`

- **config.json 側はここで書かない。**`ConfigStore.load()` の手順 3（T-18 §4.2）が `reconcile()` の真を受けてから
  `deleteSourceAudio = false`・`deleteSkippedSource = false`・`mountMode = "ro"` を書き、`config_warning rule=CV-30` を出して読み直す。
  （PLAN §8.9.8 は「reaper.conf を false → config を無効側、の 2 段」と書くが、config 側を書くのは `ConfigStore` の責務に置いた。
  `DeletionEnabler` が `update` を呼ぶと、設定エラー中の `ConfigStore.update` が手順 1 で失敗して修復できない。§10 の提案 3）
- reaper の削除と要求の取り下げは**しない**（PLAN §8.9.8）

### 4.4 `Bootstrap.swift` の変更（T-30 のファイル）

```swift
let enabler = DeletionEnabler(layout: layout, paths: paths, config: configStore,
                              verifier: CodeSignatureVerifier(requirement: ReaperSignature.production),
                              ingest: ingest, log: log)
await configStore.setLock1Reconciler { [enabler] in await enabler.reconcileLock1() }
_ = await configStore.load()      // 修復口を挿した後に読む
```

- `setLock1Reconciler` は **`load()` より前**に呼ぶ（起動時の CV-30 を 1 回目の読み込みで直すため）
- T-30 の `Bootstrap` は 7 で `load()` し、11 で `IngestService` を**読み込んだ設定の時刻帯とログで**作る。`DeletionEnabler` は `ingest` を要るので、
  7 の中で `LateBoundIngest()`（`Bootstrap.swift` の internal な `final class LateBoundIngest: IngestPort`。`Mutex<IngestService?>` を持ち、`bind(_:)` の前は `nil`・`.idle`・すぐ終わるストリームを返す）を渡して作り、11 の直後に `enablerIngest.bind(ingest)` でつなぐ。
  13 の行は「7 でつないだ」のコメントにする
  - **なぜ中継か**（利用者の決定 2026-09-22）: 代わりに `IngestService` を `load()` の前に作ると、取り込み側のログが設定の時刻帯（`timeZone`）とレベル（`logging.level`）に従わなくなる。ログを設定に従わせる方を優先し、循環は中継で切る。`LateBoundIngest` は internal で Bootstrap の中だけで使う
  - この順は単体テストで動かせない（`Bootstrap.build()` は本番の <HOME> を使う）ので、`Tests/PolicyTests/BootstrapOrderTests.swift` が `func build(` の本体のトークンで「`setLock1Reconciler` が最初の `config.load()` より前」を検査する（コメントと文字列は数えない）
- `DeletionEnabler` は `AppContext.enabler` に持たせ、`LiveServices` が `AppModel` の 3 つの口から呼ぶ（`AppModel` は `AppServices` だけを見る。T-30）

### 4.5 `AppModel.swift` の変更（T-30 のファイル。UI への口）

```swift
extension AppModel {
    /// パネルとメニューバーが読む値。tick / 走査 / 操作のたびに作り直す
    var deletion: DeletionPanelState? { get }
    /// 「元音声の削除を有効にする」。赤いボタンの 3 秒の長押しが完了したときだけ呼ぶ（F-65）。
    /// services には定数 DeletionStrings.confirmationWord を渡す（完全一致の判定は DeletionEnabler。安全の二重化）
    func enableDeletion() async -> Result<Void, EnableError>
    /// 「無音・重複も消す」（同じ長押し。同じく定数を渡す）
    func enableSkippedDeletion() async -> Result<Void, EnableError>
    /// 「削除を無効にする」（確認なし）。失敗した段の名前をパネルに出す
    func disableDeletion() async -> [String]
}
```

- `deletion` の作り方: `LiveServices.read` が `AppSnapshot.deletion = DeletionPanelState(display: await context.locks.display(config: c, snapshot: s.device), deleteSkippedSource: c.cleanup.deleteSkippedSource)` を入れ、`AppModel.deletion` は `snapshot.deletion` を返す計算プロパティ（状態を 2 か所に持たない。CR-06）。設定エラー中は nil
- `AppServices` に足す口（`LiveServices` は `context.enabler` へそのまま委ねる）: `func enableDeletion(confirmation: String) async -> Result<Void, EnableError>`、`func enableSkippedDeletion(confirmation: String) async -> Result<Void, EnableError>`、`func disableDeletion() async -> [String]`
- `AppModel` の 3 つの操作は `services` を呼んでから `refresh()` する。成功した有効化は `private(set) var deletionNotice: String?` に `DeletionStrings.reinsertNotice` を入れ、無効化は `private(set) var disableFailedStages: [String]` に戻り値を入れて `deletionNotice` を消す
- `AppModel.showsTrash` は `IconState.showsTrash(deletion, residual: snapshot.deletionResidual)`（`IconState` の `static func showsTrash(_ deletion: DeletionPanelState?, residual: Bool) -> Bool`。`deletion` が在ればその `showsTrash`、nil なら `residual`）
- **設定エラー中の常時表示**（PLAN §8.9.8 の条件は「`deleteSourceAudio` が真 または reaper.conf が有効」で、設定エラーかどうかは入らない）: `LiveServices.read` は設定が読めないとき `AppSnapshot.deletionResidual = await context.enabler.hasRemainingCapability()` を入れる。真なら trash と「無効にする」だけを出す
- `AppModel.showsDisableButton` = `showsTrash || !disableFailedStages.isEmpty`（無効化で `remove_reaper` などが失敗して reaper が残った間も「無効にする」を出し続ける）
- 操作の実行中は `private(set) var deletionBusy` を立て、節のボタンを `.disabled(model.deletionBusy)` にする（二度押し対策。直列化は §4.3.0 が保証する）
- `deletionNotice` は、`refresh()` で読み書きできる（観測）デバイスを見たら消す（`DeviceWritability.observe` が `.writable` のデバイスが 1 台以上）
- `IconState`: `trash` を出すのは `deletion?.showsTrash == true` のときだけ（式を書き直さない）
- 有効化が成功したら、パネルに `DeletionStrings.reinsertNotice` を出す（PLAN §8.9.8 の 5）。
  挿し直すまでの間は `deletion.notices` にも同じ文言が載る（§4.1 の 3-2）
- 有効化の前に `DeletionStrings.confirmVerified` と `DeletionStrings.confirmIrreversible` と**最新の診断結果**（T-32 の `[DiagnosticResult]`）を出す
- 無効化の返り値が空でなければ、段の名前をそのまま並べて出す（`copy_reaper` などの語は英語のまま。ログと突き合わせるため）
- 有効化・根拠 B の失敗は `private(set) var enableError: EnableError?` に残し（成功と無効化で nil に戻す）、`Strings.enableFailed(_:)` で出す

`Strings` に足す文言（PLAN に無いので最小限。形は「有効にできませんでした: <理由>」。利用者の決定 2026-09-22）:

| ケース | 文言 |
|---|---|
| ボタン（有効化） | `有効にする` |
| ボタン（根拠 B） | `無音・重複も消す` |
| ボタン（無効化） | `無効にする` |
| 無効化の失敗 `disableFailed(stages)` | `無効にできなかった段: ` ＋ 段の名前を `, ` でつないだもの |
| `.notConfirmed` | `有効にできませんでした: 赤いボタンを 3 秒長押ししてください`（F-65。秒数は `HoldToConfirmButton.holdDuration` から作る） |
| `.install(m)` | `有効にできませんでした: 削除モジュールを置けません（m）` |
| `.signature` | `有効にできませんでした: 削除モジュールの署名を確かめられません` |
| `.reaperConfWrite(m)` | `有効にできませんでした: reaper.conf を書けません（m）` |
| `.config([])` | `有効にできませんでした: 元音声の削除が有効になっていません` |
| `.config(v)`（空でない） | `有効にできませんでした: 設定に書けません（` ＋ `v.map(\.rendered)` を `、` でつないだもの ＋ `）` |
| `.configNotLoaded` | `有効にできませんでした: 設定が読み込まれていません` |
| `.rollback(stages)` | `有効にできませんでした: 元に戻せなかった段があります（` ＋ 段の名前を `, ` でつないだもの ＋ `）` |

### 4.6 `Tests/VDPipelineTests/EnablerBench.swift`

```swift
// 有効化・無効化の舞台（DeletionScene に本物の ConfigStore を足したもの）。
import Foundation
import TestSupport
import VDContract
import VDCore
@testable import VDPipeline

struct EnablerBench {
    let scene: DeletionScene
    let store: ConfigStore
    let ingest: ScriptedIngest
    let enabler: DeletionEnabler
    let paths: AppPaths
    let verifier: FakeSignatureVerifier
    /// <tmp>/VoiceDock.app/Contents/Helpers/voicedock-reaper（同梱の reaper に見立てた 32 バイトのファイル）
    let bundledReaper: URL

    /// 既定は「削除 OFF の初期状態」（reaper 無し・reaper.conf 無し・config は false/false/ro）
    init(enabled: Bool = false, realReaper: Bool = false) async throws

    func config() async -> AppConfig?
    func reaperConf() -> ReaperConfObservation
    func reaperIsInstalled() -> Bool
    func reaperMode() -> mode_t?                 // lstat の st_mode & 0o777
    func tmpCopyExists() -> Bool                 // bin/.voicedock-reaper.tmp
    func logLines() -> [String]                  // scene.logLines
}
```

`init` の手順:
1. `scene = try DeletionScene()`（T-36。三重ロックを全部外した状態で作られる）
2. `paths`: `resources` は `PackageRoot.file("Resources")`、`helpers` は `<tmp>/VoiceDock.app/Contents/Helpers`（作る）。
   `bundledReaper = paths.bundledReaperURL` に 32 バイトの固定の内容（`Data(repeating: 0x2A, count: 32)`）を書き 0o755 にする
3. `enabled == false` なら初期状態に戻す: `scene.removeReaper()`、`scene.removeReaperConf()`、
   `scene.updateConfig { $0.cleanup.deleteSourceAudio = false; $0.cleanup.deleteSkippedSource = false; $0.device.mountMode = "ro" }`
4. `scene.config` を `ConfigLoader.encode` して `layout.configFile` に書く（`AtomicFile`）
5. `store = ConfigStore(layout: scene.layout, catalog: TestCatalogs.minimal, log: scene.log, observeReaperConf: { [layout = scene.layout] in ReaperConf.observe(at: layout.reaperConf) }, defaultTimeZone: { "Asia/Tokyo" })`、`_ = await store.load()`
6. `ingest = ScriptedIngest(snapshot: scene.snapshot())`、`await ingest.setScanner { [scene] g in scene.snapshot(generation: g) }`（台本が尽きたら generation を 1 つ進めた同じ snapshot を返す。`ScriptedIngest` は scanner を渡さないと見送る）
7. `verifier = scene.verifier`（`FakeSignatureVerifier(valid: true)`）
8. `enabler = DeletionEnabler(layout: scene.layout, paths: paths, config: store, verifier: verifier, ingest: ingest, log: scene.log)`
9. `realReaper` が真なら `try scene.installRealReaper()`（T-38。本物の実行ファイルを bin に置く）。
   **本物の reaper と既定の `VOLUMES_ROOT=/Volumes` を組み合わせない**: reaper.conf が `.valid` で `volumesRoot != Contract.volumesRoot` でなければ `BenchError` を投げる（`enabled: false` と `realReaper: true` の組は投げる）

- `/Volumes` には触れない（`DeletionScene` の約束のまま）

### 4.7 `Panel/DeletionSection.swift`（T-30 のファイル。PLAN §8.9.8・§8.12 の 7。F-65 で「元音声の削除」の画面の中身）

主画面には「› 元音声の削除  有効／無効」の行（T-30 §4.13 の `PanelRow`）を、`DeletionSection.isAvailable(model)`（`model.deletion != nil || model.showsDisableButton`）のときだけ出す。押すと `model.show(.deletion)` で別の画面になり、`SubScreen(title: Strings.sectionDeletion)` の中にこの順で出す:
1. カード（見出しは `deletion.showsTrash` なら `Strings.deletionOn`、でなければ `Strings.deletionOff`）に `deletion.lines`（3 行。等幅）と `deletion.notices`
2. 同じカードに `model.deletionNotice`（`deletion.notices` に同じ文言が無いときだけ）
3. `deletion.showsTrash` が真なら:
   - `showsSkippedToggle` が真で `skippedEnabled` が偽なら、カードに `Strings.holdToEnableHint` と `HoldToConfirmButton(title: Strings.buttonEnableSkippedDeletion, disabled: model.deletionBusy)`。長押しが完了したら `enableSkippedDeletion()`
4. 偽なら（有効化の前）: カードに `DeletionStrings.confirmVerified`・`DeletionStrings.confirmIrreversible`、診断が済んでいれば `Diagnostics.summary(結果)`、済んでいなければ `Strings.buttonRunDiagnostics`。続けて `Strings.holdToEnableHint` と `HoldToConfirmButton(title: Strings.buttonEnableDeletion, disabled: model.deletionBusy)`。長押しが完了したら `enableDeletion()`（**クリック 1 回・途中で離した長押しでは呼ばない**。確認語の判定は `DeletionEnabler`）
5. `model.showsDisableButton` が真なら `Strings.buttonDisableDeletion`（**確認を出さない。1 クリック**。`.disabled(model.deletionBusy)`）→ `disableDeletion()`
6. `model.enableError` があれば `Strings.enableFailed(_:)`、`model.disableFailedStages` が空でなければ `Strings.disableFailed(_:)`（赤）
7. `model.deletion` が nil で `showsDisableButton` も偽のときに画面が開いていれば `Strings.deletionUnavailable` だけ

設定エラー中で消す能力が残っていれば（`deletion == nil` かつ `showsDisableButton`）、5 と 6 だけを出す（PLAN §8.9.8 の常時表示）。

### 4.7b `Panel/HoldToConfirmButton.swift`（F-65。PLAN §8.9.8 の 2）

```swift
struct HoldToConfirmButton: View {
    nonisolated static let holdDuration: Double = 3.0   // 押し続ける秒数
    static let tickMilliseconds = 16                     // 押している間の進捗の更新の間隔
    let title: String
    let disabled: Bool
    let onConfirm: @MainActor () -> Void

    struct Progress: Equatable { let fraction: Double; let complete: Bool }
    /// 経過時間 → 進捗。純関数。fraction は 0〜1 に丸め、complete は elapsed >= duration。duration が 0 以下なら完了扱い
    nonisolated static func progress(elapsed: Double, duration: Double = holdDuration) -> Progress

    /// 押し始めの時刻と、完了を知らせたか。完了の知らせは 1 回の押下につき 1 回だけ
    struct Tracker: Equatable {
        let duration: Double
        private(set) var startedAt: Double?
        private(set) var fired: Bool
        init(duration: Double = HoldToConfirmButton.holdDuration)
        var isHolding: Bool { get }
        mutating func press(at t: Double)      // 押している間の 2 回目は無視（押し始めを動かさない）
        mutating func release()                // 途中でも完了後でも最初に戻す
        func progress(at t: Double) -> Progress // 押していなければ 0
        mutating func tick(at t: Double, stillPressed: Bool = true) -> Bool // 完了に達した最初の 1 回だけ true。stillPressed が偽なら release して false
    }
}
```

- 見た目: 赤いカプセル（押せないときは灰色）に、白い進捗のリングと題。押している間の題は `Strings.holdKeepPressing`
- `DragGesture(minimumDistance: 0)` の `onChanged` で押し始め、`onEnded` で離す。押し始めで `Tracker.press(at:)` し、`tickMilliseconds` ごとに `progress(at:)` でリングを描き直し、`tick(at:)` が true になったら `onConfirm()` を 1 回呼んで更新を止める
- 時刻は `SystemClock().uptime()`（単調な時計。`@State` に持ち、ビューの寿命の間は起点を動かさない。PT-09 に触れない）
- 離した・`disabled` が真になった・画面から消えたら、途中でも `Tracker.release()` してリングを 0 に戻す（何もしない）
- 同じ押下は、完了した後や押せなくなった後に離さないまま数え直さない（`awaitingRelease`。離すまで押し直しと見なさない）
- 押しているかは `@GestureState`（`pressing`）でも持つ。`onEnded` を経ずにジェスチャーが取り消されたとき（押したまま popover が閉じた等）は `pressing` が偽に戻るので、`onChange` と `tick(at:stillPressed: pressing)` の両方で止め、`onConfirm` を呼ばない
- 更新の待ちは `Task.sleep(for: .milliseconds(16))` を直接使う（`Sleeper` は秒単位で 16ms を表せない。`AppDelegate` の終了待ちと同じ例外。CR-08）
- VoiceOver の `accessibilityAction` は付けない（1 回の操作で有効化できる経路になるため）

ビューそのものはテストしない。文言は §6.5、口は §6.6 で守る。

## 5. ログ（このチケットが出すもの）

| イベント | レベル | フィールド | 出す場所 |
|---|---|---|---|
| `deletion_enabled` | INFO | （無し） | `enable` の成功 |
| `deletion_enabled` | INFO | `reason=skipped_source` | `enableSkippedDeletion` の成功 |
| `deletion_disabled` | INFO | （無し） | `disable` が全段成功 |
| `deletion_disabled` | WARNING | `reason=<失敗した段を "," でつないだもの>` | `disable` に失敗した段が在る |
| `config_warning` | WARNING | `rule=CV-30` `message=…` | `reconcileLock1` が reaper.conf を書けなかったとき |

（`config_warning rule=CV-30 message=reaper.conf と config.json の削除の設定を無効側に揃えました` を出すのは `ConfigStore.load()`。T-18 §4.2 の手順 3-4）

## 6. テスト

すべて `import Testing`、`import TestSupport`、`@testable import VDPipeline`。

### 6.1 `DeletionEnablerTests.swift`（`@Suite("DeletionEnabler") struct DeletionEnablerTests`）

**有効化**（準備は `EnablerBench()`＝削除 OFF の初期状態）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `enableTurnsAllThreeLocksOff` | 有効化で 3 つのロックが全部外れる | `enable(confirmation: "ENABLE")` | `.success`、reaper が 0o755 の通常ファイル、`reaperConf() == .valid(ReaperConf(deleteSourceAudio: true, volumesRoot: <Volumes>))`、config が `deleteSourceAudio == true`・`mountMode == "rw"`・`deleteSkippedSource == false`、`bin/.voicedock-reaper.tmp` が無い、`deletion_enabled` が 1 行 |
| `enableWritesTheConfVerbatim` | reaper.conf の中身は 3 行＋末尾改行 | 同上 | ファイルのバイト列が `"SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=" + p(volumesRoot) + "\n"`、権限 0o644 |
| `enableVerifiesTheCopyNotTheBundle` | 署名を検証するのは複製した方 | 同上 | `verifier.verifiedURLs == [bin/.voicedock-reaper.tmp]`（同梱の元を検証していない） |
| `enableRequiresTheExactWord` | `ENABLE` 以外では何も変えない | `"enable"`・`"ENABLE "`・`" ENABLE"`・`"Y"`・`""`・`"ＥＮＡＢＬＥ"`・`"ENABLE\u{200B}"`・`"ENABLE\n"`（パラメタ化） | `.failure(.notConfirmed)`、reaper 無し、reaper.conf 無し、config が false/ro、ログ 0 行 |
| `enableRollsBackWhenTheSignatureFails` | 署名が通らなければ 1 つも変わらない | `verifier.setValid(false)` | `.failure(.signature)`、reaper 無し、tmp 無し、reaper.conf 無し、config が false/ro |
| `enableRollsBackWhenTheConfCannotBeWritten` | reaper.conf を書けなければ reaper を消して戻す | `bin/reaper.conf` を**ディレクトリ**として作っておく（`rename` が失敗する） | `.failure(.reaperConfWrite(_))`、**reaper が無い**、tmp 無し、config が false/ro |
| `enableRollsBackWhenTheConfigIsRejected` | config を書けなければ reaper.conf を戻し reaper を消す | `layout.configFile` を 0o444、`layout.root` を 0o555 にして書き込みを塞ぐ | `.failure(.config(_))`、reaper が無い、**reaper.conf が無い**（元が無かったので消える）、config.json のバイト列が変わらない |
| `enableRestoresTheOldConfOnRollback` | 巻き戻しは元の reaper.conf の内容に戻す | 先に `writeReaperConfRaw("SCHEMA=1\nDELETE_SOURCE_AUDIO=false\nVOLUMES_ROOT=/x\n")` を置き、config を書けなくする | reaper.conf のバイト列が元のまま（`/x` が残る） |
| `enableKeepsAnExistingReaperOnRollback` | 元から在った reaper は巻き戻しで消さない | `scene.installReaperStub()` で先に置く。config を書けなくする | `.failure(.config(_))`、**reaper が在る** |
| `enableRefusesWhenTheConfigIsNotLoaded` | 設定エラー中は有効化しない | `config.json` を壊して `store.load()` | `.failure(.configNotLoaded)`、何も変わらない |
| `enableKeepsTheVolumesRootOfTheOldConf` | 既存の `VOLUMES_ROOT` を引き継ぐ | 先に `VOLUMES_ROOT=/x` の conf（false）を置く | 新しい conf が `DELETE_SOURCE_AUDIO=true`・`VOLUMES_ROOT=/x` |

**根拠 B**

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `enableSkippedSetsTheFlag` | 根拠 B を `ENABLE` で有効にする | `EnablerBench(enabled: true)` → `enableSkippedDeletion("ENABLE")` | `.success`、`deleteSkippedSource == true`、`deletion_enabled reason=skipped_source` |
| `enableSkippedRequiresTheExactWord` | `ENABLE` 以外では通らない | 同上に `"y"` | `.failure(.notConfirmed)`、false のまま |
| `enableSkippedRequiresDeletionEnabled` | 削除が無効なら根拠 B にできない（CV-43） | `EnablerBench()`（OFF）→ `"ENABLE"` | `.failure(.config([]))`、false のまま |

**無効化**（準備は `EnablerBench(enabled: true)`＝三重ロックが外れた状態。要求を 2 件置く）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `disableTurnsEverythingBackOnWithoutAsking` | 無効化は確認なしで全部掛け直す | `disable()` | `[]`、`reaperConf()` が `.valid(false)`、reaper 無し、config が false/false/ro、`queue/delete` が空、`ingest.scanNowCalls == 1`、`deletion_disabled` が INFO で 1 行 |
| `disableIsNotBlockedByItsOwnCV30` | `F-37` 回帰: reaper.conf を書けなくても config は無効になる | `AtomicFile.tmpURL(for: layout.reaperConf)`（`bin/.reaper.conf.tmp`）をディレクトリにして段 1 を失敗させる（config は true、conf も **true のまま読める**。conf をディレクトリにすると観測が `.invalid` になり CV-30 が出ないので、破壊による証明 12 が落ちない） | 戻り値に `"reaper_conf"` が在る、**`config.cleanup.deleteSourceAudio == false`**、reaper 無し、要求 0 件、`scanNowCalls == 1` |
| `disableContinuesAfterAFailedStage` | 途中で失敗しても残りを続ける | reaper を消し、その位置を空でないディレクトリにして段 2 の `unlink` を失敗させる（`bin/` を 0o555 にすると段 1 の reaper.conf も書けない） | 戻り値が `["remove_reaper"]`、conf false、config false、要求 0 件、`scanNowCalls == 1` |
| `disableWithdrawsEveryRequest` | 要求を全部取り下げる（結果は残す） | 要求 3 件＋`.tmp.json`（`.` 始まり）＋結果 1 件 | `queue/delete` に `.` 始まりだけが残る、`queue/result` が 1 件のまま |
| `disableReportsARefusedRemount` | 再マウントが見送られたら段の名前を返す | `ingest.script([.skip])` | 戻り値が `["remount"]`、ほかは全部成功、`deletion_disabled` が WARNING で `reason=remount` |
| `disableOnAFreshHomeSucceeds` | 何も無い状態でも成功する（TEST-28） | `EnablerBench()`（OFF、reaper 無し・conf 無し・要求 0 件） | `[]`、conf が `.valid(false)`（新しく書かれる）、config が false/false/ro |
| `disableReportsTheStagesInOrder` | 失敗した段は順番どおりに返る | 段 1（conf をディレクトリ）と段 2（bin を 0o555）を同時に失敗させる | `["reaper_conf", "remove_reaper"]`（この順） |
| `disableReportsConfBeforeConfig` | 無効化は reaper.conf を config より先に止める | 段 1（`bin/.reaper.conf.tmp` をディレクトリ）と段 3（config を書けなくする）を同時に失敗させる | `["reaper_conf", "config"]`（この順） |
| `disableReportsRemoveReaperBeforeConfig` | 無効化は reaper の削除を config より先に行う | 段 2（reaper の位置を空でないディレクトリ）と段 3 を同時に失敗させる | `["remove_reaper", "config"]`（この順） |
| `disableScansLast` | 無効化の再マウントはほかの段が全部済んでから | scanner のクロージャの中で conf・reaper・config.json・queue/delete を記録 | 走査の時点で conf が false、reaper 無し、config.json が `"deleteSourceAudio" : false`、要求 0 件 |
| `disableDuringEnableWins` | 有効化の途中で来た無効化は有効化の後に走る（無効化が勝つ） | `store.update` の mutate で `ConfigStore` を塞ぎ、`enable` を `config.current()` で止めてから `disable` を呼び、塞ぎを外す | `enable` は成功、`disable` は `[]`、最終状態が conf false（`/Volumes`）・reaper 無し・config false/false/ro |
| `noRemainingCapabilityOnAFreshHome` | TEST-28 何も無ければ消す能力は残っていない | `EnablerBench()` | `hasRemainingCapability() == false` |
| `confKeepsTheCapability` | reaper.conf が有効なら消す能力が残っている | conf true | true |
| `reaperKeepsTheCapability` | reaper が在れば消す能力が残っている | `installReaperStub()` | true |
| `disabledConfWithoutReaperHasNoCapability` | reaper.conf が無効で reaper が無ければ残っていない | conf false | false |
| `benchRefusesRealReaperWithoutTheSceneVolumesRoot` | 舞台: 本物の reaper と既定の /Volumes は組み合わせない | `EnablerBench(enabled: false, realReaper: true)` | `BenchError` を投げる |

### 6.2 `ReconcileLock1Tests.swift`（`@Suite("ロック 1 の修復（PLAN §6.1）")`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `reconcileTurnsTheConfOff` | reaper.conf を無効側に揃えて true | `EnablerBench(enabled: true)` → `reconcileLock1()` | `true`、`reaperConf()` が `.valid(false)`、**config.json は変わらない**、reaper は在るまま、要求も残る |
| `reconcileKeepsTheVolumesRoot` | `VOLUMES_ROOT` を消さない | 同上（conf の `VOLUMES_ROOT` は舞台の一時ディレクトリ） | 新しい conf の `volumesRoot` が同じ |
| `reconcileWritesTheConfEvenWhenItIsMissing` | conf が無くても無効側の conf を書く | `scene.removeReaperConf()` | `true`、`.valid(false)` |
| `reconcileFailsWhenTheConfCannotBeWritten` | 書けなければ false と `config_warning` | `bin/reaper.conf` をディレクトリに | `false`、`config_warning rule=CV-30` が 1 行 |
| `cv30IsReconciledOnLoad` | `F-37` 回帰: 片方だけ有効な状態が読み込みで無効側に揃う | config は true/rw、reaper.conf は `DELETE_SOURCE_AUDIO=false`。`store.setLock1Reconciler { await enabler.reconcileLock1() }` を挿して `store.load()` | `.valid(c)`（**設定エラーにならない**）、`c.cleanup.deleteSourceAudio == false`・`deleteSkippedSource == false`・`mountMode == "ro"`、`reaperConf()` が `.valid(false)`、`config_warning rule=CV-30` が 1 行 |
| `cv30TheOtherDirectionIsAlsoReconciled` | 逆向き（config false・conf true）も無効側に揃う | config は false/ro、reaper.conf は true | 同上（config はもともと false、conf が false になる） |
| `cv30BecomesAConfigErrorWhenTheConfCannotBeFixed` | 揃えられなければ設定エラーにする | 上の準備に加えて `bin/reaper.conf` を書けなくする（親を 0o555） | `.invalid(v)` に `rule == "CV-30"` が在る、`config_invalid` のログ |
| `loadWithoutAReconcilerIsAConfigError` | 修復口を挿していなければ設定エラーのまま（対照） | `setLock1Reconciler` を呼ばずに `load()` | `.invalid(v)` に CV-30 |

### 6.3 `DeletionPanelStateTests.swift`（`@Suite("DeletionPanelState")`）

準備: `LockDisplay` を直接組み立てる（`LockEvaluator` を通さない。値の写像だけを見る）。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `linesAreVerbatim` | 3 行が PLAN §8.9.8 の逐語 | `appEnabled: true`、`confState: .enabled`、`reaper: .valid(version: "1.0.0")`、`mountMode: "rw"`、`devices: [("DJIMIC3", .writable)]`、`readiness: .configured` | `lines == ["ロック 1  : アプリ=有効, reaper.conf=有効", "ロック 2-A: 削除モジュール=導入済み（署名 OK, 版 1.0.0）", "ロック 2-B: 設定=rw, DJIMIC3=読み書き可能（観測）"]` |
| `trashIsShownWhileEitherSideIsEnabled` | 片方だけ有効でも `trash` を出す | (app true, conf disabled) / (app false, conf enabled) / (app true, conf enabled) / (app false, conf missing)（パラメタ化） | 順に true / true / true / false |
| `trashIsShownEvenWhenTheDeviceIsAbsent` | デバイスが未接続でも `trash` は消えない | app true、`devices: []`、`readiness: .disabled("mount_mode_ro")` | `showsTrash == true` |
| `reinsertNoticeWhileTheDeviceIsReadOnly` | 観測が読み取り専用の間は挿し直しの案内を出す | app true、`devices: [("DJIMIC3", .readOnly)]` | `notices == [DeletionStrings.reinsertNotice]` |
| `reinsertNoticeWhenTheObservationIsUnknown` | 観測できないときも案内を出す | `devices: [("DJIMIC3", .unknown)]` | 同上 |
| `noReinsertNoticeWhenDeletionIsOff` | 削除が無効なら案内は出さない | app false・conf missing、`devices: [("DJIMIC3", .readOnly)]` | `notices == []` |
| `updateNoticeOnVersionMismatch` | 版が違えば更新の案内を出す | `reaper: .versionMismatch(found: "0.9.0")`、`devices: [("DJIMIC3", .writable)]` | `notices == [DeletionStrings.reaperUpdateNotice]`、行 2 の末尾が同じ文言で終わる |
| `bothNoticesAppearInOrder` | 2 つとも当てはまれば更新が先 | `reaper: .versionMismatch(found: nil)`、`devices: [("DJIMIC3", .readOnly)]` | `notices == [reaperUpdateNotice, reinsertNotice]` |
| `noNoticesWhenEverythingIsReleased` | 全部外れていれば案内は無い | `linesAreVerbatim` と同じ | `notices == []` |
| `skippedToggleFollowsTheAppSetting` | 「無音・重複も消す」は削除が有効なときだけ出す | app true / app false | true / false |
| `confirmationWordIsVerbatim` | 確認語は `ENABLE` | — | `DeletionStrings.confirmationWord == "ENABLE"`、`DeletionEnabler.confirmationWord` が同じ値 |

### 6.4 `DisableStopsDeletionTests.swift`（`@Suite("E2E-17 の単体: 無効化で以後削除されない", .serialized)`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `e2e17DisableStopsFurtherRequests` | `E2E-17` 無効化の後は要求が書かれない | `EnablerBench(enabled: true, realReaper: true)`。まず `SessionDeletionStage`（T-38）を 1 回回して要求が 1 件書かれることを確かめる（正の対照）→ `enabler.disable()` → 新しい `DeletionDependencies` で同じ段をもう一度回す | 1 回目は要求 1 件・`readiness == .configured`。`disable()` が `[]`。2 回目は要求 0 件、`readiness == .disabled(DeletionReason.deleteSourceAudioDisabled)`、`source_delete_skipped reason=delete_source_audio_disabled` |
| `e2e17DisableWithdrawsTheRequestInFlight` | `E2E-17` 途中の要求も取り下げられる | 1 回目の後（要求 1 件）に `disable()` | `queue/delete` が空、Part の `delete_request_id` は残る（`RequestExpirer` が期限で外す。T-38 の担当） |
| `e2e17DisableRemountsAtOnce` | `E2E-17` 直ちに再マウントを促す | 同上 | `ingest.scanNowCalls == 1` |
| `e2e17TheReaperIsGone` | `E2E-17` 削除モジュールが消える | `realReaper: true` で有効な状態から `disable()` | `reaperIsInstalled() == false`、`readiness == .disabled(delete_source_audio_disabled)`（config が先に落ちる） |

### 6.5 `Tests/VoiceDockAppTests/DeletionTextsTests.swift`（`@Suite("元音声の削除の文言")`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `labelsAreVerbatim` | ボタンと無効化の失敗の文言は逐語 | — | §4.5 の表のボタン 3 つ、`Strings.sectionDeletion == "元音声の削除"`、`disableFailed(["reaper_conf", "remount"]) == "無効にできなかった段: reaper_conf, remount"` |
| `planTextsAreVerbatim` | PLAN §8.9.8 の事前確認・確認語・挿し直しの案内は逐語 | — | `DeletionStrings` の 4 つが §4.1 の逐語 |
| `enableFailureTextsAreVerbatim` | EnableError の各ケースの文言は逐語（T-40 §4.5 の表） | 8 ケース（パラメタ化。`.config` は空と違反 1 件の 2 通り） | §4.5 の表のとおり |
| `disableFailedWithNoStages` | TEST-28 段が 0 件でも無効化の失敗の文言は落ちない | `disableFailed([])` | `"無効にできなかった段: "` |

### 6.6 `Tests/VoiceDockAppTests/AppModelDeletionTests.swift`（`@Suite("AppModel+Deletion")`。`FakeServices` を使う。`disableDeletion` を止める `setHoldDisable` / `releaseDisable` を足す）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `enablePassesTheConstantWordAndShowsTheReinsertNotice` | 長押しの完了で呼ぶ有効化は定数の確認語 ENABLE を services に渡し、成功したら挿し直しの案内を出す（F-65） | `enableDeletion()` | `fake.enableConfirmations == ["ENABLE"]`、`skippedConfirmations == []`、`deletionNotice == DeletionStrings.reinsertNotice` の逐語、`enableError == nil`、`read` が 1 回 |
| `enableFailureIsKept` | 有効化の失敗は enableError に残り、案内は出さない | `setEnableResult(.failure(.notConfirmed))` | `enableError == .notConfirmed`、`deletionNotice == nil` |
| `enableSkippedPassesTheConstantWord` | 根拠 B も長押しの完了で定数の確認語 ENABLE を services に渡す（F-65） | `setEnableResult(.failure(.config([])))` → `enableSkippedDeletion()` | `skippedConfirmations == ["ENABLE"]`、`enableConfirmations == []`、`enableError == .config([])` |
| `disableCallsServicesOnceAndKeepsTheStages` | 無効化は確認なしで services を 1 回呼び、失敗した段をそのまま持つ | `setDisableResult(["reaper_conf", "remount"])`、先に有効化 | `disableCount == 1`、戻り値と `disableFailedStages` が同じ 2 語、`deletionNotice == nil` |
| `disableWithNoFailures` | TEST-28 無効化がすべて成功すれば段の表示は空 | 既定 | `[]` |
| `deletionAndTrashFollowTheSnapshot` | deletion は観測の写しのまま、trash は DeletionPanelState.showsTrash に従う | (app false, conf enabled) → (app false, conf missing) | `deletion` が写しのまま、`showsTrash` が true → false |
| `noTrashWithoutDeletionState` | TEST-28 設定エラー中で消す能力も残っていなければ trash も「無効にする」も出さない | `deletion: nil`、`deletionResidual: false` | `deletion == nil`、`showsTrash == false`、`showsDisableButton == false` |
| `residualCapabilityShowsTrashAndDisable` | 設定エラー中でも消す能力が残っていれば trash と「無効にする」を出す（PLAN §8.9.8） | `configPresent: false`、`deletionResidual: true` | `showsTrash == true`、`showsDisableButton == true` |
| `failedDisableKeepsTheButton` | 無効化に失敗した段がある間は「無効にする」を出し続ける | (app false, conf disabled)、`setDisableResult(["remove_reaper"])` | `showsTrash == false`、`showsDisableButton == true` |
| `busyWhileOperating` | 操作の実行中は deletionBusy が立ち、終われば下りる | `setHoldDisable(true)` | 実行中 true、`releaseDisable()` の後 false |
| `reinsertNoticeClearsOnWritableDevice` | 挿し直しの案内は、読み書きできるデバイスを観測したら消える | 読み取り専用の観測で有効化 → 読み書きできる観測に替えて `refresh()` | 案内が出て、替えた後に nil |

### 6.9 `Tests/VoiceDockAppTests/HoldToConfirmButtonTests.swift`（`@Suite("HoldToConfirmButton")`。F-65。ビューは作らない）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `holdDurationIsThreeSeconds` | 押し続ける時間は 3 秒（PLAN §8.9.8 の 2） | — | `holdDuration == 3.0` |
| `progressFollowsElapsedTime` | 経過時間 → 進捗と完了（0 秒・1.5 秒・3.0 秒・それより後） | 0・1.5・3.0・4.5（パラメタ化） | (0, 偽)・(0.5, 偽)・(1, 真)・(1, 真) |
| `almostThereIsNotComplete` | 2.99 秒ではまだ完了しない（リングはほぼ満ちている） | 2.99 | `complete == false`、`0.99 < fraction < 1` |
| `zeroAndNegativeElapsedAreNotComplete` | TEST-28 押した瞬間（0 秒）と負の経過は完了せず、進捗は 0 | 0・-1 | どちらも (0, 偽) |
| `idleTrackerNeverFires` | 押していなければ進捗は 0 で、完了を知らせない | `Tracker()` | `isHolding == false`、`progress(at: 100)` が (0, 偽)、`tick(at: 100) == false` |
| `firesExactlyOnce` | 3 秒押し続けたら完了を 1 回だけ知らせる（押したままの次の tick では知らせない） | `press(at: 10)` → `tick` を 10・11.5・12.99・13.0・13.016・20 | 13.0 だけ true。`progress(at: 20)` が (1, 真) |
| `releasingEarlyCancels` | 途中で離すと何もしない（離した後の tick も、時間が過ぎても知らせない） | `press(at: 10)` → `tick(at: 11.5)` → `release()` → `tick(at: 14)` | すべて false、11.5 の進捗は (0.5, 偽)、離した後は (0, 偽) |
| `cancelledGestureNeverFires` | onEnded を経ずに押下が取り消されたら、3 秒に達していても知らせずに最初に戻す | `press(at: 10)` → `tick(at: 11)` → `tick(at: 13, stillPressed: false)` → `tick(at: 14)` | すべて false、取り消しの後 `isHolding == false` |
| `pressingAgainStartsOver` | 押し直すと 0 から数え直す（離す前の時間を足さない） | 10 に押して 12 で離し、20 に押す | `tick(at: 21) == false`、`tick(at: 23) == true` |
| `secondPressWhileHoldingIsIgnored` | 押している間の 2 回目の press は押し始めの時刻を動かさない | `press(at: 10)`・`press(at: 12)` | `tick(at: 13) == true` |
| `eachPressFiresOnce` | 完了して離した後、もう一度 3 秒押せばもう一度知らせる（1 回の押下につき 1 回） | 0 に押して 3 で完了 → 離す → 10 に押す | `tick(at: 12) == false`、`tick(at: 13) == true`、`tick(at: 14) == false` |

### 6.7 `Tests/PolicyTests/BootstrapOrderTests.swift`（`@Suite("起動の順（T-40）")`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `reconcilerIsInstalledBeforeTheFirstLoad` | 修復口を最初の config.load() より前に挿す | `SourceTree.load()` の `VoiceDockApp/Bootstrap.swift` | `func build(` の本体で `config.setLock1Reconciler`（`(` か `{` が続き、その後のクロージャの本体に `reconcileLock1` がある）が最初の `config.load()` より前 |
| `selfTest` | 自己テスト: 順が逆・呼び出しが無い・呼び先が違う・reconcileLock1 が無い・関数が無いを検出する | 7 つの断片（パラメタ化。空の入力を含む） | 正しい順は nil、ほかはそれぞれの説明 |
| `commentsAreIgnored` | 自己テスト: コメントの中の setLock1Reconciler は数えない | コメントにだけ書いた断片 | `"setLock1Reconciler がありません"` |

### 6.8 `Tests/PolicyTests/ReaperInstallOrderTests.swift`（`@Suite("複製の手順（T-40）")`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `installReaperKeepsTheOrder` | installReaper は fsync → 署名検証 → chmod → rename の順で、書き込みの open( に O_NOFOLLOW がある | `VDPipeline/DeletionEnabler.swift` の `func installReaper(` の本体 | 違反 0 件（`fsync(`・`verifier.verify(`・`chmod(`・`rename(` の最初の位置がこの順、`O_WRONLY` か `O_CREAT` を含む `open(` がすべて `O_NOFOLLOW` を含む） |
| `selfTest` | 自己テスト: 順の入れ替え・欠落・O_NOFOLLOW の欠落を検出する | 5 つの断片（パラメタ化。空の入力を含む） | それぞれの説明 |

## 7. 破壊による証明

| # | 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|---|
| 1 | `isConfirmed` を `s == "ENABLE"`（Swift の `==`）にする | `enableRequiresTheExactWord`（全角の例が通ってしまう場合。通らなければ `s.hasPrefix("ENABLE")` にして `"ENABLE "` の例で落とす） |
| 2 | `enable` の手順 2（`current() != nil`）を消す | `enableRefusesWhenTheConfigIsNotLoaded` |
| 3 | `installReaper` の手順 6（署名検証）を消す | `enableRollsBackWhenTheSignatureFails` |
| 4 | 手順 6 の検証先を `tmp` から `paths.bundledReaperURL` に変える | `enableVerifiesTheCopyNotTheBundle` |
| 5 | 手順 7 の `chmod 0o755` を消す | `enableTurnsAllThreeLocksOff`（`reaperMode() == 0o755` の検査） |
| 6 | 手順 5 の `fsync` を消す | `installReaperKeepsTheOrder`（§6.8 のトークン検査。ふるまいのテストでは観測できない） |
| 7 | 段 2 の失敗で巻き戻さない | `enableRollsBackWhenTheConfCannotBeWritten` |
| 8 | 段 3 の失敗で巻き戻さない | `enableRollsBackWhenTheConfigIsRejected`、`enableRestoresTheOldConfOnRollback` |
| 9 | `rollback` の `reaperExisted` の分岐を消して常に消す | `enableKeepsAnExistingReaperOnRollback` |
| 10 | `enable` の書き込み順を「reaper.conf → 複製 → config」にする | `enableRollsBackWhenTheSignatureFails`（先に書いた reaper.conf が複製の失敗で残り、「reaper.conf 無し」が落ちる。`enableRollsBackWhenTheConfCannotBeWritten` は reaper がまだ置かれていないので落ちない。実装で確かめた） |
| 11 | `enableSkippedDeletion` の手順 3 を消す | `enableSkippedRequiresDeletionEnabled`（CV-43 が受け止めるので、違反の中身が `.config([])` から `.config([CV-43])` に変わる。PR に両方を貼る） |
| 12 | `disable` の段 3 で `reaperConfObservation` を渡さない（今の値で検証する） | `disableIsNotBlockedByItsOwnCV30`（**F-37 の回帰**） |
| 13 | `disable` の段の順を「config → reaper.conf」にする | `disableReportsConfBeforeConfig`・`disableReportsRemoveReaperBeforeConfig`（失敗した段の並びで順が見える） |
| 14 | `disable` の段 1 の失敗で `return` する（残りを続けない） | `disableContinuesAfterAFailedStage`、`disableReportsTheStagesInOrder`、`disableIsNotBlockedByItsOwnCV30` |
| 15 | `disable` の段 4（要求の取り下げ）を消す | `disableWithdrawsEveryRequest`、`e2e17DisableWithdrawsTheRequestInFlight` |
| 16 | `disable` の段 5（`scanNow`）を消す | `disableTurnsEverythingBackOnWithoutAsking`、`e2e17DisableRemountsAtOnce` |
| 17 | `withdrawAllRequests` が結果（`queue/result`）も消す | `disableWithdrawsEveryRequest` |
| 18 | `reconcileLock1` が config.json も書く | `reconcileTurnsTheConfOff`（config.json が変わらないことの検査） |
| 19 | `reconcileLock1` の `volumesRoot` を `Contract.volumesRoot` に固定する | `reconcileKeepsTheVolumesRoot`、`enableKeepsTheVolumesRootOfTheOldConf` |
| 20 | `Bootstrap` の `setLock1Reconciler` を `load()` の後に動かす | `reconcilerIsInstalledBeforeTheFirstLoad`（§6.7 のトークン検査。`Bootstrap.build()` は本番の <HOME> を使うので動かすテストは無い）。順序の効き目は `cv30IsReconciledOnLoad`（挿してから読む）と `loadWithoutAReconcilerIsAConfigError`（挿さずに読む）の対で示す。PR のレビュー項目にも書く |
| 21 | `DeletionPanelState` の `showsTrash` を `display.readiness == .configured` にする | `trashIsShownWhileEitherSideIsEnabled`、`trashIsShownEvenWhenTheDeviceIsAbsent` |
| 22 | `notices` の 2 つの順を入れ替える | `bothNoticesAppearInOrder` |
| 24 | `AppModel.enableDeletion` の成功で `deletionNotice` を入れない | `enablePassesTheConstantWordAndShowsTheReinsertNotice` |
| 25 | `AppModel.enableDeletion` が定数の代わりに空文字を渡す（F-65） | `enablePassesTheConstantWordAndShowsTheReinsertNotice`（`["ENABLE"]` が渡ることの検査） |
| 26 | `AppModel.disableDeletion` が段の名前を持たない | `disableCallsServicesOnceAndKeepsTheStages` |
| 27 | `AppModel.enableSkippedDeletion` が `services.enableDeletion` を呼ぶ | `enableSkippedPassesTheConstantWord` |
| 28 | `Strings.enableFailureReason` の `.signature` の文言を変える | `enableFailureTextsAreVerbatim` |
| 29 | `AppModel.showsTrash` を `deletion != nil` にする | `deletionAndTrashFollowTheSnapshot` |
| 30 | `serially` を外して本体を直接呼ぶ（直列化しない） | `disableDuringEnableWins` |
| 31 | `LiveServices.read` が設定エラー中に `deletionResidual` を入れない（`IconState.showsTrash` が nil で偽を返す） | `residualCapabilityShowsTrashAndDisable` |
| 32 | `showsDisableButton` を `showsTrash` だけにする | `failedDisableKeepsTheButton` |
| 33 | 操作で `deletionBusy` を立てない | `busyWhileOperating` |
| 34 | `refresh()` で挿し直しの案内を消さない | `reinsertNoticeClearsOnWritableDevice` |
| 35 | `installReaper` の書き込みの `open(` から `O_NOFOLLOW` を外す | `installReaperKeepsTheOrder` |
| 36 | `installReaper` で `chmod` と `rename` を入れ替える | `installReaperKeepsTheOrder` |
| 37 | `disable` で `scanNow` を段 4 の前に動かす | `disableScansLast` |
| 38 | `hasRemainingCapability` が reaper の有無を見ない | `reaperKeepsTheCapability` |
| 39 | `EnablerBench` の組み合わせの検査を外す | `benchRefusesRealReaperWithoutTheSceneVolumesRoot` |
| 40 | （F-65）`HoldToConfirmButton.holdDuration` を 0 にする | `holdDurationIsThreeSeconds`、`progressFollowsElapsedTime`（0 秒で完了になる）、`zeroAndNegativeElapsedAreNotComplete` |
| 41 | （F-65）`Tracker.tick` の `!fired` の条件を外す（完了の知らせを 2 回以上出す） | `firesExactlyOnce`、`eachPressFiresOnce` |
| 42 | （F-65）`Tracker.release` で `startedAt` を消さない | `releasingEarlyCancels` |
| 43 | （F-65）`tick` の `stillPressed` の条件を外す（取り消された押下でも 3 秒で知らせる） | `cancelledGestureNeverFires` |
| 23 | `LockDisplay` の行 2 に文言を直書きに戻す | 落ちない（値は同じ）。**PT の対象外なので、`DeletionStrings.reaperUpdateNotice` を 1 文字変えると `updateNoticeOnVersionMismatch` の「行 2 の末尾が同じ文言で終わる」が落ちることを PR に貼る** |

## 8. 受け入れ条件

- [ ] `enable` は `ENABLE` の完全一致でしか通らず、どの段で失敗しても 3 つとも元のまま（all-or-nothing）
- [ ] （F-65）パネルの有効化と根拠 B は赤いボタンの 3 秒の長押しが完了したときだけ呼ばれ、定数の確認語を渡す。クリック 1 回・途中で離した長押しでは呼ばれない（`HoldToConfirmButtonTests`）
- [ ] 書き込み順が PLAN §8.9.8 の 3 のとおり（複製 → reaper.conf → config）で、複製の中の順が §8.9.3 の 6 のとおり（tmp → fsync → 署名検証 → chmod 0755 → rename）
- [ ] `disable` は確認を求めず、PLAN §8.9.8 の順で進み、途中で失敗しても残りを続け、失敗した段の名前を順に返す
- [ ] `disable` が自分の CV-30 に阻まれない（F-37 の回帰テストが通る）
- [ ] `reconcileLock1` が `ConfigStore.setLock1Reconciler` に挿さり、片方だけ有効な状態が起動時の 1 回目の読み込みで無効側に揃う
- [ ] `bin/` に書くコードと `bundledReaperURL` を参照するコードが `DeletionEnabler.swift` だけ（PT-11 が通る）。`unlink(` も同じ（PT-01）
- [ ] §8.9.8 の 3 行と 2 つの注意書きが逐語で、`trash` の表示条件が `DeletionPanelState.showsTrash` の 1 か所にある
- [ ] `make test` が通り、破壊による証明の結果が PR 本文にある

## 9. SPEC の変更

`docs/SPEC.md` に足す表:

| 節 | 内容 |
|---|---|
| S10（削除の有効化・無効化の段。新設） | 有効化 `copy_reaper` → `reaper_conf` → `config`、無効化 `reaper_conf` → `remove_reaper` → `config` → `withdraw_requests` → `remount` の順と、各段の「失敗したときの扱い」（有効化は全部戻す / 無効化は続ける） |

（`DeletionStage` の定数と S10 の並びを照合するテストを T-05 の SPEC 同期に足す。このチケットの PR で `SpecDocument` の鍵に `S10` を足す）

→ **issue #18（SPEC 同期の拡張。PLAN F-68）で検討し、足さなかった**: S10 は #18 で名前の正規表現に使った。段の順は PLAN §8.9.8 の散文（有効化は番号付きの手順、無効化は矢印の 1 文）で表が無く、実装の `DeletionStage` は個々の定数で順の列を持たない（順は `DeletionEnabler` の振る舞いで、そのテストが見ている）。足すなら PLAN §8.9.8 に段の表を置き、`DeletionStage` に `enableOrder` / `disableOrder` を足す別の PR で行う（`Sources/VDPipeline` を変える。節番号は S14 以降の空き）

## 10. マージ後にやること

- T-41 が同じパネルの「詳細」に後追いの 2 つのボタンを並べる（`DeletionPanelState` に足す）
- T-42 の実機 E2E-17（【利用者が行う】）: 有効な状態から「削除を無効にする」を押し、直ちに読み取り専用へ再マウントされ、以後削除されないことを `docs/E2E.md` に生の出力で残す
- T-34 の `make-app.sh` が `Contents/Helpers/voicedock-reaper` を `<BUNDLE_ID>.reaper` で署名する（署名していない `.app` では `enable` が `.signature` で止まる。README にそう書く）

## 11. API 地図への変更提案

1. §11 の `DeletionEnabler.swift` の行を実際の形にする:
   `public actor DeletionEnabler { init(layout: HomeLayout, paths: AppPaths, config: ConfigStore, verifier: any SignatureVerifier, ingest: any IngestPort, log: AppLog); func enable(confirmation: String) async -> Result<Void, EnableError>; func enableSkippedDeletion(confirmation: String) async -> Result<Void, EnableError>; func disable() async -> [String]; func reconcileLock1() async -> Bool }`
   と、同じファイルの `public enum EnableError`・`public enum DeletionStage`
2. §11 に `DeletionPanelState.swift`（`public enum DeletionStrings`・`public struct DeletionPanelState`）を足す。§12 の `IconState.swift` と `Panel/DeletionSection.swift` はこの値を読む
3. **PLAN §8.9.8 と §6.1 の「reconcileLock1 が config も無効側に書く」を直す**: config.json を書くのは `ConfigStore.load()`（T-18 §4.2 の手順 3）で、`reconcileLock1()` は reaper.conf だけを揃えて真偽を返す。
   設定エラー中は `ConfigStore.update` が「設定が読み込まれていません」で失敗するため、`DeletionEnabler` から config を直せない（T-18 が既にこの形で書かれている）
4. §11 の `DeleteQueue` に `static func withdrawAllRequests(layout: HomeLayout) -> (removed: Int, failed: Int)` を足す（T-38 のファイルへの追加）
5. PLAN §8.9.8 の無効化に「`config.update` に渡す reaper.conf の観測は**これから揃える先（false）**」を明記する（F-37 の修正が実装で消えないように。本チケット §4.3.5 の段 3）
6. PLAN §8.9.8 の常時表示に「`trash` を出す条件 = `config.cleanup.deleteSourceAudio` か `reaper.conf` のどちらかが有効」を明記する（「削除が有効な間」だけでは片方だけ有効な中途の状態の扱いが決まらない）
7. 付録 A.4 の `deletion_enabled` に `reason=skipped_source` を足す（根拠 B の有効化を同じイベントで区別する）。`deletion_disabled` に `reason=<失敗した段>` を足す
8. （整合修正・低 9）`IngestService.remountAllReadOnly()` は誰も呼んでいない（本チケットの段 5 は `scanNow()` を使う。戻り値の generation が要るため）→ **T-15 §4 と地図 §5 から消した**（2026-09-21）
9. （実装で分かった）§12 の `AppServices.swift` の行に T-40 の 3 つの口 `enableDeletion(confirmation:)`・`enableSkippedDeletion(confirmation:)`・`disableDeletion()` を名前で書く。`AppSnapshot` の `deletionEnabled` は `deletion: DeletionPanelState?` に置き換えた（trash の条件を 1 か所にするため）
10. （実装で分かった）§12 の `Panel/*.swift` の行に「`DeletionSection` の中身は T-40（§4.7）」と書く。`EnableError` の文言は PLAN に無いので本チケット §4.5 の表で決めた（利用者の決定 2026-09-22）。PLAN §8.9.8 に失敗の表示の形「有効にできませんでした: <理由>」を足すとよい
11. （実装で分かった）起動の順: PLAN §6.1 は修復口を最初の読み込みの前に要るが、T-30 の Bootstrap は `IngestService` を読み込みの後に作る。本チケットは `LateBoundIngest`（Bootstrap の internal な中継）で循環を切った（§4.4。ログを設定に従わせる方を優先した利用者の決定 2026-09-22）。順は PolicyTests（§6.7）が固定する。PLAN §8.15 の起動の列に「修復口を挿す → 設定を読む」を明記するとよい
12. （レビューで分かった）地図 §16 の索引から `DeleteQueue.withdrawAllRequests`（T-40）を外す。`DeleteQueue` は internal のままで、`withdrawAllRequests` も internal（同じモジュールの `DeletionEnabler` だけが呼ぶ。T-38 §11 の提案 8）なので、公開 API の索引に載せるものではない
13. （レビューで分かった）`DeletionEnabler` に渡すログは起動時のもの（`Bootstrap` の 7。設定を読む前の既定のレベルと時刻帯）のまま。`ConfigStore`・`LockEvaluator` も同じ。設定を読んだ後のログに差し替える口が要るかを決める（本チケットでは変えない）
14. （レビューで分かった）地図 §11 の `DeletionEnabler.swift` の行に `func hasRemainingCapability() -> Bool`（設定エラー中の常時表示に使う。§4.5）を足す。PLAN §8.9.8 の常時表示に「設定エラー中も、reaper.conf が有効か reaper が在れば trash と『無効にする』を出す」を明記するとよい
15. （レビューで分かった）PLAN §8.9.8 に「有効化・無効化は受け付けた順に 1 本ずつ実行する（有効化の途中で来た無効化は有効化の後に走る）」を明記する（§4.3.0）
