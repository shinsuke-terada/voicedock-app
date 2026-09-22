# T-33 voicedock からの乗り換え（`imported_keys` の走査）

| 項目 | 値 |
|---|---|
| ID | T-33 |
| Phase | 7（UI と乗り換え） |
| 前提 | T-29（Raw / Daily の工程・`PipelineWorld`・`installVault`・`VaultPaths`）。間接に T-11（`imported_keys` の表・`importedKeys()` / `insertImportedKeys(_:)`）、T-14（取り込みの候補から外す）、T-26（`Frontmatter`）、T-27（`VaultIndex.rawFolderPrefix`）、T-28（`VaultCheck`・`OutputPathResolver`）、T-18（`Worker.performStart`・`WorkerDependencies`） |
| 見積もり | ソース約 210 行、テスト約 420 行 |
| 後続 | T-30（Bootstrap が `ImportedKeysService` を組み立てる）、T-31（Vault を選んだ直後に呼ぶ）、T-35（E2E-18 を実機で行う）、T-43（README の乗り換えの手順） |

## 1. 目的

参照実装 voicedock を使っていた利用者が本アプリに乗り換えたとき、**同じ録音を二重に処理せず、voicedock が書いたノートを 1 バイトも変えない**ようにする（PLAN §8.13）。

そのために、Vault の Raw フォルダにある `*.md` の frontmatter から `voicedock_recording_keys` を読み、**アプリの DB に行が無い** partkey を `imported_keys` に入れる。
`imported_keys` に入った partkey は IngestService がコピーせず（§8.13・T-14）、そのノートは「上書きしてよい」の条件を満たさないので ` (2)` に書かれる（§8.8・T-28）。

## 2. 参照

- PLAN §8.13（`ImportedKeysScanner.scan(vault:)` の全文）、§8.8（既存ノートの扱い・X-11）、§8.1（IngestService の候補）、§7.2（`imported_keys` の表）、§8.15（起動の順）、付録 A.4（`imported_keys_added`）、付録 B.3（E2E-18）、付録 D（X-11）
- 00-api-map.md §11（`ImportedKeysScanner`）、§3（`Store.importedKeys()` / `insertImportedKeys(_:)`）、§9（`Frontmatter`・`VaultIndex.rawFolderPrefix`・`VaultCheck`・`OutputPathResolver`）
- voicedock@d3d595e `src/voicedock/notes.py:194-211`（frontmatter の鍵の読み取り）、`src/voicedock/wiki.py:46-167`（Vault の走査。`.` 始まりと symlink の扱い）
- T-27 §4.4（`VaultIndex.build` の走査の手順。**本チケットの走査はこれと同じ規則にする**）、T-26 §4.5（`Frontmatter.recordingKeys(ofFile:)`）、T-11（`insertImportedKeys` の SQL）、T-14（`selectCandidates` の手順 4・5）

## 3. 作るもの

| パス | 中身 |
|---|---|
| `Sources/VDPipeline/ImportedKeysScanner.swift` | `ImportedKeysScanner`（走査そのもの。同期・`throws`） |
| `Sources/VDPipeline/ImportedKeysService.swift` | `ImportedKeysService`（actor。呼び出しの契機と Vault の確認）・`ImportedKeysScanReason` |
| `Sources/VDPipeline/WorkerDependencies.swift`（変更） | `importedKeys: ImportedKeysService` を**末尾に**足す |
| `Sources/VDPipeline/Worker.swift`（変更） | `performStart(delayed:)` の最後に起動時の走査を足す |
| `Tests/VDPipelineTests/PipelineFixtures.swift`（変更） | `PipelineWorld` に `importedKeys` と Vault の部品を足す（§5.0） |
| `Tests/VDPipelineTests/ImportedKeysScannerTests.swift` | 走査の単体（§5.1） |
| `Tests/VDPipelineTests/ImportedKeysServiceTests.swift` | 契機とガード（§5.2） |
| `Tests/VDPipelineTests/MigrationIntegrationTests.swift` | E2E-18 に対応する結合（§5.3） |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 1 キーを消す（§5.4） |

## 4. 仕様

各ファイルの先頭 1 行のコメントは括弧内の文を逐語で書く。共通の短縮は T-18 / T-29 と同じ。

### 4.1 `ImportedKeysScanner.swift`（「// voicedock が書いた Raw ノートの録音の鍵を imported_keys に取り込む（PLAN §8.13）。」）

