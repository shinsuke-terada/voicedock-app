# T-44 v1.0 のリリース

| 項目 | 値 |
|---|---|
| ID | T-44 |
| 題 | v1.0 のリリース（VERSION・タグ・dmg・verify-bundle・E2E-06 の記録・公開リポジトリでのリリース） |
| Phase | 9 |
| 前提 | T-43（README）、T-42（削除のゲート）、T-34（`make release`）、T-46〜T-51（話者分離。PLAN F-89） |
| 見積もり | 手で書く行 約 230（`docs/RELEASE.md` 約 140、テスト約 80、`VERSION` と `Version.swift` と `docs/DEVELOPMENT.md` の状態の表の更新 約 10） |

## 1. 目的

**v1.0 を出す手順を `docs/RELEASE.md` に正本として置き**、その手順で実際に v1.0 を出す。
「出してよい状態か」（削除のゲート・E2E-06・verify-bundle）を**機械が確かめられる形**にして、判断を思い出しに頼らない。

## 2. 参照

- PLAN §11.3（`make release` の全手順）、§11.4（版の付け方。`VERSION` が唯一の出所。**辞書順で比べない**）、§12.4（削除のゲート）、§13（検証の段）、§10.8（CI。2026-09-28 から公開リポジトリ。F-101）、§3.2（リポジトリ）
- 先行チケット: T-01（`VERSION`・`Makefile`・`versionFileIsSemVer`）、T-06（`AppVersion`）、T-34（`scripts/release.sh`・`verify-bundle.sh`）、T-35（`docs/E2E.md` と `Runbook`）、T-42（`RunbookGate`）、T-43（`README.md` と `Readme`）
- voicedock@d3d595e には対応物が無い（リリース配布をしていない）

## 3. 作るもの

| パス | 内容 |
|---|---|
| `docs/RELEASE.md` | 下記 §4 の全文（リリース手順の正本） |
| `docs/release-notes/TEMPLATE.md` | 下記 §4.6 の雛形（`<版>` のまま。コピーして `<版>.md` を作る） |
| `Tests/PolicyTests/ReleaseChecklistTests.swift` | 下記 §5 の全文 |
| `VERSION` | `1.0.0` と改行 1 つ（`0.9.0` から上げる。F-100 で先に 0.9.0 を出した） |
| `Sources/VDContract/Version.swift` | `AppVersion.string = "1.0.0"`（**同じ PR で両方を変える**。T-06 の照合テストが落ちて気づく） |
| `docs/DEVELOPMENT.md` | `## 状態` の表だけを更新（Phase 9 の行を `—` でなくする。F-93 で README から移った） |

## 4. `docs/RELEASE.md`

### 4.1 構成（見出しはこの順・この文字列）

```text
# VoiceDock for Mac のリリース手順
## 0. この文書の約束
## 1. 版の決め方
## 2. リリース前の確認表
## 3. 手順
### 3.1 版を上げる PR
### 3.2 develop → main
### 3.3 タグを打つ
### 3.4 make release
### 3.5 GitHub のリリースを作る（公開リポジトリ）
### 3.6 リリース後
## 4. 失敗したときの戻し方
## 5. 記録
### 5.1 削除のゲート
### 5.2 make test
### 5.3 make test-disk
### 5.4 make release と verify-bundle
### 5.5 別アカウントでの導入
### 5.6 未解決の issue
```

見出しは**全部で 19 行**（`#` 1 つが 1、`##` が 6、`###` が 12）。`theReleaseHeadingsAreInOrder` が深さと本文で完全一致を見る。

### 4.2 `## 0. この文書の約束`（逐語）

```markdown
# VoiceDock for Mac のリリース手順

**この文書がリリース手順の正本である。**手順を issue や PR の本文に置かない。

- **すべて手元の Mac で行う。**証明書とキーチェーンのプロファイルを CI に置かない（PLAN §10.8）
- 判定は `✅ PASS` / `✗ FAIL` / `⬜ 未実施` / `— 対象外` のいずれかで始める。**空欄にしない**
- **1 件でも未実施なら出さない**（§2 の確認表が全部 `✅` か `—` になるまで待つ）
- 版番号をこの文書に直書きしない。版は `VERSION` が唯一の出所である（PLAN §11.4）
```

