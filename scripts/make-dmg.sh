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
