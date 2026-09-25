# P0 実機 PoC（P0-01〜P0-12）

| 項目 | 値 |
|---|---|
| ID | P0 |
| 題 | 実機 PoC（Phase 0） |
| Phase | 0 |
| 前提 | なし（T-01 より前に行う。P0-10 は行わない。CI を開発機のセルフホストランナーにしたため。T-02） |
| 見積もり | コードは使い捨て（リポジトリに入れない）。成果物は `docs/POC.md`（T-01 の最初のコミットに含める） |

## 安全の規則（最初に読む）

- **テスト・PoC の自動の手順は、`/Volumes` 配下の実機（DJI Mic 3 など、利用者が挿しているボリューム）に一切触れない。**`diskutil`・`hdiutil detach`・書き込み・削除・再マウントをしない。読み取りも、手順に書かれていなければしない
- **実機を使う手順（下の各節で「【利用者が行う】」と書いたもの）は、利用者が自分で明示的に行う。**エージェント（Claude など）は実行しない。実機を使う前に、その手順で消えてよいのは「この試験のために新しく録った録音」だけであることを利用者が確かめる
- ディスクイメージの実験は `~/VoiceDockPoC/` の下で行い、**`/Volumes` 以外のマウント点**（`~/VoiceDockPoC/mnt/<名前>`）に `-mountpoint` / `-mountPoint` を付けて attach・再マウントする。
  実機と名前が衝突しないよう、ボリューム名は `PoCDJI`（DJIMIC3 ではない）にする
- `/Volumes` に自動でマウントされる操作（`-mountPoint` を付けない `diskutil mount`、`-mountpoint` を付けない `hdiutil attach`）は、実機をすべて抜いた状態で【利用者が行う】ときだけ使う

## 目的

計画（PLAN）が前提にしている macOS・DJI Mic 3・whisper.cpp・llama.cpp の振る舞いを、**推測ではなく実測**で確かめる。
結果で PLAN とチケットを直し、Phase 0 で決めること（`BUNDLE_ID`・`TEAM_ID`・llama.cpp の版・Xcode の版・再マウントの `-mountPoint`）を確定する。

## 参照

- PLAN §12.2（P0 の表）、§14（RK-01〜06・RK-33）、§3.1、§8.1（再マウント）、§8.7（Vault の確認）、§8.11（DR-10・DR-11）、§11.1〜§11.2
- voicedock@d3d595e `docs/POC.md`（§0 記録の規約、§6 実機の実測、§10.0 TCC、§10.5 所要時間、§11 LLM）、`poc/mkimg.sh`

## 作るもの

| パス | 中身 | リポジトリに入れるか |
|---|---|---|
| `~/VoiceDockPoC/`（リポジトリの外） | 使い捨ての SwiftPM パッケージと台本（下記） | 入れない |
| `docs/POC.md` | 実測の記録（下記の書式） | **入れる**（T-01 の最初のコミット） |

`~/VoiceDockPoC/` の構成（使い捨て。名前はこのとおりにする）:

```text
~/VoiceDockPoC/
├── Package.swift                 # swift-tools-version: 6.2、macOS 15、3 つの実行ファイル
├── Sources/PoCMenuBar/main.swift # P0-01 / P0-02 / P0-03 / P0-08 / P0-11 / P0-12 用の最小アプリ
├── Sources/pocunlink/main.swift  # P0-03 の子プロセス（1 つのパスを unlink して結果を出す）
├── Sources/pocconvert/main.swift # P0-05 の変換（AVAudioConverter）
├── Info.plist                    # PoCMenuBar.app 用
├── make-poc-app.sh               # PoCMenuBar.app を組み立てて Apple Development で署名する
├── mkimg.sh                      # voicedock poc/mkimg.sh を写し、attach を `-mountpoint ~/VoiceDockPoC/mnt/PoCDJI` に直したもの（/Volumes に出さない。VDPOC_FS=MS-DOS FAT32、ボリューム名 PoCDJI）
└── logs/                         # 生の出力の置き場（POC.md へ貼る）
```

## 仕様

### 0. 記録の規約（`docs/POC.md` の先頭にこの節をそのまま置く）