### 4.3 `## 1. 版の決め方`

- `VERSION`（SemVer、1 行、末尾に改行 1 つ）が唯一の出所。`Sources/VDContract/Version.swift` の `AppVersion.string` と**同じ PR で**揃える
- `CFBundleShortVersionString` は `VERSION`、`CFBundleVersion` は `git rev-list --count HEAD`（T-34）
- reaper の `--version` も `VERSION` と同じ（違うと削除が止まる。§8.9.3 の 5。RELEASE.md では `X.Y.Z` の形を避けて「PLAN §8.9 の reaper の版の照合」と書く）
- **版を文字列の辞書順で比べない**（`1.10` と `1.9` の大小が逆になる）。比べるときは `AppVersion.components` の数値の組（RELEASE.md の散文に `X.Y.Z` の形を書くと `theReleaseDocDoesNotPinTheVersion` が落ちるので、例も 2 つ組で書く）
- v1.0 の後の上げ方: 不具合の修正 = patch、機能の追加 = minor、**`BUNDLE_ID` / reaper の識別子 / `<HOME>` の変更 = しない**（PLAN §3.1）

### 4.4 `## 2. リリース前の確認表`（形と中身）

```markdown
## 2. リリース前の確認表

| # | 条件 | 確かめ方 | 判定 | 記録 |
|---|---|---|---|---|
| RL-01 | `docs/E2E.md` の削除のゲートが開いている | 本書 §5.1 | ✅ PASS | §5.1 |
…
```

| # | 条件 | 確かめ方 |
|---|---|---|
| RL-01 | `docs/E2E.md` の `**ゲート: 開**`（`G-1`〜`G-5` がすべて `✅` か `—`） | `make test-policy`（`RunbookGateTests`）と目視 |
| RL-02 | E2E-06（1 日分）が `✅ PASS`（運用の中での確認が済んでいる） | `docs/E2E.md` §2 と §3.6 |
| RL-03 | `make test` が緑（ND → policy → 残り） | 全出力を §5.2 に貼る |
| RL-04 | `make test-disk` が緑（`.diskImage` を含む） | 全出力を §5.3 に貼る |
| RL-05 | `make lint` が緑 | 出力を貼る |
| RL-06 | `VERSION` と `AppVersion.string` と reaper の `--version` が一致 | `make test`（T-06 の照合テスト）＋ `"$VD_HOME/bin/voicedock-reaper" --version`（導入済みのとき） |
| RL-07 | `README.md` の件数が SPEC と一致し、参照切れが無い | `make test-policy`（`ReadmeTests`） |
| RL-08 | `docs/SPEC.md` が `docs/PLAN.md` の写しとして最新 | `make spec` して `git diff --quiet docs/SPEC.md` |
| RL-09 | `Package.resolved` がコミット済みで、依存が `exact:` で固定されている | `git status` と `Package.swift` |
| RL-10 | `scripts/verify-bundle.sh` の全項目が OK | §3.1 のリハーサルの出力を §5.4 に貼る（本番の §3.4 の出力はリリースの後に追記する） |
| RL-11 | 別のユーザアカウント、またはいまのアカウントで `<HOME>` を退避した状態（どちらも `<HOME>` が無い状態）で、リハーサルの dmg から導入し、「はじめに」を最後まで通せた | 手順と結果を §5.5 に書く（退避で代えたときは、TCC の初回の許可を確かめていないことも書く） |
| RL-12 | 未解決の FAIL・未起票の不具合が無い | issue の一覧を §5.6 に書く |

- **RL-01 と RL-02 と RL-10 は `ReleaseChecklistTests` が機械で見る**（§5）。残りは記録で見る
- 判定は 4 つの記号のどれかで始める

### 4.5 `## 3. 手順`

#### `### 3.1 版を上げる PR`

1. `develop` から `feat/T-44-release-v1` を切る
2. `VERSION` を `1.0.0` に、`Sources/VDContract/Version.swift` の `AppVersion.string` を `"1.0.0"` にする
3. `docs/DEVELOPMENT.md` の `## 状態` の表を更新する（Phase 9 の行。F-93）
4. ここまでをコミットし、作業ツリーが clean な状態で **`make release` の 2〜7 段をリハーサルとして回す**（下のコードブロック）。
   1 段目の `make test` は、確認表が埋まるまで `everyChecklistPassesBeforeRelease` で落ちるので、ここでは回さない。
   このリハーサルの dmg で RL-10（`verify-bundle`）と RL-11（`<HOME>` が無い状態での導入）を確かめる
