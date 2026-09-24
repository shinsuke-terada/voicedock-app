#!/bin/bash
# argmax-oss-swift を versions.env の版からソースでビルドする（PLAN §11.2。F-89）。成果物は Vendor/build/bin/argmax-cli。
# 使い方: Vendor/build-argmax.sh [--update-fixtures]
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

work="$here/work/argmax-oss-swift"
out="$here/build/bin"
rm -rf "$work"
mkdir -p "$here/work" "$out"

git clone --quiet --depth 1 --branch "$ARGMAX_OSS_REF" "$ARGMAX_OSS_REPO" "$work"
actual="$(git -C "$work" rev-parse HEAD)"
if [ "$actual" != "$ARGMAX_OSS_SHA" ]; then
  echo "ERROR: argmax-oss-swift $ARGMAX_OSS_REF のコミットが違います（期待 ${ARGMAX_OSS_SHA}、実際 ${actual}）" >&2
  exit 1
fi

swift build --package-path "$work" -c release --product argmax-cli --arch arm64
built="$(swift build --package-path "$work" -c release --arch arm64 --show-bin-path)/argmax-cli"
if [ ! -f "$built" ]; then
  # P0-13 では --show-bin-path と違う .build/out/Products/Release/ に出た
  built="$(find "$work/.build" -name argmax-cli -type f -perm +111 | head -n 1 || true)"
  [ -n "$built" ] || { echo "ERROR: argmax-cli のビルド成果物が見つかりません" >&2; exit 1; }
fi
install -m 0755 "$built" "$out/argmax-cli"
"$here/check-linkage.sh" "$out/argmax-cli"

help="$("$out/argmax-cli" diarize --help 2>&1 || true)"
for flag in --audio-path --model-path --rttm-path --use-exclusive-reconciliation; do
  grep -qE -- "(^|[[:space:],[])${flag}([][:space:],=]|$)" <<<"$help" || { echo "ERROR: argmax-cli diarize --help に $flag がありません" >&2; exit 1; }
done

if [ "$update_fixtures" -eq 1 ]; then
  mkdir -p "$root/Tests/Fixtures"
  # ビルド先の絶対パスを落とし、どこでビルドしても同じ fixture にする
  printf '%s\n' "$help" | sed "s|$out/||g" > "$root/Tests/Fixtures/argmax-cli-diarize-help.txt"
  echo "更新: Tests/Fixtures/argmax-cli-diarize-help.txt"
fi
echo "OK: $out/argmax-cli ($ARGMAX_OSS_REF $actual)"