```markdown
# VoiceDock for Mac Phase 0 PoC 測定記録

`docs/PLAN.md` が「こう設計する」を書き、**本ファイルは「実際にこう動いた」を書く。**
両者が食い違う場合は本ファイルの実測値を正とし、**PLAN とチケットを直す PR を出す。**

## 0. 記録の規約

- **測定日・コマンド・生の出力**をそのまま貼る。要約した数値だけを書かない
- 判定は `✅ PASS` / `✗ FAIL` / `⬜ 未実施` / `— 対象外` のどれかで始める（空欄・散文にしない）
- 判定の根拠が生の出力のどれなのかを示す
- 代替手段で測った場合は**その限界**を明記する
- 実機（DJI Mic 3）で消す録音は、**この試験のために新しく録った 1 本だけ**にする
```

続けて次の目次の表を置き、各行の判定欄を埋める:

```markdown
| 章 | P0 | 内容 | 反映先 | 判定 |
|---|---|---|---|---|
| 1 | — | ホスト環境 | PLAN §3.3 | ⬜ |
| 2 | P0-01 | マウント通知・TCC・列挙・システム設定の URL | PLAN §8.1 規則 5、§8.11 DR-11、T-13、T-32 | ⬜ |
| 3 | P0-02 | 読み取り専用での再マウント・パスの変化・`-mountPoint` | PLAN §8.1、T-15 | ⬜ |
| 4 | P0-03 | 子プロセスの unlink（ディスクイメージ・実機） | PLAN §8.9.3、RK-01、T-37 | ⬜ |
| 5 | P0-04 | whisper.cpp v1.9.4（Metal）の RTF と JSON の形 | PLAN §8.4、RK-03、T-03、T-17 | ⬜ |
| 6 | P0-05 | AVAudioConverter と ffmpeg の比較 | PLAN §8.3、RK-05、T-16 | ⬜ |
| 7 | P0-06 | llama-server（Metal）と json_object・起動時間・メモリ | PLAN §8.5、RK-04、T-03、T-21 | ⬜ |
| 8 | P0-07 | 1 日分（10 時間・約 220,000 文字）の Map-Reduce | PLAN §10.6、T-24 | ⬜ |
| 9 | P0-08 | SMAppService のログイン項目 | PLAN §8.12、RK-02、T-31 | ⬜ |
| 10 | P0-09 | 1 日分の処理見込み（文字数で外挿） | PLAN §12.2、E2E-06 | ⬜ |
| 11 | P0-10 | GitHub ランナーでのディスクイメージ | PLAN §10.8、RK-06、RK-33、T-02 | `— 対象外`（T-02 で理由を記入） |
| 12 | P0-11 | DADiskMountApprovalCallback（任意） | PLAN §8.1（v1 では採用しない） | ⬜ |
| 13 | P0-12 | Vault が書類フォルダ・iCloud Drive にあるときの TCC | PLAN §8.7、§8.11 DR-10、T-28、T-32 | ⬜ |
| 14 | — | Phase 0 で決めたこと | PLAN §3.1、§3.3、§8.1、`identity.env` | ⬜ |
```

### 1. ホスト環境（章 1）

実行して生の出力を貼る:

```bash
sw_vers
uname -m
sysctl -n machdep.cpu.brand_string hw.memsize hw.physicalcpu hw.logicalcpu
xcodebuild -version
swift --version
cmake --version
uv --version
security find-identity -v -p codesigning
```

`security find-identity` の出力から `Apple Development: …` と `Developer ID Application: … (<TEAM_ID>)` を確かめる。**TEAM_ID は括弧の中の 10 文字**。

### 2. PoCMenuBar（P0-01 / P0-02 / P0-03 / P0-08 / P0-11 / P0-12 で共用する最小アプリ）

`Sources/PoCMenuBar/main.swift` に次の機能だけを持つアプリを書く（UI は NSStatusItem のメニューだけ。使い捨てなので本番の規約（PT）は適用しない）:

| メニュー項目 | 動き |
|---|---|
| （起動時） | `NSWorkspace.shared.notificationCenter` の `didMountNotification` / `didUnmountNotification` を購読し、受けるたびに `<ISO8601 ミリ秒> mount <path>` を `~/VoiceDockPoC/logs/events.log` に追記。mount のたびに `opendir(path)` を試し、`opendir ok` か `opendir errno=<n> (<strerror>)` を追記 |
| 「列挙する」 | `/Volumes` の各エントリに `opendir` → `readdir` で直下の名前を最大 20 件ログに出す（errno も） |
| 「システム設定を開く」 | `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)` |
| 「ro 再マウント ×20」 | 選んだボリュームで P0-02 の手順を 20 回（下記）。**選べるのは `~/VoiceDockPoC/mnt/` 配下のマウント点だけ**（実機は【利用者が行う】節でだけ、利用者が明示的に選ぶ） |
| 「子に unlink させる」 | `pocunlink` を `posix_spawn`（`POSIX_SPAWN_SETPGROUP`）で起動し、選んだファイルを unlink させる（P0-03） |
| 「ログイン項目に登録」/「解除」 | `SMAppService.mainApp.register()` / `unregister()` と `status` をログに出す（P0-08） |
| 「Vault を試す」 | `NSOpenPanel` で選んだディレクトリに `opendir`・`access(W_OK)`・`<dir>/.poc-write-test.tmp` の作成と削除を行い、それぞれの結果と errno を出す（P0-12） |

`Info.plist`（`make-poc-app.sh` が `PoCMenuBar.app/Contents/Info.plist` に置く）:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.shinsuke-terada.VoiceDockPoC</string>
  <key>CFBundleName</key><string>PoCMenuBar</string>
  <key>CFBundleExecutable</key><string>PoCMenuBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSRemovableVolumesUsageDescription</key><string>録音デバイスから音声を読み込むために使います</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Obsidian の保管庫がこのフォルダにある場合に、ノートを書き込むために使います</string>
  <key>NSDesktopFolderUsageDescription</key><string>Obsidian の保管庫がこのフォルダにある場合に、ノートを書き込むために使います</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Obsidian の保管庫がこのフォルダにある場合に、ノートを書き込むために使います</string>