```swift
import Foundation
import VDContract
import VDCore
import VDNotes
import VDStore

public struct ImportedKeysScanner: Sendable {
    public init(store: Store, log: AppLog)

    /// Raw フォルダの接頭辞の下の *.md を走り、DB に行が無い partkey を imported_keys に入れる。
    /// 戻りは**新しく入れた件数**。ブロックする（呼び手が BlockingIO.run で包む）。
    public func scan(vault: URL, config: ObsidianConfig) throws -> Int
}
```

`scan(vault:config:)` の手順:

1. `prefix = VaultIndex.rawFolderPrefix(config.raw.folderTemplate)`（既定 `Daily/Voice/Raw`）
2. `root = prefix.isEmpty ? vault : RelPath.components(prefix).reduce(vault) { $0.appendingPathComponent($1, isDirectory: true) }`
   （`prefix` が空 = テンプレートが `{` で始まる場合は Vault 全体が Raw フォルダ。§8.13 の定義どおり）
3. `files = ImportedKeysScanner.markdownFiles(root: root, base: prefix)`（§4.2）。空なら `0` を返す（DB を触らない）
4. `var rows: [(partkey: String, sourceNote: String)] = []`、`var seen: Set<String> = []`
5. `files`（Vault からの相対パスのスカラー列の昇順）を順に:
   - `keys = Frontmatter.recordingKeys(ofFile: vault.appendingPathComponent(relative, isDirectory: false))`
     （読めない・UTF-8 でない・frontmatter が無い・配列でない → `[]`。例外を投げない。T-26 §4.5）
   - 各 `key` を順に: `PartKey.deviceID(of: key) != nil`、`PartKey.relpath(of: key) != nil` かつ `RelPath.isSafe(relpath)` でなければ**捨てる**（壊れた鍵を DB に入れない。PLAN §8.13「`<device_id>/<relpath>` で `RelPath.isSafe`」）。
     `seen.insert(key).inserted` が真のときだけ `rows.append((key, relative))`（**先に見つけたノートを `source_note` にする**。走査の順が決まっているので結果は決定的）
6. `rows` が空なら `0` を返す
7. `n = try store.insertImportedKeys(rows)`（**DB に行がある partkey と、既に `imported_keys` に在る partkey は入らない**。T-11 の `WHERE NOT EXISTS` と `INSERT OR IGNORE`）
8. `n > 0` なら `log.info(.importedKeysAdded, [(.count, .int(Int64(n)))])`
9. `n` を返す

- **既に在る partkey は上書きしない**（`source_note` も `imported_at` も変えない。PLAN §8.13）
- アプリが書いた Raw ノートの鍵は DB に行があるので入らない（誰が書いたノートかを見ない。PLAN §8.13）

### 4.2 走査（`ImportedKeysScanner.markdownFiles`。internal）

```swift
extension ImportedKeysScanner {
    /// root の下の *.md を、Vault からの相対パス（base を頭に付けたもの）で返す。
    /// 深さ優先。`.` で始まる名前は無視し、symlink は辿らない。読めないディレクトリは飛ばす。例外を投げない。
    static func markdownFiles(root: URL, base: String) -> [String]
}
```
手順（**T-27 §4.4 の `VaultIndex.build` と同じ規則**。走査の規則を 2 種類にしない）:
1. `stack = [(root, base.isEmpty ? [] : RelPath.components(base))]`、`out: [String] = []`
2. `while let (dir, rel) = stack.popLast()`:
   - `FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))` が失敗 → 次へ
   - 各 `name` について:
     - スカラー列が `.` で始まる → 無視（`.obsidian`・`.trash`・書きかけの `.….md.tmp`）
     - `lstat(dir/name)` が失敗 → 無視
     - `S_ISDIR`（**symlink は辿らない**。symlink は `S_ISLNK` なので入らない）→ `stack.append((dir/name, rel + [name]))`
     - ディレクトリでないもの: 名前のスカラー列が `.md`（**大小を区別する**）で終われば `out.append(RelPath.join(rel + [name]))`
3. `out` をスカラー列の昇順に並べて返す（`out.sorted { Array($0.unicodeScalars).lexicographicallyPrecedes(Array($1.unicodeScalars)) }`。00-api-map §0「バイト一致が要る所ではスカラー列で比べる」）
- symlink のファイル（`.md` への symlink）も**開かない**: `S_ISREG` でなければ `out` に入れない
- `root` が無い・ディレクトリでない → 空の配列

