# V1 移植メモ: VDContract・デバイス取り込み・reaper（voicedock d3d595e）

すべて `git -C /Users/terada/Projects/voicedock show d3d595e:<path>` から読んだ事実。行番号は d3d595e のもの。
「→ Swift」は本アプリでの推奨実装（仕様修正案と一致させてある）。

---

## 1. 名前規則（`src/voicedock/device.py`）

### 1.1 正規表現（device.py:36-45、SPEC §5.2 の写し）

```python
RECORDING_FILENAME_RE = re.compile(
    r"^(?P<tx>TX\d{2})"
    r"_(?P<mic>MIC\d{3})"
    r"_(?P<date>\d{8})"
    r"_(?P<time>\d{6})"
    r"(?P<orig>_orig)?"
    r"\.(?P<ext>wav|WAV)$"
)
RECORDING_FOLDER_RE = re.compile(r"^TX_(?P<mic>MIC\d{3})_(?P<date>\d{8})_(?P<time>\d{6})$")
```

- Python の `\d` は Unicode の数字（全角・アラビア数字など）にも一致する。Python の `$` は末尾の `\n` の直前にも一致する。
  reaper（bash）は `[0-9]` の case glob（voicedock-reaper:102-118、voicedock-ingest:230-245）で ASCII のみ。**voicedock 内で既に 2 系統が食い違っている。**
- → Swift: `NSRegularExpression` の文字列定数は `\d` ではなく `[0-9]` を使い、`^…$` の代わりに「一致範囲が文字列全体（`NSRange(location:0,length:utf16.count)`）と等しい」ことを確かめる（`$` の末尾改行一致を避ける）。
  ```swift
  static let filePattern   = "^(TX[0-9]{2})_(MIC[0-9]{3})_([0-9]{8})_([0-9]{6})(_orig)?\\.(wav|WAV)$"
  static let folderPattern = "^TX_(MIC[0-9]{3})_([0-9]{8})_([0-9]{6})$"
  ```

### 1.2 `parse_filename`（device.py:68-92）

1. `RECORDING_FILENAME_RE.match(name)`、不一致 → `None`
2. `datetime.strptime(date+time, "%Y%m%d%H%M%S")`、`ValueError` → `None`（例外にしない）
3. `transmitter_id = "TX01"`（文字列そのまま）、`mic_index = int("MIC002".removeprefix("MIC")) = 2`、
   `started_at = naive.replace(tzinfo=tz)`（**付与のみ・変換しない**）、`variant = "orig" if _orig else "denoised"`
- → Swift: 日時の妥当性は Calendar に任せず整数範囲で判定して決定的にする:
  year 1...9999、month 1...12、day 1...(その月の日数。グレゴリオ暦の閏年規則)、hour 0...23、minute 0...59、second 0...59。
  （Python の `%S` は 60/61 を受けるが `datetime` の構築で落ちるので 0...59 と同じ）

テスト固定例（tests/unit/test_device_parse.py）:
| 入力 | 期待 |
|---|---|
| `TX01_MIC002_20260829_071204.wav` | tx=TX01, mic=2, denoised |
| `TX01_MIC002_20260829_071204_orig.wav` | TX01, 2, orig |
| `TX01_MIC002_20260829_071204.WAV` / `_orig.WAV` | 同上（拡張子大文字可） |
| `TX00_MIC000_…_orig.wav` / `TX99_MIC999_…_orig.wav` / `TX00_MIC001_20260912_120950_orig.wav` | 境界値・実機名 |
| `TX1_…`, `TX001_…`, `MIC02`, `MIC0002`, date 7 桁, time 5 桁, `.mp3`, `_ORIG`, `_orig_orig`, `._TX…`（AppleDouble）, `prefix_TX…`, `….wav.partial`, `….wav.meta.json` | None |
| `20260230`（2/30）, `20261301`, `251204`, `076104`, `00000000_000000` | None（例外にしない） |
| タイムゾーン: JST と UTC で同じファイル名 → どちらも 07:12（付与のみ） | |

---

## 2. 鍵と relpath（`src/voicedock/paths.py`）

### 2.1 `is_safe_relpath`（paths.py:108-125）

