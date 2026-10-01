# VoiceDock for Mac のリリース手順

**この文書がリリース手順の正本である。**手順を issue や PR の本文に置かない。

## 0. この文書の約束

- **すべて手元の Mac で行う。**証明書とキーチェーンのプロファイルを CI に置かない（PLAN §10.8）
- 判定は `✅ PASS` / `✗ FAIL` / `⬜ 未実施` / `— 対象外` のいずれかで始める。**空欄にしない**
- **1 件でも未実施なら出さない**（§2 の確認表が全部 `✅` か `—` になるまで待つ）
- 版番号をこの文書に直書きしない。版は `VERSION` が唯一の出所である（PLAN §11.4）。コマンドでは `$version`（`VERSION` から読む）、文では `<版>` と書く。`## 5. 記録` に貼る生の出力（コードフェンスの中）には版が出てよい
- 実機（DJI Mic 3）に触れる手順は無い。`make test-disk` と `make release` の前に、**実機が抜いてあることを利用者が確かめる**（`ls /Volumes` が `Macintosh HD` だけ）
- タグの push と `gh release create` は外部に公開する操作なので、**その都度利用者の確認を得てから**行う。`main` への PR のマージは利用者が行う

## 1. 版の決め方

- `VERSION`（SemVer、1 行、末尾に改行 1 つ）が唯一の出所。`Sources/VDContract/Version.swift` の `AppVersion.string` と**同じ PR で**揃える
- `CFBundleShortVersionString` は `VERSION`、`CFBundleVersion` は `git rev-list --count HEAD`（T-34）
- reaper の `--version` も `VERSION` と同じ（違うと削除が止まる。PLAN §8.9 の reaper の版の照合）
- **版を文字列の辞書順で比べない**（`1.10` と `1.9` の大小が逆になる）。比べるときは `AppVersion.components` の数値の組
- v1.0 の後の上げ方: 不具合の修正 = patch、機能の追加 = minor、**`BUNDLE_ID` / reaper の識別子 / `<HOME>` の変更 = しない**（PLAN §3.1）

## 2. リリース前の確認表

| # | 条件 | 確かめ方 | 判定 | 記録 |
|---|---|---|---|---|
| RL-01 | `docs/E2E.md` の `**ゲート: 開**`（`G-1`〜`G-5` がすべて `✅` か `—`） | `make test-policy`（`RunbookGateTests`）と目視 | ✅ PASS | §5.1 |
| RL-02 | E2E-06（1 日分）が `✅ PASS`（運用の中での確認が済んでいる） | `docs/E2E.md` §2 と §3.6 | ✅ PASS | §5.1 |
| RL-03 | `make test` が緑（ND → policy → 残り） | 全出力を `docs/release-logs/` に置き、集計の行を §5.2 に貼る | ✅ PASS | §5.2 |
| RL-04 | `make test-disk` が緑（`.diskImage` を含む） | 全出力を `docs/release-logs/` に置き、集計の行を §5.3 に貼る | ✅ PASS | §5.3 |
| RL-05 | `make lint` が緑 | 出力を貼る | ✅ PASS | §5.2 |
| RL-06 | `VERSION` と `AppVersion.string` と reaper の `--version` が一致 | `make test`（T-06 の照合テスト）＋ `"$VD_HOME/bin/voicedock-reaper" --version`（導入済みのとき） | ✅ PASS | §5.2 |
| RL-07 | `README.md` の件数が SPEC と一致し、参照切れが無い | `make test-policy`（`ReadmeTests`） | ✅ PASS | §5.2 |
| RL-08 | `docs/SPEC.md` が `docs/PLAN.md` の写しとして最新 | `make spec` して `git diff --quiet docs/SPEC.md` | ✅ PASS | §5.2 |
| RL-09 | `Package.resolved` がコミット済みで、依存が `exact:` で固定されている | `git status` と `Package.swift` | ✅ PASS | §5.2 |
| RL-10 | `scripts/verify-bundle.sh` の全項目が OK | §3.1 のリハーサルの出力を §5.4 に貼る（本番の §3.4 の出力はリリースの後に追記する） | ✅ PASS | §5.4 |
| RL-11 | 別のユーザアカウント、またはいまのアカウントで `<HOME>` を退避した状態（どちらも `<HOME>` が無い状態）で、リハーサルの dmg から導入し、「はじめに」を最後まで通せた | 手順と結果を §5.5 に書く（退避で代えたときは、TCC の初回の許可を確かめていないことも書く） | ✅ PASS | §5.5 |
| RL-12 | 未解決の FAIL・未起票の不具合が無い | issue の一覧を §5.6 に書く | ✅ PASS | §5.6 |

- **`ReleaseChecklistTests` が機械で見るのは、RL-01（`docs/E2E.md` のゲートが開）と RL-02（判定表の E2E-06 が `✅`）と、この表の判定欄の記号だけ**（版が 1 以上のとき、全行が `✅` か `—` でないと `make test` が落ちる）。RL-10 の `verify-bundle` の出力などの中身は記録で見る
- 次の版を上げるときは、この表の判定を `⬜ 未実施` に戻してから始める（**前回の `✅` を残したまま出さない**）

## 3. 手順

### 3.1 版を上げる PR

1. `develop` から `feat/<チケット>-release-<短い名前>` を切る
2. `VERSION` と `Sources/VDContract/Version.swift` の `AppVersion.string` を新しい版にする
3. `docs/DEVELOPMENT.md` の `## 状態` の表を更新する（F-93）
4. ここまでをコミットし、作業ツリーが clean な状態で **`make release` の 2〜7 段をリハーサルとして回す**（下のコードブロック）。
   1 段目の lint と test（`make test`）は、確認表が埋まるまで `everyChecklistPassesBeforeRelease` で落ちるので、ここでは回さない。
   このリハーサルの dmg で RL-10（`verify-bundle`）と RL-11（`<HOME>` が無い状態での導入）を確かめる
5. この文書の `## 2` の確認表と `## 5` の記録を埋め、`docs/release-notes/<版>.md` を書く（§3.5 の雛形）
6. `make lint && make test && make test-disk` を回し、全出力を `docs/release-logs/<日付>-*.txt` に置いて、集計の行を PR 本文と `## 5` に貼る（`make test` と `make test-disk` の全出力は約 1 MB ずつあり、本文に入らない）
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

### 3.2 develop → main

