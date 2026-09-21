#!/usr/bin/env python3
"""PreToolUse(Bash) のガード。実機（/Volumes）と参照実装ツリーへの破壊的な操作を止める。

公式仕様: permissionDecision を返すときは JSON を stdout に出して exit 0 で終わる。
exit 2（stderr でブロック）とは別の経路なので、両方を混ぜない。ask を返せるのはこちらだけ。

判定は「/Volumes という文字列があるか」ではなく「その区間の動詞が破壊的か」で行う。
`ls /Volumes` と `rm /Volumes/x` の違いはそこにしかない。

この層の限界は .claude/rules/safety.md に書いてある。変数展開・eval・スクリプトの起動・
テストバイナリは抜ける。滑りを止めるだけで、防壁ではない。
"""

import json
import os
import re
import shlex
import sys

VOLUMES = "/Volumes"
VOICEDOCK = "/Users/terada/Projects/voicedock"

# 直接 /Volumes 配下の引数を取ったら止める動詞
MUTATING = {
    "rm", "rmdir", "unlink", "truncate", "touch", "mkdir", "ln", "chmod", "chown",
    "mv", "rename",  # mv は移動元も変える。/Volumes 側がどちらの引数でも止める
    "chflags", "xattr", "tee", "umount", "mount", "fsck", "newfs", "SetFile", "plutil",
    "mkfs", "shred", "srm", "chgrp", "mtree",
}
# 最後の引数（コピー先）が /Volumes 配下なら止める動詞
COPY_LIKE = {"cp", "rsync", "ditto", "install", "scp"}
# 引数を丸ごと別のコマンドとして実行するラッパ（読み飛ばして中身を見る）
WRAPPERS = {"env", "time", "nice", "nohup", "timeout", "stdbuf", "command", "builtin",
            "noglob", "xargs", "setsid", "ionice", "flock", "script"}
INTERPRETERS = {"sh", "bash", "zsh", "dash", "ksh", "python", "python3", "perl",
                "ruby", "node", "osascript", "swift"}
GIT_READONLY = {"show", "log", "cat-file", "rev-parse", "rev-list", "ls-tree", "ls-files",
                "archive", "diff", "status", "grep", "describe", "for-each-ref", "blame",
                "shortlog", "tag", "branch", "remote", "config"}

HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
VOICEDOCK_RE = re.compile(re.escape(VOICEDOCK) + r"(?![A-Za-z0-9_-])")
REDIRECT_RE = re.compile(r">>?\s*['\"]?" + re.escape(VOLUMES))
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
DURATION = re.compile(r"^\d+[smhd]?$")


def emit(decision, reason):
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": decision,
            "permissionDecisionReason": reason,
        }
    }, ensure_ascii=False) + "\n")
    sys.exit(0)


def deny(reason):
    emit("deny", reason)


def ask(reason):
    emit("ask", reason)


def strip_heredocs(text):
    """ヒアドキュメントの本文を落とす。PR 本文に禁止例を書いただけで止まらないように。"""
    out, tag = [], None
    for line in text.splitlines():
        if tag is not None:
            if line.strip() == tag:
                tag = None
            continue
        out.append(line)
        m = HEREDOC.search(line)
        if m:
            tag = m.group(2)
    return "\n".join(out)


def segments(text):
    """引用の中を避けながら ; | & 改行 で区間に割る。"""
    segs, buf, quote = [], [], None
    i = 0
    while i < len(text):
        c = text[i]
        if quote:
            buf.append(c)
            if c == quote:
                quote = None
            elif c == "\\" and quote == '"' and i + 1 < len(text):
                i += 1
                buf.append(text[i])
        elif c in "'\"":
            quote = c
            buf.append(c)
        elif c in ";|&\n":
            segs.append("".join(buf))
            buf = []
        else:
            buf.append(c)
        i += 1
    segs.append("".join(buf))
    return [s.strip() for s in segs if s.strip()]


def unquoted(text):
    """引用の中身を伏せた見え方を返す。本物のリダイレクトだけを見分けるために使う。
    `echo "a > /Volumes/x"` はリダイレクトではないが `echo a > /Volumes/x` はリダイレクト。"""
    out, quote = [], None
    i = 0
    while i < len(text):
        c = text[i]
        if quote:
            if c == quote:
                quote = None
                out.append(c)
            elif c == "\\" and quote == '"' and i + 1 < len(text):
                i += 1
                out.append("_")
            else:
                out.append("_")
        elif c in "'\"":
            quote = c
            out.append(c)
        else:
            out.append(c)
        i += 1
    return "".join(out)


def tokenize(seg):
    try:
        return shlex.split(seg, comments=False)
    except ValueError:
        return seg.split()


def verb_and_args(tokens):
    """先頭の環境変数代入とラッパを読み飛ばし、実際の動詞と引数を返す。"""
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if ENV_ASSIGN.match(t):
            i += 1
            continue
        base = os.path.basename(t)
        if base in WRAPPERS:
            i += 1
            while i < len(tokens) and (tokens[i].startswith("-") or DURATION.match(tokens[i])):
                i += 1
            continue
        return base, tokens[i + 1:]
    return "", []


def touches_volumes(args):
    return any(VOLUMES in a for a in args)