`PurePosixPath` を受ける。偽: 絶対パス / parts が空 / 要素が `""` `.` `..` / 要素が `.` 始まり / 要素に `ord<0x20` か `0x7F`。
**注意（Python の正規化）**: `PurePosixPath("./a.wav").parts == ("a.wav",)`、`"a//b"` も `("a","b")` に畳まれる → voicedock では `./a.wav` と `a//b.wav` が**真**（test_paths.py:160, 174-181）。
`\` や `"` は Python 側では拒否しない。reaper 側は `"` と `\` を拒否（voicedock-reaper:79）、`//`（空要素）も拒否（同 89）。**voicedock 内で 2 系統が食い違っている。**
- → Swift（仕様 §4.3 の厳格版をそのまま採用してよい）: 生文字列を `/` で split（omittingEmptySubsequences: false）。偽: 空文字 / 先頭 `/` / 空要素 / 要素が `.` `..` / 要素が `.` 始まり / U+0000–U+001F・U+007F / `\` を含む / UTF-8 1024 バイト超。
  `./a.wav` と `a//b.wav` は**偽**（voicedock と違うが安全側。仕様に「voicedock より厳しい」と明記）。

テスト表（test_paths.py:153-168）: `TX_MIC001_…/TX01_…wav`→真、`a.wav`→真、`/TX01/a.wav`→偽、`""`→偽、`../a.wav`→偽、`TX01/../a.wav`→偽、`.Trashes/a.wav`→偽、`TX01/.fseventsd`→偽、`TX01/a\nb.wav`→偽、`TX01/a\x7fb.wav`→偽。
（`./a.wav`→voicedock 真 / Swift 偽）

### 2.2 `partkey_for`（paths.py:131-158）

検査順: device_id 空 → `ValueError` / `/` を含む / `.` 始まり / `is_safe_relpath(rel)` 偽。**`:` は拒否しない**（session_key_for だけが拒否）。
戻り値 `f"{device_id}/{rel}"`（`str(PurePosixPath)` なので正規化後の文字列）。
- 固定値: device `DJIMIC3`、relpath `TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav` →
  partkey `DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav`、key_slug `a5d046dce76cfedc`（test_paths.py:366-413。親が shasum で再計算して一致を確認済み）
- `NO NAME` の空白入りでも作れる（test_paths.py:442-449）
- 拒否例（test_paths.py:452-466）: `("", rel)`, `("a/b", rel)`, `(".hidden", rel)`, `(dev, "../escape.wav")`, `(dev, "/absolute.wav")`, `(dev, ".Trashes/x.wav")`
- → Swift: 仕様 §4.2 の「`:` を含む → エラー」は voicedock より厳しい。macOS の POSIX パスでは Finder 上の `/` が `:` として現れる（`/Volumes/a:b`）ので**実際に起こりうる**。デバイス判定の側で `DeviceID.isValid` を満たさないボリュームを `reason=invalid_device_id` で対象外にする規則が要る（仕様に欠落）。

### 2.3 session_key（paths.py:161-267）

- `session_key_for(device_id, started_at, tz, overflow=1)`: device_id 空 / `:` / `/` / `.` 始まり → ValueError。`overflow<1` → ValueError。
  `day = started_at.astimezone(tz).strftime("%Y%m%d")`、`suffix = "" if overflow == 1 else f"#{overflow}"`
- `device_id_of_session`: **最後の `:`**（rpartition）より前
- `_split_day`: `tail` を `#` で partition。`#` 無し → overflow 1。`#` 有りで int 化できない → ValueError、`< 2` → ValueError（`#1` を作らない）
- `next_overflow`: `#n` → `#(n+1)`
- `device_id_of(partkey)`: **最初の `/`** より前、`relpath_of`: 最初の `/` より後
- 固定値: `DJIMIC3:20260829` → key_slug `43a71bce144be7a7`（親が再計算して一致）

### 2.4 key_slug（paths.py:317-329）

`hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]`。slug の衝突は確率で片付けず、staging の持ち主照合（CONC-13）で検出。

### 2.5 SafeUnlink 相当（paths.py:335-421）

- 根: inbox / data(staging・transcripts・analysis) / vault(tmp のみ) / queue（`delete/` か `result/` 直下の `.json` のみ）
- `safe_unlink_tmp`: 名前が `.` 始まり かつ `.tmp` 終わり かつ `len > len(".")+len(".tmp")`（`.tmp` 単体を拒否）
- `_unlink` の順: 封じ込め（`is_under`: 両方絶対・`..` 無し・realpath 後に root の**真の配下**。root 自身は偽）→ 不在なら missing_ok で return / FileNotFoundError → **symlink なら拒否**（リンクも消さない）→ 通常ファイルでなければ拒否 → unlink
- `is_under` のテスト（test_paths.py:57-141）: 子=真、root 自身=偽、兄弟=偽、接頭辞兄弟（`data` vs `data-old`）=偽、相対=偽、`..`=偽、symlink で外へ=偽、root 内部の symlink 経由=**真**（Vault 内の symlink を許す）、存在しない target=真

---

## 3. 削除要求・結果（`src/voicedock/cleaner.py`、SPEC §14.1.1）

