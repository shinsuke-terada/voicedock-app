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
- **`main` はブランチ保護で `check` が緑でないとマージできない**（PLAN §10.8・F-102。PR 必須・管理者にも適用）。CI のランナー（開発機）が止まっているとマージできないので、先にランナーを動かす
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

この節は**いま出そうとしている版**の記録である（版は `VERSION`）。前の版の記録は、その記録の PR がマージされた後の `develop` にある（`git show 4535cb6:docs/RELEASE.md` の §5。全出力は `docs/release-logs/2026-10-01-make-release-main.txt` など）。

### 5.1 削除のゲート

実施: 2026-10-05。RL-01・RL-02 の根拠。`docs/E2E.md` は前の版から変わっていない（ゲートと E2E-06・E2E-13 の行の写し）。`RunbookGateTests` と `ReleaseChecklistTests` は §5.2 の `make test` の中で通った。

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

実施: 2026-10-05 23:40〜23:42。版を上げるブランチのコミット `91da979`（確認表をすべて ✅ にし、§5 の記録を書いた後。`everyChecklistPassesBeforeRelease` が確認表を見る）。作業ツリーは clean（RL-05 の出力の `git status` に出る 1 行は、書き込んでいる途中のこのログのファイル自身）。実機は接続されていない（`ls /Volumes` が `Macintosh HD` だけ）。
この節と §5.3 の記録を書いた後のコミットでは、文書テストだけを回し直した（記録の本文はテストの対象の外）。
全出力は `docs/release-logs/2026-10-05-make-lint.txt` と `docs/release-logs/2026-10-05-make-test.txt`（約 1 MB。本文には先頭の 4 行と集計の行だけを貼る）。どちらも終了コード 0、失敗 0。
`with 3 known issues` は `GoldenSupportTests` が「違えば記録する」ことを `withKnownIssue` で確かめている 3 件で、想定どおり（`docs/E2E.md` §4.3 と同じ）。

RL-05（`make lint`）:

```text
$ date; ls /Volumes; git rev-parse HEAD; git status --porcelain
Mon Oct  5 23:40:04 JST 2026
Macintosh HD
91da97981db48765ff39665c21990ced8fab6377
?? docs/release-logs/2026-10-05-make-lint.txt
$ make lint; echo "exit=$?"
swift format lint --strict --recursive Sources Tests
exit=0
```

RL-03（`make test`。ND → policy → 残り。RL-06 の版の照合・RL-07 の `ReadmeTests`・RL-01 の `RunbookGateTests` を含む）:

```text
$ date; ls /Volumes; git rev-parse HEAD
Mon Oct  5 23:40:08 JST 2026
Macintosh HD
91da97981db48765ff39665c21990ced8fab6377
$ make test; echo "exit=$?"
􁁛  Test run with 10 tests in 1 suite passed after 0.314 seconds.
􁁛  Test run with 119 tests in 10 suites passed after 10.480 seconds.
􁁛  Test run with 33 tests in 3 suites passed after 1.143 seconds.
􁁛  Test run with 34 tests in 1 suite passed after 0.701 seconds.
􀢂  Test run with 325 tests in 36 suites passed after 9.284 seconds with 3 known issues.
􁁛  Test run with 317 tests in 39 suites passed after 0.496 seconds.
􁁛  Test run with 132 tests in 17 suites passed after 23.895 seconds.
􁁛  Test run with 78 tests in 8 suites passed after 0.392 seconds.
􁁛  Test run with 43 tests in 5 suites passed after 12.234 seconds.
􁁛  Test run with 861 tests in 89 suites passed after 19.294 seconds.
􁁛  Test run with 314 tests in 22 suites passed after 0.690 seconds.
􁁛  Test run with 65 tests in 6 suites passed after 0.707 seconds.
􁁛  Test run with 202 tests in 19 suites passed after 12.778 seconds.
􁁛  Test run with 205 tests in 19 suites passed after 3.333 seconds.
􁁛  Test run with 394 tests in 45 suites passed after 1.823 seconds.
􁁛  Test run with 156 tests in 24 suites passed after 0.129 seconds.
􁁛  Test run with 85 tests in 7 suites passed after 0.687 seconds.
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

実施: 2026-10-05 23:41〜23:44。§5.2 と同じコミット `91da979`。**実機は接続されていない**（実行の直前の `ls /Volumes` が `Macintosh HD` だけ。利用者はリリースが終わるまで抜いたままにすると答えた）。利用者の許可を得てエージェントが実行した。
全出力は `docs/release-logs/2026-10-05-make-test-disk.txt`（約 1 MB）。終了コード 0、失敗 0。`VOICEDOCK_DISK_TESTS=1` なので R3（ディスクイメージ）の Suite も走った（ND の 119 件が 53 秒）。

```text
$ date; ls /Volumes; git rev-parse HEAD
Mon Oct  5 23:41:55 JST 2026
Macintosh HD
91da97981db48765ff39665c21990ced8fab6377
$ make test-disk; echo "exit=$?"
􁁛  Test run with 10 tests in 1 suite passed after 0.326 seconds.
􁁛  Test run with 119 tests in 10 suites passed after 53.481 seconds.
􁁛  Test run with 33 tests in 3 suites passed after 1.190 seconds.
􁁛  Test run with 34 tests in 1 suite passed after 0.704 seconds.
􀢂  Test run with 325 tests in 36 suites passed after 10.591 seconds with 3 known issues.
􁁛  Test run with 317 tests in 39 suites passed after 0.510 seconds.
􁁛  Test run with 132 tests in 17 suites passed after 23.616 seconds.
􁁛  Test run with 78 tests in 8 suites passed after 0.454 seconds.
􁁛  Test run with 43 tests in 5 suites passed after 9.461 seconds.
􁁛  Test run with 861 tests in 89 suites passed after 20.635 seconds.
􁁛  Test run with 314 tests in 22 suites passed after 0.619 seconds.
􁁛  Test run with 65 tests in 6 suites passed after 0.827 seconds.
􁁛  Test run with 202 tests in 19 suites passed after 13.435 seconds.
􁁛  Test run with 205 tests in 19 suites passed after 6.736 seconds.
􁁛  Test run with 394 tests in 45 suites passed after 1.820 seconds.
􁁛  Test run with 156 tests in 24 suites passed after 10.084 seconds.
􁁛  Test run with 85 tests in 7 suites passed after 0.717 seconds.
exit=0
```

### 5.4 make release と verify-bundle

**リハーサル**（§3.1 の 4）。2026-10-05 23:1x〜23:27（公証の記録の時刻が 23:26:56 と 23:27:24）、版を上げるブランチのコミット `6ca3f70`（版を上げたコミット。作業ツリーは clean）で `make release` の 2〜7 段を回した。
VoiceDock は終了しており、始める直前に `ls /Volumes` が `Macintosh HD` だけであることを確かめた（利用者は実機を抜いたままにすると答えた）。dmg の作業用のイメージは `dist/` の中にだけマウントされる（`scripts/make-dmg.sh`）。
全出力（220 行）は `docs/release-logs/2026-10-05-rehearsal-make-release.txt`。公証は 2 回とも `Accepted`、`verify-bundle` は V-1〜V-10 がすべて OK、ビルドは 462。
本番（`main` のタグの上での §3.4）の出力は、リリースの後にこの節へ書き足す（§3.6 の 2）。

公証（全出力の 97〜155 行目から、コマンドと結果の行だけ）:

```text
OK: --files-only の検査に通りました
OK: /Users/terada/Projects/voicedock_app/dist/VoiceDock.app（版 1.0.1、ビルド 462、署名 developerid）
$ scripts/notarize.sh dist/VoiceDock.app

Current status: In Progress...
Current status: In Progress....
Current status: Accepted.....Processing complete
  status: Accepted
OK: dist/VoiceDock.app を公証・staple しました（submission d1137e43-30fd-4720-b013-691f496d6bc2）
$ scripts/make-dmg.sh dist/VoiceDock.app
OK: 作業用のイメージを /Users/terada/Projects/voicedock_app/dist/.dmg-stage.uWwx8Y/mnt にマウントしました（/dev/disk21）
OK: /Users/terada/Projects/voicedock_app/dist/.dmg-stage.uWwx8Y/mnt/.DS_Store
OK: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.1.dmg
$ scripts/sign.sh developerid dist/VoiceDock-1.0.1.dmg
OK: dmg を署名しました
$ scripts/notarize.sh dist/VoiceDock-1.0.1.dmg

Current status: In Progress...
Current status: In Progress....
Current status: Accepted.....Processing complete
  status: Accepted
OK: dist/VoiceDock-1.0.1.dmg を公証・staple しました（submission 71dbff8e-0be7-4dcc-b59c-1bd6a654a4b8）
```

`verify-bundle` と SHA-256（全出力の 156〜220 行目）:

```text
$ scripts/verify-bundle.sh dist/VoiceDock.app dist/VoiceDock-1.0.1.dmg
== V-1 バンドルの中身
  OK   38 件が一致
  OK   ディレクトリ 28 個が一致
== V-2 Info.plist
  OK   plist として読める
  OK   CFBundleIdentifier = io.github.shinsuke-terada.VoiceDock
  OK   CFBundleName = VoiceDock
  OK   CFBundleExecutable = VoiceDock
  OK   CFBundlePackageType = APPL
  OK   CFBundleShortVersionString = 1.0.1
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
Processing: /Users/terada/Projects/voicedock_app/dist/VoiceDock-1.0.1.dmg
The validate action worked!
  OK   stapler validate（dmg）
  OK   dmg の名前が版と一致
