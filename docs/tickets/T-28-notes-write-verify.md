# T-28 VDNotes: Vault の確認・ノートの書き込み・保存検証・出力先の決定

| 項目 | 内容 |
|---|---|
| ID | T-28 |
| Phase | 6（ノート） |
| 前提 | T-26（Frontmatter・PyStr・ScalarText・`NotesFixtures`）。T-06（AtomicFile・RelPath）、T-08（ErrorCode・StageFailure）、T-10（FileHasher）、T-45（PyText）は T-26 の前提に含まれる（T-27 の型は使わない） |
| 見積もり | 本体 約 400 行、テスト 約 600 行 |

## 1. 目的

ノートを書く前の **Vault の確認**（空の Vault に書かない。DEL-06）、**atomic な書き込み**、書いた後の**保存検証**（RN-1〜RN-6 / DN-1〜DN-9）、**出力先の決定**（既存ノートを上書きしてよいか。X-11）を作る。
保存検証は削除条件の根拠（§8.9.1 の `verifyRawNote`）でもあるので、**書き込み直後と削除判定で同じ関数を使う**。

## 2. 参照

- PLAN §8.7（Vault の確認・書き込み・保存検証）、§8.8（既存ノートの扱い）、§8.9.1（`verifyRawNote` の期待値）、§5.4（ガード）、付録 C DEL-06 / NOTE-12 / NOTE-13 / NOTE-14 / NOTE-16、付録 D X-11
- voicedock@d3d595e: `src/voicedock/notes.py:223-524`（atomic_write・verify_note・vault_is_available・resolve_output_path）
- voicedock のテスト: `tests/unit/test_verify.py`、`tests/unit/test_atomic_write.py`、`tests/unit/test_vault_available.py`、`tests/unit/test_vault_missing.py`
- 00-api-map.md §9（`VaultCheck` / `NoteWriter` / `NoteVerifier` / `OutputPathResolver`）、§1（`AtomicFile`）

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDNotes/VaultCheck.swift` | `VaultStatus`、`VaultCheck` |
| `Sources/VDNotes/NoteWriter.swift` | `NoteWriter`、`NoteFolder`、`NoteErrorText` |
| `Sources/VDNotes/NoteVerifier.swift` | `NoteKind`、`NoteVerification`、`NoteVerifier` |
| `Sources/VDNotes/OutputPathResolver.swift` | `OutputPathResolver` |
| `Tests/VDNotesTests/VaultCheckTests.swift` | |
| `Tests/VDNotesTests/NoteWriterTests.swift` | |
| `Tests/VDNotesTests/NoteVerifierTests.swift` | RN / DN |
| `Tests/VDNotesTests/OutputPathResolverTests.swift` | (2) の規則 |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 2 キーを消す（§5.5） |

## 4. 仕様

T-26 の「4.0 全体の規則」を適用する。この章のコードはファイルを読むが、**書き込みは `AtomicFile`（VDContract）と `FileManager.createDirectory` だけ**（PT-12）。削除はしない（PT-01）。

### 4.1 `VaultCheck.swift`

```swift
// Vault の確認（PLAN §8.7 手順 0 / DEL-06）。ガード・Raw・Daily・診断・削除条件が共有する唯一の判定関数。Vault のルートを作らない。
import Foundation
import VDCore

public enum VaultStatus: Equatable, Sendable {
    case notConfigured
    case missingRoot
    case notReadable(errno: Int32)
    case missingMarker
    case available
    public var isAvailable: Bool { get }                       // self == .available
    public func message(path: String, marker: String) -> String
}

