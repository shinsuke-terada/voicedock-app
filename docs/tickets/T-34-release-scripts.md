# T-34 .app の組み立て・署名・公証・dmg

| 項目 | 値 |
|---|---|
| ID | T-34 |
| 題 | `.app` の組み立て・署名・公証・dmg（`make app` / `make release`） |
| Phase | 7 |
| 前提 | T-30（`VoiceDockApp` の実行ファイル）、T-03（`Vendor/build/bin/*` と `check-linkage.sh`）、T-01（`Makefile`・`identity.env`・`VERSION`・`voicedock-reaper` の仮置き） |

> **T-37（reaper の中身）は前提にしない。**`swift build --product voicedock-reaper` は T-01 の仮置きの `main.swift` でも通るので、
> Phase 7 の時点で `.app` を組み立てて署名できる。**中身が空の reaper が入った `.app` で削除は起きない**（ロック 2-A は `<HOME>/bin/` に複製されるまで掛かったまま）。
> T-37 がマージされた後に `make app` をやり直すだけでよい。
| 見積もり | 手で書く行 約 590（シェル 6 本 約 390、Info.plist.template 約 50、entitlements 2 本 約 20、manifest 12、テスト約 120）。生成物（`dist/`）は数えない |

## 1. 目的

`VoiceDock.app` を**スクリプトだけ**で組み立て、Apple Development（開発）か Developer ID（配布）で署名し、公証・staple・dmg 化し、
**バンドルの中身が決めた一覧と完全一致すること**をリリースの必須ゲートとして検査する（PLAN §11.1〜§11.3）。

## 2. 参照

- PLAN §11.1（`.app` の構成と Info.plist の必須キー）、§11.2（外部バイナリと `otool -L`）、§11.3（署名・公証・dmg・`verify-bundle.sh`）、§11.4（版）
- PLAN §3.1（`BUNDLE_ID` / `TEAM_ID` / reaper の識別子）、§3.2（リポジトリの木と Makefile）、§2.3（`<HOME>`）
- PLAN §8.9.3（reaper は `Contents/Helpers/` に同梱し、そこからは実行しない。署名の要件文字列）、§8.11 DR-17（ad-hoc 署名だと TCC が毎回失効する）
- 先行チケット: T-01（`identity.env`・`Makefile`・`VERSION`・`PackageRoot`）、T-03（`Vendor/check-linkage.sh`・`versions.env`）、T-04（`MarkdownDocument` は使わない。`SourceScanner` も使わない。素のファイル読みでよい）、T-06（`AppVersion`）、T-10（`AppPaths`）、T-36（`AppIdentity`・`ReaperSignature.requirement`）
- voicedock@d3d595e には対応物が無い（Docker 配布のため）。`scripts/doctor.sh` の書き方（`set -euo pipefail`・1 検査 1 関数・状態の集約）だけを写す

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Resources/Info.plist.template` | 下記の全文 |
| `Resources/VoiceDock.entitlements` | 下記の全文 |
| `Resources/reaper.entitlements` | 下記の全文 |
| `Resources/bundle-manifest.txt` | 下記の全文（バンドルに入ってよいファイルの**唯一の出所**） |
| `scripts/make-app.sh` | 下記の全文（実行権 0755） |
| `scripts/sign.sh` | 下記の全文（実行権 0755） |
| `scripts/notarize.sh` | 下記の全文（実行権 0755） |
| `scripts/make-dmg.sh` | 下記の全文（実行権 0755） |
| `scripts/release.sh` | 下記の全文（実行権 0755） |
| `scripts/verify-bundle.sh` | 下記の全文（実行権 0755） |
| `Tests/PolicyTests/ReleaseBundleTests.swift` | 下記の全文 |
| `Resources/AppIcon.icns` | 仮アイコン（利用者の決定 2026-09-22）。SF Symbol の `waveform` を青紫のグラデーションの角丸に白で描いた 1024×1024 の PNG から `sips` と `iconutil` で作ったもの。差し替えは §4.10 の手順 |

`.gitignore` は**変更しない**（T-01 が `# .app と dmg（T-34）` の注釈つきで `dist/` を入れてある。`distIsIgnored` がそれを確かめる）。

`Resources/AppIcon.icns` は仮アイコン（利用者の決定 2026-09-22）。作り手は T-30 から T-34 に移した。差し替えは §4.10 の手順。

## 4. 仕様

### 4.1 共通の約束（6 本のスクリプトすべて）

1. 1 行目は `#!/bin/bash`、2 行目は役割の日本語コメント（PLAN の節番号つき）、3 行目に使い方、その次に `set -euo pipefail`
2. リポジトリのルートは `root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"` で求める。**カレントディレクトリに依存しない**
3. `BUNDLE_ID` と `TEAM_ID` は `identity.env` を `source` して得る。**スクリプトに値を直書きしない**（`ReleaseBundleTests.scriptsDoNotHardcodeTheIdentifiers` が検査する）
4. 版は `VERSION` の中身（前後の空白を除いたもの）。スクリプトに書かない
5. 出力先は `dist/`（`.gitignore` に入れる）。`dist/` 以外に書かない
6. **`/Volumes` という文字列をどのスクリプトにも書かない**（`noScriptMentionsVolumes` が検査する。実機に触れない約束。PLAN の安全の約束）
7. 失敗は `echo "ERROR: …" >&2` と 0 以外の終了コード。成功の各段は `echo "OK: …"`
8. `codesign` / `spctl` / `xcrun` / `hdiutil` / `ditto` / `otool` / `lipo` / `plutil` はフルパスを書かず、`xcrun` が要るものだけ `xcrun` を付ける
9. **macOS の `/bin/bash` は 3.2 である。**`mapfile` / `readarray`、連想配列（`declare -A`）、`${var^^}`、`&>>`、`|&` を使わない
   （`zsh` や Homebrew の bash では動いて macOS で落ちる。`noScriptUsesBash4Features` が検査する）。配列・`<<<`・`${PIPESTATUS[0]}` は 3.2 でも使える
10. `set -e` の下で `cmd && { …; exit 1; }` と書かない（`cmd` が偽のとき**式全体が偽になり、そこでスクリプトが落ちる**）。判定は `if … then … fi` で書く。
    `a && ok || ng` の形は `ng` が 0 で返るので使ってよい

### 4.2 `Resources/Info.plist.template`（全文）

置換する記号は `@BUNDLE_ID@` / `@VERSION@` / `@BUILD@` の 3 つだけ。`make-app.sh` が `sed` で置き換える。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- VoiceDock.app の Info.plist の雛形（PLAN §11.1）。3 つの記号（BUNDLE_ID・VERSION・BUILD を @ で囲んだもの）を scripts/make-app.sh が置き換える。 -->
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>ja</string>
	<key>CFBundleExecutable</key>
	<string>VoiceDock</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>@BUNDLE_ID@</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>VoiceDock</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>@VERSION@</string>
	<key>CFBundleVersion</key>
	<string>@BUILD@</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSDesktopFolderUsageDescription</key>
	<string>Obsidian の保管庫がこのフォルダにある場合に、ノートを書き込むために使います</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>Obsidian の保管庫がこのフォルダにある場合に、ノートを書き込むために使います</string>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>Obsidian の保管庫がこのフォルダにある場合に、ノートを書き込むために使います</string>
	<key>NSRemovableVolumesUsageDescription</key>
	<string>録音デバイスから音声を読み込むために使います</string>