5. `docs/RELEASE.md` の `## 2` の確認表と `## 5` の記録を埋める（`docs/release-notes/<版>.md` も書く）
6. `make lint && make test && make test-disk` を回し、全出力を PR 本文と `## 5` に貼る
7. PR を `develop` へ。利用者が確かめてマージする

```bash
version="$(tr -d '[:space:]' < VERSION)"
git status --porcelain                                   # 空であること
scripts/make-app.sh release
scripts/notarize.sh dist/VoiceDock.app
scripts/make-dmg.sh dist/VoiceDock.app
scripts/sign.sh developerid "dist/VoiceDock-$version.dmg"
scripts/notarize.sh "dist/VoiceDock-$version.dmg"
scripts/verify-bundle.sh dist/VoiceDock.app "dist/VoiceDock-$version.dmg"
shasum -a 256 "dist/VoiceDock-$version.dmg"; git rev-parse HEAD
```

#### `### 3.2 develop → main`

```bash
gh pr create --base main --head develop --title "Release $(tr -d '[:space:]' < VERSION)"
```

- **`main` へは利用者が PR をマージする**（「Create a merge commit」で。エージェントは `gh pr merge` を実行しない）
- **ブランチ保護は設定していない**（PLAN §10.8・F-101。公開リポジトリなので使えるが、2026-10-01 の時点では未設定）。「保護した」と書かない
- マージの後、`main` で CI が緑になることを確かめる

#### `### 3.3 タグを打つ`

```bash
git switch main && git pull
test "$(cat VERSION | tr -d '[:space:]')" = "$(git show HEAD:VERSION | tr -d '[:space:]')"
git tag -a "v$(tr -d '[:space:]' < VERSION)" -m "VoiceDock $(tr -d '[:space:]' < VERSION)"
git push origin "v$(tr -d '[:space:]' < VERSION)"
```

- タグは `v<VERSION>`（`v1.0.0`）。**注釈付きタグ**（`-a`）にする
- **タグは `make release` の前に打つ**（`CFBundleVersion` はコミット数なので、タグを打ってもビルドは変わらない。タグと成果物のコミットを一致させるため）
- 打ち間違えたら `git tag -d` と `git push --delete origin <tag>` で消してから打ち直す（**リリースを作った後のタグは消さない**）

#### `### 3.4 make release`

```bash
git switch main && git pull && git status --porcelain   # 空であること
make release
```

- `make release` = `scripts/release.sh`（T-34）。lint → test → `.app` の組み立てと Developer ID 署名 → 公証 → staple → dmg → dmg の署名 → 公証 → staple → `verify-bundle.sh`
- **`verify-bundle.sh` の全出力（V-1〜V-10）と `shasum -a 256` と `git rev-parse HEAD` を `## 5` に貼る**
- 失敗したら §4 の戻し方へ

#### `### 3.5 GitHub のリリースを作る（公開リポジトリ）`

```bash
version="$(tr -d '[:space:]' < VERSION)"
gh release create "v$version" "dist/VoiceDock-$version.dmg" \
  --title "VoiceDock $version" \
  --notes-file docs/release-notes/"$version".md \
  --verify-tag \
  --latest
```

- `--verify-tag`: **タグが無ければ作らない**（`gh` は既定でタグを勝手に作るので必ず付ける）
- `--notes-file`: `docs/release-notes/<版>.md` を先に書く（§4.6 の雛形）
- **公開リポジトリのリリースの見え方**（2026-09-28 に公開した。PLAN F-101）:
  - リリースの本文も添付の dmg も、**GitHub にサインインしていない人でも（匿名で）見られ、落とせる**
  - 配る相手には、リリースのページ（`releases/latest`）から落としてもらう。`gh` を使う人は `gh release download "v$version" --repo shinsuke-terada/voicedock-app --pattern '*.dmg'` でも落とせる
  - リポジトリを非公開に戻すと、リリースも招待された人にしか見えなくなり、匿名のリンクは効かなくなる（そのときはこの節と README の案内を直す）