### 3.1 要求（cleaner.py:48-81, 391-458）

- JSON: `json.dumps(obj, ensure_ascii=False, indent=2) + "\n"`、キー順は挿入順: `schema, request_id, created_at, device_id, partkey, session_key, targets[{relpath,size,mtime}]`
- `created_at = now.isoformat(timespec="seconds")`（オフセット付き）
- 書き方: `queue/delete/.<request_id>.json.tmp` へ書く → flush → fsync → `replace`（cleaner.py:436-448）。**ディレクトリ fsync なし**
- `request_id`（cleaner.py:451-458）: `now.astimezone(tz=None).strftime("%Y%m%dT%H%M%S")` + `-` + `key_slug(partkey)` + `-` + `secrets.token_hex(3)`。
  **docstring は「UTC」だが実装はシステムのローカル時刻で、しかも末尾に `Z` が付かない**（例 `20260913T090000-abcdef0123456789-a1b2c3`。test_reaper.py:62）。SPEC の例 `20260912T180000Z-42-a1b2c3` は `Z` 付き・旧整数 ID。
- → Swift: 仕様 §4.4 の `^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}-[0-9a-f]{6}$`（UTC・`Z` 付き）で統一。X-16 の説明に「実装には `Z` も無かった」を足す。
- → Swift の JSON 出力は voicedock と同一である必要はない（reaper も Swift）。ただし「誰が書いても同じ」にするため符号化を固定する:
  `JSONEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]` + 末尾 `"\n"`。`mtime` の Double は整数値だと `1787000000` と出る（`.0` は付かない）ので、読み手は整数・小数の両方を受ける。

### 3.2 結果（voicedock-reaper:180-197）

- キー順: `schema, request_id, completed_at, reaper_version, device_id, partkey, status, detail`
- `detail`: **DELETED なら relpath、SOURCE_IDENTITY_MISMATCH なら理由語**（2 つを連結しない）。仕様 §4.4 の `"detail": "<relpath> | <理由語>"` は「どちらか一方」の意味だが、連結と誤読しうる。
- 書き方: `queue/result/.<request_id>.json.tmp` → `mv`（fsync なし）
- `completed_at`: `date +%Y-%m-%dT%H:%M:%S%z` を `+09:00` 形へ（システムのローカル時刻）

### 3.3 コンテナ側の事前確認 `target_is_identical`（cleaner.py:351-388）

順: inventory が None → 偽 / `source_path` が空か None → 偽 / `is_safe_relpath` 偽 → 偽 / `partkey_for(device_id, rel) != partkey` → 偽 / inventory に relpath が無い → 偽 / `source_size`・`source_mtime` が None → 偽。
（本アプリはこれに加えて実ファイルへ TargetIdentity をかける＝仕様 §8.9.5。voicedock はデバイスを見られなかった）

- `MTIME_TOLERANCE_SECONDS = 2.0`（cleaner.py:41）。reaper は `MTIME_TOLERANCE=2`（voicedock-reaper:31）で、**整数秒どうしの差**（`have_mtime`=stat %m の整数、`${want_mtime%%.*}`=小数点以下切り捨て）`|diff| >= 2` → mismatch（voicedock-reaper:168-170）。
  SPEC の規範実装（Python）は `abs(st.st_mtime - expected) < 2.0`（浮動小数）。→ Swift は浮動小数の式に統一（`Double(tv_sec) + Double(tv_nsec)/1e9`）。FAT の mtime は 2 秒刻みなので実害なし。
- テスト: `mtime + 120` → `mtime_mismatch`、`mtime + 1` → 削除される（test_reaper.py:158-173）。

---

## 4. reaper（`helper/voicedock-reaper`、d3d595e）

### 4.1 起動と設定

- 引数: なし（`--help`/`-h` は使い方を出して 0、その他の引数は 2）。conf は `$VOICEDOCK_HELPER_CONF` か `<script dir>/../helper.conf`。conf が無い → 2、`VOICEDOCK_HOME` がディレクトリでない → 2（voicedock-reaper:320-347）
- conf は bash で `source`（任意コード実行・未知キー無視 = fail-open）
- `locks_are_released`（292-314）: `DELETE_SOURCE_AUDIO != true` → `reaper_disabled reason=delete_source_audio_false`、`MOUNT_MODE != rw` → `reaper_disabled reason=mount_mode_ro`、heartbeat の `mount_readonly` が `true` → `reaper_disabled reason=mount_readonly`。**いずれも終了コード 0**（`locks_are_released || return 0`）。
  heartbeat が無い・読めない → 素通り（fail-open）。`json_string_bool` の `\|` が BSD sed で常に空 → **heartbeat の確認が macOS では常に素通り**（658adde で修正。`MOUNT_MODE` の文字列比較は効いていた）
