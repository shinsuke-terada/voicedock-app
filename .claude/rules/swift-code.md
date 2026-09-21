---
paths:
  - "Sources/**/*.swift"
---

# Swift の書き方（`Sources/`）

正は `docs/PLAN.md` §9（規約）と §9.4（静的ポリシー）。ここはその索引。

## 言語と構成

- Swift 6 言語モード、strict concurrency complete、**警告はエラー**（`treatAllWarnings(as: .error)`）
- 1 ファイル 1 主要型。ファイル名 = 型名。ファイルの先頭に 1 行のコメントでファイルの役割を書く
  （例 `// 削除要求と結果の JSON（PLAN §4.4）。アプリと reaper が共有する。`）
- ドキュメントコメント（`///`）は日本語。安全に関わる規則には根拠の ID を書く（例 `/// DEL-12: size と mtime はデバイス上の原本の値。`）
- `public` は**モジュールをまたぐものだけ**。テストからだけ使うものは `internal` にして `@testable import`
- **チケットに書いていない公開 API を足さない**
- 名前: 型は UpperCamelCase、関数・変数は lowerCamelCase。**DB の列・JSON のキー・ログのキーは snake_case の文字列のまま**（Swift 側の名前とは `CodingKeys` や定数で対応させる）
- 定数は `static let` で型の中に置く。**同じ値を 2 か所に書かない**（CR-06）
- 文字数は `TextLimit.scalarCount`、Python 互換の処理は `PyText` / `PyJSON`、時刻は `Instant` と `ZonedTime`
- 共有状態は `Synchronization` の `Mutex`（`@unchecked Sendable` を使わないため）。どのモジュールでも import してよい

## import の許可リスト（PT-07 が検査する）

| モジュール | import してよいもの |
|---|---|
| VDContract | Foundation, Darwin, CryptoKit |
| VDCore | Foundation, Darwin, os, CryptoKit, VDContract |
| VDStore | Foundation, VDContract, VDCore, GRDB |
| VDProcess | Foundation, Darwin, VDCore |
| VDDevice | Foundation, Darwin, AppKit（NSWorkspace の通知だけ）, CryptoKit, VDContract, VDCore, VDProcess, VDStore, VDAudio（`AudioProbe` だけ） |
| VDAudio | Foundation, AVFoundation, CryptoKit, VDContract（`HomeLayout`）, VDCore |
| VDTranscribe | Foundation, VDContract, VDCore, VDProcess |
| VDLLM | Foundation, Darwin, VDContract, VDCore, VDProcess |
| VDNotes | Foundation, CryptoKit, VDContract, VDCore, Yams |
| VDModels | Foundation, CryptoKit, VDContract, VDCore |
| VDPipeline | Foundation, Darwin, Security, CryptoKit, VDContract, VDCore, VDStore, VDProcess, VDDevice, VDAudio, VDTranscribe, VDLLM, VDNotes |
| VoiceDockApp | Foundation, AppKit, SwiftUI, ServiceManagement, os, すべての VD モジュール |
| voicedock-reaper | **Foundation, Darwin, VDContract のみ** |

`Synchronization` はどのモジュールでも可。ここに無い import は PT-07 が落とす。「Apple 標準なら何でもよい」ではない。

## 禁止（PT-01〜22。許可場所の外で使わない）

