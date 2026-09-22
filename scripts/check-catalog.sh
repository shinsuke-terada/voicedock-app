#!/bin/bash
# ModelCatalog.json の値を Hugging Face API で確かめる（PLAN §8.10。T-24）。
# **アプリのコードではない。**開発者が手で走らせる（アプリがインターネットに出るのは PLAN §8.10 の場合だけ。PT-02）。
# 使い方:
#   scripts/check-catalog.sh                 # Resources/ModelCatalog.json の全項目
#   scripts/check-catalog.sh <repo> <file>   # 候補を 1 つだけ調べる（例 unsloth/Qwen3-4B-Instruct-2507-GGUF Qwen3-4B-Instruct-2507-Q4_K_M.gguf）
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
catalog="$root/Resources/ModelCatalog.json"

api() {
    # $1 = repo。lastModified の commit・license・各 blob の oid（= sha256）と size を出す
    curl -fsS "https://huggingface.co/api/models/$1?blobs=true"
}

if [ "$#" -eq 2 ]; then
    api "$1" | python3 -c '
import json, sys
m = json.load(sys.stdin)
print("repo    :", m.get("id"))
print("commit  :", m.get("sha"))
print("license :", (m.get("cardData") or {}).get("license"))
want = sys.argv[1]
for f in m.get("siblings", []):
    if f.get("rfilename") == want:
        lfs = f.get("lfs") or {}
        print("file    :", want)
        print("size    :", lfs.get("size", f.get("size")))
        print("sha256  :", lfs.get("oid"))
' "$2"
    exit 0
fi

python3 - "$catalog" <<'PY'
import json, subprocess, sys, urllib.parse
catalog = json.load(open(sys.argv[1]))
bad = 0
for kind in ("whisper", "vad", "llm"):
    for e in catalog[kind]:
        url = urllib.parse.urlparse(e["url"])
        parts = url.path.strip("/").split("/")          # <org>/<repo>/resolve/<sha>/<file>
        repo, commit, name = "/".join(parts[:2]), parts[3], "/".join(parts[4:])
        meta = json.loads(subprocess.run(
            ["curl", "-fsS", f"https://huggingface.co/api/models/{repo}?blobs=true"],
            capture_output=True, check=True, text=True).stdout)
        blob = next((f for f in meta.get("siblings", []) if f.get("rfilename") == name), None)
        lfs = (blob or {}).get("lfs") or {}
        got = {"sha256": lfs.get("oid"), "bytes": lfs.get("size"),
               "license": (meta.get("cardData") or {}).get("license"), "head": meta.get("sha")}
        for key in ("sha256", "bytes"):
            if str(got[key]) != str(e[key]):
                bad += 1
                print(f"MISMATCH {e['id']} {key}: catalog={e[key]} hf={got[key]}")
        print(f"{e['id']}\t{repo}\tpinned={commit}\thead={got['head']}\tbytes={got['bytes']}\t"
              f"sha256={got['sha256']}\tlicense={got['license']}")
print("NG" if bad else "OK")
sys.exit(1 if bad else 0)
PY
