#!/bin/bash
# whisper.cpp を versions.env の版からソースでビルドする（PLAN §11.2）。成果物は Vendor/build/bin/whisper-cli。
# 使い方: Vendor/build-whisper.sh [--update-fixtures]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/.." && pwd -P)"
# shellcheck source=versions.env
source "$here/versions.env"

update_fixtures=0
case "${1:-}" in
  "") ;;
  --update-fixtures) update_fixtures=1 ;;
  *) echo "使い方: $0 [--update-fixtures]" >&2; exit 2 ;;
esac

command -v cmake >/dev/null || { echo "ERROR: cmake がありません（brew install cmake）" >&2; exit 1; }

work="$here/work/whisper.cpp"
out="$here/build/bin"
rm -rf "$work"
mkdir -p "$here/work" "$out"

git clone --quiet --depth 1 --branch "$WHISPER_CPP_REF" "$WHISPER_CPP_REPO" "$work"
actual="$(git -C "$work" rev-parse HEAD)"
if [ "$actual" != "$WHISPER_CPP_SHA" ]; then
  echo "ERROR: whisper.cpp $WHISPER_CPP_REF のコミットが違います（期待 ${WHISPER_CPP_SHA}、実際 ${actual}）" >&2
  exit 1
fi

cmake -S "$work" -B "$work/build" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_EXAMPLES=ON \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build "$work/build" --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)"

install -m 0755 "$work/build/bin/whisper-cli" "$out/whisper-cli"
"$here/check-linkage.sh" "$out/whisper-cli"

help="$("$out/whisper-cli" --help 2>&1 || true)"
for flag in --vad --vad-model --vad-threshold --vad-min-speech-duration-ms --vad-min-silence-duration-ms --vad-speech-pad-ms; do
  grep -qE -- "(^|[[:space:],])${flag}([[:space:],=]|$)" <<<"$help" || { echo "ERROR: whisper-cli --help に $flag がありません" >&2; exit 1; }
done

if [ "$update_fixtures" -eq 1 ]; then
  mkdir -p "$root/Tests/Fixtures"
  printf '%s\n' "$help" > "$root/Tests/Fixtures/whisper-cli-help.txt"
  echo "更新: Tests/Fixtures/whisper-cli-help.txt"
fi
echo "OK: $out/whisper-cli ($WHISPER_CPP_REF $actual)"