| ID | 禁止するもの | 許可する場所 |
|---|---|---|
| PT-01 | `removeItem` `trashItem` `unlink(` `unlinkat(` `rmdir(` `remove(` `removefile(` | `VDCore/SafeUnlink.swift`, `VDContract/AtomicFile.swift`, `voicedock-reaper/Unlinker.swift`, `VDPipeline/DeletionEnabler.swift` |
| PT-02 | `URLSession` `import Network` `CFNetwork` `NWConnection` `CFSocket` `socket(` | `VDModels/`, `VDLLM/LoopbackHTTP.swift`（ここでは `URL(string:` も禁止） |
| PT-03 | `posix_spawn` `Process(` `NSTask` `fork(` `execv` 系 | `VDProcess/` |
| PT-04 | 文字列 `/bin/sh` `/bin/bash` `/bin/zsh` `/usr/bin/env`、`system(` `popen(` | どこにも無い |
| PT-05 | `UPDATE`＋`SET`＋`status` を含む SQL、`INSERT INTO recordings/sessions`、`PersistableRecord` | SQL の 3 つは `VDStore/Transitions.swift`。プロトコル 2 つはどこにも無い |
| PT-06 | 状態名・エラーコード名の直書き（大小区別）、`\(…)/\(…)` の手組み | 状態名は `VDCore/States.swift`、エラーコードは `VDCore/ErrorCode.swift`（+ `VDContract/DeleteResult.swift`）、手組みは `VDContract/PartKey.swift` と `RelPath.swift` |
| PT-07 | 上の許可リストに無い `import` | — |
| PT-08 | `Logger(` `os_log(` `NSLog(` `print(` `debugPrint(` `dump(` | `VDCore/Log.swift`, `voicedock-reaper/ReaperLog.swift`, `reaper/main.swift`（`--version` だけ） |
| PT-09 | `Date()` `Date.now` `CFAbsoluteTimeGetCurrent(` `ContinuousClock()` `SuspendingClock()` `clock_gettime(` 等 | `VDCore/Clock.swift`（`SystemClock`）, `voicedock-reaper/ReaperClock.swift` |
| PT-10 | `VDDevice/` での `open(` `opendir(` `fopen(` `FileHandle(` `Data(contentsOf:`。`DeviceReader.swift` と `TargetIdentity.swift` での書き込みフラグ | `VDDevice/DeviceReader.swift`, `VDDevice/InboxWriter.swift` |
| PT-11 | `bundledReaperURL` `binDirectory` `reaperExecutable` `reaperConf` の語 | `AppPaths.swift`, `HomeLayout.swift`, `DeletionEnabler.swift`, `ReaperRunner.swift`, `LockEvaluator.swift`, `voicedock-reaper/` |
| PT-12 | `.write(to:` `write(toFile:` `createFile(` `FileHandle(forWritingTo:` `copyItem(` `moveItem(` `rename(` `O_CREAT` | `AtomicFile.swift`, `FileLock.swift`, `LogFile.swift`, `InboxWriter.swift`, `ModelDownloader/Importer.swift`, `Normalizer.swift`, `reaper/ProcessedLog・ReaperLog・QueueFiles.swift`, `DeletionEnabler.swift` |
| PT-13 | 版の固定が緩いこと（`exact:` でない依存、`latest` のランナー、SHA でない `uses:`） | — |
| PT-14 | `@unchecked Sendable` `nonisolated(unsafe)` | どこにも無い |
| PT-15 | `voicedock-reaper/` での `Process` `posix_spawn` `URLSession` `removeItem`、VDContract 以外の VD の import、文字列 `diskutil` | — |
| PT-16 | `copyOne(` の中で `registerCopied(` が `commitPartial(` より先（本体が先、記録が後。DEV-16） | — |
| PT-17 | `VDPipeline/Diagnostics/` での削除・書き込み API、`AtomicFile`、`Store(`（読みは `ReadOnlyStore.open(url:)`） | — |
| PT-18 | `ProcessInfo.processInfo.environment` `getenv(` `setenv(` | どこにも無い（テストの有効化は `Tests/` の中だけ） |
| PT-19 | `precondition(` `preconditionFailure(` `assert(` `assertionFailure(` `fatalError(` `try!` `as!` | どこにも無い（CR-16） |
| PT-20 | Swift の `Regex<` `Regex(` `#/`（正規表現は `NSRegularExpression` の文字列定数で持つ） | どこにも無い |
| PT-21 | `.recovery`（`TransitionKind`） | `VDCore/States.swift`, `VDStore/Transitions.swift`, `VDPipeline/Recovery.swift` |
| PT-22 | `VolumeHandle(` の初期化子（本番は `openVolume` 経由） | `VDContract/TargetIdentity.swift` |

PT はコメントと文字列リテラルの中身を空白にしてから照合する（`SourceScanner`）。**コメントに書いたから逃げられる、ではない** — コード側の語が対象。

## 整形（`.swift-format`。`make lint` が `--strict` で見る）

- インデント 4、1 行 120 桁
- `import` はバイト順に並べる（`Foundation` → `TestSupport` → `Testing` → `@testable import VDCore`）
- `/* */` のブロックコメントは使わない
- 5 桁以上の整数は `_` で区切る
- 強制アンラップ `!`・`try!`・`as!`・暗黙アンラップ Optional は使わない