- 添付した dmg の `shasum -a 256` をリリース本文にも書く（ダウンロードした人が確かめられる）

#### `### 3.6 リリース後`

1. `gh release view "v$version"` の出力を `## 5` に貼る
2. `/Applications/VoiceDock.app` を**リリースした dmg から入れ直し**、パネルの「詳細」の版表示が `VERSION` と同じであることを確かめる
3. 削除を有効にしている場合は、**削除モジュールの版も上がっている**ことを確かめる（パネルに「削除モジュールの更新が必要です」が出たら、有効化の操作をもう一度通す）
4. issue を閉じる（`develop` へのマージでは自動で閉じない。PLAN §12.1）
5. `dist/` は消してよい（`.gitignore` に入っている）

### 4.6 `docs/release-notes/TEMPLATE.md`（全文）

リリースのたびに `cp docs/release-notes/TEMPLATE.md docs/release-notes/"$version".md` して埋める。

```markdown
# VoiceDock <版>

<1 行で何ができるか>

## 入れ方
1. `VoiceDock-<版>.dmg` を開き、`VoiceDock` を `Applications` へドラッグする
2. 初めてデバイスを挿したときの許可のダイアログで「許可」を押す
3. 詳しくは README を参照

## 変わったこと
- <箇条書き>

## 既知の制約
- README の「既知の制約」を参照

## 確認
- SHA-256: `<shasum -a 256 の出力>`
- コミット: `<git rev-parse HEAD>`
```

- 版番号は**写した側（`<版>.md`）にだけ書く**。`TEMPLATE.md` と `docs/RELEASE.md` 本体には版を直書きしない
- `docs/release-notes/<版>.md` はコミットする（リリース本文の出所を git に残す）

### 4.7 `## 4. 失敗したときの戻し方`

| 何が失敗したか | 戻し方 |
|---|---|
| `make release` の lint / test | 直して `develop` へ PR。**タグは打ち直す**（消してから） |
| 公証が Rejected | `dist/notarytool-*.txt` と `xcrun notarytool log` を読む。よくある原因: 署名していない Mach-O が入った（`bundle-manifest.txt` を確認）、Hardened Runtime が付いていない、タイムスタンプが無い |
| `verify-bundle.sh` の V-1（中身の一覧） | `Resources/bundle-manifest.txt` と `scripts/make-app.sh` を直す。**一覧を成果物に合わせて緩めない**（余計なファイルが入っているほうを直す） |
| `verify-bundle.sh` の V-7（reaper の識別子） | `scripts/sign.sh` の `--identifier` と `identity.env` を確認。`ReaperSignature.requirement`（T-36）と同じ形であること |
| `gh release create` が失敗 | タグを push したか（`--verify-tag`）。`gh auth status` |
| リリース後に重大な不具合 | **リリースを下書きに戻す**（`gh release edit "v$version" --draft`）。**タグは消さない**。次の版を出して直す |

### 4.8 `## 5. 記録`

`### 5.1 削除のゲート` / `### 5.2 make test` / `### 5.3 make test-disk` / `### 5.4 make release と verify-bundle` / `### 5.5 別アカウントでの導入` / `### 5.6 未解決の issue` の 6 節。
各節に**生の出力**を ```text で貼る（`docs/E2E.md` と同じ規約）。§5.5 と §5.6 は文でよい。

## 5. 文書テスト

### `Tests/PolicyTests/ReleaseChecklistTests.swift`（構成）

T-35 の `Runbook`、T-42 の `RunbookGate`、T-43 の `Readme` を**同じターゲットの中でそのまま使う**（import は要らない）。

```swift
// docs/RELEASE.md と、v1.0 を出せる状態かの検査（PLAN §11.4・§12.4。T-44）。
import Foundation
import TestSupport
import Testing

struct ReleaseDoc: Sendable {
    static let path = "docs/RELEASE.md"

    let document: MarkdownDocument
    let text: String

    static func load() throws -> ReleaseDoc {
        let document = try MarkdownDocument.load(path)
        return ReleaseDoc(document: document, text: document.lines.joined(separator: "\n"))
    }