public enum VaultCheck {
    public static func evaluate(path: String?, marker: String) -> VaultStatus
}
```

（VDNotes の import の許可リスト（PLAN §3.4・PT-07）に Darwin は無い。`stat` / `opendir` / `lstat` は Foundation 経由で使う。`PyText` のために VDCore を import する）

**`evaluate`** の手順（この順。最初に当たったものを返す）:
1. `path == nil` → `.notConfigured`
2. `var st = stat(); let r = stat(path, &st)`（symlink を辿る）:
   - `r != 0` で `errno` が `EPERM` か `EACCES` → `.notReadable(errno: errno)`
   - `r != 0`（それ以外の errno）→ `.missingRoot`
   - `(st.st_mode & S_IFMT) != S_IFDIR` → `.missingRoot`
3. `opendir(path)` が nil → `.notReadable(errno: errno)`（`EPERM` は TCC。書類フォルダ・iCloud Drive の Vault で起こる）。成功したら `closedir`
4. `marker` の `PyText.strip` が空、または `marker` に `/` を含む、または `marker` が `.` か `..`（`PyText.scalarsEqual` で比べる）→ `.missingMarker`（CV-41 が弾くが、ここでも fail-closed。voicedock の「空で検査を無効化」は廃止。X-18）
5. `stat(path + "/" + marker)`（symlink を辿る。連結は `URL(fileURLWithPath: path).appendingPathComponent(marker, isDirectory: false).path(percentEncoded: false)`）が失敗するかディレクトリでない → `.missingMarker`
6. `.available`

**`message(path:marker:)`**（逐語）:
| 状態 | 文言 |
|---|---|
| `.notConfigured` | `Vault が選ばれていません` |
| `.missingRoot` | `<path> がありません` |
| `.notReadable(n)` | `<path> を読めません（errno <n>）` |
| `.missingMarker` | `<path> に <marker>/ がありません（Vault が未マウントか、別の場所を指しています）` |
| `.available` | `""` |

（括弧は全角。`<path>` は渡された文字列のまま）

- 書き込みの権限は見ない（DR-10 は `access(W_OK)` を別に見る。T-32）
- ファイルもフォルダも作らない（NOTE-16）

### 4.2 `NoteWriter.swift`

```swift
// ノートの atomic な書き込み（PLAN §8.7。voicedock notes.py:223-288 と同じ手順）。
public enum NoteWriter {
    /// content を UTF-8 で書き、書いた内容の SHA-256（小文字 16 進）を返す
    public static func write(_ content: String, to url: URL) throws(AtomicFileError) -> String
}

/// ノートのフォルダを作る（Vault の確認の後に呼ぶ。Vault のルートは作らない）
public enum NoteFolder {
    public static func ensure(relative: String, vault: URL) throws -> URL
}

/// 例外を「<型名>: <説明>」の 1 行にする（error_message 用。voicedock の f"{type(exc).__name__}: {exc}" に相当）
public enum NoteErrorText {
    public static func describe(_ error: any Error) -> String
}
```

**`write`**:
1. `data = Data(content.utf8)`、`sha = FileHasher.sha256(data)`
2. `try AtomicFile.write(data, to: url, permissions: 0o644, verifyReadBack: true)`
   - `AtomicFile`（T-06）が行うこと（ここでは確かめるだけ）: 同じディレクトリの `.<ファイル名>.tmp`（**`.md` を含む**。例 `.2026-08-29 raw.md.tmp`）を `O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW` で開く（既存の tmp は切り詰めて使う）→ 全部書く → `fsync` → close →
     読み直して一致を確かめる（不一致なら `.readBackMismatch`、rename しない）→ `rename` → 親ディレクトリを `fsync`（開けない・失敗は無視）。途中で失敗したら tmp を消し、元のエラーを投げる（後片付けの失敗で元の失敗を隠さない。NOTE-14）
3. `sha` を返す

**`NoteFolder.ensure(relative:vault:)`**:
1. `relative` が空でなく、`RelPath.isSafe(relative)` でなければ `NoteFolderError.unsafeRelative` を投げる（テンプレートが `..` を含まないことは CV-11 が保証するが、ここでも確かめる）。空なら `vault` をそのまま返す
2. `relative` を `/` で分けた要素ごとに、`vault` から 1 段ずつ `createDirectory(at:, withIntermediateDirectories: false)`（既にディレクトリなら飛ばす）。Vault のルートは呼び手の `VaultCheck` で在ることが確かめ済みで、ここで作るのはその下だけ。**確認の後に Vault のルートが消えていても（外付けの Vault が外れた等）、最初の段が ENOENT で失敗し、ルートやその上の階層を作り直さない**（T-29 のレビューで判明。`withIntermediateDirectories: true` だとルートを作り直してノートを本体のディスクに書いてしまう）
3. 最後の段の `dir` を返す
- `public enum NoteFolderError: Error, Equatable, Sendable { case unsafeRelative }`

**`NoteErrorText.describe(e)`** = `"\(type(of: e)): \(e)"`（例 `AtomicFileError: open(errno: 13)`）。DB で 200 文字に切り詰められる

### 4.3 `NoteVerifier.swift`

```swift
// 保存検証（PLAN §8.7 の RN-1〜RN-6 / DN-1〜DN-9。voicedock notes.py:294-454 の R-n / W-n と同じ判定と打ち切り）。
public enum NoteKind: Sendable { case raw, daily }

public struct NoteRuleResult: Equatable, Sendable {
    public let rule: String       // "RN-1" … "RN-6" / "DN-1" … "DN-9"
    public let passed: Bool       // 00-api-map §9 の名前
}