</dict>
</plist>
```

- 字下げはタブ 1 つ（`plutil -convert xml1` の出力に合わせる）。キーはアルファベット順
- `LSUIElement` は `<true/>`（`<string>YES</string>` でも同じ意味だが、`plutil` が真偽値に正規化するため最初から真偽値で書く）
- 3 つのフォルダの説明は**同じ 1 文**（別々のダイアログに出るので 3 つとも要る）。文言は PLAN §11.1 の逐語
- `CFBundleVersion`（= `@BUILD@`）は `git rev-list --count HEAD`。単調増加であればよく、表示はされない
- 注釈に記号そのもの（`@BUNDLE_ID@` など）を書かない。書くと各記号が 2 回現れて `infoPlistTemplateUsesPlaceholders` が落ち、`sed` が注釈の中まで実際の値に置き換える

### 4.3 `Resources/VoiceDock.entitlements`（全文）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- VoiceDock.app のエンタイトルメント（PLAN §11.3）。Hardened Runtime だけを使い、サンドボックスも例外も足さない。
     ここに何かを足す PR は、なぜ要るかを PR 本文に書く（TCC とロック 2-B の前提が変わる）。 -->
<plist version="1.0">
<dict/>
</plist>
```

### 4.4 `Resources/reaper.entitlements`（全文）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- voicedock-reaper のエンタイトルメント（PLAN §11.3）。空である。reaper は親（VoiceDock.app）の TCC の許可だけで動く。 -->
<plist version="1.0">
<dict/>
</plist>
```

### 4.5 `Resources/bundle-manifest.txt`（全文）

**バンドルに入ってよいファイルの唯一の出所。**`verify-bundle.sh` はこの一覧と `find` の結果を**集合として完全一致**で比べる（多くても少なくても NG）。

```text
# VoiceDock.app に入ってよいファイルの全部（PLAN §11.1・§11.3）。行は VoiceDock.app からの相対パス。
# `#` で始まる行と空行は注釈。並びは辞書順。ここに無いファイルがバンドルに在れば verify-bundle.sh が落ちる。
Contents/Helpers/llama-server
Contents/Helpers/voicedock-reaper
Contents/Helpers/whisper-cli
Contents/Info.plist
Contents/MacOS/VoiceDock
Contents/Resources/AppIcon.icns
Contents/Resources/ModelCatalog.json
Contents/Resources/prompts/analyze_ja.txt
Contents/Resources/prompts/map_ja.txt
Contents/Resources/prompts/reduce_ja.txt
Contents/Resources/prompts/repair_json_ja.txt
Contents/_CodeSignature/CodeResources
```

- `Contents/_CodeSignature/CodeResources` は `codesign` が作る。**署名の後に**照合する
- プロンプトの 4 本は `Resources/prompts/` の中身と一致すること（テスト `manifestListsEveryPromptFile` が照合する。プロンプトを増やす PR はこの一覧も直す）
- `.DS_Store`・`*.dSYM`・`Contents/PkgInfo`・`Contents/Frameworks` は**入れない**（一覧に無いので落ちる）

### 4.6 `scripts/make-app.sh`（全文）

```bash
#!/bin/bash
# VoiceDock.app を組み立てて署名する（PLAN §11.1）。
# 使い方: scripts/make-app.sh <debug|release>
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -ne 1 ] || { [ "$1" != "debug" ] && [ "$1" != "release" ]; }; then
  echo "使い方: $0 <debug|release>" >&2
  exit 2
fi
conf="$1"
if [ "$conf" = "release" ]; then sign_mode=developerid; else sign_mode=development; fi

# shellcheck source=../identity.env
source "$root/identity.env"
: "${BUNDLE_ID:?identity.env に BUNDLE_ID がありません}"
: "${TEAM_ID:?identity.env に TEAM_ID がありません}"

version="$(tr -d '[:space:]' < "$root/VERSION")"
[ -n "$version" ] || { echo "ERROR: VERSION が空です" >&2; exit 1; }
build="$(git -C "$root" rev-list --count HEAD)"
[ "$build" -gt 0 ] || { echo "ERROR: ビルド番号（コミット数）が 0 です" >&2; exit 1; }

# 1. Swift の 2 つの実行ファイル
echo "==> swift build -c $conf --arch arm64"
swift build --package-path "$root" -c "$conf" --arch arm64 --product VoiceDockApp
swift build --package-path "$root" -c "$conf" --arch arm64 --product voicedock-reaper
bin="$(swift build --package-path "$root" -c "$conf" --arch arm64 --show-bin-path)"

# 2. 外部バイナリ（make vendor の成果物）
for tool in whisper-cli llama-server; do
  [ -x "$root/Vendor/build/bin/$tool" ] || { echo "ERROR: Vendor/build/bin/$tool がありません（make vendor を先に実行してください）" >&2; exit 1; }
done
[ -f "$root/Resources/AppIcon.icns" ] || { echo "ERROR: Resources/AppIcon.icns がありません（作り方は T-34 §4.10）" >&2; exit 1; }

# 3. 組み立て（毎回まっさらから作る）
app="$root/dist/VoiceDock.app"
rm -rf "$root/dist/VoiceDock.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources/prompts"

