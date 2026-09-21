# T-40 VDPipeline: 削除の有効化・無効化・ロック 1 の修復と常時表示

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
`ENABLE` の入力を求める有効化は全段が成功するか 1 つも変えないかのどちらかにし、無効化は確認を求めず消す能力に近いものから順に止める。
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
| `Sources/VDPipeline/LockDisplay.swift`（変更） | 行 2 の「削除モジュールの更新が必要です」を `DeletionStrings.reaperUpdateNotice` から取る（CR-06） |
| `Sources/VDPipeline/DeleteQueue.swift`（変更） | `withdrawAllRequests(layout:)` を足す |
| `Sources/VoiceDockApp/Bootstrap.swift`（変更） | `DeletionEnabler` を作り `ConfigStore.setLock1Reconciler` に挿す |
| `Sources/VoiceDockApp/AppModel.swift`（変更） | `deletion: DeletionPanelState?` と 3 つの操作の口 |
| `Sources/VoiceDockApp/IconState.swift`（変更） | `trash` を出す条件を `DeletionPanelState.showsTrash` から取る |
| `Tests/VDPipelineTests/EnablerBench.swift` | テストの舞台（`DeletionScene` ＋ 本物の `ConfigStore`） |
| `Tests/VDPipelineTests/DeletionEnablerTests.swift` | 有効化・無効化・`enableSkippedDeletion` |
| `Tests/VDPipelineTests/ReconcileLock1Tests.swift` | `reconcileLock1` と `ConfigStore.load` との配線（F-37 の回帰） |
| `Tests/VDPipelineTests/DeletionPanelStateTests.swift` | 3 行の逐語・`trash`・注意書き |
| `Tests/VDPipelineTests/DisableStopsDeletionTests.swift` | E2E-17 に対応する単体 |

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

    static let confirmationWord = DeletionStrings.confirmationWord
    /// 複製の読み込みの上限（reaper は数 MB。壊れた入力で巨大な確保をしない）
    static let maxReaperBytes = 64 * 1024 * 1024
}
```

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
5. **再マウント**: `await ingest.scanNow()` が nil → `failed.append(DeletionStage.remount)`（走査が見送られた＝読み取り専用に戻せていない）
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
- `DeletionEnabler` は `AppModel` にも渡す

### 4.5 `AppModel.swift` の変更（T-30 のファイル。UI への口）

```swift
extension AppModel {
    /// パネルとメニューバーが読む値。tick / 走査 / 操作のたびに作り直す
    var deletion: DeletionPanelState? { get }
    /// 「元音声の削除を有効にする」。confirmation はテキストフィールドの入力そのまま
    func enableDeletion(confirmation: String) async -> Result<Void, EnableError>
    /// 「無音・重複も消す」
    func enableSkippedDeletion(confirmation: String) async -> Result<Void, EnableError>
    /// 「削除を無効にする」（確認なし）。失敗した段の名前をパネルに出す
    func disableDeletion() async -> [String]
}
```

- `deletion` の作り方: `DeletionPanelState(display: await locks.display(config: config, snapshot: ingest.latestSnapshot()), deleteSkippedSource: config.cleanup.deleteSkippedSource)`。設定エラー中は nil
- `IconState`: `trash` を出すのは `deletion?.showsTrash == true` のときだけ（式を書き直さない）
- 有効化が成功したら、パネルに `DeletionStrings.reinsertNotice` を出す（PLAN §8.9.8 の 5）。
  挿し直すまでの間は `deletion.notices` にも同じ文言が載る（§4.1 の 3-2）
- 有効化の前に `DeletionStrings.confirmVerified` と `DeletionStrings.confirmIrreversible` と**最新の診断結果**（T-32 の `[DiagnosticResult]`）を出す
- 無効化の返り値が空でなければ、段の名前をそのまま並べて出す（`copy_reaper` などの語は英語のまま。ログと突き合わせるため）

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
    init(enabled: Bool = false, realReaper: Bool = false) throws

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
6. `ingest = ScriptedIngest(snapshot: scene.snapshot())`（`scanNow` の既定の scanner は generation を 1 つ進めた同じ snapshot を返す）
7. `verifier = scene.verifier`（`FakeSignatureVerifier(valid: true)`）
8. `enabler = DeletionEnabler(layout: scene.layout, paths: paths, config: store, verifier: verifier, ingest: ingest, log: scene.log)`
9. `realReaper` が真なら `try scene.installRealReaper()`（T-38。本物の実行ファイルを bin に置く）

- `/Volumes` には触れない（`DeletionScene` の約束のまま）

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
| `enableRequiresTheExactWord` | `ENABLE` 以外では何も変えない | `"enable"`・`"ENABLE "`・`" ENABLE"`・`"Y"`・`""`・`"ＥＮＡＢＬＥ"`（パラメタ化） | `.failure(.notConfirmed)`、reaper 無し、reaper.conf 無し、config が false/ro、ログ 0 行 |
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
| `disableIsNotBlockedByItsOwnCV30` | `F-37` 回帰: reaper.conf を書けなくても config は無効になる | `bin/reaper.conf` をディレクトリにして段 1 を失敗させる（config は true のまま、conf も true 相当が読めない） | 戻り値に `"reaper_conf"` が在る、**`config.cleanup.deleteSourceAudio == false`**、reaper 無し、要求 0 件、`scanNowCalls == 1` |
| `disableContinuesAfterAFailedStage` | 途中で失敗しても残りを続ける | reaper の親ディレクトリを 0o555 にして段 2 を失敗させる | 戻り値が `["remove_reaper"]`、conf false、config false、要求 0 件、`scanNowCalls == 1` |
| `disableWithdrawsEveryRequest` | 要求を全部取り下げる（結果は残す） | 要求 3 件＋`.tmp.json`（`.` 始まり）＋結果 1 件 | `queue/delete` に `.` 始まりだけが残る、`queue/result` が 1 件のまま |
| `disableReportsARefusedRemount` | 再マウントが見送られたら段の名前を返す | `ingest.script([.skip])` | 戻り値が `["remount"]`、ほかは全部成功、`deletion_disabled` が WARNING で `reason=remount` |
| `disableOnAFreshHomeSucceeds` | 何も無い状態でも成功する（TEST-28） | `EnablerBench()`（OFF、reaper 無し・conf 無し・要求 0 件） | `[]`、conf が `.valid(false)`（新しく書かれる）、config が false/false/ro |
| `disableReportsTheStagesInOrder` | 失敗した段は順番どおりに返る | 段 1（conf をディレクトリ）と段 2（bin を 0o555）を同時に失敗させる | `["reaper_conf", "remove_reaper"]`（この順） |

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

## 7. 破壊による証明

| # | 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|---|
| 1 | `isConfirmed` を `s == "ENABLE"`（Swift の `==`）にする | `enableRequiresTheExactWord`（全角の例が通ってしまう場合。通らなければ `s.hasPrefix("ENABLE")` にして `"ENABLE "` の例で落とす） |
| 2 | `enable` の手順 2（`current() != nil`）を消す | `enableRefusesWhenTheConfigIsNotLoaded` |
| 3 | `installReaper` の手順 6（署名検証）を消す | `enableRollsBackWhenTheSignatureFails` |
| 4 | 手順 6 の検証先を `tmp` から `paths.bundledReaperURL` に変える | `enableVerifiesTheCopyNotTheBundle` |
| 5 | 手順 7 の `chmod 0o755` を消す | `enableTurnsAllThreeLocksOff`（`reaperMode() == 0o755` の検査） |
| 6 | 手順 5 の `fsync` を消す | 落ちない（テストでは観測できない）。レビュー項目として PR に書く |
| 7 | 段 2 の失敗で巻き戻さない | `enableRollsBackWhenTheConfCannotBeWritten` |
| 8 | 段 3 の失敗で巻き戻さない | `enableRollsBackWhenTheConfigIsRejected`、`enableRestoresTheOldConfOnRollback` |
| 9 | `rollback` の `reaperExisted` の分岐を消して常に消す | `enableKeepsAnExistingReaperOnRollback` |
| 10 | `enable` の書き込み順を「reaper.conf → 複製 → config」にする | `enableRollsBackWhenTheConfCannotBeWritten`（reaper が置かれていない状態で段 2 が失敗し、巻き戻しの対象が変わる。落ちなければ、段 2 の失敗時に reaper が無いことを確かめる行を足す） |
| 11 | `enableSkippedDeletion` の手順 3 を消す | `enableSkippedRequiresDeletionEnabled`（CV-43 が受け止めるので、違反の中身が `.config([])` から `.config([CV-43])` に変わる。PR に両方を貼る） |
| 12 | `disable` の段 3 で `reaperConfObservation` を渡さない（今の値で検証する） | `disableIsNotBlockedByItsOwnCV30`（**F-37 の回帰**） |
| 13 | `disable` の段の順を「config → reaper.conf」にする | 落ちない（最終状態は同じ）。**「消す能力に近いものから先に止める」は順序の規約なので、`disable` の本体に段の順を書いたコメントとレビュー項目で守る。PR に書く** |
| 14 | `disable` の段 1 の失敗で `return` する（残りを続けない） | `disableContinuesAfterAFailedStage`、`disableReportsTheStagesInOrder`、`disableIsNotBlockedByItsOwnCV30` |
| 15 | `disable` の段 4（要求の取り下げ）を消す | `disableWithdrawsEveryRequest`、`e2e17DisableWithdrawsTheRequestInFlight` |
| 16 | `disable` の段 5（`scanNow`）を消す | `disableTurnsEverythingBackOnWithoutAsking`、`e2e17DisableRemountsAtOnce` |
| 17 | `withdrawAllRequests` が結果（`queue/result`）も消す | `disableWithdrawsEveryRequest` |
| 18 | `reconcileLock1` が config.json も書く | `reconcileTurnsTheConfOff`（config.json が変わらないことの検査） |
| 19 | `reconcileLock1` の `volumesRoot` を `Contract.volumesRoot` に固定する | `reconcileKeepsTheVolumesRoot`、`enableKeepsTheVolumesRootOfTheOldConf` |
| 20 | `Bootstrap` の `setLock1Reconciler` を `load()` の後に動かす | `cv30IsReconciledOnLoad`（テスト側で同じ順に組むので、`loadWithoutAReconcilerIsAConfigError` が対照になる） |
| 21 | `DeletionPanelState` の `showsTrash` を `display.readiness == .configured` にする | `trashIsShownWhileEitherSideIsEnabled`、`trashIsShownEvenWhenTheDeviceIsAbsent` |
| 22 | `notices` の 2 つの順を入れ替える | `bothNoticesAppearInOrder` |
| 23 | `LockDisplay` の行 2 に文言を直書きに戻す | 落ちない（値は同じ）。**PT の対象外なので、`DeletionStrings.reaperUpdateNotice` を 1 文字変えると `updateNoticeOnVersionMismatch` の「行 2 の末尾が同じ文言で終わる」が落ちることを PR に貼る** |

## 8. 受け入れ条件

- [ ] `enable` は `ENABLE` の完全一致でしか通らず、どの段で失敗しても 3 つとも元のまま（all-or-nothing）
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
