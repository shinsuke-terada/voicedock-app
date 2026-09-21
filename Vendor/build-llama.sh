#!/bin/bash
# llama.cpp の llama-server を versions.env の版からソースでビルドする（PLAN §11.2）。成果物は Vendor/build/bin/llama-server。
# HTTPS（モデルのダウンロード）を持たないビルドにする: LLAMA_OPENSSL=OFF、ビルド中の UI の取得もしない: LLAMA_USE_PREBUILT_UI=OFF。
# 使い方: Vendor/build-llama.sh [--update-fixtures]
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

work="$here/work/llama.cpp"
out="$here/build/bin"
rm -rf "$work"
mkdir -p "$here/work" "$out"

git clone --quiet --depth 1 --branch "$LLAMA_CPP_REF" "$LLAMA_CPP_REPO" "$work"
actual="$(git -C "$work" rev-parse HEAD)"
if [ "$actual" != "$LLAMA_CPP_SHA" ]; then
  echo "ERROR: llama.cpp $LLAMA_CPP_REF のコミットが違います（期待 ${LLAMA_CPP_SHA}、実際 ${actual}）" >&2
  exit 1
fi

cmake -S "$work" -B "$work/build" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build "$work/build" --config Release --target llama-server -j "$(sysctl -n hw.ncpu)"

install -m 0755 "$work/build/bin/llama-server" "$out/llama-server"
"$here/check-linkage.sh" "$out/llama-server"

help="$("$out/llama-server" --help 2>&1 || true)"
for flag in --model --host --port --api-key-file --ctx-size --n-gpu-layers --jinja --parallel --no-webui --offline; do
  grep -qE -- "(^|[[:space:],])${flag}([[:space:],=]|$)" <<<"$help" || { echo "ERROR: llama-server --help に $flag がありません" >&2; exit 1; }
done

if [ "$update_fixtures" -eq 1 ]; then
  mkdir -p "$root/Tests/Fixtures"
  # ビルド先の絶対パス（usage 行の $0）を落とし、どこでビルドしても同じ fixture にする
  printf '%s\n' "$help" | sed "s|$out/||g" > "$root/Tests/Fixtures/llama-server-help.txt"
  echo "更新: Tests/Fixtures/llama-server-help.txt"
fi
echo "OK: $out/llama-server ($LLAMA_CPP_REF $actual)"