    /// 確認表の行（`| RL-01 | 条件 | 確かめ方 | 判定 | 記録 |`）。
    func checklist() throws -> [(id: String, verdict: String)] {
        var found: [(String, String)] = []
        for table in MarkdownDocument.tables(in: try document.section("2. リリース前の確認表")) {
            for cells in table.rows where cells.count == 5 && cells[0].hasPrefix("RL-") {
                found.append((cells[0], cells[3]))
            }
        }
        return found.map { (id: $0.0, verdict: $0.1) }
    }

    /// `VERSION` の中身（前後の空白を除く）。
    static func versionString() throws -> String {
        try String(contentsOf: PackageRoot.file("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `X.Y.Z` を数値の組にする（`AppVersion.components` と同じ規則。PolicyTests は VDContract に依存しないので写す）。
    static func components(_ s: String) -> (major: Int, minor: Int, patch: Int)? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return (numbers[0], numbers[1], numbers[2])
    }
}
```

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `theComponentParserIsExact()` | **陽性対照**: 版の読み取りが正確 | 文字列を直に渡す | `"1.0.0"` → `(1,0,0)`、`"1.10.0"` → `(1,10,0)`、`"1.0"` → nil、`"1.0.0 "` → nil、`"1.0.0a"` → nil、`"01.0.0"` → `(1,0,0)` |
| `theVersionIsOnePointZeroOrLater()` | 版が 1.0.0 以上 | `VERSION` | `components` が読め、`(major, minor, patch) >= (1, 0, 0)`（**辞書順で比べない**） |
| `theReleaseDocExists()` | docs/RELEASE.md が在る | — | `ReleaseDoc.load()` が投げない |
| `theReleaseHeadingsAreInOrder()` | 見出しが §4.1 のとおり | 見出しの列 | 深さと本文が **19 行**と完全一致 |
| `theChecklistIsConsecutive()` | 確認表が RL-01 から連番 | `checklist()` | ID が `RL-01`…`RL-<n>`（n ≧ 12）で連番 |
| `everyChecklistVerdictStartsWithAMarker(_:)` | 確認表の判定が記号で始まる | `checklist()` で parametrize | `✅` / `✗` / `⬜` / `—` のどれかで始まる |
| `theReleaseIsGatedOnTheDeletionGate()` | **ゲートが開いていなければ v1.0 を名乗れない** | `RunbookGate.load()`（T-42）と `VERSION` | `components(VERSION).major >= 1` なら `gateState() == "**ゲート: 開**"` |
| `theOneDayScenarioIsDone()` | **E2E-06 が済んでいなければ v1.0 を名乗れない** | `Runbook.load()`（T-35） | `components(VERSION).major >= 1` なら、判定表の `E2E-06` の判定が `✅` で始まる |
| `everyChecklistPassesBeforeRelease()` | 確認表が全部通っている | `checklist()` と `VERSION` | `major >= 1` なら、全行が `✅` か `—` で始まる |
| `theReadmeStatusIsUpdated()` | `docs/DEVELOPMENT.md` の Phase 9 が `—` のままでない（F-93） | `docs/DEVELOPMENT.md`（`Readme.developmentPath`）の `## 状態` の表 | `major >= 1` なら、`9` で始まる行の状態の列が `—` でない |
| `everyReferencedPathExists(_:)` | RELEASE.md が指すファイルが実在 | `Readme.referencedPaths(text)` で parametrize | `PackageRoot.file(_)` が在る |
| `everyMakeTargetExists(_:)` | RELEASE.md が挙げる make のターゲットが実在 | `Readme.makeTargets(text)` で parametrize | `Makefile` に `^<name>:` が在る |
| `theReleaseDocDoesNotPinTheVersion(_:)` | 手順に版を直書きしない | **コードフェンスの外の行だけ**を連結したものに `Readme.versionLikeNumbers` を掛けて parametrize | **1 件も無い**（手順の散文に `X.Y.Z` を書かない。版は `$version` と `<版>` で表す）。**`## 5. 記録` に貼る生の出力（フェンスの中）には版が出るので、フェンスの中は見ない** |
| `theTemplateDoesNotPinTheVersion(_:)` | 雛形に版を直書きしない | `docs/release-notes/TEMPLATE.md` の全文 | `versionLikeNumbers` が空 |
| `theReleaseNotesTemplateExists()` | リリースノートの雛形が在る | `docs/release-notes/TEMPLATE.md` | 在り、`<版>` を含む |
| `theReleaseDocNamesTheGate(_:)` | 手順が必須のコマンドに触れている | `make release`・`scripts/verify-bundle.sh`・`gh release create`・`--verify-tag`・`shasum -a 256`・`git tag -a` で parametrize | `text` に含まれる |
| `theReleaseCommandVerifiesTheTag()` | `gh release create` のコマンドに `--verify-tag` が付いている | `### 3.5` の節のコードフェンスの中の `gh release create` から、行末が `\` の続きの行まで | `--verify-tag` を含む（説明の箇条書きにも同じ語があるので、本文の検索だけではコマンドから消えても気づけない。破壊による証明の 10 で分かった） |
| `theReleaseDocExplainsPublicDistribution()` | 公開リポジトリの配り方を説明している（F-101） | `### 3.5` の節 | `gh release download` と「匿名」の語を含む |

- **`theReleaseIsGatedOnTheDeletionGate` と `theOneDayScenarioIsDone` と `everyChecklistPassesBeforeRelease` が本チケットの中心。**
  `VERSION` を `1.0.0` に上げた瞬間に、ゲートが閉じていたり E2E-06 が未実施だったりすれば `make test` が落ちる。
  **「出してよいか」の判断を人の記憶に置かない**
- 版が `0.x.y` の間はこの 3 本が**素通りする**（`major >= 1` の条件）。素通りしていることが分かるよう、`theComponentParserIsExact` と
  `theVersionIsOnePointZeroOrLater` を別に置く（このチケットで `1.0.0` に上げるので、以後は必ず効く）

## 6. 破壊による証明

| # | 壊し方 | 落ちるべきテスト |
|---|---|---|
| 1 | `docs/E2E.md` の `**ゲート: 開**` を `**ゲート: 閉**` に戻す | `theReleaseIsGatedOnTheDeletionGate` |
| 2 | `docs/E2E.md` の判定表の `E2E-06` を `⬜ 未実施` に戻す | `theOneDayScenarioIsDone`、T-42 の `theGateIsClosedUntilEverythingPasses` |
| 3 | `docs/RELEASE.md` の `RL-04` の判定を `⬜ 未実施` にする | `everyChecklistPassesBeforeRelease` |
| 4 | `docs/RELEASE.md` の確認表から `RL-07` の行を消す | `theChecklistIsConsecutive` |
| 5 | `RL-01` の判定を `たぶん大丈夫` にする | `everyChecklistVerdictStartsWithAMarker("RL-01")` |
| 6 | `VERSION` を `1.0` にする | `theVersionIsOnePointZeroOrLater`、T-01 の `versionFileIsSemVer` |
| 7 | `VERSION` を `1.0.0` にしたまま `Version.swift` を `"0.1.0"` に戻す | T-06 の `AppVersion.string` と `VERSION` の照合テスト |
| 8 | `docs/DEVELOPMENT.md` の Phase 9 の状態を `—` に戻す（F-93） | `theReadmeStatusIsUpdated` |
| 9 | `docs/RELEASE.md` に `v1.0.0 のタグを打つ` と版を直書きする | `theReleaseDocDoesNotPinTheVersion("1.0.0")` |
| 10 | `gh release create` の行から `--verify-tag` を消す | `theReleaseCommandVerifiesTheTag`（`theReleaseDocNamesTheGate("--verify-tag")` は説明の箇条書きの語で通ってしまう） |
| 11 | `### 3.5` から `gh release download` の説明を消す | `theReleaseDocExplainsPublicDistribution` |
| 12 | `docs/release-notes/TEMPLATE.md` を消す | `theReleaseNotesTemplateExists` |
| 12b | `docs/release-notes/TEMPLATE.md` の `<版>` を `1.0.0` にする | `theTemplateDoesNotPinTheVersion("1.0.0")` |
| 13 | `ReleaseDoc.components` を `s.split(separator: ".").count >= 3` に緩める | `theComponentParserIsExact`（`"1.0.0 "` が nil でなくなる） |
| 14 | `## 3. 手順` と `## 4. 失敗したときの戻し方` の順を入れ替える | `theReleaseHeadingsAreInOrder` |

## 7. 受け入れ条件

- [ ] `docs/RELEASE.md` が §4.1 の 19 見出しをその順で持ち、確認表が `RL-01`〜`RL-12` の連番
- [ ] `VERSION` が `1.0.0`、`AppVersion.string` が `"1.0.0"`、`make test` が緑
- [ ] `docs/DEVELOPMENT.md` の `## 状態` の Phase 9 が更新されている（F-93）
- [ ] `docs/E2E.md` が `**ゲート: 開**` で、E2E-06 が `✅ PASS`
- [ ] 【利用者が行う】`### 3.2`〜`### 3.6` を実際に行い、`docs/RELEASE.md` の `## 5` に生の出力を貼った:
  - [ ] `make test` と `make test-disk` と `make lint` の全出力
  - [ ] `make release` の全出力（`verify-bundle.sh` の V-1〜V-10 が全部 OK）
  - [ ] `shasum -a 256 dist/VoiceDock-1.0.0.dmg` と `git rev-parse HEAD` と `git tag -l v1.0.0 -n1`
  - [ ] `gh release view v1.0.0` の出力
- [ ] 【利用者が行う】リリースした dmg を**ダウンロードし直して**導入し、版表示が `1.0.0` であること、Gatekeeper の警告が出ないことを確かめた
- [ ] 【利用者が行う】リリースの dmg が**サインインしていないブラウザ（プライベートウィンドウ）でも**落とせることと、`gh release download v1.0.0` が通ることを確かめた（F-101）
- [ ] 破壊による証明の結果が PR 本文にある
- [ ] issue を手で閉じた（`develop` へのマージでは閉じない）

## 8. SPEC の変更

なし。

## 9. マージ後にやること

- 次の版を上げるときは `docs/RELEASE.md` の `## 2` の確認表の判定を `⬜ 未実施` に戻してから始める（**前回の `✅` を残したまま出さない**）。
  `everyChecklistPassesBeforeRelease` は「出す直前に全部 `✅`」を要求するので、作業中の `⬜` は `make test` を落とす。
  **版を上げる PR の中で確認表も同じ PR で埋める**運用にする（T-44 の §4.5 の 3.1 のとおり）
- `docs/E2E.md` のゲートは v1.0 以降も**開いたまま**にする。削除の仕組みに触れる PR は、ゲートの根拠（ND・E2E・1 日運用）を更新してからマージする

## 10. API 地図への変更提案

1. §14 の `PolicyTests` の「主な中身」に `ReleaseChecklistTests`（T-44）を足す
2. `ReleaseDoc.components` は `AppVersion.components`（VDContract、T-06）の**写し**になる。
   `PolicyTests` は `TestSupport` にしか依存しないので VDContract を直接呼べない。**`PolicyTests` の依存に `VDContract` を足す**か、
   `TestSupport` に `SemanticVersion.parse` を置いて両方から使うか、どちらかを地図で決めたい（写しが 2 つあるのは CR-06 に反する）。
   **提案: 地図 §14 の `PolicyTests` の依存を `TestSupport, VDContract` にする**（VDContract は Foundation と Darwin だけに依存するので、PolicyTests の独立性を損なわない）
3. PLAN §11.4 に「タグは `v<VERSION>` の注釈付きタグ」「`gh release create` は `--verify-tag` を付ける」「**非公開リポジトリのリリースは匿名で配れない**」を足すことを提案する（§11.4 は版の付け方だけで、リリースの作り方に触れていない）。→ 反映済み。2026-09-28 にリポジトリを公開したので、F-101 で「匿名で落とせる」に直した
4. PLAN §12.3 の Phase 9 の行（T-44）の「成果物」は `dmg` だが、実際には **`docs/RELEASE.md`（手順の正本）と `docs/release-notes/<版>.md`** も成果物になる。表への追記を提案する
5. `docs/release-notes/`（`TEMPLATE.md` と `<版>.md`）と `docs/RELEASE.md` は PLAN §3.2 のリポジトリの木に無い。追記を提案する
