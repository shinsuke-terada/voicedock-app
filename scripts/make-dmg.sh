#!/bin/bash
# 配布用の dmg を作る（PLAN §11.3 の 3）。作業用のイメージは dist/ の中にだけマウントする（既定のマウント先には何もマウントしない）。
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
rw="$stage/VoiceDock-rw.dmg"
mnt="$stage/mnt"
mkdir "$mnt"
mnt_real="$(cd "$mnt" && pwd -P)"
dev=""

# 途中で失敗しても、マウントを残さず一時ファイルを消す
cleanup() {
  if [ -n "$dev" ]; then
    hdiutil detach "$dev" -quiet || hdiutil detach "$dev" -force -quiet || true
  fi
  rm -rf "$stage"
}
trap cleanup EXIT

# 1. 空の HFS+ イメージ（.app の大きさに 2 割と 16 MB の余裕を足す）。フォルダから直に作る方式は使わない（F-62）
app_kb="$(du -sk "$app" | awk '{ print $1 }')"
size_mb=$((app_kb * 12 / 10 / 1024 + 16))
hdiutil create -size "${size_mb}m" -fs HFS+ -volname VoiceDock -type UDIF -layout NONE "$rw"

# 2. dist/ の中にだけマウントする。attach の出力でマウント先が指定どおりであることを確かめる
out="$(hdiutil attach -nobrowse -noautoopen -noverify -mountpoint "$mnt" "$rw")"
dev="$(awk 'NR == 1 { print $1 }' <<<"$out")"
got="$(awk -F'\t' 'NF >= 3 { m = $NF; sub(/^[ ]+/, "", m); sub(/[ ]+$/, "", m); if (m != "") print m }' <<<"$out" | head -n 1)"
if [ "$got" != "$mnt_real" ]; then
  echo "ERROR: 作業用のイメージが指定と違う場所にマウントされました（${got:-<不明>}）。すぐに外します" >&2
  exit 1
fi
echo "OK: 作業用のイメージを ${mnt_real} にマウントしました（${dev}）"

# 3. 中身。ditto は署名と拡張属性を保つ
ditto "$app" "$mnt/VoiceDock.app"
ln -s /Applications "$mnt/Applications"

# 4. 外す
hdiutil detach "$dev" -quiet
dev=""

# 5. 圧縮して配布用にする
hdiutil convert "$rw" -format UDZO -o "$dmg"
echo "OK: $dmg"
