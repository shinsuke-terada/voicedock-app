#!/bin/bash
# リリースの必須ゲート（PLAN §11.3 の 4）。バンドルの中身・署名・公証・リンクを検査する。
# 使い方: scripts/verify-bundle.sh [--files-only] <VoiceDock.app> [<VoiceDock-<ver>.dmg>]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

files_only=0
if [ "${1:-}" = "--files-only" ]; then files_only=1; shift; fi
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "使い方: $0 [--files-only] <VoiceDock.app> [<VoiceDock-<ver>.dmg>]" >&2
  exit 2
fi
app="$1"
dmg="${2:-}"
[ -d "$app" ] || { echo "ERROR: $app がありません" >&2; exit 1; }

# shellcheck source=../identity.env
source "$root/identity.env"
: "${BUNDLE_ID:?identity.env に BUNDLE_ID がありません}"
: "${TEAM_ID:?identity.env に TEAM_ID がありません}"
version="$(tr -d '[:space:]' < "$root/VERSION")"

status=0
ok()   { echo "  OK   $1"; }
ng()   { echo "  NG   $1" >&2; status=1; }
step() { echo "== $1"; }

# V-1 中身の一覧が Resources/bundle-manifest.txt と完全一致（ディレクトリは一覧の各行の親から導き、空のディレクトリも見つける）
step "V-1 バンドルの中身"
expected="$(grep -v -e '^#' -e '^$' "$root/Resources/bundle-manifest.txt" | LC_ALL=C sort)"
# stapler は公証チケットを Contents/CodeResources に置く。staple の後の検査（--files-only でない）だけ、その 1 件を許す
if [ "$files_only" -eq 0 ]; then
  expected="$(printf '%s\nContents/CodeResources\n' "$expected" | LC_ALL=C sort)"
fi
actual="$(cd "$app" && find . -type f -o -type l | sed 's|^\./||' | LC_ALL=C sort)"
if [ "$expected" = "$actual" ]; then
  ok "$(wc -l <<<"$expected" | tr -d ' ') 件が一致"
else
  ng "一覧が一致しません"
  diff <(echo "$expected") <(echo "$actual") >&2 || true
fi
expected_dirs="$(awk -F/ '{ p = ""; for (i = 1; i < NF; i++) { p = (i == 1) ? $i : p "/" $i; print p } }' <<<"$expected" | LC_ALL=C sort -u)"
actual_dirs="$(cd "$app" && find . -mindepth 1 -type d | sed 's|^\./||' | LC_ALL=C sort)"
if [ "$expected_dirs" = "$actual_dirs" ]; then
  ok "ディレクトリ $(wc -l <<<"$expected_dirs" | tr -d ' ') 個が一致"
else
  ng "ディレクトリが一致しません（空のディレクトリか、一覧に無い場所があります）"
  diff <(echo "$expected_dirs") <(echo "$actual_dirs") >&2 || true
fi

# V-2 Info.plist の必須キー
step "V-2 Info.plist"
plist="$app/Contents/Info.plist"
plutil -lint "$plist" > /dev/null && ok "plist として読める" || ng "plist が壊れています"
check_key() {
  local key="$1" want="$2" got
  got="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null || echo "<無し>")"
  [ "$got" = "$want" ] && ok "$key = $got" || ng "$key が $want でない（${got}）"
}
check_key CFBundleIdentifier "$BUNDLE_ID"
check_key CFBundleName VoiceDock
check_key CFBundleExecutable VoiceDock
check_key CFBundlePackageType APPL
check_key CFBundleShortVersionString "$version"
check_key LSMinimumSystemVersion 15.0
check_key LSUIElement true
for key in NSRemovableVolumesUsageDescription NSDocumentsFolderUsageDescription \
           NSDesktopFolderUsageDescription NSDownloadsFolderUsageDescription; do
  plutil -extract "$key" raw -o - "$plist" > /dev/null 2>&1 && ok "$key が在る" || ng "$key が無い"
done

# V-3 すべての Mach-O が arm64 単体
step "V-3 アーキテクチャ"
machos=("$app/Contents/MacOS/VoiceDock" "$app/Contents/Helpers/voicedock-reaper"
        "$app/Contents/Helpers/whisper-cli" "$app/Contents/Helpers/llama-server")
for bin in "${machos[@]}"; do
  arch="$(lipo -archs "$bin" 2>/dev/null || echo "<読めない>")"
  [ "$arch" = "arm64" ] && ok "$(basename "$bin") = arm64" || ng "$(basename "$bin") が arm64 単体でない（${arch}）"