- キュー走査: `"$queue"/*.json`（bash の glob は `.` 始まりを拾わない → tmp を無視）。名前順。件数を `reaper_completed requests=N` に出す

### 4.2 1 件の処理順（process_request、212-281）

1. `request_id` を sed で抜く。空 → `warn request_invalid reason=no_request_id` して**要求を放置**（毎回警告し続ける。d419397 で rejected/ 退避に修正）
2. リプレイ: `grep -qxF id state/processed.log` → 結果 MISMATCH `replayed` を書き要求を消す（processed.log には再追記しない）
3. `device_id`, `partkey`, `relpath`, `size`, `mtime` のどれかが空 → reject `malformed_request`
4. `"$device_id/$rel" != "$partkey"` → reject `partkey_mismatch`
5. `[ ! -d "$VOLUMES_ROOT/$device_id" ]` → `warn device_absent`、**要求を残す・processed にも書かない**
6. `target_is_identical`（138-173）の順: relpath_is_safe（`relpath_unsafe`）→ `-L target`（`target_is_symlink`）→ `! -f target`（`target_missing`）→ realpath 失敗（`realpath_failed`）→ 配下でない（`outside_volume`）→ `resolved != target`（`path_contains_symlink`）→ ファイル名規則（`filename_rule`。**denoised も通る**）→ 親フォルダ名規則（`folder_rule`）→ stat 失敗（`stat_failed`）→ size（`size_mismatch`）→ mtime（`mtime_mismatch`）
7. `rm -f "$volume/$rel"` 失敗 → `unlink_failed`、`-e` で残存 → `still_present`
8. 成功: `mark_processed` → `write_result DELETED detail=relpath` → 要求を `rm -f` → `info source_deleted request_id=… recording_key=<partkey>`
- reject（283-288）: `warn source_delete_rejected request_id=… reason=…` → processed.log 追記 → 結果 MISMATCH → 要求を消す
- processed.log: `state/processed.log`、1 行 1 request_id（`printf '%s\n'`）、追記のみ、fsync なし。照合は行の完全一致（`grep -qxF`）
- ログ行: `<ISO8601+09:00> <LEVEL:%-5s> <event k=v…>`（INFO は stdout、WARN は stderr。launchd がファイルへ流す）

### 4.3 d419397（d3d595e より後）の request_id 検証

- `request_id_is_safe`: `'' | *[!A-Za-z0-9_-]*` → 偽
- 空・不正 → `queue/rejected/<basename>` へ `mv -f`（失敗したら `rm -f`）、`warn request_invalid file=… reason=no_request_id|request_id_unsafe`。**processed.log にも結果にも書かない**（信用できない値をファイル名に使わない）
- 検証位置: request_id を読んだ直後、partkey/device_id を読む前
- install.sh の make_tree に `queue/rejected` を追加

### 4.4 → Swift reaper の推奨仕様（仕様 §8.9.4 / B.2 を決定的にするための補足）

**終了コード**
- 0: 正常（ロック 1 が false で何もしなかった場合も 0。`reaper_disabled reason=lock1`）
- 2: 引数不正（`--home` 無し等）/ reaper.conf が無い・読めない・形式不正（未知キー・重複・不正値・必須キー欠落）。ログ `reaper_disabled reason=conf_invalid`。**キューに触らない**
- 3: RV-00 置き場所不正（ログを書く前に判定し、何も書かずに終了してよい）
- `--version`: RV-00 より前に処理し、`<VERSION>\n` を stdout に出して 0（I/O はこれだけ）

**自分の実行ファイルパス**: `_NSGetExecutablePath` → `realpath(3)`。`<HOME>/bin/voicedock-reaper` は `lstat` で通常ファイル（symlink 不可）であることを確かめ、`realpath` 同士を比較。加えて自パスに `.app/Contents/` を含めば 3。

**reaper.conf の書式（固定）**
```
SCHEMA=1
DELETE_SOURCE_AUDIO=true
VOLUMES_ROOT=/Volumes
```
- 行は `\n` 区切り。空行と `#` 始まりの行は無視。それ以外は `^[A-Z_]+=[^[:space:]]*$` に完全一致しなければ形式不正
- 必須: `SCHEMA`（`1` のみ）、`DELETE_SOURCE_AUDIO`（`true`/`false` のみ）。任意: `VOLUMES_ROOT`（`/` 始まりの絶対パス。既定 `/Volumes`）
- 未知キー・重複キー → 形式不正（exit 2）
- ファイルは `open(O_RDONLY|O_NOFOLLOW)`、通常ファイル、64 KiB 以下