</dict>
</plist>
```

`make-poc-app.sh`（`swift build -c release` → `.app` の木を作る → `pocunlink` を `Contents/Helpers/` に置く → 内側から `codesign --force --options runtime --timestamp --sign "Apple Development: …"`）。
**ad-hoc 署名にしない**（ビルドのたびに TCC の許可が失効する。PLAN §11.1）。

### 3. P0-01 マウント通知・TCC・列挙（章 2）

【利用者が行う】（実機を挿し、表示とログを確かめるだけ。アプリは列挙の読み取りしかしない）

1. `PoCMenuBar.app` を起動する。`tccutil reset SystemPolicyRemovableVolumes io.github.shinsuke-terada.VoiceDockPoC` で許可を消しておく
2. DJI Mic 3 を挿す。挿した時刻を手で記録し、`events.log` の `mount` の時刻との差を「検出まで」とする（合格: 10 秒以内）
3. 許可のダイアログが出ることを確かめ、**「許可しない」**を選ぶ → `events.log` に `opendir errno=1 (Operation not permitted)` が出ることを確かめる（EPERM）
4. 同じ状態で `access("/Volumes/<名前>", R_OK)` が 0 を返すことも出す（PLAN §8.1 規則 5 の「`access(2)` は成功する」の実証）
5. 「システム設定を開く」で該当画面が開くか（開かない場合は開いた画面を記録）
6. システム設定で許可 → 抜き挿し → `opendir ok` と直下の名前が出る
7. `mount | grep -i <名前>` と `diskutil info /Volumes/<名前>` を貼る（FS 種別・Device Node・ボリューム名の確認）

判定: 検出 ≤ 10 秒、拒否時に errno 1、許可後に列挙できる → ✅。URL の可否は結果として記録（✅/✗ に含めない）。

### 4. P0-02 読み取り専用での再マウント（章 3）

ディスクイメージで先に行い、実機の部分は【利用者が行う】。ディスクイメージの作り方（`mkimg.sh`。**`/Volumes` の外に attach する**）:

```bash
mkdir -p ~/VoiceDockPoC/mnt/PoCDJI
hdiutil create -quiet -size 64m -fs "MS-DOS FAT32" -volname PoCDJI ~/VoiceDockPoC/img.dmg
hdiutil attach -nobrowse -mountpoint ~/VoiceDockPoC/mnt/PoCDJI ~/VoiceDockPoC/img.dmg
```

アプリの「ro 再マウント ×20」は、各回で次を行い、1 行ずつログに出す（子プロセスは `posix_spawn`、環境は `PATH=/usr/bin:/bin:/usr/sbin:/sbin`・`LC_ALL=C`）:

```text
statfs(path) → f_flags & MNT_RDONLY、f_mntfromname、f_mntonname を出す
既に ro なら "already_ro" を出して次へ（何もしない）
/usr/sbin/diskutil unmount <path>            → 終了コードと出力
/usr/sbin/diskutil mount readOnly -mountPoint <元のパス> <node>   → 終了コードと出力（ディスクイメージでは必ず -mountPoint を付け、/Volumes に出さない）
getmntinfo で f_mntfromname == node の項目を探し、その f_mntonname（新しいパス）を出す
statfs(新しいパス) → MNT_RDONLY を出す
（次の回のために）/usr/sbin/diskutil unmount <新しいパス> → /usr/sbin/diskutil mount -mountPoint <元のパス> <node>（rw に戻す）
```

- 合格: 20 回連続で ro を観測し、既に ro のときは diskutil を呼ばない
- `-mountPoint`: ディスクイメージで、`diskutil unmount` の後に元のディレクトリが残るか消えるかと、`diskutil mount readOnly -mountPoint <元のパス> <node>` がパスを保つか・失敗するかを 5 回ずつ記録する（元のディレクトリが消えていたら `mkdir -p` してからもう一度試し、その結果も書く）
- **パスの変化（`/Volumes` に出る場合）【利用者が行う】**: 実機を**すべて抜いた**状態で、ボリューム名 `PoCDJI` のイメージを 2 つ `-mountpoint` 無しで attach し（`/Volumes/PoCDJI` と `/Volumes/PoCDJI 1` になるかを見る）、`-mountPoint` 無しの `diskutil mount readOnly <node>` で再マウントしたときにパスが変わるかを記録する。終わったら両方を `hdiutil detach` する
- **実機での確認【利用者が行う】**: 実機を挿した状態で、アプリの「ro 再マウント ×20」を実機のボリュームで利用者が実行する（実機のファイルには触れない。マウントの状態だけが変わる）。20 回の結果と、`-mountPoint` を付けたときのパスを記録する
- DiskArbitration の拒否（EBUSY、`0xF8DA0008`）が起きた回数を数える（voicedock #107 では 34 回中 3 回）
- **判断**（章 14 に書く）: `-mountPoint` で常にパスが保たれるなら、T-15 の `DiskutilRemounter(useMountPoint: true)` を既定にする。そうでなければ `false`

### 5. P0-03 子プロセスの unlink（章 4）

`pocunlink`（`Sources/pocunlink/main.swift`）: 引数 1 つのパスを `unlink(2)` し、`ok` か `errno=<n>` を stdout に出して終わる。

1. ディスクイメージ（`~/VoiceDockPoC/mnt/PoCDJI`。`/Volumes` の外）上に `TX_MIC001_20260918_120000/TX00_MIC001_20260918_120000_orig.wav`（中身は `dd if=/dev/urandom bs=1m count=1`）を作る
2. アプリの「子に unlink させる」で消す → `ok`
3. **実機【利用者が行う】**: DJI Mic 3 で**この試験のために 5 秒ほど録音した 1 本**を使う（他の録音には触れない）。rw でマウントされた状態で、利用者がアプリの「子に unlink させる」でそのファイルを明示的に選んで消す → 結果
4. **【利用者が行う】** 別の試験用の 1 本を、ターミナルから `~/VoiceDockPoC/.build/release/pocunlink <path>` で直接消そうとした結果（TCC の差）を記録
5. 合格: アプリの子としてディスクイメージと実機の両方で消せる
6. **FAIL のとき**: RK-01 のとおり**推測で進めない**。PLAN §8.9.3 の方式（アプリの子として reaper を起動）が成り立たないので、XPC サービスなどの別計画を利用者と決めるまで Phase 8 に入らない

### 6. P0-04 whisper.cpp v1.9.4（Metal）（章 5）

1. T-03 の `Vendor/build-whisper.sh` と同じ手順（`versions.env` の REF と SHA を照合、cmake の引数も同じ）で `~/VoiceDockPoC/vendor/` にビルドする
2. `otool -L whisper-cli` を貼る（`/usr/lib/` と `/System/Library/` だけ）
3. 実音声 30 分（**密な発話**。ほぼ無音の素材で測らない。ASR-10）の BWF を用意し、ffmpeg で 16 kHz にしたもの（`ffmpeg -i in.wav -ar 16000 -ac 1 -c:a pcm_s16le in16k.wav`）で実行:

```bash
/usr/bin/time -l ./whisper-cli -m ggml-large-v3-turbo-q5_0.bin -f in16k.wav -l ja -t 8 \
  --vad --vad-model ggml-silero-v5.1.2.bin --vad-threshold 0.5 \
  --vad-min-speech-duration-ms 250 --vad-min-silence-duration-ms 1000 --vad-speech-pad-ms 200 \
  -oj -of out -np