public struct NoteVerification: Equatable, Sendable {
    public let results: [NoteRuleResult]      // 評価した規則（評価の順）
    public var failedRules: [String] { get }  // passed でないものの rule（評価の順）
    public var passed: Bool { get }           // results が空でなく、全部 passed
    public var failureMessage: String { get } // "落ちた規則: " + failedRules.joined(separator: ", ")
}

public enum NoteVerifier {
    public static func verify(url: URL, kind: NoteKind, sessionKey: String, expectedSHA256: String,
                              expectedKeys: Set<String>, summaryHeading: String) -> NoteVerification
}
```

規則 ID は Raw が `RN-n`、Daily が `DN-n`（voicedock の `R-n` / `W-n` と同じ番号）。`add(n, ok)` は `results.append(NoteRuleResult(rule: prefix + "-" + String(n), passed: ok))`。

**`verify`** の手順（**打ち切りの位置を voicedock と同じにする**。落ちた規則の列が error_message に出るため）:
1. **規則 1**: `lstat(url.path(percentEncoded: false))` が失敗 → `add(1, false)`、終わり。`S_ISREG` でない（symlink・ディレクトリなど）→ `add(1, false)`、終わり。そうでなければ `add(1, true)`
2. **規則 2**: `size = st.st_size`（規則 1 の lstat の値）。`add(2, size > 0)`。`size == 0` なら終わり
3. `data = try? Data(contentsOf: url)`。nil なら `add(3, false)`、終わり（voicedock は例外になった。本アプリは安全側で打ち切る）
4. **規則 3**: `text = String(validating: data, as: UTF8.self)`（BOM は U+FEFF として残す）。nil なら `add(3, false)`、終わり。そうでなければ `add(3, true)`
5. **規則 4**: `add(4, FileHasher.sha256(data) == expectedSHA256)`（偽でも続ける）
6. Daily のとき **DN-5**: `add(5, Frontmatter.split(text) != nil)`
7. `doc = Frontmatter.parse(text)`、`keyRule = (kind == .raw) ? 5 : 6`
8. `doc == nil` のとき: `add(keyRule, false)`、`add(keyRule + 1, false)`。Daily ならさらに `dailyBodyChecks(text)`（DN-8・DN-9）。終わり
9. **RN-5 / DN-6**: `add(keyRule, (doc[Frontmatter.keySessionKey] as? String).map { PyText.scalarsEqual($0, sessionKey) } ?? false)`（文字列でなければ偽。鍵はスカラー列で比べる。00-api-map §0）
10. `found = Set(Frontmatter.stringList(doc, Frontmatter.keyRecordingKeys))`（配列でなければ空集合）
    - 鍵の集合は**スカラー列の集合**（`Set(keys.map { Array($0.unicodeScalars) })`。内部の `NoteVerifier.scalarSet`）で比べる。`Set<String>` は正準等価で比べるので、partkey の照合（00-api-map §0）に使わない。`expected = scalarSet(expectedKeys)`、`found = scalarSet(stringList(…))`
    - Raw **RN-6**: `add(6, expected.isSubset(of: found))`（**包含**）
    - Daily **DN-7**: `add(7, found == expected)`（**完全一致**。RN-6 と混同しない。NOTE-12）
11. Daily なら `dailyBodyChecks(text)`

`dailyBodyChecks(text)`:
- **DN-8**（`hasContentUnder(text, summaryHeading)`。NOTE-13。voicedock の `^<見出し>\s*$` と `^#{1,6} ` を行単位で同じ結果にしたもの）:
  1. `lines = ScalarText.splitLF(text)`
  2. 最初に「行のスカラー列が `summaryHeading` で始まり、残りが全部 `PyText.isSpace`（空でもよい）」を満たす行を探す。無ければ偽
  3. その次の行から、最初に「`#` が 1〜6 個続いた直後が半角空白（U+0020）」で始まる行の手前までを `"\n"` でつなぎ、`PyText.strip` して空でなければ真
- **DN-9**（NOTE-01。`\[\[[^\]]+\]\]` が在るか）: スカラー列 `s` で、`s[i] == "[" && s[i+1] == "["` の各 `i` について、`i+2` 以降で最初の `]` の位置 `j` を探し、`j >= i+3` かつ `s[j+1] == "]"` なら真。どの `i` でも見つからなければ偽
- 追加の順は DN-8 → DN-9

- 規則の件数: Raw は最大 6、Daily は最大 9（SPEC の RN / DN の表と SPEC 同期で突き合わせる）
- **削除条件の再検証（§8.9.1 の `verifyRawNote`。T-36）も同じ関数を呼ぶ**。期待値は呼び手が決める（書き込み直後: 書いた SHA と載せた Part の鍵。削除判定: DB の `raw_output_sha256` と `RawNoteMembership` の Part の鍵）