**キューの走査**: `queue/delete` を `opendir`。名前が `.` で始まるものは無視。名前の**バイト順昇順**で処理。以下、1 件ずつ:

| 順 | 検査 | 失敗時 |
|---|---|---|
| RV-02a | ファイル名が `^<REQUEST_ID_RE 本体>\.json$` に完全一致 | `queue/rejected/<name>` へ rename（同名は上書き）。結果・processed.log は書かない。ログ `request_rejected reason=malformed_request_id` |
| — | `openat(O_RDONLY|O_NOFOLLOW)`、通常ファイル、64 KiB 以下、UTF-8 JSON オブジェクト | 結果 MISMATCH `malformed_request`（request_id はファイル名の stem を使う。stem は RV-02a を通過済みで安全） |
| RV-02b | JSON の `request_id` が文字列でファイル名の stem と一致 | rejected/ へ（RV-02a と同じ扱い） |
| RV-03 | 形: キー集合がちょうど `{schema, request_id, created_at, device_id, partkey, session_key, targets}`、`schema == 1`（整数。bool 不可）、文字列 4 つが文字列、`targets` がちょうど 1 要素でキー集合 `{relpath,size,mtime}`、`size` は 0 以上の整数（bool 不可）、`mtime` は有限の数（bool 不可） | MISMATCH `malformed_request` |
| RV-04 | `state/processed.log` に同じ行が無い | MISMATCH `replayed`（processed.log に再追記しない） |
| RV-05 | `device_id + "/" + relpath == partkey` | MISMATCH `partkey_mismatch` |
| RV-06 | `DeviceID.isValid(device_id)`（§4.2 と同じ関数）。`<VOLUMES_ROOT の realpath>/<device_id>` を `open(O_RDONLY|O_DIRECTORY|O_NOFOLLOW)`。ENOENT → `device_absent`（**要求を残す**）。ELOOP/ENOTDIR → `not_a_mount_point`。開いた fd に `fstatfs`: `f_mntonname` が開いたパス（realpath 済み）と一致しなければ `not_a_mount_point`、`f_fstypename != "msdos"` → `unexpected_fs` | absent は残す、他は MISMATCH |
| RV-07 | 同じ `fstatfs` の `f_flags & MNT_RDONLY == 0` | `mount_readonly`（**要求を残す**） |
| RV-08〜12 | `TargetIdentity`（下記）を**同じボリューム fd** に対して実行 | 各理由語で MISMATCH |
| RV-13 | `unlinkat(parentFD, name, 0)`（TargetIdentity が返した**検証済みの親 fd**を使う）→ `fstatat(parentFD, name, AT_SYMLINK_NOFOLLOW)` が ENOENT | `unlink_failed` / `still_present` |

- JSON のデコードで `JSONSerialization` を使う場合、真偽値の `NSNumber` は `as? Int` / `as? Double` で**成功してしまう**。`CFGetTypeID(n) == CFBooleanGetTypeID()` で弾くこと（または `JSONDecoder` で型厳密に読み、キー集合は別に照合）。
- **fstatfs を開いた fd に対して行う**（statfs(path) → open(path) の間に差し替えられる窓を消す）。
- `f_mntonname` との比較は **realpath 済みのパス**で行う。テストの一時ディレクトリは `/var/folders/…`（`/private/var` への symlink 経由）なので、realpath しないと hdiutil でマウントした `f_mntonname`（`/private/var/…`）と一致しない。

**書き込み順**（voicedock と同じ）: 拒否 = processed.log 追記（`O_APPEND` + fsync）→ 結果（`.<id>.json.tmp` → fsync → rename）→ 要求を unlinkat。成功 = unlink → processed.log → 結果 → 要求を消す。

**reaper.log**: `<HOME>/logs/reaper.log`、5 MiB 超で `.1` へ rename（1 世代）。行形式は app.log と同じ `<ts> <LEVEL> <event> k=v …`。`ts` は `yyyy-MM-dd'T'HH:mm:ssxxxxx`（システムのローカルタイムゾーン。reaper は config.json を読まないため）。
イベント（固定）: `reaper_started`, `reaper_disabled reason=lock1|conf_invalid`, `request_rejected file=<name> reason=malformed_request_id`, `source_delete_rejected request_id=… reason=<理由語>`, `device_absent request_id=… device=…`, `mount_readonly request_id=… device=…`, `source_deleted request_id=… partkey=…`, `reaper_completed requests=<N>`。

---

## 5. TargetIdentity（仕様 §4.6）の API 修正案

`verify` が `Verdict` だけを返すと、reaper は unlink の直前にパスを開き直すことになり、openat 連鎖で消したはずの TOCTOU が戻る。検証済みの親ディレクトリ fd を unlink まで保持する API にする:

```swift
public enum TargetIdentity {
    /// RV-06/07: ボリュームを開き fstatfs で確かめる
    public static func openVolume(volumesRoot: String, deviceID: String) -> VolumeOpenResult
    // .opened(VolumeHandle) / .absent / .rejected(reason)  // reason ∈ not_a_mount_point, unexpected_fs
    /// RV-08〜12。検証済みなら親 fd を持つ VerifiedTarget をクロージャに貸す（クロージャを抜けたら close）
    public static func withVerifiedTarget<R>(volume: VolumeHandle, relpath: String,
        expectedSize: Int64, expectedMtime: Double,
        _ body: (VerifiedTarget) -> R) -> Result<R, IdentityMismatch>
}
public struct VerifiedTarget: ~Copyable { public let parentFD: Int32; public let name: String }  // もしくは非公開 init の struct
```
- アプリの事前確認は `withVerifiedTarget(...) { _ in () }` を呼ぶだけ（unlink しない）
- `VolumeHandle` は `readOnly: Bool`（観測）も持つ（RV-07 とアプリのロック 2-B 観測を同じ値で行う）
- 中間要素 `openat(O_RDONLY|O_DIRECTORY|O_NOFOLLOW)`: ELOOP → `path_contains_symlink`、ENOTDIR → `path_contains_symlink`（仕様どおり。中間に通常ファイルがある場合も同じ語）、ENOENT → `target_missing`、その他 → `target_missing`
- 最後の要素 `fstatat(AT_SYMLINK_NOFOLLOW)`: ENOENT → `target_missing`、S_ISLNK → `target_is_symlink`、!S_ISREG → `not_regular_file`
- 規則の順: ファイル名（`_orig` 必須。`RecordingName.parseFile(name)?.isOrig == true`）→ 親フォルダ名（`RecordingName.isFolder`。**relpath が 1 要素＝ボリューム直下のファイルは親がボリューム名なので常に `folder_rule`**）→ size → mtime
- 旧 reaper の `realpath_failed` / `outside_volume` / `stat_failed` は openat 連鎖では出ない（B.2 に載せない理由を注記）

---

## 6. 取り込み（`helper/voicedock-ingest`、SPEC §5.4 / §10.1〜§10.3）

### 6.1 デバイス判定（voicedock-ingest:271-312、SPEC §5.4）

`VOLUMES_ROOT/*` の各エントリ（glob なので `.` 始まりは列挙されない）に**この順**:
1. `INCLUDE_VOLUMES` が非空で、どのパターンにも一致しない → `volume_skipped name=… reason=not in INCLUDE_VOLUMES`（空なら規則 1 を適用しない＝全エントリが次へ）
2. `EXCLUDE_VOLUMES` のどれかに一致 → `reason=in EXCLUDE_VOLUMES`（bash の `case` glob = fnmatch。`.*` は「`.` 始まり」）
3. `-L` → `reason=symlink`
4. `! -d || ! -r` → `reason=not a readable directory`
5. `_has_recordings`（直下に、`.` 始まり以外で「ディレクトリかつフォルダ規則」または「ファイルかつファイル規則（denoised も可）」が 1 つ以上）偽 → `find -maxdepth 1` が成功すれば `reason=no DJI recordings`、失敗すれば `reason=volume not listable — …`
- 合格 → `device_detected name=…`。**device_id = `/Volumes` 直下のエントリ名（basename）**。SPEC §5.4 末尾「`device_id` は Volume 名とする」は、実装上はマウント点の basename。
- statfs によるマウント点確認は **voicedock には無い**（本計画の追加。FakeVolume の単体テストでは通らないので、判定器は `MountInspector` として注入可能にする必要がある）

テスト（test_helper_ingest.py:513-641）: include 空 → 通る / include `DJIMIC*` → 通る / include `NOPE` → 0 件 / include `.*` → 通らない（glob）/ exclude `"My Device"`（空白入り 1 パターン）で除外、`"My"` では除外されない / symlink のエントリ（`Escape -> DJIMIC3`）は `reason=symlink`、本物は検出 / 録音の無いディレクトリ → `no DJI recordings` / 列挙不可（mode 444）→ `volume not listable`、空の読めるボリューム → `no DJI recordings`（陰性対照）/ 深さ上限 / 複数デバイス。

→ Swift で注意: `opendir` の失敗は TCC なら `EPERM`、パーミッション（テストの mode 000）なら `EACCES`。**EPERM だけを not_listable にすると EACCES が「録音なし」に化ける**（DEV-03 の再発）。`opendir` が失敗したら errno に関わらず `not_listable`（errno を detail に残す）。EPERM のときだけ TCC の案内を出す。
mode 444 はディレクトリの読み取りは成功する（x が無いので中身の stat が失敗）→ Swift の単体テストは mode 000 を使う。