```

4. 記録: 経過秒、RTF（経過秒 ÷ 1800）、最大 RSS、出力の文字数（`text` の Unicode スカラー数）、「文字 / 経過秒」
5. `out.json` の最上位のキー、`transcription[0]` のキー、`offsets` がミリ秒であることを貼る（`jq 'keys, (.transcription[0] | keys), .transcription[0].offsets' out.json`）
6. 比較: voicedock（CPU 版。voicedock の Docker の whisper-cli）の同じ音声の出力と、キーの集合が同じこと
7. **終了コードの確認**（RK-34）: 存在しない音声ファイル・不明な引数（`--no-such-flag`）で実行し、終了コードと JSON の有無を記録する

### 7. P0-05 AVAudioConverter と ffmpeg（章 6）

（入力の BWF は、実機から利用者が Finder で `~/VoiceDockPoC/audio/` にコピーしたものを使う。自動の手順は実機を読まない）

1. `pocconvert <in.wav> <out.wav>`: PLAN §8.3 の手順 4 のとおり（`AVAudioFile(forReading:)` → `AVAudioConverter` 16000 Hz / 1 ch / Float32、`sampleRateConverterQuality = .max` → Int16 へ `clamp(lrint(x × 32768))` → `AVAudioFile(forWriting:settings:commonFormat: .pcmFormatInt16, interleaved: true)`、settings に `AVAudioFileTypeKey = kAudioFileWAVEType`）
2. 入力は 3 種: 実機の 24 bit BWF、実機の 32 bit float BWF（DJI の設定を切り替えて録る。録音とコピーは【利用者が行う】）、voicedock の `tests/fixtures/make_wav.py` 相当で作った fmt 16 バイト・tag 3 の float WAV
3. 各入力で ffmpeg 版（`ffmpeg -i in.wav -ar 16000 -ac 1 -c:a pcm_s16le ff.wav`）も作り、`afinfo` で長さを比べる（合格: 差 ≤ 1.0 秒）
4. 両方の 16 kHz を P0-04 の whisper にかけ、`text` の差分（`diff <(jq -r .transcription[].text a.json) <(jq -r .transcription[].text b.json)`）を貼る。判定は「実用上同等」（語の欠落・幻覚の増加が無い）を人が判断し、理由を書く
5. （F-77・issue #117 で追加。任意）実機の WAV のチャンクの並びを記録する。PLAN §8.3 手順 6 の照合は、data の後ろに**チャンクでないバイト**（0 埋め・ID3v1 の `TAG` など）があると、正常な録音でも「入力のヘッダの長さと実データの量が合いません」で `NORMALIZE_VERIFY_FAILED` にする（消さない側だが、取り込みが止まる）。実機がそういうファイルを作らないことを確かめるための手順。
   対象（録音とコピーは【利用者が行う】。デバイスの上では読むだけ。写しは `~/VoiceDockPoC/audio/` に置く）: (a) 24 bit の設定で録った `_orig.wav`、(b) 32 bit float の設定で録った `_orig.wav`、(c) `_orig` でない方のファイル（あれば）、
   (d) 電池が切れるまで録り続ける・録音中に電源を切るなどで途中で止まった録音。
   各写しで、先頭から辿ったチャンクの id とサイズ、data の開始位置と宣言したサイズ、ファイルのサイズ（`xxd -l 64` と、`data` の位置の前後の `xxd -s <位置> -l 16`、`stat -f %z`）と `afinfo` の長さ（ヘッダの長さ）を貼り、
   `ファイルのサイズ − data の開始位置` が宣言したサイズと一致するか（data の後ろにチャンクや詰め物が無いか。あればその中身の先頭 16 バイト）を書く。
   (a)〜(c) で一致しなければ照合の規則を見直す（利用者に上げる）。(d) でヘッダが実データより短ければ、本アプリは手順 6 で `NORMALIZE_VERIFY_FAILED` にして消さない（期待どおり）

### 8. P0-06 llama-server（章 7）

1. T-03 の `Vendor/build-llama.sh` と同じ手順でビルドし、`otool -L` を貼る（libssl・libcurl を含まない）
2. `./llama-server --help` から `--model --host --port --api-key-file --ctx-size --n-gpu-layers --jinja --parallel --no-webui --offline` の行を貼る
3. API キーを `umask 077; openssl rand -hex 16 > key.txt` で作り、起動:

```bash
./llama-server --model Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf --host 127.0.0.1 --port 18080 \
  --api-key-file key.txt --ctx-size 32768 --n-gpu-layers 999 --jinja --parallel 1 --no-webui --offline