def check_hdiutil(seg, args):
    sub = next((a for a in args if not a.startswith("-")), "")
    if sub in ("detach", "eject"):
        # 自分で attach したイメージの後始末は要るので、/Volumes を指すときだけ止めて、
        # それ以外は利用者に「実機が挿さっていないか」を確かめてもらう。
        if VOLUMES in seg:
            deny("/Volumes 配下を hdiutil detach / eject しないでください。実機を外す操作です。")
        ask("hdiutil detach / eject です。外そうとしているのが自分で attach した "
            "~/VoiceDockPoC/mnt/ 配下のイメージであること、実機ではないことを確かめてください。")
    if sub not in ("attach", "mount"):
        return
    mp = None
    for i, a in enumerate(args):
        if a.lower() == "-mountpoint" and i + 1 < len(args):
            mp = args[i + 1]
        elif a.lower().startswith("-mountpoint="):
            mp = a.split("=", 1)[1]
    if mp is None:
        deny("hdiutil attach には -mountpoint が必須です（既定では /Volumes に自動マウントされます）。"
             "~/VoiceDockPoC/mnt/<名前> を指定してください（P0-poc.md）。")
    if os.path.abspath(os.path.expanduser(mp)).startswith(VOLUMES + "/") or \
            os.path.expanduser(mp).rstrip("/") == VOLUMES:
        deny("マウント点を /Volumes 配下にはできません。~/VoiceDockPoC/mnt/<名前> を使ってください。")


def check_voicedock_tree(seg, verb, args):
    if not VOICEDOCK_RE.search(seg):
        return
    if verb == "git":
        sub = next((a for a in args if not a.startswith("-") and a != "-C"), "")
        # `git -C <path> show ...` の形では -C の次がパスなので読み飛ばす
        for i, a in enumerate(args):
            if a == "-C" and i + 2 < len(args) + 1:
                sub = next((x for x in args[i + 2:] if not x.startswith("-")), "")
                break
        if sub in GIT_READONLY:
            return
    deny("参照実装 /Users/terada/Projects/voicedock の作業ツリーは読み取り専用です。"
         "git -C /Users/terada/Projects/voicedock show d3d595e:<path> か archive d3d595e だけを使ってください。")


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    cmd = ((data.get("tool_input") or {}).get("command") or "")
    if not cmd.strip():
        sys.exit(0)

    cmd = strip_heredocs(cmd)
    pending_ask = None

    for seg in segments(cmd):
        tokens = tokenize(seg)
        if not tokens:
            continue
        if os.path.basename(tokens[0]) == "sudo":
            deny("sudo は使いません。必要なら手順を提示して利用者に依頼してください。")

        verb, args = verb_and_args(tokens)
        if not verb:
            continue

        if verb == "diskutil":
            deny("diskutil は実機のマウント状態を変える恐れがあるため、エージェントは実行しません。"
                 "手順を提示して【利用者が行う】として渡してください（P0-poc.md）。")

        if verb == "hdiutil":
            check_hdiutil(seg, args)

        check_voicedock_tree(seg, verb, args)

        # インタプリタのワンライナー（粗い検出。抜けることは safety.md に明記）
        if verb in INTERPRETERS and any(a in ("-c", "-e") for a in args):
            if VOLUMES in seg or "diskutil" in seg:
                deny("インタプリタ経由で /Volumes や diskutil に触れる書き方は読めないため禁止です。"
                     "何をしたいのかを手順に分けて書いてください。")

        if touches_volumes(args):
            vol_args = [a for a in args if VOLUMES in a]
            if verb in MUTATING:
                deny(f"/Volumes 配下への破壊的な操作は禁止です（{verb} {' '.join(vol_args)}）。"
                     "実機の録音は戻りません。ディスクイメージは ~/VoiceDockPoC/mnt/ に attach してください。")
            if verb in COPY_LIKE:
                positional = [a for a in args if not a.startswith("-")]
                if positional and VOLUMES in positional[-1]:
                    deny(f"/Volumes 配下を書き込み先にはできません（{verb} → {positional[-1]}）。")
            if verb == "dd":
                if any(a.startswith("of=") and VOLUMES in a for a in args):
                    deny("dd の of= を /Volumes 配下にはできません。")
            if verb == "find" and any(a in ("-delete", "-exec", "-execdir", "-ok") for a in args):
                deny("find の -delete / -exec を /Volumes 配下で使わないでください。読み取りだけなら -print を使ってください。")
            if verb == "sed" and any(a == "-i" or a.startswith("-i") for a in args):
                deny("sed -i を /Volumes 配下のファイルに使わないでください。")

        if REDIRECT_RE.search(unquoted(seg)):
            deny("/Volumes 配下へのリダイレクト（> / >>）は禁止です。")

        # 実機に触れうるテストは利用者の判断を仰ぐ
        if any(t.startswith(("VOICEDOCK_DISK_TESTS=", "VOICEDOCK_REAL_TOOLS=")) for t in tokens):
            pending_ask = ("ディスクイメージ／実ツールを使うテストの環境変数を設定しています。"
                           "実機が抜いてあることを確かめてから続けてください（safety.md 1・4）。")
        if verb == "make" and "test-disk" in args:
            pending_ask = ("make test-disk はディスクイメージを attach します。"
                           "実機が抜いてあることを確かめてから続けてください（safety.md 1・4）。")

    if pending_ask:
        ask(pending_ask)
    sys.exit(0)


if __name__ == "__main__":
    main()
