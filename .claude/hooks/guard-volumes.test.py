"""guard-volumes.py の回帰テスト。実機には一切触れず、フックに JSON を流して判定だけを見る。

    python3 .claude/hooks/guard-volumes.test.py

フックを直したら必ず回す。0 件で終われば合格。
"""
import json, pathlib, subprocess, sys

HOOK = str(pathlib.Path(__file__).with_name("guard-volumes.py"))

DENY = [
    "diskutil unmount /Volumes/DJIMIC3",
    "diskutil mount readOnly /dev/disk4s1",
    "/usr/sbin/diskutil list",
    "rm -rf /Volumes/DJIMIC3/x",
    'rm "/Volumes/DJIMIC3/a.wav"',
    "mv /Volumes/DJIMIC3/a.wav /tmp/",
    "cp ~/x.wav /Volumes/DJIMIC3/",
    "echo hi > /Volumes/DJIMIC3/x",
    "cat note.md >> /Volumes/DJIMIC3/log",
    "dd if=/dev/zero of=/Volumes/DJIMIC3/x bs=1m",
    "find /Volumes -delete",
    "chmod -R 777 /Volumes/DJIMIC3",
    "hdiutil attach x.dmg",
    "hdiutil attach -mountpoint /Volumes/P x.dmg",
    "hdiutil detach /Volumes/PoCDJI",
    "sudo diskutil list",
    "timeout 30 rm -rf /Volumes/DJIMIC3",
    'python3 -c "import os; os.unlink(\'/Volumes/DJIMIC3/a\')"',
    "touch /Users/terada/Projects/voicedock/x",
    "git -C /Users/terada/Projects/voicedock commit -am wip",
    "rm -rf /Users/terada/Projects/voicedock/voicedock",
    "cd /tmp && rm -rf /Volumes/DJIMIC3/x",
    # F-94: 実機は VOICEDOCK に改名して使う（フックは名前を見ないが、改名後の場所でも止まることを確かめる）
    "diskutil unmount /Volumes/VOICEDOCK",
    "rm -rf /Volumes/VOICEDOCK/TX_MIC001_20260912_120950",
]
ASK = [
    "make test-disk",
    "VOICEDOCK_DISK_TESTS=1 swift test",
    "VOICEDOCK_REAL_TOOLS=1 make test",
    "hdiutil detach ~/VoiceDockPoC/mnt/PoCDJI",
]
PASS = [
    "ls -la /Volumes",
    "stat /Volumes/DJIMIC3/DJI_01.WAV",
    "mount",
    "df -h",
    "find /Volumes -name '*.WAV' -print",
    "cp /Volumes/DJIMIC3/a.wav ~/VoiceDockPoC/audio/",
    "make lint",
    "make test",
    "swift test --skip-build --filter PolicyTests",
    "python3 docs/porting-notes/check-tickets.py",
    "git -C /Users/terada/Projects/voicedock show d3d595e:voicedock/db.py",
    "git -C /Users/terada/Projects/voicedock archive d3d595e",
    "hdiutil attach -nobrowse -mountpoint ~/VoiceDockPoC/mnt/PoCDJI ~/VoiceDockPoC/img.dmg",
    'echo "rm -rf /Volumes は禁止" >> PR.md',
    'git commit -m "guard: rm /Volumes を止める"',
    "grep -rn volumesRoot Sources/",
    "rm -rf .build",
    "cd /Users/terada/Projects/voicedock_app && make lint",
    "cat > /tmp/note.md <<'EOF'\nrm -rf /Volumes/DJIMIC3 は絶対に行わない\ndiskutil unmount /Volumes/DJIMIC3 も同様\nEOF",
]

def decide(cmd):
    out = subprocess.run([HOOK], input=json.dumps(
        {"tool_name": "Bash", "tool_input": {"command": cmd}}),
        capture_output=True, text=True).stdout.strip()
    if not out:
        return "pass"
    return json.loads(out)["hookSpecificOutput"]["permissionDecision"]

fails = 0
for want, cases in (("deny", DENY), ("ask", ASK), ("pass", PASS)):
    print(f"\n### {want} であるべき ({len(cases)} 件)")
    for c in cases:
        got = decide(c)
        ok = got == want
        fails += not ok
        print(f"  {'ok  ' if ok else 'NG！'} {got:5} {c[:70]!r}")
print(f"\n=== 失敗 {fails} 件 / 全 {len(DENY)+len(ASK)+len(PASS)} 件 ===")
sys.exit(1 if fails else 0)
