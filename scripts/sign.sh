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
for tool in whisper-cli llama-server argmax-cli; do
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