### 4.4 `OutputPathResolver.swift`

```swift
// 出力先の決定と既存ノートの扱い（PLAN §8.8 / X-11）。voicedock の「session_key が一致すれば誰のでも上書き」を、鍵の所有まで見る規則にした。
public enum OutputPathResolver {
    public static let maxSuffix = 99
    public static func resolve(folder: URL, baseName: String, existing: URL?, sessionKey: String,
                               ownedPartkeys: Set<String>, kind: NoteKind) -> Result<URL, StageFailure>
    /// 上書きしてよいか（§8.8）
    public static func mayOverwrite(_ url: URL, sessionKey: String, ownedPartkeys: Set<String>, kind: NoteKind) -> Bool
}
```

- `existing` = DB の当該 Session の `raw_output_path` / `output_path` を Vault の URL に足したもの（無ければ nil）。呼び手（T-29）が作る
- `ownedPartkeys` = アプリの DB でこの Session に属する Part の partkey の全部（状態を問わない）。呼び手が作る

**`resolve`** の手順:
1. `existing != nil` なら: `!exists(existing) || mayOverwrite(existing, …)` のとき `.success(existing)`
2. 候補を順に: `folder/<baseName>.md`、`folder/<baseName> (2).md`、…、`folder/<baseName> (99).md`（`(n)` の前は半角空白 1 つ、括弧は半角）。
   最初に `!exists(c) || mayOverwrite(c, …)` を満たすものを `.success(c)`
3. どれも満たさなければ `.failure(StageFailure(kind == .raw ? .obsidianRawWriteFailed : .obsidianWriteFailed, "同名ファイルが多すぎます: " + baseName + ".md"))`

`exists(url)` = `stat(url.path(percentEncoded: false))` が成功する（**symlink を辿る**。壊れた symlink は「無い」→ そこへ書き、rename が symlink 自体を置き換える。voicedock どおり）

**`mayOverwrite`**:
1. `Data(contentsOf:)` が失敗 → 偽
2. `String(validating:as: UTF8.self)` が nil → 偽
3. `doc = Frontmatter.parse(text)` が nil → 偽
4. `(doc[Frontmatter.keySessionKey] as? String).map { PyText.scalarsEqual($0, sessionKey) } ?? false` が偽 → 偽
5. `keys = stringList(doc, Frontmatter.keyRecordingKeys)`。Daily なら `+ stringList(doc, Frontmatter.keyFailedParts) + stringList(doc, Frontmatter.keySkippedParts)`
6. `keys` の全要素が `ownedPartkeys` に含まれれば真、1 つでも含まれなければ偽（`keys` が空なら真）。スカラー列で照合する（`NoteVerifier.scalarSet(keys).isSubset(of: NoteVerifier.scalarSet(ownedPartkeys))`。00-api-map §0）

- 読めないノート・voicedock が書いたノート（鍵がアプリの DB に無い）・利用者が作ったノートは上書きしない
- rename の後・DB 更新の前に落ちた場合、自分のノートは鍵が全部自分の DB に在るので上書きされる（` (2)` が増え続けない）
- 利用者がアプリのノートを編集していても、上の条件を満たせば上書きする（RK-18）

## 5. テスト

T-26 の `NotesFixtures` を使う。ノートの内容を作る補助（テストファイル内）:
```swift
func buildNote(sessionKey: String = NotesFixtures.sessionKey, keys: [String] = [keyA, keyB],
               body: String = "\n# 2026-08-29\n\n## Summary\n\n打ち合わせをした。\n\n[[2026-08-29 raw]]\n",
               extra: [(String, FrontmatterValue)] = []) -> String {
    // frontmatter のキーは T-26 の定数で書く（文字列リテラルを増やさない。CR-06）。
    // 種類の値は "voice-daily"（T-27 の `DailyNote.noteType`）だが、本チケットは T-27 の型を使わないので値を直接書く。
    Frontmatter.render([(Frontmatter.keyType, .string("voice-daily")),
                        (Frontmatter.keySessionKey, .string(sessionKey)),
                        (Frontmatter.keyRecordingKeys, .array(keys))] + extra) + body
}
```
テストの中では準備のためにファイルを直接書いてよい（`Data.write(to:)`。PT は `Tests/` を対象にしない）。

### 5.1 `VaultCheckTests.swift`

