# 安全（このプロジェクトで絶対に守ること）

利用者の実機 DJI Mic 3 が `/Volumes/DJIMIC3` にマウントされていることがある。消えた録音は戻らない。

1. **ディスクを扱うセッションを始める前に、実機を物理的に抜いてもらう。** 抜け道の無い唯一の対策。
2. `/Volumes` 配下に `diskutil`・書き込み・削除・再マウントをしない。読み取り（`ls`・`stat`・`find -print`）だけ。
3. ディスクイメージは `hdiutil attach -nobrowse -mountpoint ~/VoiceDockPoC/mnt/<名前>` で **`/Volumes` の外**に attach する。ボリューム名に `DJIMIC3` を使わない。
4. `VOICEDOCK_DISK_TESTS` / `VOICEDOCK_REAL_TOOLS` / `VOICEDOCK_LLM_MODEL` を自分で設定しない。`make test-disk` を自分で回さない。実機が抜いてあることを利用者が確かめてから。
5. テストは注入された `volumesRoot`（`TempDirectory`）だけを見る。本番のコードパスに「テストなら」の分岐を作らない（CR-25）。
6. 参照実装 `/Users/terada/Projects/voicedock` は読み書きしない。`git -C /Users/terada/Projects/voicedock show d3d595e:<path>` と `… archive d3d595e` だけを使う。
7. 実機を使う手順は【利用者が行う】と書いて**そこで止まる**。自分で実行しない（P0・T-35・T-42）。
8. PR のマージは利用者が行う。`gh pr merge` を実行しない。GitHub への公開（`gh repo create`・push・release）は利用者の確認を得てから。
9. `sudo` を使わない。必要なら手順を提示して利用者に渡す。

## ガードフックの限界

`.claude/hooks/guard-volumes.py` はコマンドの文字列を見ているだけで、**防壁ではない**。次は素通りする。

- 変数展開・`eval`・コマンド置換（`rm "$T"` の `T=/Volumes/…`）
- スクリプトの起動（`./mkimg.sh`・`make` のレシピの中身）
- cwd が `/Volumes` の中にあるときの相対パス、`/Volumes` を指すシンボリックリンク
- インタプリタのワンライナーの凝った書き方、そして**コンパイル済みのテストバイナリ**

本当の防壁は **1（実機を抜く）** と **5（`volumesRoot` の注入）** の 2 つ。フックは滑りを止める最後の一歩でしかない。

フックを直したら `python3 .claude/hooks/guard-volumes.test.py` を回す（45 件。実機には触れない）。
