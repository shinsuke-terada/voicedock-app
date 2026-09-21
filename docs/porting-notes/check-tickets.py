#!/usr/bin/env python3
# チケット一式の機械的な整合検査。読むだけで、何も書き換えない。
import re, sys, collections, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
TDIR = ROOT / 'docs/tickets'
# T-01 が計画書を docs/PLAN.md にコピーし、tmp/ は消さずに gitignore する。
# 以後の正は docs/PLAN.md なので、あればそちらを見る（古い tmp/ を見続けて緑のままにしない）。
PLAN = ROOT / 'docs/PLAN.md'
TMP_PLAN = ROOT / 'tmp/witty-gliding-clover.md'
SPEC = PLAN if PLAN.exists() else TMP_PLAN
MAP  = TDIR / '00-api-map.md'
README = TDIR / 'README.md'

tickets = sorted(p for p in TDIR.glob('*.md') if p.name not in ('00-api-map.md', 'README.md', 'STATUS.md'))
text = {p.name: p.read_text(encoding='utf-8') for p in tickets}
spec = SPEC.read_text(encoding='utf-8')
amap = MAP.read_text(encoding='utf-8')
readme = README.read_text(encoding='utf-8')
allt = '\n'.join(text.values())

def strip_code(s):
    out, incode = [], False
    for l in s.split('\n'):
        if l.strip().startswith('```'):
            incode = not incode; continue
        if not incode: out.append(l)
    return '\n'.join(out)

problems = collections.defaultdict(list)
def P(cat, msg): problems[cat].append(msg)

# 1. 表の列数（\| はエスケープなので除く）
def table_check(name, s):
    incode, block = False, []
    def flush(b):
        if len(b) < 2: return
        hdr = b[0][1]
        for ln, c in b[1:]:
            if c != hdr: P('表の列数', f'{name}:{ln} 列数 {c}（見出し {b[0][0]} 行目は {hdr}）')
    for i, l in enumerate(s.split('\n'), 1):
        if l.strip().startswith('```'):
            incode = not incode; flush(block); block = []; continue
        if incode: continue
        t = l.strip()
        if t.startswith('|') and t.endswith('|'):
            block.append((i, len(t.replace('\\|', '\x00').split('|')) - 2))
        else:
            flush(block); block = []
    flush(block)
for p in tickets: table_check(p.name, text[p.name])
table_check('00-api-map.md', amap)
table_check('README.md', readme)

# 2. 目次に載っているチケットとファイルの対応
linked = set(re.findall(r'\]\((T-\d\d[^)]*\.md|P0-poc\.md)\)', readme))
files = {p.name for p in tickets}
for f in sorted(files - linked): P('目次', f'目次に載っていないチケット: {f}')
for f in sorted(linked - files): P('目次', f'目次のリンク先が無い: {f}')

# 3. チケット間の参照（T-nn）が実在するか
ids = set()
for f in files:
    m = re.match(r'(T-\d\d|P0)', f)
    if m: ids.add(m.group(1))
for name, s in text.items():
    for ref in set(re.findall(r'\bT-(\d\d)\b', s)):
        if f'T-{ref}' not in ids: P('参照切れ', f'{name} が実在しない T-{ref} を参照')

# 4. 仕様の節番号 §x.y が仕様書に在るか
secs = set(re.findall(r'^#{2,4}\s+(\d+(?:\.\d+)*)[ .　]', spec, re.M))
secs |= set(re.findall(r'^#{2,4}\s+§?(\d+(?:\.\d+)*)', spec, re.M))
# PLAN / 仕様 の直後の § だけを仕様書への参照とみなす（「T-25 §4.12」「移植メモ V1 §6.5」は別物）
for name, s in list(text.items()) + [('00-api-map.md', amap), ('README.md', readme)]:
    for ref in sorted(set(re.findall(r'(?:PLAN|仕様(?:書)?)\s*§(\d+(?:\.\d+)+)', s))):
        if ref not in secs and not any(x.startswith(ref + '.') for x in secs):
            P('仕様の節', f'{name} → PLAN §{ref} が仕様書に見つからない')

# 5. 規範 ID がどこかで定義されているか（仕様書に在るか）
for pre in ('CV', 'ND', 'RV', 'DR', 'PT', 'CR', 'PR', 'X', 'F', 'RK', 'DEL', 'SN', 'E2E'):
    inspec = set(re.findall(rf'\b{pre}-(\d+[a-z]?)\b', spec))
    for name, s in text.items():
        for ref in sorted(set(re.findall(rf'\b{pre}-(\d+[a-z]?)\b', s))):
            if ref not in inspec and pre in ('CV', 'ND', 'RV', 'DR', 'PT', 'CR', 'PR') and name not in ('T-05-spec-sync.md', 'T-43-readme.md'):
                P('規範 ID', f'{name} → {pre}-{ref} が仕様書に無い')