| 表示名 | 関数名 | 準備 → 期待 |
|---|---|---|
| `目印のある Vault は使える` | `vaultWithMarkerAvailable` | `v/.obsidian/` → `.available` |
| `空のディレクトリは Vault でない（DEL-06）` | `emptyDirectoryIsNotVault` | `v/` だけ → `.missingMarker` |
| `ルートが無い` | `missingRoot` | 存在しないパス → `.missingRoot` |
| `ルートがファイル` | `rootIsFile` | ファイルのパス → `.missingRoot` |
| `目印がファイルでは足りない` | `markerFileNotEnough` | `v/.obsidian` がファイル → `.missingMarker` |
| `CE vault.marker 目印の名前を変えられる` | `customMarker` | marker `.vault`（既定は `.obsidian`）、`v/.vault/` → `.available`、`v/.obsidian/` だけ → `.missingMarker` |
| `CE vault.path が指す場所を見る` | `ceVaultPath` | `v1/.obsidian/` と `v2/`（目印なし）を作り、`path = v1` → `.available`、`path = v2` → `.missingMarker`。`OutputPathResolver` の出力先も `path` の下に変わる |
| `空の目印では通さない（X-18）` | `emptyMarkerFailsClosed` | marker `""`・`"  "`・`"a/b"`・`"."`・`".."` → `.missingMarker` |
| `未設定` | `notConfigured` | path nil → `.notConfigured` |
| `列挙できないルートは notReadable` | `unreadableRoot` | `v/` を chmod 000 → `.notReadable(errno: EACCES)`（root ならスキップ。後で chmod 755 に戻す） |
| `親が辿れないルートは notReadable` | `unreachableRoot` | `p/v/.obsidian/` を作り `p` を chmod 000 → `.notReadable(errno: EACCES)` |
| `symlink の Vault と目印を辿る` | `followsSymlinks` | Vault のパスが `v` への symlink `link`、`v/.obsidian` がディレクトリ `real/` への symlink → `.available` |
| `文言は逐語` | `messagesAreVerbatim` | 4.1 の表の 5 つ（path `/tmp/v`、marker `.obsidian`、errno 13）を比較 |
| `何も作らない（NOTE-16）` | `createsNothing` | 空のディレクトリで evaluate した後、ディレクトリの中身が空のまま |

### 5.2 `NoteWriterTests.swift`

| 表示名 | 関数名 | 準備 → 期待 |
|---|---|---|
| `書いて SHA を返す` | `writesAndReturnsSHA` | `write("# x\n", to: d/a.md)` の戻り値が `FileHasher.sha256(Data("# x\n".utf8))`、ファイルの中身が一致 |
| `一時ファイルが残らない` | `noTemporaryLeft` | 書いた後、`d` に `.a.md.tmp` が無い |
| `既存のノートを上書きする` | `overwritesExisting` | 既存 `old` → `new` になる |
| `既存の一時ファイルを切り詰めて使う` | `staleTempIsReused` | 先に `.a.md.tmp` に 1 MiB のごみを置く → 書いた後の中身は新しい内容だけ、tmp は残らない |
| `書けないときは既存のノートを変えない` | `failureLeavesExistingIntact` | `d` を chmod 555（既存 `a.md` あり）→ `AtomicFileError` を投げ、`a.md` は元のまま、tmp は無い（root ならスキップ） |
| `空の内容も書ける` | `emptyContentWritten` | `""` → 0 バイトのファイル（検証は RN-2 で落ちるが書き込みは成功） |
| `フォルダを中間ごと作る` | `folderCreatesIntermediates` | `NoteFolder.ensure(relative: "Daily/Voice/Raw/20260829", vault: v)` → ディレクトリができる |
| `Vault のルートが消えていたら作り直さない（確認の後に外付けの Vault が外れた場合）` | `folderNeverRecreatesAMissingVaultRoot` | 無い Vault の URL を渡す → 例外を投げ、Vault のルートは作られない（T-29 のレビューで追加） |
| `危ないフォルダ名は作らない` | `folderRejectsUnsafe` | `"../x"`・`"/abs"`・`".hidden/x"` → `NoteFolderError.unsafeRelative`、何も作られない |
| `エラーの文言` | `errorText` | `NoteErrorText.describe(AtomicFileError.open(errno: 13))` == `"AtomicFileError: open(errno: 13)"` |

### 5.3 `NoteVerifierTests.swift`

`check(url, kind, …)` = 既定で `sessionKey = NotesFixtures.sessionKey`、`expectedSHA256` = ファイルの実際の SHA（無ければ空の SHA）、`expectedKeys = [keyA, keyB]`、`summaryHeading = "## Summary"` で `verify` を呼ぶ補助。