### 6.2 走査（voicedock-ingest:321-352）

- `_scan_dir(path, "", MAX_SCAN_DEPTH)`、`depth < 1` で終了。ルート直下が depth=3、1 段下が 2、2 段下が 1 → **ファイルは最大 3 階層（root/a/b/file）まで**
- `.` 始まりは黙って無視（ログ無し）。ディレクトリは symlink なら入らない。**全ディレクトリへ降りる（フォルダ規則は見ない）**
- ファイル: `-f`（**symlink を辿る**）かつファイル規則一致 → 全件一覧（denoised 含む）へ。`_orig` のみ候補。墓標があれば stat もしない
- → Swift: `lstat` で判定し symlink はファイルもディレクトリも無視（voicedock は file の symlink を辿ってコピーしうる）。デバイス上のファイルは `open(O_RDONLY|O_NOFOLLOW)`。

### 6.3 安定性判定（voicedock-ingest:358-431）

1. 候補全件の (size, mtime) を stat（整数秒）。取れなければ空
2. mtime が取れていて `mtime <= now - FAST(60)` → OK=CHECKS（即断）。残りを pending と数え、0 なら終わり。`info stability_pending count=N`
3. `round in 0..<CHECKS`: 全件の値を控える → `sleep INTERVAL` → 全件再 stat → OK<CHECKS のものについて「size が空でなく size・mtime とも控えと一致」なら OK+=1、そうでなければ OK=0
4. コピー対象は `OK >= CHECKS` のもの。それ以外は `info file_not_stable relpath=…`（保留。失敗ではない）
- ちょうど CHECKS 回しか回らないので、1 度でも不一致なら今回は見送り（仕様の記述と同じ結果）
- `STABILITY_FAST_PATH_SECONDS` が欠落・不正なら 60（0 にしない。BH-5 / DEV-13）
- 待ち時間は `INTERVAL × CHECKS`（ファイル数に比例しない。25 件で 20 秒未満のテスト test_helper_ingest.py:653-673）

### 6.4 コピー（voicedock-ingest:437-502）

- 宛先 `inbox/<device_id>/<folder>/<name>`（relpath がルート直下なら `inbox/<device_id>/<name>`）。`partial = <dst>/<name>.partial`（**voicedock は `.` 始まりではない**。本アプリは `.<name>.partial`）
- `cat src | tee partial | sha256` の 1 回読み。失敗 → partial を消して `warn copy_failed`、次へ
- partial の size が控えの size と違う → `warn copy_size_mismatch relpath=… expected=…`、消して次へ
- `mv partial → name` → 墓標（`.meta.json`）を tmp → mv（**本体が先・記録が後**）→ `info copied relpath=… bytes=…`
- 墓標の `mtime` は `%s.0`（整数秒 + `.0`）。size・mtime は**デバイス上の原本**の stat（コピーの stat ではない。BC-1 / #151）
- fixture の原本 mtime はコピー時刻の 4 時間 34 分前（`DEVICE_MTIME_OFFSET`、tests/fixtures/fake_tree.py）

### 6.5 読み取り専用の確保（voicedock-ingest:521-547, 803-864）

- `_is_mounted_readonly`: `mount` の出力に ` on <path> ` を含み `read-only` を含む行があるか
- `remount_readonly`: 既に ro → 0（何もしない）/ diskutil 無し → `no_diskutil` / `diskutil info -plist` の DeviceNode が取れない → `no_device_node` / `diskutil unmount <path>` 失敗 → `unmount_failed` / `diskutil mount readOnly <node>` 失敗 → `mount_failed` / 再観測で ro でない → `still_writable`
- 失敗しても取り込み続行。`warn remount_readonly_failed name=… reason=…`
- **観測値**を書く。`MOUNT_MODE=rw` でも観測する。デバイス 0 台のとき mount_readonly は false のまま（**voicedock は「0 台」を false と書いていた**。本計画 DEL-32 の `readOnly: Bool?` はこれを直す）
- 空き容量は再マウントの**後**に `df -Pk` の 4 列目 × 1024（→ Swift: `statfs` の `f_bavail * f_bsize`）
- 再マウント後も `path="$VOLUMES_ROOT/$device_id"` を使い続ける（**パスが変わる場合の扱いは voicedock に無い**）
- 実機: `/dev/disk4 on /Volumes/DJIMIC3 (msdos, local, nodev, nosuid, noowners, noatime, fskit)`、Device Node `/dev/disk4`（superfloppy）、`File System Personality: MS-DOS FAT32`、出荷時名 `NO NAME`（docs/POC.md:292-301）
- DiskArbitration は ro ボリュームの unmount を dissent（0xF8DA0008）。5 分ごとの unmount で 34 サイクル中 3 回 EBUSY（#107）