```

4. 起動時刻から `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/health` が 200 になるまでの秒数（1 秒ごと。読み込み中の 503 も記録）
5. `ps -o rss= -p <pid>` の常駐メモリ（KB）を、起動直後と 1 回の要求の後で記録
6. `curl -s http://127.0.0.1:18080/v1/chat/completions -H "Authorization: Bearer $(cat key.txt)" -H 'Content-Type: application/json' -d '{"model":"x","messages":[{"role":"system","content":"{\"ok\": true} と返してください。"},{"role":"user","content":"ping"}],"temperature":0.1,"top_p":0.9,"max_tokens":64,"response_format":{"type":"json_object"}}'` の応答を貼る（合格: `choices[0].message.content` が JSON）
7. API キー無しの要求が 401 になること、`/health` はキー無しで 200 になることを貼る

### 9. P0-07 1 日分の Map-Reduce（章 8）

voicedock の LLM のコードをそのまま使って測る（本アプリの実装はまだ無いため）:

1. `git -C /Users/terada/Projects/voicedock archive d3d595e | tar -x -C ~/VoiceDockPoC/vd` → `cd ~/VoiceDockPoC/vd && uv sync --frozen --python 3.12`
2. llama-server を **`--api-key-file` を付けずに**起動する（voicedock の HTTP クライアントは認証ヘッダを送らないため。この違いを記録に書く）
3. 約 220,000 文字（10 時間分）の transcript（実録音の P0-04 の出力を連結するか、T-24 で作る合成 fixture の長文）を `SessionTranscript` にし、`voicedock.llm.analyze_session` を `VOICEDOCK_LLM_URL=http://127.0.0.1:18080/v1`・`VOICEDOCK_LLM_MODEL=x` で呼ぶ台本 `~/VoiceDockPoC/p007.py` を書いて実行
4. 記録: 総時間、チャンク数、各 Map・Reduce の時間、修復の回数、最終結果が検証を通ったか
5. 合格: 30 分以内

### 10. P0-08 ログイン項目（章 9）

1. `PoCMenuBar.app` を `/Applications` に置いて起動し、「ログイン項目に登録」→ `status` を記録（`.enabled` か `.requiresApproval`）
2. `requiresApproval` なら `SMAppService.openSystemSettingsLoginItems()` で開き、許可
3. ログアウト → ログイン → `pgrep -fl PoCMenuBar` と `sfltool dumpbtm | grep -A5 VoiceDockPoC` を貼る
4. 合格: 再ログイン後に起動している

### 11. P0-09 1 日分の処理見込み（章 10）

- 入力: P0-04 の「文字 / 経過秒」、voicedock POC の実測「密な発話は 3.9〜4.6 文字/秒（音声 1 秒あたり）」、10 時間
- 見込みの文字数 = 10 × 3600 × 4.6 = 165,600 文字（上限側で見積もる）
- 見込みの文字起こし時間 = 見込みの文字数 ÷ （P0-04 の文字 / 経過秒）
- 見込みの解析時間 = P0-07 の総時間 × （見込みの文字数 ÷ P0-07 の文字数）
- 合格: 文字起こし + 解析 + コピー（1 日分 約 11 分）が 24 時間未満。計算式と数値を貼る