| 表示名 | 関数名 | 準備 → 期待 |
|---|---|---|
| `RN と DN の件数（SPEC S12 の表と同じ）` | `ruleCounts` | 正しいノートで Raw の `results` の rule が `RN-1`〜`RN-6`、Daily が `DN-1`〜`DN-9`（SPEC S12 の表から読む。#18） |
| `正しいノートは全部通る` | `validNotePasses` | Raw・Daily とも `passed` |
| `RN-1 / DN-1 ファイルが無い` | `rule1Missing` | 存在しないパス → `failedRules == ["RN-1"]`（Daily は `["DN-1"]`）、`results.count == 1` |
| `RN-1 / DN-1 symlink を拒む` | `rule1Symlink` | 正しいノートへの symlink → 規則 1 だけが評価されて偽 |
| `RN-1 / DN-1 ディレクトリを拒む` | `rule1Directory` | ディレクトリ → 規則 1 が偽 |
| `RN-2 / DN-2 空のファイル` | `rule2Empty` | 0 バイト → `results` の rule が 1・2 だけ、2 が偽 |
| `RN-3 / DN-3 UTF-8 でない` | `rule3InvalidUTF8` | `0xff 0xfe 0xfd` → 1〜3、3 が偽 |
| `RN-4 / DN-4 SHA が違う（続けて評価する）` | `rule4Mismatch` | expected に別の SHA → 4 が偽、他は評価されて真 |
| `DN-5 frontmatter の区切りが無い` | `dn5RequiresBlock` | 本文だけ → DN-5 が偽 |
| `DN-5 閉じの区切りが無い` | `dn5RequiresClosing` | `"---\na: 1\n"` → DN-5 が偽 |
| `Raw に DN-5 は無い` | `rawHasNoDN5` | Raw の結果に 5 番の「区切り」規則が無い（`RN-5` は session_key） |
| `RN-5 / DN-6 session_key が違う` | `sessionKeyMismatch` | Raw → `RN-5` が偽、Daily → `DN-6` が偽 |
| `RN-5 / DN-6 session_key が無い` | `sessionKeyMissing` | frontmatter に鍵が無い → 同上 |
| `RN-5 / DN-6 session_key が文字列でない` | `sessionKeyNotString` | `voicedock_session_key: 123` → 偽 |
| `YAML が読めなくても残りの規則を報告する` | `unparseableReportsRules` | `"---\na: [unclosed\n---\n…"`: Raw → `RN-5`・`RN-6` が偽で `results` は 6 件。Daily → `DN-6`・`DN-7` が偽、`DN-8`・`DN-9` も評価され 9 件 |
| `RN-6 は包含` | `rn6ContainmentOnly` | ノートの鍵 `[keyA, keyB, keyC]`、期待 `[keyA, keyB]` → RN-6 が真 |
| `RN-6 は欠けると偽` | `rn6MissingKeyFails` | ノート `[keyA]` → RN-6 が偽 |
| `DN-7 は完全一致` | `dn7ExactEquality` | ノート `[keyA, keyB, keyC]` → DN-7 が偽、`[keyB, keyA]`（順が違う）→ 真 |
| `RN-6 / DN-7 鍵の欄が無い` | `keysFieldMissing` | Raw → RN-6 が偽、Daily → DN-7 が偽 |
| `DN-8 見出しの下に本文が要る` | `dn8RequiresContent` | `## Summary\n\n## Timeline\n…` → DN-8 が偽、本文ありで真 |
| `DN-8 見出しが無い` | `dn8MissingHeading` | `## Summary` が無い → 偽 |
| `DN-8 設定の見出しを使う` | `dn8UsesConfiguredHeading` | summaryHeading `## 要約` で `## 要約\n\n本文` → 真、`## Summary\n\n本文` だけ → 偽 |
| `DN-8 次の見出しで止まる` | `dn8StopsAtNextHeading` | `## Summary\n\n## Timeline\n\n本文` → 偽 |
| `DN-8 見出しの後ろの空白を許す` | `dn8AllowsTrailingSpaces` | `## Summary   \n本文` → 真 |
| `DN-8 # が 7 個は見出しでない` | `dn8SevenHashesNotHeading` | `## Summary\n####### x\n` → 真（`####### x` は本文として数える） |
| `DN-9 リンクが要る` | `dn9RequiresLink` | `[[` が無い → 偽 |
| `DN-9 [[…]] があれば通る` | `dn9SatisfiedByLink` | `[[2026-08-29 raw]]` → 真、`[[]]` だけ → 偽、`[[a]b]]` → 偽、`[[[x]]` → 真 |
| `落ちた規則の列と文言` | `failedRulesAndMessage` | session_key 違い＋SHA 違いの Raw → `failedRules == ["RN-4", "RN-5"]`、`failureMessage == "落ちた規則: RN-4, RN-5"` |