```bash
gh pr create --base main --head develop --title "Release $(tr -d '[:space:]' < VERSION)"
```

- **`main` へは利用者が PR をマージする**（「Create a merge commit」で。エージェントは `gh pr merge` を実行しない）
- **ブランチ保護は設定していない**（PLAN §10.8・F-101。公開リポジトリなので使えるが、2026-10-01 の時点では未設定）。「保護した」と書かない
- マージの後、`main` で CI が緑になることを確かめる

### 3.3 タグを打つ

```bash
git switch main && git pull
test "$(cat VERSION | tr -d '[:space:]')" = "$(git show HEAD:VERSION | tr -d '[:space:]')"
git tag -a "v$(tr -d '[:space:]' < VERSION)" -m "VoiceDock $(tr -d '[:space:]' < VERSION)"
git push origin "v$(tr -d '[:space:]' < VERSION)"
```

- タグは `v<VERSION>`。**注釈付きタグ**（`-a`）にする
- **タグは `make release` の前に打つ**（`CFBundleVersion` はコミット数なので、タグを打ってもビルドは変わらない。タグと成果物のコミットを一致させるため）
- 打ち間違えたら `git tag -d` と `git push --delete origin <tag>` で消してから打ち直す（**リリースを作った後のタグは消さない**）

### 3.4 make release

```bash
git switch main && git pull && git status --porcelain   # 空であること
make release
```

- `make release` = `scripts/release.sh`（T-34）。lint → test → `.app` の組み立てと Developer ID 署名 → 公証 → staple → dmg → dmg の署名 → 公証 → staple → `verify-bundle.sh`
- **実機を抜いてから**行う（`ls /Volumes` が `Macintosh HD` だけ）
- **`verify-bundle.sh` の全出力（V-1〜V-10）と `shasum -a 256` と `git rev-parse HEAD` を `## 5` に貼る**
- 失敗したら §4 の戻し方へ

### 3.5 GitHub のリリースを作る（公開リポジトリ）

先に `docs/release-notes/<版>.md` の `## 確認` の 2 行（SHA-256 とコミット）を、§3.4 の `shasum -a 256` と `git rev-parse HEAD` の出力で埋める（埋めないと、プレースホルダのままリリースの本文になる）。この変更は §3.6 の 2 でコミットする。

```bash
version="$(tr -d '[:space:]' < VERSION)"
gh release create "v$version" "dist/VoiceDock-$version.dmg" \
  --title "VoiceDock $version" \
  --notes-file docs/release-notes/"$version".md \
  --verify-tag \
  --latest
```

- `--verify-tag`: **タグが無ければ作らない**（`gh` は既定でタグを勝手に作るので必ず付ける）
- `--notes-file`: `docs/release-notes/<版>.md` を先に書く（雛形は `docs/release-notes/TEMPLATE.md`。`cp docs/release-notes/TEMPLATE.md docs/release-notes/"$version".md` して埋める）
- `--latest`: README の「最新版の dmg をダウンロード」は `releases/latest` を指す。プレリリースにすると `latest` が指さない
- **公開リポジトリのリリースの見え方**（2026-09-28 に公開した。PLAN F-101）:
  - リリースの本文も添付の dmg も、**GitHub にサインインしていない人でも（匿名で）見られ、落とせる**
  - 配る相手には、リリースのページ（`releases/latest`）から落としてもらう。`gh` を使う人は `gh release download "v$version" --repo shinsuke-terada/voicedock-app --pattern '*.dmg'` でも落とせる
  - リポジトリを非公開に戻すと、リリースも招待された人にしか見えなくなり、匿名のリンクは効かなくなる（そのときはこの節と README の案内を直す）
- 添付した dmg の `shasum -a 256` をリリース本文にも書く（ダウンロードした人が確かめられる）

### 3.6 リリース後

1. `gh release view "v$version"` の出力を `## 5` に貼る
2. `docs/release-notes/<版>.md`（§3.5 で埋めた確認の 2 行）と、この文書の §5.4 に足した本番の出力と 1 の出力をコミットし、`develop` へ PR する（`main` には次の版の §3.2 で入る）
3. `/Applications/VoiceDock.app` を**リリースした dmg から入れ直し**、パネルの「詳細」の版表示が `VERSION` と同じであることを確かめる
4. 削除を有効にしている場合は、**削除モジュールの版も上がっている**ことを確かめる（パネルに「削除モジュールの更新が必要です」が出たら、有効化の操作をもう一度通す）
5. issue を閉じる（`develop` へのマージでは自動で閉じない。PLAN §12.1）
6. `dist/` は消してよい（`.gitignore` に入っている）

## 4. 失敗したときの戻し方

| 何が失敗したか | 戻し方 |
|---|---|
| `make release` の lint / test | 直して `develop` へ PR。**タグは打ち直す**（消してから） |
| 公証が Rejected | `dist/notarytool-*.txt` と `xcrun notarytool log` を読む。よくある原因: 署名していない Mach-O が入った（`bundle-manifest.txt` を確認）、Hardened Runtime が付いていない、タイムスタンプが無い |
| `verify-bundle.sh` の V-1（中身の一覧） | `Resources/bundle-manifest.txt` と `scripts/make-app.sh` を直す。**一覧を成果物に合わせて緩めない**（余計なファイルが入っているほうを直す） |
| `verify-bundle.sh` の V-7（reaper の識別子） | `scripts/sign.sh` の `--identifier` と `identity.env` を確認。`ReaperSignature.requirement`（T-36）と同じ形であること |
| `gh release create` が失敗 | タグを push したか（`--verify-tag`）。`gh auth status` |
| リリース後に重大な不具合 | **リリースを下書きに戻す**（`gh release edit "v$version" --draft`）。**タグは消さない**。次の版を出して直す |

## 5. 記録

### 5.1 削除のゲート

実施: 2026-10-01。RL-01・RL-02 の根拠。`docs/E2E.md` の §4（ゲート）と §2（E2E-06・E2E-13 の行）の写し。`RunbookGateTests` と `ReleaseChecklistTests` は §5.2 の `make test` の中で通った。

