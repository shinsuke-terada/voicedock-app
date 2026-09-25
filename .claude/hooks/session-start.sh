#!/bin/bash
# SessionStart: 危険と現在地を毎回セッションの先頭に置く。
# 標準出力の平文はそのまま Claude の文脈に足される（公式仕様）。exit 0 で終える。
set -uo pipefail
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

echo "## VoiceDock セッションの現在地"

# 1) 実機が挿さっているか（最優先）
# 実機は利用者が Finder で VOICEDOCK に改名して使う（F-94）。改名前の DJIMIC3 も実機として扱う
REAL="$(/sbin/mount 2>/dev/null | sed -nE 's#.* on (/Volumes/(VOICEDOCK|DJIMIC3)( [0-9]+)?) \(.*#\1#p' | paste -sd', ' -)"
if [ -n "${REAL:-}" ]; then
  echo "- ⚠️ **実機 DJI Mic 3 が ${REAL} にマウント中**。ディスク系の手順（hdiutil・make test-disk・イメージの実験）は行わない。行う前に利用者に物理的に抜いてもらう。"
else
  OTHER="$(/sbin/mount 2>/dev/null | sed -n 's#.* on \(/Volumes/[^(]*\) (.*#\1#p' | sed 's/ *$//' | paste -sd', ' -)"
  if [ -n "${OTHER:-}" ]; then
    echo "- /Volumes にマウント中: ${OTHER}（実機の VOICEDOCK・DJIMIC3 は無し）。それでも /Volumes 配下への書き込み・削除・再マウントはしない。"
  else
    echo "- /Volumes に外部ボリュームは無し。"
  fi
fi

# 2) git（T-01 より前は存在しない）
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "- ブランチ: $(git -C "$ROOT" branch --show-current 2>/dev/null)"
  git -C "$ROOT" log --oneline -3 2>/dev/null | sed 's/^/  - /'
  DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  [ "$DIRTY" != "0" ] && echo "  - 未コミットの変更 ${DIRTY} 件（破壊による証明の前に確認する）"
else
  echo "- git リポジトリはまだ無い（T-01 で \`git init -b main\` する）。"
fi

# 3) 次にやること
NEXT="$(sed -n '/^## 次にやること/,/^## /p' "$ROOT/docs/tickets/STATUS.md" 2>/dev/null \
        | grep -m2 -E '^[0-9]+\. ' | sed 's/^/  /')"
if [ -n "${NEXT:-}" ]; then
  echo "- 次にやること（docs/tickets/STATUS.md）:"
  echo "$NEXT"
fi

echo "- チケットを直したら \`python3 docs/porting-notes/check-tickets.py\` が 0 件であることを確かめる。"
exit 0
