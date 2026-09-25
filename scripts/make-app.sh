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
for tool in whisper-cli llama-server argmax-cli; do
  [ -x "$root/Vendor/build/bin/$tool" ] || { echo "ERROR: Vendor/build/bin/$tool がありません（make vendor を先に実行してください）" >&2; exit 1; }
done
[ -f "$root/Vendor/build/SpeakerModels/NOTICE.txt" ] || { echo "ERROR: Vendor/build/SpeakerModels がありません（make vendor を先に実行してください）" >&2; exit 1; }
[ -f "$root/Resources/AppIcon.icns" ] || { echo "ERROR: Resources/AppIcon.icns がありません（作り方は T-34 §4.10）" >&2; exit 1; }

# 3. 組み立て（毎回まっさらから作る）
app="$root/dist/VoiceDock.app"
rm -rf "$root/dist/VoiceDock.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources/prompts"

install -m 0755 "$bin/VoiceDockApp" "$app/Contents/MacOS/VoiceDock"
install -m 0755 "$bin/voicedock-reaper" "$app/Contents/Helpers/voicedock-reaper"
install -m 0755 "$root/Vendor/build/bin/whisper-cli" "$app/Contents/Helpers/whisper-cli"
install -m 0755 "$root/Vendor/build/bin/llama-server" "$app/Contents/Helpers/llama-server"
install -m 0755 "$root/Vendor/build/bin/argmax-cli" "$app/Contents/Helpers/argmax-cli"
install -m 0644 "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
install -m 0644 "$root/Resources/ModelCatalog.json" "$app/Contents/Resources/ModelCatalog.json"
# ライセンス（F-93）: 本体の LICENSE・NOTICE と、同梱物の著作権表示とライセンス文
install -m 0644 "$root/LICENSE" "$app/Contents/Resources/LICENSE"
install -m 0644 "$root/NOTICE" "$app/Contents/Resources/NOTICE"
install -m 0644 "$root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
for prompt in "$root"/Resources/prompts/*.txt; do
  install -m 0644 "$prompt" "$app/Contents/Resources/prompts/$(basename "$prompt")"
done
# 話者分離のモデル（ditto は拡張属性を落とさないので、続けて消す）
ditto "$root/Vendor/build/SpeakerModels" "$app/Contents/Resources/SpeakerModels"
xattr -cr "$app/Contents/Resources/SpeakerModels"

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