```text
$ sed -n "/^## 4\. 削除のゲート/,/^\*\*ゲート/p" docs/E2E.md
## 4. 削除のゲート（PLAN §12.4）

**v1.0 を出す前にすべてを満たす。緩めない。**G-1〜G-5 は PLAN §12.4 の 1〜5 と同じ順・同じ意味である。

| # | 条件 | 判定 | 記録 |
|---|---|---|---|
| G-1 | 付録 B.1 の ND が全件 PASS（アプリ層・reaper 層とも。正の対照を含む） | ✅ PASS | §4.1 |
| G-2 | 付録 B.3 の E2E が全件 PASS（E2E-06 は運用の中で確認してよいが、確認が済むまでゲートは開かない） | ✅ PASS | §2 |
| G-3 | `.diskImage` のテストが CI か手元で PASS し、その記録が PR にある | ✅ PASS | §4.3 |
| G-4 | 実機で「三重ロックを全部外して 1 日流す」を行った | ✅ PASS | §5 |
| G-5 | 削除 ON で E2E-01〜09 を再実行した（本書 §6） | ✅ PASS | §6 |

**ゲート: 開**
$ grep -E "^\| E2E-(06|13) " docs/E2E.md
| E2E-06 | 1 日分を 1 セッションに | OFF | ✅ PASS | §3.6 |
| E2E-13 | 処理中にスリープ | OFF | ✅ PASS | §3.13 |
```

### 5.2 make test

実施: 2026-10-01 20:48〜20:50。`feat/T-44-release-v1` のコミット `e31247f`（確認表をすべて ✅ にし、レビューの指摘を直した後。`everyChecklistPassesBeforeRelease` が確認表を見る）。作業ツリーは clean（RL-05 の出力の `git status` に出る 1 行は、書き込んでいる途中のこのログのファイル自身）。実機は接続されていない（`ls /Volumes` が `Macintosh HD` だけ）。
この節と §5.3 の記録を書いた後のコミットでは、文書テストだけを回し直した（記録の本文はテストの対象の外）。
全出力は `docs/release-logs/2026-10-01-make-lint.txt` と `docs/release-logs/2026-10-01-make-test.txt`（約 1 MB。G-1・G-3 と同じく、本文には先頭の 4 行と集計の行だけを貼る）。どちらも終了コード 0、失敗 0。
`with 3 known issues` は `GoldenSupportTests` が「違えば記録する」ことを `withKnownIssue` で確かめている 3 件で、想定どおり（`docs/E2E.md` §4.3 と同じ）。

RL-05（`make lint`）:

```text
$ date; ls /Volumes; git rev-parse HEAD; git status --porcelain
Thu Oct  1 20:48:48 JST 2026
Macintosh HD
e31247fbb9a93b56ce45b97c0519da35c7decbbf
 M docs/release-logs/2026-10-01-make-lint.txt
$ make lint; echo "exit=$?"
swift format lint --strict --recursive Sources Tests
exit=0
```

RL-03（`make test`。ND → policy → 残り。RL-06 の版の照合・RL-07 の `ReadmeTests`・RL-01 の `RunbookGateTests` を含む）:

```text
$ date; ls /Volumes; git rev-parse HEAD
Thu Oct  1 20:48:52 JST 2026
Macintosh HD
e31247fbb9a93b56ce45b97c0519da35c7decbbf
$ make test; echo "exit=$?"
􁁛  Test run with 10 tests in 1 suite passed after 0.293 seconds.
􁁛  Test run with 119 tests in 10 suites passed after 9.041 seconds.
􁁛  Test run with 33 tests in 3 suites passed after 1.139 seconds.
􁁛  Test run with 34 tests in 1 suite passed after 0.713 seconds.
􀢂  Test run with 325 tests in 36 suites passed after 9.573 seconds with 3 known issues.
􁁛  Test run with 317 tests in 39 suites passed after 0.472 seconds.
􁁛  Test run with 132 tests in 17 suites passed after 22.201 seconds.
􁁛  Test run with 78 tests in 8 suites passed after 0.379 seconds.
􁁛  Test run with 43 tests in 5 suites passed after 11.593 seconds.
􁁛  Test run with 861 tests in 89 suites passed after 17.978 seconds.
􁁛  Test run with 314 tests in 22 suites passed after 0.677 seconds.
􁁛  Test run with 65 tests in 6 suites passed after 0.736 seconds.
􁁛  Test run with 202 tests in 19 suites passed after 12.547 seconds.
􁁛  Test run with 205 tests in 19 suites passed after 3.283 seconds.
􁁛  Test run with 393 tests in 45 suites passed after 1.980 seconds.
􁁛  Test run with 156 tests in 24 suites passed after 0.156 seconds.
􁁛  Test run with 85 tests in 7 suites passed after 0.735 seconds.
exit=0
```

RL-08（SPEC）と RL-09（依存の固定）:

```text
$ make spec >/dev/null 2>&1; git diff --quiet docs/SPEC.md; echo "spec_diff_exit=$?"
spec_diff_exit=0
$ git status --porcelain Package.resolved; git ls-files Package.resolved; grep -n 'exact:' Package.swift
Package.resolved
27:        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
28:        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
```

### 5.3 make test-disk

実施: 2026-10-01 20:50〜20:53。§5.2 と同じコミット `e31247f`。**実機は接続されていない**（実行の直前の `ls /Volumes` が `Macintosh HD` だけ）。利用者の許可を得てエージェントが実行した。
全出力は `docs/release-logs/2026-10-01-make-test-disk.txt`（約 960 KB）。終了コード 0、失敗 0。`VOICEDOCK_DISK_TESTS=1` なので R3（ディスクイメージ）の Suite も走った（ND の 119 件が 48 秒）。

```text
$ date; ls /Volumes; git rev-parse HEAD
Thu Oct  1 20:50:34 JST 2026
Macintosh HD
e31247fbb9a93b56ce45b97c0519da35c7decbbf
$ make test-disk; echo "exit=$?"
􁁛  Test run with 10 tests in 1 suite passed after 0.319 seconds.
􁁛  Test run with 119 tests in 10 suites passed after 47.809 seconds.
􁁛  Test run with 33 tests in 3 suites passed after 1.224 seconds.
􁁛  Test run with 34 tests in 1 suite passed after 0.735 seconds.
􀢂  Test run with 325 tests in 36 suites passed after 8.995 seconds with 3 known issues.
􁁛  Test run with 317 tests in 39 suites passed after 0.491 seconds.
􁁛  Test run with 132 tests in 17 suites passed after 23.005 seconds.
􁁛  Test run with 78 tests in 8 suites passed after 0.382 seconds.
􁁛  Test run with 43 tests in 5 suites passed after 9.137 seconds.
􁁛  Test run with 861 tests in 89 suites passed after 18.130 seconds.
􁁛  Test run with 314 tests in 22 suites passed after 0.600 seconds.
􁁛  Test run with 65 tests in 6 suites passed after 0.793 seconds.
􁁛  Test run with 202 tests in 19 suites passed after 12.785 seconds.
􁁛  Test run with 205 tests in 19 suites passed after 6.506 seconds.
􁁛  Test run with 393 tests in 45 suites passed after 1.874 seconds.
􁁛  Test run with 156 tests in 24 suites passed after 9.263 seconds.
􁁛  Test run with 85 tests in 7 suites passed after 0.725 seconds.
exit=0
```