### 4.3 `ImportedKeysService.swift`（「// 乗り換えの走査を呼ぶ契機（PLAN §8.13。起動時と Vault を選んだ直後）。」）

```swift
public enum ImportedKeysScanReason: String, Sendable {
    case startup
    case vaultSelected = "vault_selected"
}

public actor ImportedKeysService {
    public init(store: Store, config: ConfigStore, log: AppLog)

    /// Vault が .available のときだけ走る。戻りは足した件数（走らなければ 0）。例外を投げない。
    @discardableResult
    public func scanIfAvailable(_ reason: ImportedKeysScanReason) async -> Int
}
```

`scanIfAvailable(_:)` の手順:
1. `guard let cfg = await config.current() else { return 0 }`（設定が不正なら何もしない）
2. `guard let path = cfg.vault.path, VaultCheck.evaluate(path: path, marker: cfg.vault.marker).isAvailable else { return 0 }`
   （**Vault の判定関数は 1 つ**。ガード・Raw・Daily・診断・削除条件と同じ `VaultCheck.evaluate`。PLAN §8.7）
3. `let vault = VaultPaths.root(path), s = store, o = cfg.obsidian, g = log`
4. ```swift
   do { return try await BlockingIO.run { try ImportedKeysScanner(store: s, log: g).scan(vault: vault, config: o) } }
   catch { g.warning(.configWarning, [(.rule, .string("store")), (.message, .string(String(describing: type(of: error))))]); return 0 }
   ```
   （DB の例外で常駐を止めない。専用のイベントを増やさない。付録 A.4）
- `reason` はログに出さない（`imported_keys_added` のフィールドは `count` だけ。付録 A.4）。**引数に残すのは呼び出し側の意図を型で示すため**で、将来フィールドを足すときの口になる
- actor なので**同時に 2 回走らない**（起動と Vault の選択が重なっても直列になる）

### 4.4 呼び出しの契機

| 契機 | 呼ぶ場所 | 引数 |
|---|---|---|
| 起動時 | `Worker.performStart(delayed:)` の最後（§4.5） | `.startup` |
| Vault を選んだ直後 | T-31 の Vault の選択（「はじめに」と設定パネル）。**選び直したときも呼ぶ** | `.vaultSelected` |

- 起動時に Worker から呼ぶのは、PLAN §8.15 の起動の順が「DB を開く → `Worker.start()` → `IngestService.start()`」であり、**最初の走査より前に `imported_keys` を埋められる**から
- tick では呼ばない（PLAN §8.13 は「Vault を選んだ直後と起動時」。毎周回 Vault を歩かない）
- `pendingStart`（設定が不正・共存ガードで遅れた start）でも同じ場所で呼ぶ。そのときは IngestService が先に動いているが、設定が使えない間はコピーが始まらない

### 4.5 `Worker` と `WorkerDependencies` の変更

`WorkerDependencies` の**末尾**に足す（T-18 が決めた並びを崩さない）。**足す順は 00-api-map §11 の表が正**: T-18 の並び → 本チケットの `importedKeys` → 最後に T-36 の `locks` / `volumeOpener`（T-36 は本チケットより後の Phase 8。本チケットの時点では `locks` / `volumeOpener` はまだ無い）:

```swift
/// 乗り換えの走査（PLAN §8.13）。起動時に 1 回呼ぶ。
public let importedKeys: ImportedKeysService
```

`performStart(delayed:)` の手順に 8 を足す（T-18 §4.2 の 1〜7 の後）:

```text
8. await deps.importedKeys.scanIfAvailable(.startup)     // 戻り値は捨てる（ログは scanner が出す）
```
- 7（`requeueFailed`）の**後**に置く: 走査は Vault を歩くので数百 ms かかることがあり、復旧と再投入を遅らせない
- `start()` は 1 回しか `performStart` を呼ばないので、走査も起動につき 1 回

### 4.6 ほかの工程との関係（**このチケットでは何も足さない**。つながりの確認）

