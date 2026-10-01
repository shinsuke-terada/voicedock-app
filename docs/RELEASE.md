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
| RL-01 | `docs/E2E.md` の `**ゲート: 開**`（`G-1`〜`G-5` がすべて `✅` か `—`） | `make test-policy`（`RunbookGateTests`）と目視 | ⬜ 未実施 | §5.1 |
| RL-02 | E2E-06（1 日分）が `✅ PASS`（運用の中での確認が済んでいる） | `docs/E2E.md` §2 と §3.6 | ⬜ 未実施 | §5.1 |
| RL-03 | `make test` が緑（ND → policy → 残り） | 全出力を §5.2 に貼る | ⬜ 未実施 | §5.2 |
| RL-04 | `make test-disk` が緑（`.diskImage` を含む） | 全出力を §5.3 に貼る | ⬜ 未実施 | §5.3 |
| RL-05 | `make lint` が緑 | 出力を貼る | ⬜ 未実施 | §5.2 |
| RL-06 | `VERSION` と `AppVersion.string` と reaper の `--version` が一致 | `make test`（T-06 の照合テスト）＋ `"$VD_HOME/bin/voicedock-reaper" --version`（導入済みのとき） | ⬜ 未実施 | §5.2 |
| RL-07 | `README.md` の件数が SPEC と一致し、参照切れが無い | `make test-policy`（`ReadmeTests`） | ⬜ 未実施 | §5.2 |
| RL-08 | `docs/SPEC.md` が `docs/PLAN.md` の写しとして最新 | `make spec` して `git diff --quiet docs/SPEC.md` | ⬜ 未実施 | §5.2 |
| RL-09 | `Package.resolved` がコミット済みで、依存が `exact:` で固定されている | `git status` と `Package.swift` | ⬜ 未実施 | §5.2 |
| RL-10 | `scripts/verify-bundle.sh` の全項目が OK | §3.1 のリハーサルの出力を §5.4 に貼る（本番の §3.4 の出力はリリースの後に追記する） | ⬜ 未実施 | §5.4 |
| RL-11 | 別のユーザアカウント、またはいまのアカウントで `<HOME>` を退避した状態（どちらも `<HOME>` が無い状態）で、リハーサルの dmg から導入し、「はじめに」を最後まで通せた | 手順と結果を §5.5 に書く（退避で代えたときは、TCC の初回の許可を確かめていないことも書く） | ⬜ 未実施 | §5.5 |
| RL-12 | 未解決の FAIL・未起票の不具合が無い | issue の一覧を §5.6 に書く | ⬜ 未実施 | §5.6 |

- **RL-01 と RL-02 と RL-10 は `ReleaseChecklistTests` が機械で見る**（版が 1 以上のとき、この表の全行が `✅` か `—` でないと `make test` が落ちる）。残りは記録で見る
- 次の版を上げるときは、この表の判定を `⬜ 未実施` に戻してから始める（**前回の `✅` を残したまま出さない**）

## 3. 手順

### 3.1 版を上げる PR

1. `develop` から `feat/<チケット>-release-<短い名前>` を切る
2. `VERSION` と `Sources/VDContract/Version.swift` の `AppVersion.string` を新しい版にする
3. `docs/DEVELOPMENT.md` の `## 状態` の表を更新する（F-93）
4. ここまでをコミットし、作業ツリーが clean な状態で **`make release` の 2〜7 段をリハーサルとして回す**（下のコードブロック）。
   1 段目の `make test` は、確認表が埋まるまで `everyChecklistPassesBeforeRelease` で落ちるので、ここでは回さない。
   このリハーサルの dmg で RL-10（`verify-bundle`）と RL-11（`<HOME>` が無い状態での導入）を確かめる
5. この文書の `## 2` の確認表と `## 5` の記録を埋め、`docs/release-notes/<版>.md` を書く（§3.5 の雛形）
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
2. `/Applications/VoiceDock.app` を**リリースした dmg から入れ直し**、パネルの「詳細」の版表示が `VERSION` と同じであることを確かめる
3. 削除を有効にしている場合は、**削除モジュールの版も上がっている**ことを確かめる（パネルに「削除モジュールの更新が必要です」が出たら、有効化の操作をもう一度通す）
4. issue を閉じる（`develop` へのマージでは自動で閉じない。PLAN §12.1）
5. `dist/` は消してよい（`.gitignore` に入っている）

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

⬜ 未実施

### 5.2 make test

⬜ 未実施

### 5.3 make test-disk

⬜ 未実施

### 5.4 make release と verify-bundle

⬜ 未実施

### 5.5 別アカウントでの導入

⬜ 未実施

### 5.6 未解決の issue

⬜ 未実施