### 5.4 make release と verify-bundle

**リハーサル**（§3.1 の 4）。2026-10-01 19:56〜19:58、`feat/T-44-release-v1` のコミット `f844f24`（版を上げたコミット。作業ツリーは clean）で `make release` の 2〜7 段を回した。
VoiceDock は終了しており、始める直前に別のコマンドで `ls /Volumes` が `Macintosh HD` だけであることを確かめた（ログには入っていない）。
全出力（230 行）は `docs/release-logs/2026-10-01-rehearsal-make-release.txt`。公証は 2 回とも `Accepted`、`verify-bundle` は V-1〜V-10 がすべて OK。
本番（`main` のタグの上での §3.4）の出力は、リリースの後にこの節へ書き足す（§3.6 の 2）。

下は全出力の 1〜4 行目と 63〜230 行目（5〜62 行目は `swift build` の進捗）。115 行目と 155 行目は `notarytool` の進捗が `\r` で上書きされる 1 行なので、端末に最後に残る表示を貼った。

```text
$ date; git rev-parse HEAD; git status --porcelain
Thu Oct  1 19:56:16 JST 2026
f844f243038f5344431731fe231842a7fda83441
$ scripts/make-app.sh release
==> 署名: Developer ID Application: Shinsuke Terada (ZCWP35H248)
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/whisper-cli: replacing existing signature
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/llama-server: replacing existing signature
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/argmax-cli: replacing existing signature
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/voicedock-reaper: replacing existing signature
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app: replacing existing signature
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/voicedock-reaper
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/voicedock-reaper
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/whisper-cli
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/whisper-cli
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/argmax-cli
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/argmax-cli
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/llama-server
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/llama-server
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app: valid on disk
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app: satisfies its Designated Requirement
OK: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app を署名しました（TeamIdentifier=ZCWP35H248）
== V-1 バンドルの中身
  OK   37 件が一致
  OK   ディレクトリ 28 個が一致
== V-2 Info.plist
  OK   plist として読める
  OK   CFBundleIdentifier = io.github.shinsuke-terada.VoiceDock
  OK   CFBundleName = VoiceDock
  OK   CFBundleExecutable = VoiceDock
  OK   CFBundlePackageType = APPL
  OK   CFBundleShortVersionString = 1.0.0
  OK   LSMinimumSystemVersion = 15.0
  OK   LSUIElement = true
  OK   NSRemovableVolumesUsageDescription が在る
  OK   NSDocumentsFolderUsageDescription が在る
  OK   NSDesktopFolderUsageDescription が在る
  OK   NSDownloadsFolderUsageDescription が在る
== V-3 アーキテクチャ
  OK   VoiceDock = arm64
  OK   voicedock-reaper = arm64
  OK   whisper-cli = arm64
  OK   llama-server = arm64
  OK   argmax-cli = arm64
== V-4 otool -L
  OK   リンク先は /usr/lib と /System/Library だけ
OK: --files-only の検査に通りました
OK: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app（版 1.0.0、ビルド 448、署名 developerid）
$ scripts/notarize.sh dist/VoiceDock.app
==> xcrun notarytool submit（キーチェーンプロファイル VOICEDOCK_NOTARY）
Conducting pre-submission checks for VoiceDock-notarize.zip and initiating connection to the Apple notary service...
Submission ID received
  id: 99995d9f-9862-44ba-ac1f-eceaa6a07229
Successfully uploaded file
  id: 99995d9f-9862-44ba-ac1f-eceaa6a07229
  path: /Users/terada/Projects/voicedock_app/dist/VoiceDock-notarize.zip
Waiting for processing to complete.
Current status: Accepted......Processing complete
  id: 99995d9f-9862-44ba-ac1f-eceaa6a07229
  status: Accepted

Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app
The staple and validate action worked!
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app
The validate action worked!
OK: dist/VoiceDock.app を公証・staple しました（submission 99995d9f-9862-44ba-ac1f-eceaa6a07229）
$ scripts/make-dmg.sh dist/VoiceDock.app
created: /Users/terada/Projects/voicedock_app/dist/.dmg-stage.XN5D3y/VoiceDock-rw.dmg
OK: 作業用のイメージを /Users/terada/Projects/voicedock_app/dist/.dmg-stage.XN5D3y/mnt にマウントしました（/dev/disk21）
2 images written to /Users/terada/Projects/voicedock_app/dist/.dmg-stage.XN5D3y/mnt/.background/background.tiff.
OK: /Users/terada/Projects/voicedock_app/dist/.dmg-stage.XN5D3y/mnt/.DS_Store
イメージ作成エンジンを準備中…
ディスク全体（Apple_HFS: 0）を読み込み中…
   （CRC32 $0B932EE0:ディスク全体（Apple_HFS: 0））
リソースを追加中…
経過時間:  53.479ms
ファイルサイズ: 23403482バイト、チェックサム: CRC32 $A21DB5E0
処理されたセクタ数: 151552、103873圧縮されました
速度: 948.4Mバイト/秒
節約率: 69.8%
created: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
OK: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
$ scripts/sign.sh developerid dist/VoiceDock-1.0.0.dmg
==> 署名: Developer ID Application: Shinsuke Terada (ZCWP35H248)
dist/VoiceDock-1.0.0.dmg: valid on disk
dist/VoiceDock-1.0.0.dmg: satisfies its Designated Requirement
OK: dmg を署名しました
$ scripts/notarize.sh dist/VoiceDock-1.0.0.dmg
==> xcrun notarytool submit（キーチェーンプロファイル VOICEDOCK_NOTARY）
Conducting pre-submission checks for VoiceDock-1.0.0.dmg and initiating connection to the Apple notary service...
Submission ID received
  id: 3671c9d5-f1c2-4ff9-8bf6-957552814a46
Successfully uploaded file
  id: 3671c9d5-f1c2-4ff9-8bf6-957552814a46
  path: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
Waiting for processing to complete.
Current status: Accepted......Processing complete
  id: 3671c9d5-f1c2-4ff9-8bf6-957552814a46
  status: Accepted

Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
The staple and validate action worked!
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
The validate action worked!
OK: dist/VoiceDock-1.0.0.dmg を公証・staple しました（submission 3671c9d5-f1c2-4ff9-8bf6-957552814a46）
$ scripts/verify-bundle.sh dist/VoiceDock.app dist/VoiceDock-1.0.0.dmg
== V-1 バンドルの中身
  OK   38 件が一致
  OK   ディレクトリ 28 個が一致
== V-2 Info.plist
  OK   plist として読める
  OK   CFBundleIdentifier = io.github.shinsuke-terada.VoiceDock
  OK   CFBundleName = VoiceDock
  OK   CFBundleExecutable = VoiceDock
  OK   CFBundlePackageType = APPL
  OK   CFBundleShortVersionString = 1.0.0
  OK   LSMinimumSystemVersion = 15.0
  OK   LSUIElement = true
  OK   NSRemovableVolumesUsageDescription が在る
  OK   NSDocumentsFolderUsageDescription が在る
  OK   NSDesktopFolderUsageDescription が在る
  OK   NSDownloadsFolderUsageDescription が在る
== V-3 アーキテクチャ
  OK   VoiceDock = arm64
  OK   voicedock-reaper = arm64
  OK   whisper-cli = arm64
  OK   llama-server = arm64
  OK   argmax-cli = arm64
== V-4 otool -L
  OK   リンク先は /usr/lib と /System/Library だけ
== V-5 codesign
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/voicedock-reaper
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/voicedock-reaper
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/whisper-cli
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/whisper-cli
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/argmax-cli
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/argmax-cli
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/llama-server
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/llama-server
dist/VoiceDock.app: valid on disk
dist/VoiceDock.app: satisfies its Designated Requirement
  OK   署名が有効
== V-6 本体の署名の中身
  OK   Identifier=io.github.shinsuke-terada.VoiceDock
  OK   TeamIdentifier=ZCWP35H248
  OK   Hardened Runtime
  OK   Developer ID Application で署名
== V-7 reaper の署名
  OK   Identifier=io.github.shinsuke-terada.VoiceDock.reaper
  OK   TeamIdentifier=ZCWP35H248
  OK   アプリが使う要件文字列を満たす
== V-8 エンタイトルメント
  OK   本体 のエンタイトルメントは空の dict
  OK   reaper のエンタイトルメントは空の dict
== V-9 spctl と staple
  OK   spctl: Notarized Developer ID
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app
The validate action worked!
  OK   stapler validate（app）
== V-10 dmg
  OK   spctl（dmg）
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
The validate action worked!
  OK   stapler validate（dmg）
  OK   dmg の名前が版と一致
OK: verify-bundle のすべての検査に通りました（版 1.0.0）
$ shasum -a 256 dist/VoiceDock-1.0.0.dmg; git rev-parse HEAD
bff598339164653da77aa9fa5b3d9174ca7eafb69742f08b753361dba59c4406  dist/VoiceDock-1.0.0.dmg
f844f243038f5344431731fe231842a7fda83441
Thu Oct  1 19:58:07 JST 2026
exit=0
```

