#!/bin/bash
# golden を voicedock@d3d595e から作り直す（PLAN §10.4、T-25）。
# voicedock の作業ツリーには触らない: git archive で一時ディレクトリへ展開し、その中でホストの uv を使う。
# 使い方: tools/golden/generate.sh   （環境変数 VOICEDOCK_REPO で voicedock の clone の場所を変えられる）
set -euo pipefail

VOICEDOCK_REPO="${VOICEDOCK_REPO:-/Users/terada/Projects/voicedock}"
VOICEDOCK_REF="d3d595e"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GOLDEN="$REPO_ROOT/Tests/Golden"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv が見つかりません（https://docs.astral.sh/uv/ を入れてください）" >&2
  exit 1
fi
if ! git -C "$VOICEDOCK_REPO" cat-file -e "${VOICEDOCK_REF}^{commit}" 2>/dev/null; then
  echo "voicedock の clone に ${VOICEDOCK_REF} がありません: $VOICEDOCK_REPO" >&2
  exit 1
fi
COMMIT="$(git -C "$VOICEDOCK_REPO" rev-parse "${VOICEDOCK_REF}^{commit}")"
UV_VERSION="$(uv --version)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/voicedock-golden.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

git -C "$VOICEDOCK_REPO" archive --format=tar "$VOICEDOCK_REF" | tar -x -C "$WORK"
(cd "$WORK" && uv sync --frozen --python 3.12 --quiet)

(cd "$WORK" && uv run --frozen --python 3.12 python "$REPO_ROOT/tools/golden/make_inputs.py" "$GOLDEN")
rm -rf "$GOLDEN/expected"
mkdir -p "$GOLDEN/expected"
(cd "$WORK" && uv run --frozen --python 3.12 python "$REPO_ROOT/tools/golden/generate.py" \
  --voicedock-root "$WORK" --golden "$GOLDEN" --ref "$VOICEDOCK_REF" --commit "$COMMIT" \
  --uv-version "$UV_VERSION")
echo "golden を作り直しました: $GOLDEN"