### 5.4 `OutputPathResolverTests.swift`

| 表示名 | 関数名 | 準備 → 期待 |
|---|---|---|
| `無ければ基本名` | `plainPathWhenAbsent` | 空のフォルダ → `folder/2026-08-29 raw.md` |
| `自分のノートは上書きする` | `ownNoteOverwritten` | 基本名に session_key 一致・鍵 `[keyA]`、owned `[keyA, keyB]` → 基本名 |
| `rename の後・DB 更新の前に落ちても (2) にしない` | `crashBeforeDBUpdateReusesBase` | existing nil、基本名に自分の鍵だけのノート → 基本名 |
| `voicedock のノートは上書きしない（X-11）` | `voicedockNoteNotOverwritten` | 基本名に session_key 一致・鍵 `[keyV]`（owned に無い）→ `(2)` |
| `別の Session のノートは上書きしない` | `otherSessionNumbered` | 基本名に `DJIMIC3:20260829#2` のノート → `(2)` |
| `同じ日の 2 つの Session` | `twoSessionsSameDay` | Session 1 が基本名に書いた後、Session `#2`（owned は自分の Part）→ `(2)`、さらにその後 Session 1 が existing = 基本名で → 基本名 |
| `読めないノートは別物` | `unreadableIsDifferent` | 基本名が `0xff` のバイト列 → `(2)` |
| `利用者が作ったノート` | `userNoteNotOverwritten` | frontmatter の無い `# memo` → `(2)` |
| `衝突が続けば次の番号` | `skipsMultipleCollisions` | 基本名・(2)・(3) が他人のノート → `(4)` |
| `99 を超えたら書かない（Raw）` | `tooManyRaw` | 基本名と (2)〜(99) が全部他人 → `.failure`、code `obsidianRawWriteFailed`、message `同名ファイルが多すぎます: 2026-08-29 raw.md` |
| `99 を超えたら書かない（Daily）` | `tooManyDaily` | 同じ準備で kind `.daily` → code `obsidianWriteFailed` |
| `DB の出力パスを優先する` | `existingPreferred` | existing = `folder/2026-08-29 raw (2).md`（自分のノート）、基本名は無い → existing |
| `DB の出力パスのファイルが消えていればそこへ書く` | `existingMissingReused` | existing が存在しない → existing |
| `DB の出力パスが他人のノートに置き換わっていたら番号を探す` | `existingForeignFallsBack` | existing に他人のノート → 規則 2 へ進み、基本名が空いていれば基本名 |
| `壊れた symlink は「無い」` | `brokenSymlinkIsAbsent` | 基本名が壊れた symlink → 基本名 |
| `Daily は failed / skipped の鍵も見る` | `dailyChecksExcludedKeys` | Daily ノートの `voicedock_skipped_parts` に owned に無い鍵 → 上書きしない（`(2)`）。全部 owned なら上書き |
| `鍵の無い自分の session_key のノートは上書きしてよい` | `emptyKeysOverwritable` | `voicedock_recording_keys: []` → 基本名 |

### 5.5 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`vault.path`・`vault.marker` の 2 行を消す（CE テストは §5.1）。

## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| `VaultCheck` で目印の確認を省く | `emptyDirectoryIsNotVault` |
| 空の目印で検査を無効にする（voicedock の旧仕様） | `emptyMarkerFailsClosed` |
| `opendir` の確認を省く | `unreadableRoot` |
| stat の `EACCES` を `missingRoot` にする | `unreachableRoot` |
| 規則 1 で `stat`（symlink を辿る）を使う | `rule1Symlink` |
| 規則 2 が偽でも続ける | `rule2Empty` |
| 規則 4 が偽なら打ち切る | `rule4Mismatch` |
| YAML が読めないとき Daily の DN-8 / DN-9 を評価しない | `unparseableReportsRules` |
| RN-6 を完全一致にする | `rn6ContainmentOnly` |
| DN-7 を包含にする | `dn7ExactEquality` |
| DN-8 で見出しの直後の行だけを見る | `dn8RequiresContent`（2 行目に本文があるケース）/ `dn8StopsAtNextHeading` |
| DN-8 の見出しを `#{1,7}` にする | `dn8SevenHashesNotHeading` |
| DN-9 で `[[]]` も通す | `dn9SatisfiedByLink` |
| `mayOverwrite` で鍵の所有を見ない（session_key だけ） | `voicedockNoteNotOverwritten` |
| `mayOverwrite` をやめて DB の出力パスだけで所有を決める | `crashBeforeDBUpdateReusesBase` |
| 99 超えのコードを Raw / Daily で同じにする | `tooManyRaw` / `tooManyDaily` |
| `exists` を `lstat` にする | `brokenSymlinkIsAbsent` |
| `NoteWriter` で `verifyReadBack: false` にする | （T-06 の AtomicFile のテストが落ちることを確かめ、PR に書く。ここでは `writesAndReturnsSHA` が通ることだけを確かめる） |