### 6.6 inventory（voicedock-ingest:594-680）

- 全デバイス分をまとめて 1 回。`devices: {device_id: [relpath…]}`（device_id・relpath を `LC_ALL=C sort`）。**録音 0 件のデバイスも空配列で載る**（BO-1）。0 件でも検出されるのは、規則 5 がフォルダの存在でも真になるため（全ファイル削除後もフォルダは残る。reaper はディレクトリを消さない）
- `device_free_bytes`（取れたものだけ）、`mount_readonly`、`generated_at`
- 途中経過では書かない（heartbeat はコピー 1 件ごとに更新）

### 6.7 共存ガード関連（helper/install.sh）

- LaunchAgent のラベルは `com.voicedock.ingest`（com.voicedock.ingest.plist の `Label`、install.sh:17）
- install.sh は `launchctl bootstrap "gui/$UID" <plist>`、状態表示は `launchctl print "gui/$UID/$LABEL"` の終了コード 0 を「loaded」と表示（install.sh:289-290）
- 停止: `./helper/install.sh --uninstall`（`launchctl bootout gui/$UID/$LABEL`。`<VOICEDOCK_HOME>` は消さない）
- plist は `StartOnMount` + `StartInterval 300` + `RunAtLoad`、`KeepAlive` 無し → **常駐プロセスではない。**`launchctl print` の 0 は「登録されている」であって「今動いている」ではない

---

## 7. ND 番号（voicedock SPEC §20.4、tests/unit/test_no_delete.py / test_reaper.py）

| voicedock | 層 | 本計画 B.1 |
|---|---|---|
| ND-01〜09 | コンテナ | 同番号で継承 |
| ND-10〜17 | v5.37 で廃止 | 欠番（本計画も欠番） |
| ND-18〜20 | reaper | 同番号 |
| ND-21 | コンテナ | 同番号 |
| ND-22 / ND-23 | 両層 | 同番号 |
| ND-24〜29 | reaper | 同番号（ND-26 は voicedock では「要求はキューに残りタイムアウト」、本計画は「アプリが要求を書かない」に意味が変わる） |
| ND-30 | コンテナ（`/state` の ro マウント。Docker 固有） | 欠番 |
| ND-31 | コンテナ | 同番号（本計画は A・R） |
| ND-32〜35 | コンテナ | 同番号 |
| — | — | ND-36〜44 は本計画で新設 |

→ 番号は**再割当てしていない**。仕様 §0.5 の「番号は付録 B で再割当て、対応表あり」は誤り。

正の対照: `test_deletion_actually_happens_when_everything_is_valid`（test_no_delete.py:326）、`test_a_valid_request_actually_deletes`（test_reaper.py:129）。

reaper 層のテストベンチ（test_reaper.py:40-126）: **ボリュームは普通のディレクトリ**（マウント点ではない）。request_id `20260913T090000-abcdef0123456789-a1b2c3`、FOLDER `TX_MIC001_20260912_090000`、FILENAME `TX00_MIC001_20260912_090000_orig.wav`、CONTENT `b"x"*4096`、MTIME `1787000000.0`。
→ 本計画の RV-06（マウント点・msdos）を入れると、**普通のディレクトリのベンチでは全件が RV-06 で落ちる**。RV-08 以降と正の対照を reaper 実行ファイルで試すには FAT32 ディスクイメージが必須になる。

---

## 8. RV と voicedock の検証番号の対応

| voicedock §14.1.1 | 本計画 |
|---|---|
| 1 ロック 1 | RV-01 |
| 2 MOUNT_MODE=rw かつ heartbeat の mount_readonly 偽 | RV-07（statfs 観測に置換） |
| 3 同名ボリュームがある（`-d` のみ） | RV-06（マウント点・msdos を追加） |
| 4 relpath の健全性 / 9 `.` 始まり | RV-08 |
| 5 realpath 封じ込め | RV-09（openat 連鎖に置換） |
| 6 symlink でない通常ファイル | RV-10 |
| 7 ファイル名規則 / 8 親フォルダ名規則 | RV-11（`_orig` 必須を追加） |
| 10 size・mtime | RV-12 |
| 11 リプレイ | RV-04 |
| 12 partkey 一致 | RV-05 |
| （番号なし）unlink 失敗・残存 | RV-13 |
| （無し） | RV-00 置き場所、RV-02 request_id、RV-03 JSON の形 |
