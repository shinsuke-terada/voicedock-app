#!/bin/bash
# 話者分離のモデルを versions.env のコミットから取り、speaker-models.sha256 と照合する（PLAN §3.3・§11.2。F-89）。
# 成果物は Vendor/build/SpeakerModels（20 ファイルと NOTICE.txt）。
# 使い方: Vendor/fetch-speaker-models.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=versions.env
source "$here/versions.env"

if [ "$#" -ne 0 ]; then
  echo "使い方: $0" >&2
  exit 2
fi

out="$here/build/SpeakerModels"
tmp="$here/work/SpeakerModels.tmp"
mkdir -p "$here/work" "$here/build"

# shasum -c は # の行を無視しないので、注釈と空行を除いた一覧で照合する
list="$here/work/speaker-models.sha256"
grep -v '^#' "$here/speaker-models.sha256" | grep -v '^$' > "$list"

if [ -d "$out" ] && (cd "$out" && shasum -a 256 -c "$list" > /dev/null 2>&1); then
  echo "OK: ${out}（取得済み）"
  exit 0
fi

rm -rf "$tmp"
mkdir -p "$tmp"
while read -r _ path; do
  mkdir -p "$(dirname "$tmp/$path")"
  curl -fsSL --retry 3 -o "$tmp/$path" "https://huggingface.co/$SPEAKER_MODELS_REPO/resolve/$SPEAKER_MODELS_SHA/$path"
done < "$list"

if ! (cd "$tmp" && shasum -a 256 -c "$list"); then
  echo "ERROR: 話者分離のモデルの sha256 が一致しません" >&2
  rm -rf "$tmp"
  exit 1
fi

install -m 0644 "$here/speaker-models-NOTICE.txt" "$tmp/NOTICE.txt"
rm -rf "$out" && mv "$tmp" "$out"
echo "OK: ${out}（20 ファイル）"