| 相手 | 決まっていること | どこ |
|---|---|---|
| IngestService | `selectCandidates` が `store.importedKeys()` を引き、候補から外す（安定性判定にもコピーにも進まない） | T-14（`selectCandidates` の手順 4・5）、テスト `importedKeyIsSkipped` |
| Raw / Daily の出力先 | `imported_keys` の partkey は `ownedPartkeys`（= DB でこの Session に属する Part）に**入らない**。だから voicedock のノートは `OutputPathResolver.mayOverwrite` が偽になり、` (2)` へ回る | T-28（`mayOverwrite`）、PLAN §8.8 |
| 削除 | 取り込んだ録音の原本はアプリからは消えない（transcript が無く根拠 A が成立しない） | PLAN §8.13・§8.9.1。README に「voicedock 側の `cleanup --backlog` で消すか手で消す」と書く（T-43） |
| 共存ガード | voicedock の Helper が動いていないことは §8.1 の共存ガードと DR-13 が確かめる | T-13・T-32 |

### 4.7 ログ

| イベント | レベル | フィールド | いつ |
|---|---|---|---|
| `imported_keys_added` | INFO | `count` | 1 件以上入れたとき（0 件なら**出さない**） |
| `config_warning` | WARNING | `rule=store`, `message=<例外の型名>` | `insertImportedKeys` が投げたとき |

## 5. テスト

共通: T-29 と同じ（`import Testing`、`@testable import VDPipeline`、`import VDCore`・`VDContract`・`VDNotes`・`VDStore`、`import TestSupport`）。

### 5.0 `PipelineFixtures.swift` への追加

- `PipelineWorld` に `let importedKeys: ImportedKeysService` を持たせ、`deps` に渡す（`ImportedKeysService(store: store, config: configStore, log: log)`）
- `func writeVaultNote(_ relative: String, _ text: String) throws`: Vault の中に中間ディレクトリごと作って UTF-8 で書く（末尾に改行を足さない。**渡した文字列をそのまま**）
- `func voicedockRawNote(sessionKey: String = "DJIMIC3:20260829", keys: [String], day: String = "2026-08-29") -> String`:
  voicedock が書いた Raw ノートに見える最小の本文（frontmatter は `Frontmatter.render` で作る。本文は 1 行）
  ```swift
  Frontmatter.render([
      (Frontmatter.keyType, .string(RawNote.noteType)),
      (Frontmatter.keySessionKey, .string(sessionKey)),
      (Frontmatter.keyRecordingKeys, .array(keys)),
      ("date", .string(day)),
  ]) + "\n# \(day) の記録（voicedock）\n\nこんにちは。\n"
  ```
- `static let foreignKeyA = "DJIMIC3/TX_MIC001_20260829_060000/TX01_MIC002_20260829_060000_orig.wav"`、`foreignKeyB`（時刻 `061000`）: **アプリの DB に入れない**鍵（`PipelineFixtures` に置く。partkey の区切りは `/`。PLAN §4.2）

### 5.1 `ImportedKeysScannerTests.swift`（`@Suite("ImportedKeysScanner")`）