### 12. P0-10 GitHub ランナーでのディスクイメージ（章 11）

行わない（CI を開発機のセルフホストランナーにしたため。PLAN §10.8）。章 11 には T-02 が理由とランナーの確認結果を書く。

### 13. P0-11 DADiskMountApprovalCallback（任意。章 12）

- `DASessionCreate` → `DARegisterDiskMountApprovalCallback`（`kDADiskDescriptionVolumeNameKey` が `DJIMIC3` のときだけ `DADissenterCreate` で拒否 → `DADiskMountWithArguments` に `rdonly` を渡して読み取り専用でマウントし直す）を 30 分で試せる範囲で試す
- 可否と観測を記録する。**v1 では採用しない**（PLAN §12.2）

### 14. P0-12 Vault の TCC（章 13）

1. `~/Documents/PoCVault/.obsidian/` と、iCloud Drive の `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/PoCVault/.obsidian/`（Obsidian の iCloud 保管庫の場所）を作る
2. `tccutil reset SystemPolicyDocumentsFolder io.github.shinsuke-terada.VoiceDockPoC` の後、アプリの「Vault を試す」で各ディレクトリを選ぶ
3. 各場面（許可前・拒否・許可後）で `opendir` の errno、`access(W_OK)` の戻り値、書き込みの結果、出たダイアログを記録する
4. `NSOpenPanel` で選んだ場合に TCC を通るか（ユーザーの明示的な選択による例外）と、アプリの再起動後も通るかを分けて記録する
5. 結果で PLAN §8.7 の `.notReadable` の文言と DR-10 の案内文を直す（章 14 に「直す文面」を書く）

### 15. Phase 0 で決めたこと（章 14）

次の表を埋める。値はこの章が唯一の出所で、T-01 がリポジトリの `identity.env` に写す:

```markdown
| 名前 | 値 | 根拠 |
|---|---|---|
| BUNDLE_ID | io.github.shinsuke-terada.VoiceDock（候補。変えるならここで） | PLAN §3.1 |
| TEAM_ID | <security find-identity の括弧の中の 10 文字> | 章 1 |
| Xcode | 27.0（27A266a） | 章 1 |
| llama.cpp | b11033（8ed1a55efcd7424d2c592f6cbc9f97756db1d74d）か、P0-06 で問題があれば別の版 | 章 7 |
| whisper.cpp | v1.9.4（927cfce34f31707e17f2bff35c349632fb9e2c3a） | 章 5 |
| 再マウントの -mountPoint | 使う / 使わない | 章 3 |
| CI のランナー | T-02 で記入 | 章 11 |
```

- **FAIL があった項目**は、PLAN のどの節をどう直すかを箇条書きにし、PLAN とチケットを直す PR を T-01 より前に出す（P0-03 の FAIL は Phase 8 の計画を止める）

## テスト

なし（使い捨てのコード。自動テストは作らない）。

## 破壊による証明

なし。

## 受け入れ条件

- [ ] `docs/POC.md` の目次の判定欄が、P0-10 を除いて ⬜ 以外で埋まっている（P0-11 は `— 対象外` でもよい）
- [ ] 各章に測定日・コマンド・生の出力・判定・根拠がある
- [ ] 章 14 の表が埋まり、BUNDLE_ID と TEAM_ID が決まっている
- [ ] P0-03 が ✅（✗ なら Phase 8 の別計画を利用者と決めた記録がある）
- [ ] FAIL・想定外の結果について、PLAN・チケットを直す PR（またはその予定）が章ごとに書かれている
- [ ] 実機で消したのは試験用に録った録音だけで、実機を使う手順はすべて利用者が明示的に行った（消したファイル名を記録）
- [ ] 自動の手順が `/Volumes` 配下にマウント・書き込み・削除・再マウントをしていない（ディスクイメージのマウント点がすべて `~/VoiceDockPoC/mnt/` 配下）

## SPEC の変更

なし（`docs/SPEC.md` はまだ無い）。PLAN の本文を直す必要があれば、その PR で直す。

## マージ後にやること

- T-01 で `docs/POC.md` をコミットし、章 14 の値を `identity.env` に写す
- T-02 で章 11（P0-10 を行わない理由とランナーの確認結果）を記入する