**本番**（§3.4〜§3.6）。2026-10-01 21:35〜21:40、`main` の `9042132`（PR #194 のマージ。タグ `v<版>` の注釈付きタグを 21:35 に push 済み）で `make release` を回した。作業ツリーは clean、`ls /Volumes` は `Macintosh HD` だけ。
全出力（約 1 MB）は `docs/release-logs/2026-10-01-make-release-main.txt`。1 段目の lint と test は 17 バンドルすべて passed、公証は 2 回とも `Accepted`、`verify-bundle` は V-1〜V-10 がすべて OK（ビルド 455）。

下は全出力の 1〜8 行目、1 段目の `make test` の集計の行（17 行）、9962 行目以降（2〜7 段）。`notarytool` の進捗の行は `\r` で上書きされる 1 行なので、端末に最後に残る表示を貼った。

```text
$ date; ls /Volumes; git switch main && git pull && git status --porcelain; git rev-parse HEAD; git describe --tags
Thu Oct  1 21:35:57 JST 2026
Macintosh HD
904213204c8e3b612c8a258cee0966792b5ff498
v1.0.0
$ make release; echo "exit=$?"
scripts/release.sh
==> 1/7 lint と test
􁁛  Test run with 10 tests in 1 suite passed after 0.297 seconds.
􁁛  Test run with 119 tests in 10 suites passed after 10.074 seconds.
􁁛  Test run with 33 tests in 3 suites passed after 1.128 seconds.
􁁛  Test run with 34 tests in 1 suite passed after 0.699 seconds.
􀢂  Test run with 325 tests in 36 suites passed after 10.850 seconds with 3 known issues.
􁁛  Test run with 317 tests in 39 suites passed after 0.517 seconds.
􁁛  Test run with 132 tests in 17 suites passed after 23.395 seconds.
􁁛  Test run with 78 tests in 8 suites passed after 0.466 seconds.
􁁛  Test run with 43 tests in 5 suites passed after 12.317 seconds.
􁁛  Test run with 861 tests in 89 suites passed after 19.501 seconds.
􁁛  Test run with 314 tests in 22 suites passed after 0.672 seconds.
􁁛  Test run with 65 tests in 6 suites passed after 0.835 seconds.
􁁛  Test run with 202 tests in 19 suites passed after 12.775 seconds.
􁁛  Test run with 205 tests in 19 suites passed after 3.454 seconds.
􁁛  Test run with 393 tests in 45 suites passed after 2.028 seconds.
􁁛  Test run with 156 tests in 24 suites passed after 0.136 seconds.
􁁛  Test run with 85 tests in 7 suites passed after 0.774 seconds.
==> 2/7 .app の組み立てと Developer ID 署名
==> swift build -c release --arch arm64
Building for production...
[Computing dependencies]
[14 / 57]
[18 / 59] Yams
[28 / 67] CYaml
[30 / 68] VDContract
[33 / 70] VDCore
[35 / 71] Yams
[37 / 67] VDCore
[43 / 71] VDModels
[47 / 75] VDProcess
[52 / 72] VDTranscribe
[55 / 73] VDTranscribe
[57 / 73] VDLLM
[59 / 71] GRDB
[64 / 74] VDStore
[69 / 78] VDDevice
[71 / 79] VDDevice
[82 / 89] VDPipeline
[84 / 90] VDPipeline
[87 / 87] VoiceDockApp-product
[88 / 89] VoiceDockApp-product
Build complete! (35.24秒)
Building for production...
Build complete! (0.25秒)
==> 署名: Developer ID Application: Shinsuke Terada (ZCWP35H248)
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/whisper-cli: replacing existing signature
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/llama-server: replacing existing signature
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/argmax-cli: replacing existing signature
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/voicedock-reaper: replacing existing signature
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app: replacing existing signature
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/whisper-cli
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/whisper-cli
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/argmax-cli
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/argmax-cli
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/voicedock-reaper
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/voicedock-reaper
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/llama-server
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/llama-server
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app: valid on disk
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app: satisfies its Designated Requirement
OK: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app を署名しました（TeamIdentifier=ZCWP35H248）
== V-1 バンドルの中身
  OK   37 件が一致
  OK   ディレクトリ 28 個が一致
== V-2 Info.plist
  OK   plist として読める
  OK   CFBundleIdentifier = io.github.shinsuke-terada.VoiceDock
  OK   CFBundleName = VoiceDock
  OK   CFBundleExecutable = VoiceDock
  OK   CFBundlePackageType = APPL
  OK   CFBundleShortVersionString = 1.0.0
  OK   LSMinimumSystemVersion = 15.0
  OK   LSUIElement = true
  OK   NSRemovableVolumesUsageDescription が在る
  OK   NSDocumentsFolderUsageDescription が在る
  OK   NSDesktopFolderUsageDescription が在る
  OK   NSDownloadsFolderUsageDescription が在る
== V-3 アーキテクチャ
  OK   VoiceDock = arm64
  OK   voicedock-reaper = arm64
  OK   whisper-cli = arm64
  OK   llama-server = arm64
  OK   argmax-cli = arm64
== V-4 otool -L
  OK   リンク先は /usr/lib と /System/Library だけ
OK: --files-only の検査に通りました
OK: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app（版 1.0.0、ビルド 455、署名 developerid）
==> 3/7 .app の公証と staple
==> xcrun notarytool submit（キーチェーンプロファイル VOICEDOCK_NOTARY）
Conducting pre-submission checks for VoiceDock-notarize.zip and initiating connection to the Apple notary service...
Submission ID received
  id: a2acfae5-ff19-4f94-a38e-016c3c3ae968
Successfully uploaded file
  id: a2acfae5-ff19-4f94-a38e-016c3c3ae968
  path: /Users/terada/Projects/voicedock_app/dist/VoiceDock-notarize.zip
Waiting for processing to complete.
Current status: Accepted......Processing complete
  id: a2acfae5-ff19-4f94-a38e-016c3c3ae968
  status: Accepted

Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app
The staple and validate action worked!
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app
The validate action worked!
OK: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app を公証・staple しました（submission a2acfae5-ff19-4f94-a38e-016c3c3ae968）
==> 4/7 dmg の作成
created: /Users/terada/Projects/voicedock_app/dist/.dmg-stage.GaThOW/VoiceDock-rw.dmg
OK: 作業用のイメージを /Users/terada/Projects/voicedock_app/dist/.dmg-stage.GaThOW/mnt にマウントしました（/dev/disk21）
2 images written to /Users/terada/Projects/voicedock_app/dist/.dmg-stage.GaThOW/mnt/.background/background.tiff.
OK: /Users/terada/Projects/voicedock_app/dist/.dmg-stage.GaThOW/mnt/.DS_Store
イメージ作成エンジンを準備中…
ディスク全体（Apple_HFS: 0）を読み込み中…
   （CRC32 $EB4A2397:ディスク全体（Apple_HFS: 0））
リソースを追加中…
経過時間:  55.910ms
ファイルサイズ: 23401594バイト、チェックサム: CRC32 $8DF560B5
処理されたセクタ数: 151552、103873圧縮されました
速度: 907.2Mバイト/秒
節約率: 69.8%
created: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
OK: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
==> 5/7 dmg の署名
==> 署名: Developer ID Application: Shinsuke Terada (ZCWP35H248)
/Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg: valid on disk
/Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg: satisfies its Designated Requirement
OK: dmg を署名しました
==> 6/7 dmg の公証と staple
==> xcrun notarytool submit（キーチェーンプロファイル VOICEDOCK_NOTARY）
Conducting pre-submission checks for VoiceDock-1.0.0.dmg and initiating connection to the Apple notary service...
Submission ID received
  id: a03aa940-3f5c-4159-b5a7-a93bb8afc827
Successfully uploaded file
  id: a03aa940-3f5c-4159-b5a7-a93bb8afc827
  path: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
Waiting for processing to complete.
Current status: Accepted.....Processing complete
  id: a03aa940-3f5c-4159-b5a7-a93bb8afc827
  status: Accepted

Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
The staple and validate action worked!
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
The validate action worked!
OK: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg を公証・staple しました（submission a03aa940-3f5c-4159-b5a7-a93bb8afc827）
==> 7/7 verify-bundle
== V-1 バンドルの中身
  OK   38 件が一致
  OK   ディレクトリ 28 個が一致
== V-2 Info.plist
  OK   plist として読める
  OK   CFBundleIdentifier = io.github.shinsuke-terada.VoiceDock
  OK   CFBundleName = VoiceDock
  OK   CFBundleExecutable = VoiceDock
  OK   CFBundlePackageType = APPL
  OK   CFBundleShortVersionString = 1.0.0
  OK   LSMinimumSystemVersion = 15.0
  OK   LSUIElement = true
  OK   NSRemovableVolumesUsageDescription が在る
  OK   NSDocumentsFolderUsageDescription が在る
  OK   NSDesktopFolderUsageDescription が在る
  OK   NSDownloadsFolderUsageDescription が在る
== V-3 アーキテクチャ
  OK   VoiceDock = arm64
  OK   voicedock-reaper = arm64
  OK   whisper-cli = arm64
  OK   llama-server = arm64
  OK   argmax-cli = arm64
== V-4 otool -L
  OK   リンク先は /usr/lib と /System/Library だけ
== V-5 codesign
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/whisper-cli
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/whisper-cli
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/argmax-cli
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/argmax-cli
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/voicedock-reaper
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/voicedock-reaper
--prepared:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/llama-server
--validated:/Users/terada/Projects/voicedock_app/dist/VoiceDock.app/Contents/Helpers/llama-server
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app: valid on disk
/Users/terada/Projects/voicedock_app/dist/VoiceDock.app: satisfies its Designated Requirement
  OK   署名が有効
== V-6 本体の署名の中身
  OK   Identifier=io.github.shinsuke-terada.VoiceDock
  OK   TeamIdentifier=ZCWP35H248
  OK   Hardened Runtime
  OK   Developer ID Application で署名
== V-7 reaper の署名
  OK   Identifier=io.github.shinsuke-terada.VoiceDock.reaper
  OK   TeamIdentifier=ZCWP35H248
  OK   アプリが使う要件文字列を満たす
== V-8 エンタイトルメント
  OK   本体 のエンタイトルメントは空の dict
  OK   reaper のエンタイトルメントは空の dict
== V-9 spctl と staple
  OK   spctl: Notarized Developer ID
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app
The validate action worked!
  OK   stapler validate（app）
== V-10 dmg
  OK   spctl（dmg）
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
The validate action worked!
  OK   stapler validate（dmg）
  OK   dmg の名前が版と一致
OK: verify-bundle のすべての検査に通りました（版 1.0.0）

版: 1.0.0
0b29d2b29f6e0dbf2a42d76edfff67c9f44276fd7ef080e99db09da3ddbea1d5  /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.0.dmg
904213204c8e3b612c8a258cee0966792b5ff498
exit=0
Thu Oct  1 21:40:05 JST 2026
```

