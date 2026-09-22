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