準備（既定）: `world = try await PipelineWorld.make()`、`vault = try await world.installVault()`、`scanner = ImportedKeysScanner(store: world.store, log: world.log)`、`cfg = <既定の ObsidianConfig>`。
呼び方: `try scanner.scan(vault: vault, config: cfg)`。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `importsKeysFromTheRawFolder` / 「Raw フォルダのノートの鍵を入れる」 | `Daily/Voice/Raw/20260829/2026-08-29 raw.md` に `foreignKeyA` と `foreignKeyB` | 戻り 2、`store.importedKeys() == [A, B]`、`imported_keys_added count=2` が 1 行 |
| `sourceNoteIsTheVaultRelativePath` / 「source_note は Vault からの相対パス」 | 同上 | `SELECT source_note` が `Daily/Voice/Raw/20260829/2026-08-29 raw.md` |
| `keysInTheDatabaseAreNotImported` / 「DB に行がある partkey は入れない」 | `addSession(key: vaultSessionKey, …)` → `addPart(partA, status: .rawSaved)` の鍵をノートに書く | 戻り 0、`importedKeys()` が空、ログに `imported_keys_added` が無い |
| `existingImportedKeysAreNotOverwritten` / 「既に在る partkey は上書きしない」 | 先に `insertImportedKeys([(A, "old.md")])` → ノートに A | 戻り 0、`source_note` が `old.md` のまま |
| `outsideTheRawFolderIsIgnored` / 「Raw フォルダの外は見ない」 | `Daily/Voice/Wiki/2026-08-29 Voice.md` に鍵 | 戻り 0 |
| `nestedFoldersAreScanned` / 「入れ子のフォルダも走る」 | `Daily/Voice/Raw/2026/08/note.md` | 戻り 1 |
| `dotDirectoriesAreSkipped` / 「`.` 始まりは無視する」 | `Daily/Voice/Raw/.trash/old.md` と `Daily/Voice/Raw/.hidden.md` | 戻り 0 |
| `symlinkedDirectoryIsNotFollowed` / 「ディレクトリの symlink を辿らない」 | Vault の外のディレクトリ（鍵を持つノート入り）への symlink を Raw の下に置く | 戻り 0、symlink の先は読まれない |
| `symlinkedFileIsNotRead` / 「ファイルの symlink は開かない」 | Vault の外のノートへの symlink `x.md` | 戻り 0 |
| `nonMarkdownIsIgnored` / 「`.md` 以外と大文字の `.MD` は見ない」 | `a.txt`・`b.MD` に鍵 | 戻り 0 |
| `unreadableNoteIsSkipped` / 「読めないノートは飛ばして続ける」 | `bad.md`（0o000）と `good.md`（鍵 1 つ） | 戻り 1、例外を投げない。後始末で chmod を戻す |
| `invalidUTF8IsSkipped` / 「UTF-8 でないノートは飛ばす」 | 不正なバイト列のファイルと正しいノート | 戻り 1 |
| `brokenFrontmatterIsSkipped` / 「frontmatter が壊れていれば飛ばす」 | `---\n: :\n---\n`・`no frontmatter\n`・鍵が文字列（配列でない）ノート | 戻り 0 |
| `malformedKeysAreDropped` / 「鍵の形が壊れていれば入れない」 | `voicedock_recording_keys: ["", "x", "DJIMIC3/", "/a.wav", "DJI MIC/../a.wav"]` | 戻り 0、`importedKeys()` が空 |
| `duplicateKeysAcrossNotesTakeTheFirst` / 「同じ鍵が 2 つのノートに在れば先（昇順）の方」 | `a.md` と `b.md` の両方に A | 戻り 1、`source_note` が `Daily/Voice/Raw/a.md` |
| `emptyVaultAddsNothing` / 「空の Vault では 0 件（TEST-28）」 | ノートを 1 つも置かない | 戻り 0、ログが空、`imported_keys` が空 |
| `missingRawFolderAddsNothing` / 「Raw フォルダが無くても落ちない」 | `Daily/Voice/Raw` を作らない | 戻り 0 |
| `templateWithoutPrefixScansTheWholeVault` / 「テンプレートが `{` で始まれば Vault 全体」 | `raw.folderTemplate = "{yyyymmdd}"`、`Notes/x.md` に鍵 | 戻り 1 |
| `ceObsidianRawFolderTemplate` / 「CE obsidian.raw.folderTemplate 変えると走る場所が変わる」 | `Voice/Raw/{yyyymmdd}` にして `Voice/Raw/n.md` と `Daily/Voice/Raw/n.md` | 前者だけ取り込む |

### 5.2 `ImportedKeysServiceTests.swift`（`@Suite("ImportedKeysService")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `scansWhenTheVaultIsAvailable` / 「Vault が使えれば走る」 | `installVault()` と鍵のノート | 戻り 1 |
| `noVaultPathDoesNothing` / 「Vault 未設定なら何もしない」 | `vault.path = nil` | 戻り 0、ログが空 |
| `missingMarkerDoesNothing` / 「目印が無ければ走らない（幻の Vault を読まない）」 | `installVault(marker: false)` | 戻り 0 |
| `storeErrorIsLoggedNotThrown` / 「DB の例外はログにして続ける」 | `store` を閉じた状態（`pool` を無効にする）で呼ぶ | 戻り 0、`config_warning rule=store` が 1 行、例外が出ない |
| `startupScanRunsOnce` / 「起動で 1 回だけ走る」 | 鍵のノートを置いて `worker.start()` → `worker.tick()` を 2 回 | `imported_keys_added` が 1 行だけ、`importedKeys()` が 1 件 |
| `startupScanRunsBeforeTheFirstTick` / 「起動の走査は最初の tick より前」 | 同上 | `worker.start()` の直後（tick の前）に `importedKeys()` が 1 件 |
| `delayedStartAlsoScans` / 「遅れた start でも走る」 | 設定を不正にして `start()` → 直してから `tick()` | `tick()` の後に 1 件 |

