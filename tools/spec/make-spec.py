#!/usr/bin/env python3
"""docs/PLAN.md の規範の表を docs/SPEC.md に写す（PLAN §10.3。T-05）。

使い方: python3 tools/spec/make-spec.py
PLAN の表を直したら、同じ PR でこれを実行して SPEC.md を作り直す（SpecMatchesPlanTests が食い違いを落とす）。
標準ライブラリだけを使う。
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PLAN = ROOT / "docs" / "PLAN.md"
SPEC = ROOT / "docs" / "SPEC.md"

FENCE = re.compile(r"^\s*```")
BOUNDARY = re.compile(r"^#{1,6} (?:[0-9A-Z]|付録)")
HEADING = re.compile(r"^#{1,6} (.*)$")

# (SPEC の見出し, PLAN の見出しの接頭辞, 写す範囲)
SECTIONS = [
    ("S1. 状態と復旧写像（PLAN 付録 A.1）", "A.1", "all"),
    ("S2. 遷移表（PLAN 付録 A.2）", "A.2", "all"),
    ("S3. エラーコード（PLAN 付録 A.3）", "A.3", "all"),
    ("S4. ログイベント（PLAN 付録 A.4）", "A.4", "all"),
    ("S5. 設定の検証 CV（PLAN §6.4）", "6.4", "all"),
    ("S6. 診断 DR（PLAN §8.11）", "8.11", "dr-table"),
    ("S7. 削除禁止テスト ND（PLAN 付録 B.1）", "B.1", "all"),
    ("S8. reaper の検証 RV（PLAN 付録 B.2）", "B.2", "all"),
    ("S9. 実機試験 E2E（PLAN 付録 B.3）", "B.3", "all"),
]

HEADER = """# VoiceDock 規範の表（docs/SPEC.md）

> この文書は `docs/PLAN.md` の規範の表の写しで、`tools/spec/make-spec.py` が作る。**手で直さない。**
> テスト（SPEC 同期）がこの文書を読み、実装の enum・定数・テストの表示名と突き合わせる。
> 表を変えるときは PLAN を直し、同じ PR で `python3 tools/spec/make-spec.py` を実行する（SpecMatchesPlanTests が食い違いを落とす）。
> 見出しの `S1.`〜`S9.` はテストが節を探す鍵なので変えない。
"""


def section(lines, key):
    in_fence = False
    start = None
    for index, line in enumerate(lines):
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if start is not None:
            if BOUNDARY.match(line):
                return lines[start:index]
        else:
            match = HEADING.match(line)
            if match and match.group(1).startswith(key):
                start = index + 1
    if start is None:
        sys.exit(f"PLAN に見出し {key} がありません")
    return lines[start:]


def trim(lines):
    body = list(lines)
    while body and (body[-1].strip() == "" or body[-1].strip() == "---"):
        body.pop()
    while body and body[0].strip() == "":
        body.pop(0)
    return body


def dr_table(lines):
    for index, line in enumerate(lines):
        if line.startswith("| ID | 順 |"):
            end = index
            while end < len(lines) and lines[end].startswith("|"):
                end += 1
            return lines[index:end]
    sys.exit("PLAN §8.11 に DR の表がありません")


def main():
    plan = PLAN.read_text(encoding="utf-8").split("\n")
    out = HEADER.rstrip("\n").split("\n")
    for title, key, mode in SECTIONS:
        body = section(plan, key)
        body = dr_table(body) if mode == "dr-table" else trim(body)
        out += ["", f"## {title}", ""] + body
    SPEC.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"書きました: {SPEC.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