install -m 0755 "$bin/VoiceDockApp" "$app/Contents/MacOS/VoiceDock"
install -m 0755 "$bin/voicedock-reaper" "$app/Contents/Helpers/voicedock-reaper"
install -m 0755 "$root/Vendor/build/bin/whisper-cli" "$app/Contents/Helpers/whisper-cli"
install -m 0755 "$root/Vendor/build/bin/llama-server" "$app/Contents/Helpers/llama-server"
install -m 0644 "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
install -m 0644 "$root/Resources/ModelCatalog.json" "$app/Contents/Resources/ModelCatalog.json"
for prompt in "$root"/Resources/prompts/*.txt; do
  install -m 0644 "$prompt" "$app/Contents/Resources/prompts/$(basename "$prompt")"
done

# 4. Info.plist
sed -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" -e "s|@VERSION@|$version|g" -e "s|@BUILD@|$build|g" \
  "$root/Resources/Info.plist.template" > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" > /dev/null
if grep -q '@[A-Z_][A-Z_]*@' "$app/Contents/Info.plist"; then
  echo "ERROR: Info.plist に置換されていない記号（@…@）が残っています" >&2
  exit 1
fi

# 5. 署名（内側から）
"$root/scripts/sign.sh" "$sign_mode" "$app"

# 6. 中身の一覧だけ照合する（署名・公証の検査は verify-bundle.sh の全体実行で行う）
"$root/scripts/verify-bundle.sh" --files-only "$app"

echo "OK: ${app}（版 ${version}、ビルド ${build}、署名 ${sign_mode}）"
```

- `swift build --show-bin-path` を使う（`.build/arm64-apple-macosx/<conf>` を手で組み立てない）
- 実行ファイル名は `VoiceDockApp`（SwiftPM の product 名）だが、バンドルの中では `VoiceDock`（`CFBundleExecutable`）にする
- `install -m` で権限を明示する（`cp` は元の権限を引き継ぐ）
- `rm -rf "$app"` の対象は `dist/` の中だけ。`$root` が空になりうる書き方（`rm -rf "$root/dist/"*`）をしない

### 4.7 `scripts/sign.sh`（全文）

```bash
#!/bin/bash
# Mach-O を内側から署名する（PLAN §11.3 の 1）。
# 使い方: scripts/sign.sh <development|developerid> <VoiceDock.app か *.dmg>
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -ne 2 ] || { [ "$1" != "development" ] && [ "$1" != "developerid" ]; }; then
  echo "使い方: $0 <development|developerid> <VoiceDock.app か *.dmg>" >&2
  exit 2
fi
mode="$1"
target="$2"
[ -e "$target" ] || { echo "ERROR: $target がありません" >&2; exit 1; }

# shellcheck source=../identity.env
source "$root/identity.env"
: "${BUNDLE_ID:?identity.env に BUNDLE_ID がありません}"
: "${TEAM_ID:?identity.env に TEAM_ID がありません}"

# 署名する鍵を決める。VOICEDOCK_SIGN_IDENTITY があればそれを使う（証明書が複数ある Mac 用）
if [ "$mode" = "developerid" ]; then
  prefix="Developer ID Application"
  timestamp="--timestamp"
else
  prefix="Apple Development"
  timestamp="--timestamp=none"   # 開発では署名のたびにタイムスタンプ局へ出ない（TCC の許可は Team ID で決まる）
fi

# macOS の /bin/bash は 3.2 なので、候補は配列にせず改行区切りの文字列で扱う
identity="${VOICEDOCK_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  candidates="$(security find-identity -v -p codesigning | sed -n "s/^ *[0-9]*) [0-9A-F]* \"\($prefix: .*\)\"\$/\1/p")"
  if [ "$mode" = "developerid" ]; then
    candidates="$(printf '%s\n' "$candidates" | grep -F "($TEAM_ID)" || true)"
  fi
  count="$(printf '%s\n' "$candidates" | grep -c . || true)"
  if [ "$count" != "1" ]; then
    echo "ERROR: 「${prefix}」の証明書が 1 つに決まりません（$count 件）。VOICEDOCK_SIGN_IDENTITY に完全な名前を入れてください" >&2
    printf '  候補: %s\n' "$candidates" >&2
    exit 1
  fi
  identity="$candidates"
fi
echo "==> 署名: $identity"

if [ "${target##*.}" = "dmg" ]; then
  codesign --force $timestamp --sign "$identity" "$target"
  codesign --verify --strict --verbose=2 "$target"
  echo "OK: dmg を署名しました"
  exit 0
fi

# .app は内側から。ヘルパー → reaper → 本体 の順
for tool in whisper-cli llama-server; do
  codesign --force --options runtime $timestamp --sign "$identity" "$target/Contents/Helpers/$tool"
done
codesign --force --options runtime $timestamp --sign "$identity" \
  --identifier "$BUNDLE_ID.reaper" --entitlements "$root/Resources/reaper.entitlements" \
  "$target/Contents/Helpers/voicedock-reaper"
codesign --force --options runtime $timestamp --sign "$identity" \
  --identifier "$BUNDLE_ID" --entitlements "$root/Resources/VoiceDock.entitlements" \
  "$target"

codesign --verify --deep --strict --verbose=2 "$target"

# 開発でも配布でも、署名した証明書の Team ID が identity.env と同じであること（TCC の許可と reaper の要件文字列が Team ID で決まる）
for signed in "$target" "$target/Contents/Helpers/voicedock-reaper"; do
  info="$(codesign -dvvv "$signed" 2>&1 || true)"
  if ! grep -qxF "TeamIdentifier=$TEAM_ID" <<<"$info"; then
    echo "ERROR: ${signed} の TeamIdentifier が ${TEAM_ID} でありません（identity.env と別のチームの証明書で署名しました）" >&2
    exit 1
  fi
done
echo "OK: $target を署名しました（TeamIdentifier=${TEAM_ID}）"
```

- **reaper だけ `--identifier` を明示する**（PLAN §3.1。`ReaperSignature.requirement` の `identifier "<BUNDLE_ID>.reaper"` が通るため）。
  本体にも明示するのは、`CFBundleIdentifier` と食い違ったまま気づかない事故を防ぐため
- `$timestamp` は意図的に**引用しない**（`--timestamp` と `--timestamp=none` の 1 語を渡す。空文字列を渡さないので語の分割は起きない）
- 開発でも `--options runtime` を付ける（本番と同じ制約で動かす。ad-hoc にしない。DR-17）
- 署名の後に、本体と reaper の `TeamIdentifier` が `identity.env` の `TEAM_ID` と同じことを確かめる（開発でも配布でも。Apple Development の証明書が別のチームのものだと、TCC の許可と reaper の要件文字列（Team ID で束縛）が合わない）。`codesign -dvvv | grep -q` と繋がず、いったん変数に受けてから `<<<` で渡す（`grep -q` が先に終わると `pipefail` で偽になる）

### 4.8 `scripts/notarize.sh`（全文）

```bash
#!/bin/bash
# 公証して staple する（PLAN §11.3 の 2）。
# 使い方: scripts/notarize.sh <VoiceDock.app か *.dmg>
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${NOTARY_PROFILE:-VOICEDOCK_NOTARY}"

[ "$#" -eq 1 ] || { echo "使い方: $0 <VoiceDock.app か *.dmg>" >&2; exit 2; }
target="$1"
[ -e "$target" ] || { echo "ERROR: $target がありません" >&2; exit 1; }

if [ "${target##*.}" = "app" ]; then
  upload="$root/dist/$(basename "$target" .app)-notarize.zip"
  rm -f "$upload"
  trap 'rm -f "$upload"' EXIT   # 公証用の zip は送ったら要らない（.app の側を staple する）
  ditto -c -k --keepParent "$target" "$upload"
else
  upload="$target"
fi

echo "==> xcrun notarytool submit（キーチェーンプロファイル ${profile}）"
log="$root/dist/notarytool-$(basename "$target").txt"
set +e
xcrun notarytool submit "$upload" --keychain-profile "$profile" --wait 2>&1 | tee "$log"
rc="${PIPESTATUS[0]}"
set -e

submission="$(sed -n 's/^ *id: \([0-9a-fA-F-]\{36\}\).*$/\1/p' "$log" | head -n 1)"
if [ "$rc" -ne 0 ] || ! grep -q '^ *status: Accepted$' "$log"; then
  echo "ERROR: 公証が通りませんでした（${log}）" >&2
  [ -n "$submission" ] && xcrun notarytool log "$submission" --keychain-profile "$profile" >&2 || true
  exit 1
fi

xcrun stapler staple "$target"
xcrun stapler validate "$target"
echo "OK: $target を公証・staple しました（submission ${submission}）"
```

- `--wait` を必ず付ける（待たずに次へ進むと staple が「まだ通っていない」で失敗する）
- 通らなかったときは `notarytool log` を**そのまま**標準エラーへ出す（何が弾かれたかが分かる唯一の情報）
- `.app` を包む zip は `ditto -c -k --keepParent`（PLAN §11.3。`zip(1)` は拡張属性と symlink を落とす）
- zip は `trap` で消す（`.app` の場合だけ。dmg はそれ自体を送るので消さない）

#### キーチェーンプロファイルの作り方【利用者が行う】

初回だけ、手元の Mac で 1 回実行する（Apple ID の**App 用パスワード**が要る。<https://appleid.apple.com> の「サインインとセキュリティ → App 用パスワード」で作る）:

```bash
xcrun notarytool store-credentials VOICEDOCK_NOTARY \
  --apple-id "<Apple ID のメールアドレス>" \
  --team-id "<identity.env の TEAM_ID>" \
  --password "<App 用パスワード（xxxx-xxxx-xxxx-xxxx）>"
```

- 作れたことの確認: `xcrun notarytool history --keychain-profile VOICEDOCK_NOTARY`（0 件でもよい。認証が通れば OK）
- **App 用パスワードをリポジトリ・シェルの履歴・CI に置かない**（キーチェーンにだけ置く）。CI で公証しない（PLAN §10.8）

### 4.9 `scripts/make-dmg.sh`（全文）

```bash
#!/bin/bash
# 配布用の dmg を作る（PLAN §11.3 の 3）。作成中にイメージをマウントしない（makehybrid → convert）。
# 使い方: scripts/make-dmg.sh <VoiceDock.app>
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ "$#" -eq 1 ] || { echo "使い方: $0 <VoiceDock.app>" >&2; exit 2; }
app="$1"
[ -d "$app" ] || { echo "ERROR: $app がありません" >&2; exit 1; }

version="$(tr -d '[:space:]' < "$root/VERSION")"
dmg="$root/dist/VoiceDock-$version.dmg"
rm -f "$dmg"

mkdir -p "$root/dist"
stage="$(mktemp -d "$root/dist/.dmg-stage.XXXXXX")"
hybrid="$stage.hybrid.dmg"
trap 'rm -rf "$stage"; rm -f "$hybrid"' EXIT
ditto "$app" "$stage/VoiceDock.app"
ln -s /Applications "$stage/Applications"

hdiutil makehybrid -hfs -hfs-volume-name VoiceDock -o "$hybrid" "$stage"
hdiutil convert "$hybrid" -format UDZO -o "$dmg"
echo "OK: $dmg"
```

- **作成中にイメージをマウントしない**（利用者の決定 2026-09-22。PLAN §11.3・F-62）。`hdiutil makehybrid -hfs` で一時フォルダから HFS+ のイメージを直に作り、`hdiutil convert -format UDZO` で圧縮する。`hdiutil create -srcfolder` は内部でイメージを `/Volumes` の下に attach するので使わない（テスト `makeDmgNeverMounts` が `-srcfolder` と `hdiutil attach` の不在を見る）
- ボリューム名は `VoiceDock`（`-hfs-volume-name`）。実機の DJI Mic 3（`DJIMIC3`）とは別の名前
- 既存の dmg は `rm -f` で消してから作る。一時フォルダと中間のイメージは `dist/` の中に作り、`trap` で必ず消す
- **未解決（2026-09-22 の実測。利用者の判断待ち）**: `makehybrid -hfs` は、元に無い `com.apple.FinderInfo`（`00…00 FF FF FF FF 00…`）を**すべてのファイルに付ける**。
  そのため dmg の中の `.app` と、そこから `ditto` / `cp -R` で取り出した `.app` が、`codesign --verify --deep --strict` で
  `resource fork, Finder information, or similar detritus not allowed`（`Disallowed xattr com.apple.FinderInfo`）になる（Gatekeeper も同じ理由で拒む恐れがある）。
  `makehybrid -udf` は署名を壊さない（中でも取り出しても `--strict` が通る）が、`/Applications` への symlink が壊れる（`readlink` が `Unknown error: 10000`）。
  `-hfs-volume-name` 以外のオプションでは変わらなかった。`make release` の前に方式を決める（候補: UDF で symlink を置かない／`/Volumes` の外の `-mountpoint` に attach して書く／dmg をやめて zip）
- 背景画像・アイコン配置はしない（v1 は `/Applications` への symlink だけ）

### 4.10 `Resources/AppIcon.icns`（仮アイコン）の差し替え【利用者が行う】

いまのアイコンは仮アイコン（利用者の決定 2026-09-22）。差し替えるときは、1024×1024 の PNG（`icon-1024.png`）から次の手順で作り、`Resources/AppIcon.icns` を置き換える PR を出す:

```bash
mkdir -p /tmp/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon-1024.png --out "/tmp/AppIcon.iconset/icon_${s}x${s}.png"
  sips -z $((s*2)) $((s*2)) icon-1024.png --out "/tmp/AppIcon.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
```

### 4.11 `scripts/verify-bundle.sh`（全文）

```bash
#!/bin/bash
# リリースの必須ゲート（PLAN §11.3 の 4）。バンドルの中身・署名・公証・リンクを検査する。
# 使い方: scripts/verify-bundle.sh [--files-only] <VoiceDock.app> [<VoiceDock-<ver>.dmg>]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

files_only=0
if [ "${1:-}" = "--files-only" ]; then files_only=1; shift; fi
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "使い方: $0 [--files-only] <VoiceDock.app> [<VoiceDock-<ver>.dmg>]" >&2
  exit 2
fi
app="$1"
dmg="${2:-}"
[ -d "$app" ] || { echo "ERROR: $app がありません" >&2; exit 1; }

# shellcheck source=../identity.env
source "$root/identity.env"
: "${BUNDLE_ID:?identity.env に BUNDLE_ID がありません}"
: "${TEAM_ID:?identity.env に TEAM_ID がありません}"
version="$(tr -d '[:space:]' < "$root/VERSION")"

status=0
ok()   { echo "  OK   $1"; }
ng()   { echo "  NG   $1" >&2; status=1; }
step() { echo "== $1"; }

# V-1 中身の一覧が Resources/bundle-manifest.txt と完全一致（ディレクトリは一覧の各行の親から導き、空のディレクトリも見つける）
step "V-1 バンドルの中身"
expected="$(grep -v -e '^#' -e '^$' "$root/Resources/bundle-manifest.txt" | LC_ALL=C sort)"
actual="$(cd "$app" && find . -type f -o -type l | sed 's|^\./||' | LC_ALL=C sort)"
if [ "$expected" = "$actual" ]; then
  ok "$(wc -l <<<"$expected" | tr -d ' ') 件が一致"
else
  ng "一覧が一致しません"
  diff <(echo "$expected") <(echo "$actual") >&2 || true
fi
expected_dirs="$(awk -F/ '{ p = ""; for (i = 1; i < NF; i++) { p = (i == 1) ? $i : p "/" $i; print p } }' <<<"$expected" | LC_ALL=C sort -u)"
actual_dirs="$(cd "$app" && find . -mindepth 1 -type d | sed 's|^\./||' | LC_ALL=C sort)"
if [ "$expected_dirs" = "$actual_dirs" ]; then
  ok "ディレクトリ $(wc -l <<<"$expected_dirs" | tr -d ' ') 個が一致"
else
  ng "ディレクトリが一致しません（空のディレクトリか、一覧に無い場所があります）"
  diff <(echo "$expected_dirs") <(echo "$actual_dirs") >&2 || true
fi

# V-2 Info.plist の必須キー
step "V-2 Info.plist"
plist="$app/Contents/Info.plist"
plutil -lint "$plist" > /dev/null && ok "plist として読める" || ng "plist が壊れています"
check_key() {
  local key="$1" want="$2" got
  got="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null || echo "<無し>")"
  [ "$got" = "$want" ] && ok "$key = $got" || ng "$key が $want でない（${got}）"
}
check_key CFBundleIdentifier "$BUNDLE_ID"
check_key CFBundleName VoiceDock
check_key CFBundleExecutable VoiceDock
check_key CFBundlePackageType APPL
check_key CFBundleShortVersionString "$version"
check_key LSMinimumSystemVersion 15.0
check_key LSUIElement true
for key in NSRemovableVolumesUsageDescription NSDocumentsFolderUsageDescription \
           NSDesktopFolderUsageDescription NSDownloadsFolderUsageDescription; do
  plutil -extract "$key" raw -o - "$plist" > /dev/null 2>&1 && ok "$key が在る" || ng "$key が無い"
done

# V-3 すべての Mach-O が arm64 単体
step "V-3 アーキテクチャ"
machos=("$app/Contents/MacOS/VoiceDock" "$app/Contents/Helpers/voicedock-reaper"
        "$app/Contents/Helpers/whisper-cli" "$app/Contents/Helpers/llama-server")
for bin in "${machos[@]}"; do
  arch="$(lipo -archs "$bin" 2>/dev/null || echo "<読めない>")"
  [ "$arch" = "arm64" ] && ok "$(basename "$bin") = arm64" || ng "$(basename "$bin") が arm64 単体でない（${arch}）"
done

# V-4 リンク（PLAN §11.2）
step "V-4 otool -L"
"$root/Vendor/check-linkage.sh" "${machos[@]}" && ok "リンク先は /usr/lib と /System/Library だけ" || ng "リンクに問題があります"

if [ "$files_only" -eq 1 ]; then
  [ "$status" -eq 0 ] && echo "OK: --files-only の検査に通りました" || echo "ERROR: --files-only の検査に失敗しました" >&2
  exit "$status"
fi

# V-5 署名
step "V-5 codesign"
codesign --verify --deep --strict --verbose=2 "$app" && ok "署名が有効" || ng "署名が無効"

# V-6 本体の識別子・Team ID・Hardened Runtime
step "V-6 本体の署名の中身"
info="$(codesign -dvvv "$app" 2>&1 || true)"
grep -qxF "Identifier=$BUNDLE_ID" <<<"$info" && ok "Identifier=$BUNDLE_ID" || ng "Identifier が $BUNDLE_ID でない"
grep -qxF "TeamIdentifier=$TEAM_ID" <<<"$info" && ok "TeamIdentifier=$TEAM_ID" || ng "TeamIdentifier が $TEAM_ID でない"
grep -qE '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime.*\)' <<<"$info" && ok "Hardened Runtime" || ng "Hardened Runtime でない"
grep -q 'Authority=Developer ID Application' <<<"$info" && ok "Developer ID Application で署名" || ng "Developer ID Application でない"

# V-7 reaper の識別子（PLAN §3.1・§8.9.3）
step "V-7 reaper の署名"
rinfo="$(codesign -dvvv "$app/Contents/Helpers/voicedock-reaper" 2>&1 || true)"
grep -qxF "Identifier=$BUNDLE_ID.reaper" <<<"$rinfo" && ok "Identifier=$BUNDLE_ID.reaper" || ng "reaper の Identifier が違う"
grep -qxF "TeamIdentifier=$TEAM_ID" <<<"$rinfo" && ok "TeamIdentifier=$TEAM_ID" || ng "reaper の TeamIdentifier が違う"
codesign --verify -R "=anchor apple generic and identifier \"$BUNDLE_ID.reaper\" and certificate leaf[subject.OU] = \"$TEAM_ID\"" \
  "$app/Contents/Helpers/voicedock-reaper" && ok "アプリが使う要件文字列を満たす" || ng "要件文字列を満たさない"

# V-8 エンタイトルメント（サンドボックス無し・例外無し）。本体と reaper の両方が空の dict であること
step "V-8 エンタイトルメント"
check_entitlements() {
  local target="$1" name="$2" raw ents
  if ! raw="$(codesign -d --entitlements - --xml "$target" 2>/dev/null)"; then
    ng "${name} のエンタイトルメントを読めません"
    return
  fi
  ents="$(plutil -convert json -o - - <<<"$raw" 2>/dev/null || echo "<読めない>")"
  [ "$ents" = "{}" ] && ok "${name} のエンタイトルメントは空の dict" || ng "${name} のエンタイトルメントが空の dict でない（${ents}）"
}
check_entitlements "$app" "本体"
check_entitlements "$app/Contents/Helpers/voicedock-reaper" "reaper"

# V-9 公証（Gatekeeper の判定）
step "V-9 spctl と staple"
spctl -a -t exec -vv "$app" 2>&1 | grep -q 'source=Notarized Developer ID' && ok "spctl: Notarized Developer ID" || ng "spctl が通らない"
xcrun stapler validate "$app" && ok "stapler validate（app）" || ng "staple されていない（app）"

# V-10 dmg
if [ -n "$dmg" ]; then
  step "V-10 dmg"
  [ -f "$dmg" ] || ng "$dmg がありません"
  spctl -a -t open --context context:primary-signature -v "$dmg" 2>&1 | grep -q 'accepted' && ok "spctl（dmg）" || ng "spctl が通らない（dmg）"
  xcrun stapler validate "$dmg" && ok "stapler validate（dmg）" || ng "staple されていない（dmg）"
  [ "$(basename "$dmg")" = "VoiceDock-$version.dmg" ] && ok "dmg の名前が版と一致" || ng "dmg の名前が VoiceDock-$version.dmg でない"
fi

if [ "$status" -eq 0 ]; then
  echo "OK: verify-bundle のすべての検査に通りました（版 ${version}）"
else
  echo "ERROR: verify-bundle に失敗しました" >&2
fi
exit "$status"
```

- **一覧の照合（V-1）は `find` の結果との集合の完全一致**。「余計な実行ファイルが入っていない」を担保する唯一の検査
- ディレクトリも照合する。一覧の形式（ファイルだけを書く）は変えず、各行の親のパスから期待するディレクトリの集合を導いて `find -type d` と比べる（空のディレクトリ・一覧に無い場所を見つける）
- V-8 は本体と reaper の両方で、`codesign -d --entitlements` が成功し、その plist を JSON にしたものが `{}`（空の dict）であることを見る（読めないときも NG。`com.apple.security` の語を探すだけでは、ほかの名前空間のエンタイトルメントを見逃す）
- `Identifier=` と `TeamIdentifier=` の照合は `grep -qxF`（識別子の `.` を正規表現の任意の 1 文字にしない）
- `--files-only` は `make app`（debug）から呼ぶ。公証していないバンドルに `spctl` を掛けて落とさないため
- V-7 の要件文字列は `ReaperSignature.requirement(bundleID:teamID:)`（T-36）と**同じ形**。ここを変えたら Swift 側も同じ PR で変える（逆も同じ）
- `status` を立てて**最後まで全部走らせる**（最初の NG で止めない。1 回の実行で全部の問題が見える）
- そのため `$(…)` で結果を受ける `lipo -archs`・`codesign -dvvv` には `|| echo "<読めない>"`・`|| true` を付ける（付けないと、ファイルが無い・未署名のときに `set -e` がそこでスクリプトを止める。破壊 19 で reaper を消すと V-3 の `lipo` で止まっていた）

### 4.12 `scripts/release.sh`（全文）

```bash
#!/bin/bash
# 署名・公証・dmg を通しで行う（PLAN §11.3。make release）。手元の Mac で実行する。
# 使い方: scripts/release.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(tr -d '[:space:]' < "$root/VERSION")"
dmg="$root/dist/VoiceDock-$version.dmg"

# 0. 作業ツリーが clean であること（版と成果物の対応を崩さない）
if [ -n "$(git -C "$root" status --porcelain)" ]; then
  if [ "${RELEASE_ALLOW_DIRTY:-0}" = "1" ]; then
    echo "WARNING: 作業ツリーに未コミットの変更があります（RELEASE_ALLOW_DIRTY=1 なので続けます）" >&2
  else
    echo "ERROR: 作業ツリーに未コミットの変更があります（試すだけなら RELEASE_ALLOW_DIRTY=1）" >&2
    exit 1
  fi
fi

echo "==> 1/7 lint と test"
make -C "$root" lint
make -C "$root" test

echo "==> 2/7 .app の組み立てと Developer ID 署名"
"$root/scripts/make-app.sh" release

echo "==> 3/7 .app の公証と staple"
"$root/scripts/notarize.sh" "$root/dist/VoiceDock.app"

echo "==> 4/7 dmg の作成"
"$root/scripts/make-dmg.sh" "$root/dist/VoiceDock.app"

echo "==> 5/7 dmg の署名"
"$root/scripts/sign.sh" developerid "$dmg"

echo "==> 6/7 dmg の公証と staple"
"$root/scripts/notarize.sh" "$dmg"

echo "==> 7/7 verify-bundle"
"$root/scripts/verify-bundle.sh" "$root/dist/VoiceDock.app" "$dmg"

echo
echo "版: $version"
shasum -a 256 "$dmg"
git -C "$root" rev-parse HEAD
```

- **順序が意味を持つ**: `.app` を公証・staple してから dmg に入れる（dmg を staple しても、中の `.app` が staple されていないと初回起動でネットワークを要求する）
- `make test` を含める（署名・公証に数分かかるので、その前に落ちるものは落とす）

### 4.13 `Makefile` と `.gitignore`

- T-01 の `Makefile` の `app` / `release` はこのチケットのスクリプトをそのまま呼ぶ（**変更なし**。`require_script` が満たされるようになる）
- `.gitignore` も**変更なし**（T-01 が `dist/` を入れてある）

### 4.14 Apple Development と Developer ID の切り替え

| | 開発（`make app`） | 配布（`make release`） |
|---|---|---|
| 呼び出し | `scripts/make-app.sh debug` | `scripts/make-app.sh release` |
| `sign.sh` の引数 | `development` | `developerid` |
| 証明書 | `Apple Development: <名前> (<10 文字>)` | `Developer ID Application: <名前> (<TEAM_ID>)` |
| タイムスタンプ | `--timestamp=none` | `--timestamp` |
| Hardened Runtime | 付ける | 付ける |
| 公証 | しない | する |
| `verify-bundle.sh` | `--files-only` | 全部 |

- **開発でも ad-hoc（`--sign -`）にしない。**ad-hoc だとビルドのたびに署名が変わり、リムーバブルボリュームと書類フォルダの TCC の許可が毎回失効する（PLAN §11.1、DR-17 が警告する）
- 証明書が複数ある Mac では `VOICEDOCK_SIGN_IDENTITY="Apple Development: …"` を環境変数で渡す
- **どちらの場合も Team ID は `identity.env` の 1 か所から来る。**`AppIdentity.teamID`（T-36）と一致することは `AppIdentityTests.matchesIdentityEnv` が見る

## 5. テスト

### `Tests/PolicyTests/ReleaseBundleTests.swift`（全文）

```swift
// 配布スクリプト・Info.plist・エンタイトルメント・バンドルの許可リストの静的検査（PLAN §11.1〜§11.3。T-34）。
import Foundation
import TestSupport
import Testing

@Suite("ReleaseBundle")
struct ReleaseBundleTests {
    static let scripts = [
        "scripts/make-app.sh", "scripts/sign.sh", "scripts/notarize.sh",
        "scripts/make-dmg.sh", "scripts/release.sh", "scripts/verify-bundle.sh",
    ]

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: PackageRoot.file(relativePath), encoding: .utf8)
    }

    /// `identity.env` の `KEY=VALUE`。
    static func identity() throws -> [String: String] {
        var values: [String: String] = [:]
        for line in try text("identity.env").split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        return values
    }

    /// `Resources/bundle-manifest.txt` の注釈でない行。
    static func manifest() throws -> [String] {
        try text("Resources/bundle-manifest.txt")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
    }
}
```

| ファイル | 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|---|
| `ReleaseBundleTests.swift` | `everyScriptIsExecutable(_:)` | 配布スクリプトが在り実行できる | 6 本で parametrize | ファイルが在り、`posixPermissions & 0o111 != 0` |
| 同上 | `everyScriptIsStrictBash(_:)` | 配布スクリプトは bash の strict モード | 同上 | 1 行目が `#!/bin/bash`、本文に `set -euo pipefail` が在る |
| 同上 | `everyScriptResolvesTheRootFromItsOwnPath(_:)` | 配布スクリプトはカレントに依存しない | 同上 | `BASH_SOURCE[0]` を含む |
| 同上 | `scriptsDoNotHardcodeTheIdentifiers(_:)` | 配布スクリプトに BUNDLE_ID と TEAM_ID を直書きしない | 同上 ＋ `identity()` | 本文に `BUNDLE_ID` の値も `TEAM_ID` の値も現れない |
| 同上 | `scriptsThatNeedTheIdentitySourceIt(_:)` | 識別子を使うスクリプトは identity.env を読む | `make-app.sh`・`sign.sh`・`verify-bundle.sh` | `source "$root/identity.env"` を含む |
| 同上 | `noScriptMentionsVolumes(_:)` | 配布スクリプトは /Volumes に触れない | 6 本 | `/Volumes` という文字列が無い |
| 同上 | `noScriptWritesOutsideDist(_:)` | 配布スクリプトの `rm -rf` は dist の下だけ | 6 本 | `rm -rf` を含む各行が `dist/` か `"$stage"` を含む |
| 同上 | `noScriptUsesBash4Features(_:)` | macOS の bash 3.2 で動く書き方だけを使う | 6 本 × 5 語（`mapfile`・`readarray`・`declare -A`・`&>>`・`\|&`） | どの語も含まない |
| 同上 | `infoPlistTemplateHasEveryRequiredKey(_:)` | Info.plist の必須キーが在る | 11 個のキー名で parametrize（下記） | `<key>…</key>` が在る |
| 同上 | `infoPlistTemplateHasTheFixedValues()` | Info.plist の固定値（逐語） | テンプレート | `CFBundleName`・`CFBundleExecutable` の次の行が `<string>VoiceDock</string>`、`CFBundlePackageType` が `APPL`、`LSMinimumSystemVersion` が `15.0`、`LSUIElement` の次の行が `<true/>` |
| 同上 | `infoPlistTemplateUsesPlaceholders()` | Info.plist は 3 つの記号で置換する | 同上 | `@BUNDLE_ID@`・`@VERSION@`・`@BUILD@` が各 1 回、`identity()` の `BUNDLE_ID` の値は現れない |
| 同上 | `usageDescriptionsAreVerbatim()` | TCC の説明文が PLAN の逐語 | 同上 | `録音デバイスから音声を読み込むために使います` が 1 回、`Obsidian の保管庫がこのフォルダにある場合に、ノートを書き込むために使います` が 3 回 |
| 同上 | `entitlementsAreEmpty(_:)` | エンタイトルメントは空で例外が無い | 2 ファイルで parametrize | `<dict/>` を含み、`com.apple.security` を含まない |
| 同上 | `manifestIsSortedAndUnique()` | 許可リストは辞書順で重複が無い | `manifest()` | `LC_ALL=C` 相当（Unicode スカラー比較）で昇順、`Set` の要素数が配列と同じ |
| 同上 | `manifestEntriesAreUnderContents(_:)` | 許可リストの各行は Contents/ 配下の相対パス | `manifest()` で parametrize | `Contents/` で始まり、`..` と先頭の `/` を含まない |
| 同上 | `manifestListsTheThreeHelpers()` | 許可リストにヘルパー 3 本が在る | `manifest()` | `Contents/Helpers/{whisper-cli,llama-server,voicedock-reaper}` をすべて含み、`Contents/Helpers/` で始まる行がちょうど 3 本 |
| 同上 | `manifestListsEveryPromptFile()` | 許可リストのプロンプトが Resources/prompts と一致 | `Resources/prompts/` の `.txt` の一覧 | 集合が `Contents/Resources/prompts/<名前>` と完全一致（空でない） |
| 同上 | `manifestListsTheCodeSignature()` | 許可リストに `_CodeSignature/CodeResources` が在る | `manifest()` | 含む（署名の後に照合するため） |
| 同上 | `makeAppInstallsEveryManifestEntry(_:)` | 組み立てが許可リストの各ファイルを作る | `manifest()` から `Info.plist` と `_CodeSignature/CodeResources` を除いたもので parametrize | `make-app.sh` の本文に `"$app/<その行>"` が現れる。プロンプトはループで入れるので、ループの元 `Resources/prompts/*.txt` と行き先 `"$app/Contents/Resources/prompts/` の両方が現れる |
| 同上 | `verifyBundleRunsEveryRequiredCheck(_:)` | verify-bundle が PLAN §11.3 の 4 の全項目を行う | 7 つの語で parametrize: `bundle-manifest.txt`・`codesign --verify --deep --strict`・`spctl -a -t exec`・`spctl -a -t open --context context:primary-signature`・`stapler validate`・`check-linkage.sh`・`.reaper` | `verify-bundle.sh` に含まれる |
| 同上 | `verifyBundleSupportsFilesOnly()` | `--files-only` が在り、make-app が使う | 2 ファイル | `verify-bundle.sh` に `--files-only` が在り、`make-app.sh` が `verify-bundle.sh" --files-only` を呼ぶ（パスは `"$root/scripts/verify-bundle.sh"` と引用されるので、引用符の閉じまで含めて探す） |
| 同上 | `signUsesTheReaperIdentifier()` | reaper だけ `--identifier <BUNDLE_ID>.reaper` で署名する | `sign.sh` | `--identifier "$BUNDLE_ID.reaper"` と `--entitlements "$root/Resources/reaper.entitlements"` を含む |
| 同上 | `signNeverUsesAdhoc()` | DR-17 ad-hoc 署名をしない | `sign.sh` | `--sign -` を含まない。`--options runtime` を含む |
| 同上 | `makeDmgNeverMounts()` | dmg の作成でイメージをマウントしない | `make-dmg.sh` | `-srcfolder` と `hdiutil attach` を含まない。`hdiutil makehybrid` と `hdiutil convert` を含む |
| 同上 | `notarizeWaitsAndUsesTheProfile()` | 公証はプロファイルを使い `--wait` する | `notarize.sh` | `VOICEDOCK_NOTARY`・`--keychain-profile`・`--wait`・`stapler staple`・`ditto -c -k --keepParent` を含む |
| 同上 | `releaseRunsTheStepsInOrder()` | release.sh の段の順（PLAN §11.3） | `release.sh` | `make-app.sh` → `notarize.sh` → `make-dmg.sh` → `sign.sh" developerid` → `notarize.sh` → `verify-bundle.sh` の順に現れる（各語は直前の語の出現より後ろから探す。`notarize.sh` が 2 回あるため「最初の出現位置」では 2 回目を区別できない。`sign.sh` は `"$root/scripts/sign.sh" developerid` と引用されるので引用符の閉じまで含めて探す） |
| 同上 | `makefileUsesTheseScripts()` | Makefile の app / release がこのスクリプトを呼ぶ | `Makefile` | `scripts/make-app.sh debug` と `scripts/release.sh` を含む |
| 同上 | `distIsIgnored()` | `dist/` はコミットしない | `.gitignore` | `dist/` の行が在る |
| 同上 | `theChecksWouldCatchABrokenScript()` | **陽性対照**: 検査自体が効く | 文字列を直に渡すヘルパー | `#!/bin/sh\n` は `everyScriptIsStrictBash` の判定関数で偽、`set -e` だけでも偽、`#!/bin/bash\nset -euo pipefail` で真 |

必須キーの parametrize の元（11 個）:
`CFBundleIdentifier`・`CFBundleName`・`CFBundleExecutable`・`CFBundlePackageType`・`CFBundleShortVersionString`・`CFBundleVersion`・
`LSMinimumSystemVersion`・`LSUIElement`・`NSRemovableVolumesUsageDescription`・`NSDocumentsFolderUsageDescription`・`NSDownloadsFolderUsageDescription`
（`NSDesktopFolderUsageDescription` は `usageDescriptionsAreVerbatim` が回数で見る）

- **判定は必ず関数に切り出す**（`isStrictBash(_:)` のように）。陽性対照が呼べる形にしておく（PLAN §9.4 の「検査が空振りする」形を避ける）
- 実際に `.app` を組み立てるテストは書かない（署名が要るのでランナーで再現できない）。**バンドルの中身の正しさは `verify-bundle.sh` が実機で見る**。ここは「スクリプトが PLAN の要求を書いてある」ことだけを見る

## 6. 破壊による証明

| # | 壊し方 | 落ちるべきテスト |
|---|---|---|
| 1 | `Resources/bundle-manifest.txt` から `Contents/Helpers/voicedock-reaper` を消す | `manifestListsTheThreeHelpers`（`makeAppInstallsEveryManifestEntry` は許可リストの行で parametrize するので、行を消すとその場合が無くなるだけで落ちない） |
| 2 | `Resources/bundle-manifest.txt` に `Contents/Resources/prompts/extra_ja.txt` を足す | `manifestListsEveryPromptFile` |
| 3 | `Resources/bundle-manifest.txt` の 2 行を入れ替える | `manifestIsSortedAndUnique` |
| 4 | `Resources/Info.plist.template` の `LSUIElement` を消す | `infoPlistTemplateHasEveryRequiredKey("LSUIElement")`、`infoPlistTemplateHasTheFixedValues` |
| 5 | `Resources/Info.plist.template` の `@BUNDLE_ID@` を実際の値に置き換える | `infoPlistTemplateUsesPlaceholders` |
| 6 | `NSRemovableVolumesUsageDescription` の文言の「音声」を「おんせい」にする | `usageDescriptionsAreVerbatim` |
| 7 | `Resources/VoiceDock.entitlements` に `com.apple.security.app-sandbox` を足す | `entitlementsAreEmpty("Resources/VoiceDock.entitlements")` |
| 8 | `scripts/sign.sh` の `--identifier "$BUNDLE_ID.reaper"` を消す | `signUsesTheReaperIdentifier` |
| 9 | `scripts/sign.sh` の `--options runtime` を 3 か所とも消す | `signNeverUsesAdhoc` |
| 10 | `scripts/verify-bundle.sh` の `spctl -a -t open --context context:primary-signature` の行を消す | `verifyBundleRunsEveryRequiredCheck("spctl -a -t open --context context:primary-signature")` |
| 11 | `scripts/verify-bundle.sh` の V-1（manifest の照合）を消す | `verifyBundleRunsEveryRequiredCheck("bundle-manifest.txt")` |
| 12 | `scripts/release.sh` の `make-dmg.sh` の行と `sign.sh" developerid` の行の順を入れ替える | `releaseRunsTheStepsInOrder` |
| 13 | `scripts/notarize.sh` の `--wait` を消す | `notarizeWaitsAndUsesTheProfile` |
| 14 | `scripts/make-dmg.sh` に `/Volumes/VoiceDock` の行を足す | `noScriptMentionsVolumes("scripts/make-dmg.sh")` |
| 15 | `scripts/make-app.sh` の 1 行目を `#!/bin/sh` にする | `everyScriptIsStrictBash("scripts/make-app.sh")` |
| 16 | `scripts/make-app.sh` の `source "$root/identity.env"` を消して値を直書きする | `scriptsThatNeedTheIdentitySourceIt`、`scriptsDoNotHardcodeTheIdentifiers` |
| 17 | `scripts/sign.sh` の証明書の絞り込みを `mapfile -t found < …` に戻す | `noScriptUsesBash4Features("scripts/sign.sh", "mapfile")` |
| 17a | `scripts/make-dmg.sh` を `hdiutil create -volname VoiceDock -srcfolder "$stage" -format UDZO "$dmg"` に戻す | `makeDmgNeverMounts` |
| 17b | `scripts/make-app.sh` の `"$app/Contents/MacOS/VoiceDock"` を `"$app/Contents/MacOS/VoiceDockApp"` にする | `makeAppInstallsEveryManifestEntry("Contents/MacOS/VoiceDock")` |

**手元で 1 回だけ行う破壊（出力を PR に貼る）**:

| # | 壊し方 | 期待 |
|---|---|---|
| 18 | `make app` の後に `touch dist/VoiceDock.app/Contents/Resources/extra.txt` → `scripts/verify-bundle.sh --files-only dist/VoiceDock.app` | V-1 が NG。`diff` に `extra.txt` が出て終了コード 1 |
| 19 | `make app` の後に `rm dist/VoiceDock.app/Contents/Helpers/voicedock-reaper` → 同上 | V-1 が NG。終了コード 1 |
| 20 | `codesign --force --sign - dist/VoiceDock.app` で ad-hoc に署名 → `scripts/verify-bundle.sh dist/VoiceDock.app` | V-6 の TeamIdentifier と Authority が NG |
| 21 | `mkdir dist/VoiceDock.app/Contents/Frameworks`（空）→ `scripts/verify-bundle.sh --files-only dist/VoiceDock.app` | V-1 のディレクトリの照合が NG。`diff` に `Contents/Frameworks`、終了コード 1 |
| 22 | `mv Resources/AppIcon.icns` で一時的に退避 → `scripts/make-app.sh debug` | `ERROR: Resources/AppIcon.icns がありません（作り方は T-34 §4.10）` で終了コード 1。`dist/VoiceDock.app` を作り始めない |
| 23 | `make-dmg.sh` の前後で `ls /Volumes` を取る | 前後で同じ（作成中にマウントしない） |

## 7. 受け入れ条件

- [ ] 6 本のスクリプトと 4 つの `Resources/` のファイルが在り、`make lint`（`swift format`）と `make test` が通る
- [ ] `make app` が通り、**出力全部**を PR に貼った（`swift build` から `OK: …/dist/VoiceDock.app（版 …、ビルド …、署名 development）` まで）
- [ ] `ls -lR dist/VoiceDock.app` と `codesign -dvvv dist/VoiceDock.app` と `codesign -dvvv dist/VoiceDock.app/Contents/Helpers/voicedock-reaper` の出力を PR に貼った
- [ ] `scripts/verify-bundle.sh --files-only dist/VoiceDock.app` が通り、出力を貼った
- [ ] 【利用者が行う】`xcrun notarytool store-credentials VOICEDOCK_NOTARY …` を 1 回実行し、`xcrun notarytool history --keychain-profile VOICEDOCK_NOTARY` が通ることを確かめた（**パスワードは貼らない**）
- [ ] 【利用者が行う】`make release` を 1 回通し、`verify-bundle.sh` の全項目が OK になった出力と `shasum -a 256` を PR に貼った（v1.0 のリリースそのものは T-44）
- [ ] 【利用者が行う】作った dmg を別のユーザアカウント（または新しい `~/Library/Application Support/VoiceDock` が無い状態）で開き、初回起動で Gatekeeper の警告が出ないことを確かめた
- [ ] 破壊による証明 1〜17 の落ちたテスト名と、18〜20 の出力が PR 本文にある
- [ ] `.gitignore` に `dist/` が在り、`git status` に `dist/` が出ない

## 8. SPEC の変更

なし（PLAN §11 は規範の表を持たないので `docs/SPEC.md` には写さない）。

## 9. マージ後にやること

- T-35 の E2E は `make app` で作った `.app` を使う（`/Applications` に置くのは T-44 のリリース後でよい）
- T-42 の削除 ON の E2E は、`make app`（Apple Development 署名）の `.app` でも `make release`（Developer ID 署名・公証）の `.app` でも行える。reaper の署名検証（PLAN §8.9.3）の要件文字列は `anchor apple generic` と識別子と Team ID（`certificate leaf[subject.OU]`）で束縛しており、証明書の種類は問わない（T-34 の実装時に、Apple Development 署名の reaper が `verify-bundle.sh` の V-7 で要件文字列を満たすことを確かめた）。ad-hoc 署名だけは満たさず `.disabled(reaper_invalid)` になる
- T-44 が `scripts/release.sh` をそのまま使って v1.0 を出す

## 10. API 地図への変更提案

1. （一部反映済み）§16 の「資源」の行に `Resources/bundle-manifest.txt`（T-34）は既に在る。残りの提案は「`AppPaths`（T-10）が組み立てる `Contents/Resources` と `Contents/Helpers` のパスは、この一覧の行と対応する」の一文を足すことだけ
2. §15（TestSupport の部品の作り手）に足すものは無い（`ReleaseBundleTests` は `PackageRoot` だけを使う）
3. （反映済み・利用者の決定 2026-09-22）`Resources/AppIcon.icns` の作り手を T-30 から T-34 に移し、仮アイコンを置いた。地図 §16 の「資源」の行も同じ PR で「T-34（仮アイコン。利用者の決定）」に直した
4. （反映済み）本体にも `--identifier <BUNDLE_ID>` を明示すること。PLAN §11.3 の 1 に既に書いてある
5. （反映済み）Info.plist の必須キーの `CFBundleIconFile`（= `AppIcon`）と `CFBundleDevelopmentRegion`（= `ja`）。PLAN §11.1 に既に書いてある