## 7. 受け入れ条件

- [ ] 5 章のテストが全部通る
- [ ] VDNotes のソースに PT-01（削除）・PT-12（`AtomicFile` 以外の書き込み）の違反が無い
- [ ] `VaultCheck` は Vault のルートを作らない（テストで確かめた）
- [ ] 保存検証の規則 ID が SPEC の RN / DN の表と一致する（SPEC 同期）→ **T-28 の PR では行わない。GitHub issue #18 に回した**（下の §8。当面は `ruleCounts` が PLAN §8.7 の固定の列と照合する）→ **SPEC 同期は #18 で足した**（PLAN F-68）
- [ ] 破壊による証明の結果を PR 本文に貼った

## 8. SPEC の変更

- `docs/SPEC.md` に RN-1〜RN-6 と DN-1〜DN-9 の表（PLAN §8.7 の表を ID が先頭の列になるように 2 つの表に分けたもの）を足し、SPEC 同期の対象に RN / DN を加える（`NoteVerifierTests` の表示名は `RN-n` / `DN-n` で始める）

**実装の注記（T-28 の実装時）**: T-28 の PR では行わない。T-05 の持ち物（`docs/SPEC.md`・`Tests/TestSupport/Spec/SpecDocument.swift` の `SpecIDKind`・`Tests/PolicyTests/SpecSync/SpecCoverage.swift` の `activated`）を直す必要があり、§3 に無い。GitHub issue #18（SPEC 同期の拡張。T-06・T-07・T-17 の分と同じ）に回した。RN / DN を有効にするときは、`TestNameIndex` が表示名の先頭の ID 1 つしか拾わないので、DN-1〜4・RN-5・DN-6 を先頭に持つテストの表示名の付け直し（または分割）も要る
→ **SPEC 同期は #18 で足した**（PLAN F-68）: 表は 2 つに分けず、PLAN §8.7 の表をそのまま SPEC の `S12. 保存検証 RN / DN` に写した（ID は「#」の列に RN- / DN- を付けたもの。— の欄は無い。`SpecDocument.noteRules(_:)`）。`SpecIDKind` には足さず（S12 の行は `| RN-n |` の形でないので `ids(_:)` では読めない）、網羅は `Tests/PolicyTests/SpecSync/NoteRuleCoverageTests.swift` が見る。表示名の先頭は `RN-5 / DN-6 …` のように ` / ` で ID を並べてよい（PLAN §10.3）。付け直したのは `sessionKeyMismatch`・`sessionKeyMissing`・`sessionKeyNotString`（`RN-5 / DN-6`）と `keysFieldMissing`（`RN-6 / DN-7`）。`ruleCounts` は S12 と照合する

## 9. マージ後にやること

なし

## 10. API 地図への変更提案

- `VaultStatus.message` をプロパティ（クロージャを返す）ではなく `func message(path:marker:) -> String` にする。`isAvailable` を足す → 00-api-map に反映済み（2026-09-18。`evaluate` の「stat が EPERM / EACCES なら `.notReadable`」も地図と PLAN §8.7（F-48）に反映済み）
- `NoteWriter.write` を `throws(AtomicFileError)` にする。`NoteFolder.ensure(relative:vault:)`（`NoteFolderError`）と `NoteErrorText.describe(_:)` を追加（T-29 がフォルダを作り、エラーを error_message に写すため）→ 00-api-map に反映済み（2026-09-18）。`NoteFolderError` は地図に無い（追記が要る）
- `NoteVerification` を `results: [NoteRuleResult]` を持つ形にし、`failedRules` / `passed` / `failureMessage` を計算プロパティにする（「失敗の後も評価を続けた」ことをテストで確かめるため）→ 00-api-map に反映済み（2026-09-18）。`NoteRuleResult` の真偽の名前は地図の `passed` に合わせた（旧 `ok`）
- `OutputPathResolver.mayOverwrite(_:sessionKey:ownedPartkeys:kind:)` と `maxSuffix` を公開する → `mayOverwrite` と `resolve(folder:baseName:existing:sessionKey:ownedPartkeys:kind:)` は 00-api-map に反映済み（2026-09-18）。`maxSuffix` は地図に無い
