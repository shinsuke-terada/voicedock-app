#!/bin/bash
# 配布用の dmg を作る（PLAN §11.3 の 3）。
# 使い方: scripts/make-dmg.sh <VoiceDock.app>
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ "$#" -eq 1 ] || { echo "使い方: $0 <VoiceDock.app>" >&2; exit 2; }
app="$1"
[ -d "$app" ] || { echo "ERROR: $app がありません" >&2; exit 1; }

version="$(tr -d '[:space:]' < "$root/VERSION")"
dmg="$root/dist/VoiceDock-$version.dmg"
rm -f "$dmg"

stage="$(mktemp -d "$root/dist/.dmg-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/VoiceDock.app"
ln -s /Applications "$stage/Applications"

hdiutil create -volname VoiceDock -srcfolder "$stage" -format UDZO -fs HFS+ -ov "$dmg"
echo "OK: $dmg"
