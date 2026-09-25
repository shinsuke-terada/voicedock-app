#!/bin/bash
# 配布用の dmg を作る（PLAN §11.3 の 3）。作業用のイメージは dist/ の中にだけマウントする（既定のマウント先には何もマウントしない）。
# 開くと、背景（矢印と案内）の上に左にアプリ・右に Applications が並ぶウィンドウになる（F-99。表示設定は Finder を使わずに書く）。
# 使い方: scripts/make-dmg.sh <VoiceDock.app>
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[ "$#" -eq 1 ] || { echo "使い方: $0 <VoiceDock.app>" >&2; exit 2; }
app="$1"
[ -d "$app" ] || { echo "ERROR: $app がありません" >&2; exit 1; }

version="$(tr -d '[:space:]' < "$root/VERSION")"
dmg="$root/dist/VoiceDock-$version.dmg"
# ボリューム名に版を付ける。実機の名前 VOICEDOCK と大文字小文字だけ違う「VoiceDock」にすると、既定のマウント先の名前が
# ぶつかり（大文字小文字を区別しない）、後からつないだ実機が「VOICEDOCK 1」になって取り込まれない（F-99）
volname="VoiceDock $version"

# 表示設定を書く部品（ds_store・mac_alias）。dist/.dmg-venv に requirements.txt の版で入れ、版が変わったら入れ直す
venv="$root/dist/.dmg-venv"
requirements="$root/tools/dmg/requirements.txt"
if ! cmp -s "$requirements" "$venv/requirements.txt" 2>/dev/null; then
  rm -rf "$root/dist/.dmg-venv"
  mkdir -p "$root/dist"
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --disable-pip-version-check -r "$requirements"
  cp "$requirements" "$venv/requirements.txt"
fi
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
hdiutil create -size "${size_mb}m" -fs HFS+ -volname "$volname" -type UDIF -layout NONE "$rw"

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

# 3 の続き. ウィンドウの見た目（F-99）。背景は 1 倍と 2 倍を 1 つの TIFF にまとめ（Retina で粗くならない）、
# 表示設定（ウィンドウの大きさ・アイコンの大きさと位置・背景）を .DS_Store に書く
mkdir "$mnt/.background"
tiffutil -cathidpicheck "$root/Resources/dmg/background.png" "$root/Resources/dmg/background@2x.png" \
  -out "$mnt/.background/background.tiff"
"$venv/bin/python" "$root/tools/dmg/write-ds-store.py" "$mnt" VoiceDock.app .background/background.tiff

# 4. 外す
hdiutil detach "$dev" -quiet
dev=""

# 5. 圧縮して配布用にする
hdiutil convert "$rw" -format UDZO -o "$dmg"
echo "OK: $dmg"