`gh release create`（利用者の確認を得てから。リリースノートの確認の 2 行は上の `shasum -a 256` と `git rev-parse HEAD` で埋めた）と `gh release view`:

```text
$ gh release create "v$version" "dist/VoiceDock-$version.dmg" --title "VoiceDock $version" --notes-file docs/release-notes/"$version".md --verify-tag --latest
https://github.com/shinsuke-terada/voicedock-app/releases/tag/v1.0.0
$ gh release view "v$version"
title:	VoiceDock 1.0.0
tag:	v1.0.0
draft:	false
prerelease:	false
immutable:	false
author:	shinsuke-terada
created:	2026-10-01T12:35:46Z
published:	2026-10-01T12:49:46Z
url:	https://github.com/shinsuke-terada/voicedock-app/releases/tag/v1.0.0
asset:	VoiceDock-1.0.0.dmg
--
# VoiceDock 1.0.0

DJI Mic 3 の録音を Mac につなぐだけで取り込み、文字起こし（whisper.cpp）と要約（llama.cpp）をして Obsidian の Vault にノートを書く、メニューバーのアプリです。処理はすべて Mac の中で行い、録音と文字を外へ出しません。

## 入れ方
1. `VoiceDock-1.0.0.dmg` を開き、`VoiceDock` を `Applications` へドラッグする
2. 初めてデバイスを挿したときの許可のダイアログで「許可」を押す
3. 詳しくは README を参照

## 変わったこと
- 元音声の削除の実機での確認がすべて済んだ（実機 E2E の全件、三重ロックを外しての 1 日の運用、削除 ON での E2E-01〜09 の再実行）。0.9.0 の「試験的な機能として扱う」を外した。**既定は無効のまま**で、有効にするには三重ロックを外す操作が要る
- アプリの動きは 0.9.0 から変わっていない（版の表示と削除モジュールの版が 1.0.0 になる）
- 0.9.0 で削除を有効にしていた場合は、入れ替えた後にパネルに「削除モジュールの更新が必要です」が出る。有効化の操作をもう一度通すと 1.0.0 の削除モジュールに置き換わる
- リポジトリを公開した。Releases の dmg は GitHub にサインインしなくても落とせる

## 既知の制約
- README の「既知の制約」を参照

## 確認
- SHA-256: `0b29d2b29f6e0dbf2a42d76edfff67c9f44276fd7ef080e99db09da3ddbea1d5`
- コミット: `904213204c8e3b612c8a258cee0966792b5ff498`（タグ `v1.0.0`）
```