OK: verify-bundle のすべての検査に通りました（版 1.0.1）
$ shasum / rev-parse
68bf3af7a97f029f97e236abc08983de18ae635fb37fc9ca23853b10cef00b86  dist/VoiceDock-1.0.1.dmg
6ca3f70fb86aa5a40c409d3f1c3113e263cd99db
exit=0
```

### 5.5 別アカウントでの導入

実施: 2026-10-05 23:3x。**前の版と同じく、いまのアカウントで `<HOME>` を無い状態にして行った**。利用者が「今回もデータを捨てて良い」と決めたので、`<HOME>` をゴミ箱へ移し、新しい `<HOME>` をそのまま使い続ける。LLM の 30B（18.6 GB）だけは先に `~/Downloads` へ移し、「ファイルから読み込む…」で取り込んだ。

手順（利用者が行った）:
1. VoiceDock を終了し、LLM を `~/Downloads` へ、`<HOME>` をゴミ箱へ移した（下のコマンド。エージェントが `ls` で、アプリが止まっていること・`<HOME>` が無いこと・LLM が移ったことを確かめた）
2. §5.4 のリハーサルの dmg を開き、`VoiceDock` を `Applications` へドラッグして置き換え、dmg を取り出した（`hdiutil info` に残っていない）
3. `/Applications/VoiceDock.app` を起動し、「はじめに」①〜④を上から: Vault（`~/Documents/Obsidian Vault`）・Whisper モデルの「入手する」・LLM の「ファイルから読み込む…」・ログイン時に起動
4. 終えたパネルのスクリーンショットを利用者が送った

```bash
mv "$HOME/Library/Application Support/VoiceDock/models/llm/custom-6c997b8af17debdf.gguf" ~/Downloads/
mv "$HOME/Library/Application Support/VoiceDock" ~/.Trash/VoiceDock-old-1.0.0
```

**新しく入れた `<HOME>` では Whisper の既定が q8_0 になり（PLAN F-104）、そのまま入手された。**詰まった箇所の報告は無い。

- 確かめていないこと: **TCC の初回の許可**（同じアカウントなので以前の許可が残っている）と、**ダウンロードした dmg の Gatekeeper**（手元で作った dmg には quarantine が付かない）。Gatekeeper は §3.6 でリリースの dmg を落とし直して確かめる
- 新しいデータベースは取り込み済みの記録を持たないので、デバイスに残っている録音は次に挿したときに取り込み直される（利用者に伝えた）

次は 23:36 の生の出力（`<HOME>` を作り直してから、アプリは何も取り込んでいない）。

```text
$ date; ls /Volumes
Mon Oct  5 23:36:32 JST 2026
Macintosh HD
$ cat "$HOME/Library/Application Support/VoiceDock/logs/app.log"
2026-10-05T23:35:04+09:00 INFO  service_started version=1.0.1 schema=v1_initial
2026-10-05T23:35:32+09:00 INFO  model_downloaded id=silero-v5.1.2
2026-10-05T23:36:12+09:00 INFO  model_downloaded id=large-v3-turbo-q8_0
$ ls -la "$HOME/Library/Application Support/VoiceDock/models/whisper" "$HOME/Library/Application Support/VoiceDock/models/llm"
-rw-------@ 1 terada  staff    874188075 Oct  5 23:36 ggml-large-v3-turbo-q8_0.bin
-rw-r--r--@ 1 terada  staff  18556686752 Oct  5 23:35 custom-6c997b8af17debdf.gguf
$ grep -nE '"whisperModelID"|"modelID"|"path"|"deleteSourceAudio"' "$HOME/Library/Application Support/VoiceDock/config.json"
22:    "deleteSourceAudio" : false
98:    "modelID" : "custom:6c997b8af17debdfb01d890214400ccbab00db6acc0ba8da5de1cc906c4774d0",
162:      "modelID" : "silero-v5.1.2",
166:    "whisperModelID" : "large-v3-turbo-q8_0"
170:    "path" : "/Users/terada/Documents/Obsidian Vault"
$ defaults read /Applications/VoiceDock.app/Contents/Info.plist CFBundleShortVersionString; defaults read /Applications/VoiceDock.app/Contents/Info.plist CFBundleVersion
1.0.1
462
```

### 5.6 未解決の issue

実施: 2026-10-05。開いている issue は無い（この版は issue を起こさずに PR #197 と版を上げる PR で進めた。利用者の決定）。

```text
$ gh issue list --state open
（出力なし）
```

**範囲外とした未確認の項目**は前の版と同じ（`git show 4535cb6:docs/RELEASE.md` の §5.6）。この版で足したものは無い。