### 5.3 `MigrationIntegrationTests.swift`（`@Suite("E2E-18 voicedock からの乗り換え", .serialized)`）

準備: `world = try await PipelineWorld.make()`、`vault = try await world.installVault()`、
`try world.writeVaultNote("Daily/Voice/Raw/20260829/2026-08-29 raw.md", world.voicedockRawNote(keys: [foreignKeyA, foreignKeyB]))`、
`before = Data(contentsOf: <そのノート>)`、`beforeSHA = FileHasher.sha256(before)`、`beforeStat = lstat(...)`。
`try world.addSession(key: "DJIMIC3:20260829", day: "2026-08-29", status: .ready)`、`pk = try world.addPart(partA, status: .transcribed)`（**同じ日の新しい録音**）。

| 関数名 / 表示名 | 手順 | 期待 |
|---|---|---|
| `e2e18ImportsThenWritesToTheSuffixedNote` / 「E2E-18 取り込み → 同じ日の新しい録音は ` (2)` に書く」 | `world.worker.start()` → `PartSteps(ctx: try await world.context()).ensureRawNote(row)` | 下の「期待」 |
| `e2e18VoicedockNoteIsByteIdentical` / 「E2E-18 voicedock のノートは 1 バイトも変わらない」 | 同上 | `Data(contentsOf:)` が `before` と**バイト一致**、`st_mtimespec` と `st_ino` が変わっていない、`.tmp` が残っていない |
| `e2e18ImportedKeysAreNotCopyCandidates` / 「取り込んだ鍵は取り込みの候補にならない」 | 同上 | `store.importedKeys() == [foreignKeyA, foreignKeyB]`、`store.recording(foreignKeyA) == nil`（DB に行を作らない） |
| `e2e18SecondRunChangesNothing` / 「2 回目の起動で何も増えない」 | もう一度 `ImportedKeysService.scanIfAvailable(.startup)` | 戻り 0、`imported_keys` が 2 件のまま、ノートは 2 つのまま |
| `e2e18AppNoteIsOverwrittenOnRerun` / 「アプリが書いた ` (2)` は次から上書きされる」 | 1 回目の後に Part を TRANSCRIBED に戻してもう一度 `ensureRawNote` | 同じ ` (2)` に書き直され、3 つ目のファイルができない |

**期待**（`e2e18ImportsThenWritesToTheSuffixedNote`）:
- `Daily/Voice/Raw/20260829/` の中身がちょうど 2 つ: `2026-08-29 raw.md`（voicedock のもの）と `2026-08-29 raw (2).md`（アプリのもの）
- Part は `RAW_SAVED`、`sessions.raw_output_path == "Daily/Voice/Raw/20260829/2026-08-29 raw (2).md"`、`raw_output_sha256` が新しいファイルの SHA-256 と一致
- 新しいノートの frontmatter の `voicedock_recording_keys` は `[pk]` だけ（`foreignKeyA` / `foreignKeyB` を含まない）
- `NoteVerifier.verify(url: <(2) のパス>, kind: .raw, sessionKey: "DJIMIC3:20260829", expectedSHA256: <DB の値>, expectedKeys: [pk], summaryHeading: …)` が `passed`
- ログに `imported_keys_added count=2` と `raw_note_saved` が 1 行ずつ（この順）

### 5.4 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`obsidian.raw.folderTemplate` の 1 行を消す（CE テストは `ceObsidianRawFolderTemplate`）。

## 6. 破壊による証明