公開の後、サインインせずに落とせることと `gh release download` が通ることを確かめた（エージェント。SHA-256 は上の dmg と一致）:

```text
$ curl -sI https://github.com/shinsuke-terada/voicedock-app/releases/latest | grep -i "^location"
location: https://github.com/shinsuke-terada/voicedock-app/releases/tag/v1.0.0
$ env -u GH_TOKEN -u GITHUB_TOKEN curl -sSL -o anon/VoiceDock-1.0.0.dmg -w "%{http_code} %{size_download}
" https://github.com/shinsuke-terada/voicedock-app/releases/download/v1.0.0/VoiceDock-1.0.0.dmg
200 23412864
$ gh release download v1.0.0 --repo shinsuke-terada/voicedock-app --pattern "*.dmg" --dir gh
exit=0
$ shasum -a 256 anon/VoiceDock-1.0.0.dmg gh/VoiceDock-1.0.0.dmg
0b29d2b29f6e0dbf2a42d76edfff67c9f44276fd7ef080e99db09da3ddbea1d5  anon/VoiceDock-1.0.0.dmg
0b29d2b29f6e0dbf2a42d76edfff67c9f44276fd7ef080e99db09da3ddbea1d5  gh/VoiceDock-1.0.0.dmg
```

【利用者が行った】プライベートウィンドウ（サインインしていない状態）で Releases から dmg を落とし直し、`/Applications` へ入れ直して起動した。Gatekeeper に止められずに起動し、「詳細・診断」の版の表示は `<版>`（利用者の報告は「確認できた」）。
その後にエージェントが確かめた出力（落とした dmg は `~/Downloads` に残っていなかったので、SHA-256 は上のエージェントのダウンロードで代えた。ビルド 455 は本番の `make release` のもので、リハーサルの 448 ではない）:

```text
$ shasum -a 256 ~/Downloads/VoiceDock-1.0.0.dmg
shasum: /Users/terada/Downloads/VoiceDock-1.0.0.dmg: No such file or directory
$ xattr -p com.apple.quarantine ~/Downloads/VoiceDock-1.0.0.dmg
xattr: No such file: /Users/terada/Downloads/VoiceDock-1.0.0.dmg
$ defaults read /Applications/VoiceDock.app/Contents/Info.plist CFBundleShortVersionString; defaults read /Applications/VoiceDock.app/Contents/Info.plist CFBundleVersion
1.0.0
455
$ spctl -a -vv /Applications/VoiceDock.app
/Applications/VoiceDock.app: accepted
source=Notarized Developer ID
origin=Developer ID Application: Shinsuke Terada (ZCWP35H248)
$ pgrep -fl "VoiceDock.app/Contents/MacOS/VoiceDock"
91156 /Applications/VoiceDock.app/Contents/MacOS/VoiceDock
$ tail -n 3 "$HOME/Library/Application Support/VoiceDock/logs/app.log"
2026-10-01T20:10:59+09:00 INFO  model_downloaded id=large-v3-turbo-q5_0
2026-10-01T21:54:38+09:00 INFO  service_stopping version=1.0.0
2026-10-01T21:55:59+09:00 INFO  service_started version=1.0.0 schema=v1_initial
```

RL-06 の reaper の `--version`（`<HOME>` には削除モジュールが導入されていない（削除は無効）ので、リハーサルの `.app` の中のものを確かめた）:

```text
$ dist/VoiceDock.app/Contents/Helpers/voicedock-reaper --version
1.0.0
exit=0
```

### 5.5 別アカウントでの導入

実施: 2026-10-01 20:05〜20:12。**別のアカウントではなく、いまのアカウントで `<HOME>` を無い状態にして行った**（利用者の決定。2026-09-24 の issue #139 と同じやり方）。利用者が「いまのデータは消えてよい」と決めたので、退避して戻すのではなく、`<HOME>` をゴミ箱へ移し、新しい `<HOME>` をそのまま使い続ける。
LLM の 30B（18.6 GB）だけは、ダウンロードし直さないよう先に `~/Downloads` へ移しておき、「ファイルから読み込む…」で取り込んだ。

手順（利用者が行った）:
1. VoiceDock を終了 → `mv "$HOME/Library/Application Support/VoiceDock/models/llm/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf" ~/Downloads/` → `mv "$HOME/Library/Application Support/VoiceDock" ~/.Trash/VoiceDock-old`
2. §5.4 のリハーサルの dmg（`dist/VoiceDock-<版>.dmg`）を開き、`VoiceDock` を `Applications` へドラッグ（dmg の取り出しは忘れていて、20:41 の時点でもマウントされたままだった。§5.2 を取り直す前に取り出した）
3. `/Applications/VoiceDock.app` を起動し、「はじめに」①〜④を上から: Vault（`~/VoiceDockTestVault`）・Whisper モデルの「入手する」・LLM の「ファイルから読み込む…」（`~/Downloads/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf`）・ログイン時に起動
4. 「はじめに」が消え、パネルは「待機中 / 最終接続 まだありません・未処理なし」。Whisper モデル・VAD モデル・LLM モデル（「読み込んだモデル（6c997b8a）」）に ✓、元音声の削除は「無効」（利用者のスクリーンショット）

**詰まった箇所は無かった。**

- ファイルから読み込んだ LLM は、カタログの 30B と同じファイル（SHA-256 が `Resources/ModelCatalog.json` と一致）でも `custom:<sha256>` として登録され、「読み込んだモデル」と表示される。PLAN の「ファイルから読み込む」の規則どおり（カタログの ID には寄せない）
- 確かめていないこと: **TCC の初回の許可**（同じアカウントなので、リムーバブルボリュームの許可は以前のまま残っている）と、**ダウンロードした dmg の Gatekeeper**（手元で作った dmg には quarantine が付かない）。Gatekeeper は §3.6 でリリースの dmg を落とし直して確かめる

次は 20:41 に打ち直した生の出力（`<HOME>` の作り直しから後、アプリは何も取り込んでいない）。

```text
$ date
Thu Oct  1 20:41:43 JST 2026
$ cat "$HOME/Library/Application Support/VoiceDock/logs/app.log"
2026-10-01T20:10:07+09:00 INFO  service_started version=1.0.0 schema=v1_initial
2026-10-01T20:10:42+09:00 INFO  model_downloaded id=silero-v5.1.2
2026-10-01T20:10:59+09:00 INFO  model_downloaded id=large-v3-turbo-q5_0
$ ls -la "$HOME/Library/Application Support/VoiceDock/models/llm"
total 36268032
drwxr-xr-x@ 3 terada  staff           96 Oct  1 20:11 .
drwxr-xr-x@ 5 terada  staff          160 Oct  1 20:10 ..
-rw-r--r--@ 1 terada  staff  18556686752 Oct  1 20:11 custom-6c997b8af17debdf.gguf
$ grep -nE '"modelID"|"path"|"deleteSourceAudio"' "$HOME/Library/Application Support/VoiceDock/config.json"
22:    "deleteSourceAudio" : false
98:    "modelID" : "custom:6c997b8af17debdfb01d890214400ccbab00db6acc0ba8da5de1cc906c4774d0",
162:      "modelID" : "silero-v5.1.2",
170:    "path" : "/Users/terada/VoiceDockTestVault"
$ defaults read /Applications/VoiceDock.app/Contents/Info.plist CFBundleShortVersionString; defaults read /Applications/VoiceDock.app/Contents/Info.plist CFBundleVersion
1.0.0
448
$ grep -n '6c997b8af17debdf' Resources/ModelCatalog.json
12:               "sha256": "6c997b8af17debdfb01d890214400ccbab00db6acc0ba8da5de1cc906c4774d0", "bytes": 18556686752,
```

### 5.6 未解決の issue

実施: 2026-10-01。開いている issue はこのリリースの T-44（#192）だけ。E2E の #81・#95 は E2E-13 の PASS（PR #191）で閉じた。

```text
$ gh issue list --state open
192	OPEN	T-44 v1.0 のリリース		2026-10-01T09:39:22Z
```

**v1.0 の範囲外とした未確認の項目**（削除のゲートの外。利用者の決定。2026-10-01）:
- F-76: 終了の後始末の最中にログアウトしても中断されず子が残らないこと、モデルの読み込み中に終了すると 10 秒以内に終わること（コードで確かめた。実機では未確認）
- F-84: 「再試行」の後の状態の詳細の読み直し、「モデルの節を開く」の枠がファイル選択の後も残ること（FAILED や要対応が出たときに確かめる）
- Phase 0 の未実施の実測: P0-04〜07・09・11（whisper / llama の実測）と P0-08（SMAppService）。`docs/POC.md`
