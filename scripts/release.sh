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