done

# V-4 リンク（PLAN §11.2）
step "V-4 otool -L"
"$root/Vendor/check-linkage.sh" "${machos[@]}" && ok "リンク先は /usr/lib と /System/Library だけ" || ng "リンクに問題があります"

if [ "$files_only" -eq 1 ]; then
  [ "$status" -eq 0 ] && echo "OK: --files-only の検査に通りました" || echo "ERROR: --files-only の検査に失敗しました" >&2
  exit "$status"
fi

# V-5 署名
step "V-5 codesign"
codesign --verify --deep --strict --verbose=2 "$app" && ok "署名が有効" || ng "署名が無効"

# V-6 本体の識別子・Team ID・Hardened Runtime
step "V-6 本体の署名の中身"
info="$(codesign -dvvv "$app" 2>&1 || true)"
grep -qxF "Identifier=$BUNDLE_ID" <<<"$info" && ok "Identifier=$BUNDLE_ID" || ng "Identifier が $BUNDLE_ID でない"
grep -qxF "TeamIdentifier=$TEAM_ID" <<<"$info" && ok "TeamIdentifier=$TEAM_ID" || ng "TeamIdentifier が $TEAM_ID でない"
grep -qE '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime.*\)' <<<"$info" && ok "Hardened Runtime" || ng "Hardened Runtime でない"
grep -q 'Authority=Developer ID Application' <<<"$info" && ok "Developer ID Application で署名" || ng "Developer ID Application でない"

# V-7 reaper の識別子（PLAN §3.1・§8.9.3）
step "V-7 reaper の署名"
rinfo="$(codesign -dvvv "$app/Contents/Helpers/voicedock-reaper" 2>&1 || true)"
grep -qxF "Identifier=$BUNDLE_ID.reaper" <<<"$rinfo" && ok "Identifier=$BUNDLE_ID.reaper" || ng "reaper の Identifier が違う"
grep -qxF "TeamIdentifier=$TEAM_ID" <<<"$rinfo" && ok "TeamIdentifier=$TEAM_ID" || ng "reaper の TeamIdentifier が違う"
codesign --verify -R "=anchor apple generic and identifier \"$BUNDLE_ID.reaper\" and certificate leaf[subject.OU] = \"$TEAM_ID\"" \
  "$app/Contents/Helpers/voicedock-reaper" && ok "アプリが使う要件文字列を満たす" || ng "要件文字列を満たさない"

# V-8 エンタイトルメント（サンドボックス無し・例外無し）。本体と reaper の両方が空の dict であること
step "V-8 エンタイトルメント"
check_entitlements() {
  local target="$1" name="$2" raw ents
  if ! raw="$(codesign -d --entitlements - --xml "$target" 2>/dev/null)"; then
    ng "${name} のエンタイトルメントを読めません"
    return
  fi
  ents="$(plutil -convert json -o - - <<<"$raw" 2>/dev/null || echo "<読めない>")"
  [ "$ents" = "{}" ] && ok "${name} のエンタイトルメントは空の dict" || ng "${name} のエンタイトルメントが空の dict でない（${ents}）"
}
check_entitlements "$app" "本体"
check_entitlements "$app/Contents/Helpers/voicedock-reaper" "reaper"

# V-9 公証（Gatekeeper の判定）
step "V-9 spctl と staple"
spctl -a -t exec -vv "$app" 2>&1 | grep -q 'source=Notarized Developer ID' && ok "spctl: Notarized Developer ID" || ng "spctl が通らない"
xcrun stapler validate "$app" && ok "stapler validate（app）" || ng "staple されていない（app）"

# V-10 dmg
if [ -n "$dmg" ]; then
  step "V-10 dmg"
  [ -f "$dmg" ] || ng "$dmg がありません"
  spctl -a -t open --context context:primary-signature -v "$dmg" 2>&1 | grep -q 'accepted' && ok "spctl（dmg）" || ng "spctl が通らない（dmg）"
  xcrun stapler validate "$dmg" && ok "stapler validate（dmg）" || ng "staple されていない（dmg）"
  [ "$(basename "$dmg")" = "VoiceDock-$version.dmg" ] && ok "dmg の名前が版と一致" || ng "dmg の名前が VoiceDock-$version.dmg でない"
fi

if [ "$status" -eq 0 ]; then
  echo "OK: verify-bundle のすべての検査に通りました（版 ${version}）"
else
  echo "ERROR: verify-bundle に失敗しました" >&2
fi
exit "$status"