| 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|
| `scan` の `PartKey` の形の検査を消す | `malformedKeysAreDropped` |
| `markdownFiles` で `.` 始まりを無視しない | `dotDirectoriesAreSkipped` |
| `markdownFiles` で `S_ISDIR` の代わりに `stat`（symlink を辿る）を使う | `symlinkedDirectoryIsNotFollowed` |
| `markdownFiles` で symlink のファイルも `out` に入れる | `symlinkedFileIsNotRead` |
| `markdownFiles` の並べ替えを消す | `duplicateKeysAcrossNotesTakeTheFirst` |
| `.md` の判定を大小無視にする | `nonMarkdownIsIgnored` |
| `rawFolderPrefix` を使わず Vault 全体を走る | `outsideTheRawFolderIsIgnored` |
| `insertImportedKeys` の戻り（新規の件数）ではなく `rows.count` をログに出す | `existingImportedKeysAreNotOverwritten`（`imported_keys_added` が出てしまう） |
| 0 件でも `imported_keys_added` を出す | `emptyVaultAddsNothing` |
| `scanIfAvailable` の `VaultCheck` を `vault.path != nil` だけにする | `missingMarkerDoesNothing` |
| `scanIfAvailable` の `do/catch` を消して投げる | `storeErrorIsLoggedNotThrown` |
| `performStart` の走査を `tick()` の先頭に移す | `startupScanRunsOnce`、`startupScanRunsBeforeTheFirstTick` |
| `OutputPathResolver` に渡す `ownedPartkeys` に `imported_keys` の鍵を足す | `e2e18ImportsThenWritesToTheSuffixedNote`、`e2e18VoicedockNoteIsByteIdentical` |

## 7. 受け入れ条件

- [ ] §3 のファイルがあり、`make lint` と `make test` が通る
- [ ] 走査は `.` 始まりを無視し symlink を辿らない（T-27 `VaultIndex.build` と同じ規則。両方のコードを PR 本文に並べて貼る）
- [ ] `imported_keys` に入るのは **DB に行が無い partkey だけ**（SQL は T-11 のものをそのまま使い、本チケットで SQL を書かない）
- [ ] E2E-18 の 2 つの主張（voicedock のノートがバイト一致・同じ日の新しい録音は ` (2)`）が結合テストで緑
- [ ] `imported_keys_added` は 1 件以上入れたときだけ出る
- [ ] 破壊による証明の各項目で、表のテストが落ちることを確かめ、PR 本文に貼った

## 8. API 地図への変更提案

1. `ImportedKeysScanner` に `init(store: Store, log: AppLog)` を足す（地図は `scan(vault:config:)` だけで、DB とログの渡し方が無い）
2. `ImportedKeysService`（actor）と `ImportedKeysScanReason` を 00-api-map §11 に足す（走査そのもの（同期・`throws`）と、契機・Vault の確認・`BlockingIO`（`async`）を分ける。UI（T-31）が呼ぶのは actor の方）
3. `WorkerDependencies` の末尾に `importedKeys: ImportedKeysService` を足す（起動時の走査。PLAN §8.15 の順で IngestService より前に済ませるため）。末尾に足す順は地図 §11 の表が正（T-18 の並び → `importedKeys` → T-36 の `locks` / `volumeOpener`） → 00-api-map §11 に反映済み（整合修正 M-6）
4. **仕様の補足**（PLAN §8.13）: 「Raw フォルダの接頭辞」が空になるテンプレート（`{` で始まる）のときは Vault 全体を走ると決めた。§8.13 に 1 行足すことを提案する → PLAN §8.13 に反映済み
5. **仕様の補足**（PLAN §8.13）: frontmatter の鍵が `PartKey` の形でないものは `imported_keys` に入れないと決めた（壊れた鍵が DB に残ると、IngestService の候補の除外に効いて**取り込まれない録音**が生まれうる）。§8.13 に 1 行足すことを提案する → PLAN §8.13 に反映済み（形は「`<device_id>/<relpath>` で `RelPath.isSafe`」。§4.1 の手順 5 はこれに合わせた）

## 9. SPEC の変更

なし（`imported_keys` の表は T-11 が、`imported_keys_added` は T-10 が SPEC に同期させている）

## 10. マージ後にやること

- T-30（Bootstrap）: `ImportedKeysService(store:config:log:)` を 1 つだけ作り、`WorkerDependencies.importedKeys` と UI の両方に**同じインスタンス**を渡す
- T-31（Vault の選択）: Vault のパスを保存した**直後**に `await importedKeys.scanIfAvailable(.vaultSelected)` を呼ぶ（「はじめに」と設定パネルの両方。選び直しでも呼ぶ）
- T-43（README）: 乗り換えの手順に「取り込んだ録音の原本はアプリからは消えない。voicedock 側の `cleanup --backlog` で消すか、手で消す」と書く（PLAN §8.13）
- T-35（E2E-18）: 実機の手順は `docs/E2E.md` に書く。本チケットの結合テストは偽物のデバイスで同じ性質を確かめたもの