# 6. ファイルの作り手が 1 つだけか（「作るもの」の Sources/Tests パス）
owner = collections.defaultdict(set)
for name, s in text.items():
    for path in re.findall(r'`((?:Sources|Tests|tools|scripts)/[A-Za-z0-9_\-./+]+\.(?:swift|py|sh|json|md|yml|yaml))`', s):
        owner[path].add(name)
sec_owner = collections.defaultdict(set)
for name, s in text.items():
    m = re.search(r'^##\s*4\.?\s*作るもの(.*?)^##\s', s, re.M | re.S)
    if m:
        for path in re.findall(r'`?((?:Sources|Tests|tools|scripts)/[A-Za-z0-9_\-./+]+\.(?:swift|py|sh|json|md|yml|yaml))`?', m.group(1)):
            sec_owner[path].add(name)
for path, names in sorted(sec_owner.items()):
    if len(names) > 1: P('作り手の重複', f'{path}: {sorted(names)}')

# 7. PT-11 由来: reaperConf という語のラベル
for name, s in list(text.items()) + [('00-api-map.md', amap)]:
    for m in re.finditer(r'\breaperConf\s*:', s):
        ln = s[:m.start()].count('\n') + 1
        line = s.split('\n')[ln - 1]
        # 「旧名 → 新名」を記録している行と、PT-11 の許可ファイル（HomeLayout / DeletionEnabler /
        # ReaperRunner / LockEvaluator / voicedock-reaper）の話をしている行は違反ではない
        if '→' in line or 'PT-11' in line or 'DeletionEnabler' in line or 'LockEvaluator' in line:
            continue
        P('PT-11 語', f'{name}:{ln} ラベル reaperConf:')

# 8. 消えた設定キー
for name, s in list(text.items()) + [('00-api-map.md', amap), ('README.md', readme)]:
    for key in ('summary.maxItems', 'timeline.maxItems'):
        for ln, line in enumerate(s.split('\n'), 1):
            if key not in line: continue
            # F-54 で「無くなった」ことを固定する記述・否定の期待値は違反ではない
            if any(w in line for w in ('F-54', '無く', '無い', 'CV-01', '除外', '!Golden', 'しない')):
                continue
            P('消したキー', f'{name}:{ln} に {key} が残っている')

# 9. API 地図に在る型名がチケットで使われているか（未使用＝書き忘れの手がかり）
map_types = set(re.findall(r'^\|\s*`([A-Z][A-Za-z0-9]+)`', amap, re.M))
for t in sorted(map_types):
    if not re.search(rf'\b{t}\b', allt): P('地図の未使用', f'{t} がどのチケットにも出てこない')

# 10. チケットの 10 節の形
want = ['目的', '参照', '作るもの', '仕様', 'テスト', '破壊による証明', '受け入れ条件', 'SPEC の変更', 'マージ後にやること']
DOC_TICKETS = {'T-35-e2e-off.md', 'T-42-e2e-on.md', 'T-43-readme.md', 'T-44-release-v1.md'}
for name, s in text.items():
    heads = re.findall(r'^##\s*(?:\d+\.?\s*)?(.+?)\s*$', s, re.M)
    for w in want:
        if w == '仕様' and name in DOC_TICKETS: continue
        if not any(w in h for h in heads): P('節の欠け', f'{name} に節「{w}」が無い')

# 11. 計画書の写しがずれていないか（T-01 の受け入れ条件を以後ずっと見張る）
if PLAN.exists() and TMP_PLAN.exists():
    if PLAN.read_bytes() != TMP_PLAN.read_bytes():
        P('計画書の写し', 'docs/PLAN.md と tmp/witty-gliding-clover.md が一致しない'
                      '（正は docs/PLAN.md。tmp/ を捨てるか写し直す）')

total = 0
for cat in sorted(problems):
    print(f'\n## {cat}（{len(problems[cat])} 件）')
    for m in problems[cat][:40]: print('  -', m)
    if len(problems[cat]) > 40: print(f'  … ほか {len(problems[cat])-40} 件')
    total += len(problems[cat])
print(f'\n合計 {total} 件 / チケット {len(tickets)} 本')
