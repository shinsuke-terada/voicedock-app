# V7 外部事実検証レポート（2026-09-18 時点）

検証環境: Xcode 27.0 (27A266a) / Swift 6.4 (swiftlang-6.4.0.34.1) / macOS 26.6.2 (25G83) / arm64
凡例: 「確認」= 一次ソース（GitHub API・ソースコード・HF API・ローカル実行）で確認済み。「未確認」= 一次ソースで確認できず。

---

## 1. whisper.cpp (ggml-org/whisper.cpp)

| 項目 | 結果 | ソース |
|---|---|---|
| tag `v1.9.4` 存在 | **確認: 存在** (annotated tag object `7d75b14994ae7f59623e2471445e2355fe506ed2`, tagger github-actions[bot] 2026-09-11T05:31:53Z) | `gh api repos/ggml-org/whisper.cpp/git/refs/tags/v1.9.4` |
| v1.9.4 のコミット SHA | **`927cfce34f31707e17f2bff35c349632fb9e2c3a`** ("metal : remove leftover ggml-metal.metal kernels file (#4051)") | `gh api .../git/tags/7d75b149...` → object.sha |
| 最新リリース | **`v1.9.4`**（`releases/latest`、2026-09-11 公開、prerelease=false）。同一コミットに nightly `b5130` もある（whisper.cpp も bNNNN 形式の nightly リリースを出すようになった）。v1.9.4 リリース自体には asset なし | `gh api repos/ggml-org/whisper.cpp/releases/latest`, `releases?per_page=10` |
| CMakeLists のバージョン | `WHISPER_VERSION_MAJOR 1 / MINOR 9 / PATCH 4` | `CMakeLists.txt@v1.9.4` L6-8 |

### whisper-cli フラグ（`examples/cli/cli.cpp@v1.9.4`、ターゲット名 `whisper-cli` は `examples/cli/CMakeLists.txt` で確認）
すべて **存在を確認**:

| フラグ | 定義行 | 備考 |
|---|---|---|
| `--vad` | L216 | 長形式のみ（短形式なし）|
| `--vad-model` (`-vm`) | L217 | |
| `--vad-threshold` (`-vt`) | L218 | default 0.5 |
| `--vad-min-speech-duration-ms` (`-vspd`) | L219 | default 250 |
| `--vad-min-silence-duration-ms` (`-vsd`) | L220 | default 100 |
| `--vad-speech-pad-ms` (`-vp`) | L222 | default 30 |
| `-oj` (`--output-json`) | L188 | `-ojf` = full JSON(token単位) |
| `-of` (`--output-file`) | L190 | help: "output file path (**without file extension**)"。`.json` が付与される |
| `-np` (`--no-prints`) | L191 | |
| `-l` (`--language`) | L197 | **default は `"en"`**（`ja` または `auto` を明示必須）|
| `-t` (`--threads`) | L159 | default `min(4, hw_concurrency)` |
| `-m` (`--model`) | L201 | default `models/ggml-base.en.bin` |
| `-f` (`--file`) | L202 | |

その他 VAD: `-vmsd/--vad-max-speech-duration-s`, `-vo/--vad-samples-overlap` もある。

**注意（重要な落とし穴、ソースで確認）**:
- 未知の引数・値欠落・未知の言語 → エラーメッセージを出して **`exit(0)`**（終了コード 0）。L126-129, L224-227, L1035-1038。
- 入力音声の読み込み失敗 → `"error: failed to read audio file"` を出して **`continue`**（L1169-1170）→ 他にエラーがなければ終了コード 0 で JSON 未生成。
- よってラッパー側は「終了コード 0」だけでなく **出力 JSON ファイルの存在とパース成功** で成否判定すべき。
- 推論失敗は `return 10`、モデル初期化失敗 `return 3`、入力なし `return 2`。
- 音声デコードは miniaudio で f32 / 16kHz に変換（`examples/common-whisper.cpp` L96, L167: `ma_decoder_config_init(ma_format_f32, ..., WHISPER_SAMPLE_RATE)`）。usage 表示上の対応形式は "flac, mp3, ogg, wav"。48kHz/24bit・32bit float WAV は miniaudio(dr_wav) が扱える形式だが、**DJI 実ファイルでの実地デコードは未検証**。

### JSON 出力 (-oj) の時刻単位
**確認: `transcription[].offsets.from/to` はミリ秒**。`cli.cpp` L698-707:
```cpp
start_obj("timestamps"); value_s("from", to_timestamp(t0, true)) ...   // "00:00:01,230" 形式の文字列
start_obj("offsets");    value_i("from", t0 * 10, false); value_i("to", t1 * 10, true);
```
`t0/t1` は whisper の 10ms 単位（centisecond）なので ×10 = ms。`timestamps.from/to` は `HH:MM:SS,mmm` 文字列。
VAD 有効時も `whisper_full_get_segment_t0/t1` は `map_processed_to_original_time`（`src/whisper.cpp` L8060）で **元音声の時間軸へ再マッピング** される（`vad_mapping_table`）。

### CMake オプション（v1.9.4）
| オプション | 存在 | デフォルト | ソース |
|---|---|---|---|
| `GGML_METAL` | 確認 | APPLE なら ON | `ggml/CMakeLists.txt` L96, L236 |
| `GGML_METAL_EMBED_LIBRARY` | 確認 | `${GGML_METAL}`（=ON on Apple）| L239 |
| `GGML_NATIVE` | 確認 | ON（ただし cross-compile か環境変数 `SOURCE_DATE_EPOCH` 定義時は OFF）| L105-123 |
| `WHISPER_BUILD_TESTS` | 確認 | standalone なら ON | `CMakeLists.txt` L103 |
| `WHISPER_BUILD_EXAMPLES` | 確認 | standalone なら ON | L104 |
| `WHISPER_BUILD_SERVER` | 確認（定義のみ）| standalone なら ON | L105 |
| `BUILD_SHARED_LIBS` | 確認 | ON（MinGW/Emscripten 以外）| L77 / ggml L85 |

**注意**: v1.9.4 の `examples/CMakeLists.txt` L105-111 は `WHISPER_BUILD_EXAMPLES=ON` なら `cli, bench, server, quantize, vad-speech-segments, parakeet-cli, parakeet-quantize` を **無条件で add_subdirectory**。`WHISPER_BUILD_SERVER` はこのファイルでは参照されておらず、OFF にしても whisper-server はビルド対象に残る（ソース上）。`cmake --build build --target whisper-cli` でターゲット限定を推奨。
その他: `WHISPER_CURL`(default OFF), `WHISPER_COREML`(OFF), `WHISPER_USE_SYSTEM_GGML`, `WHISPER_USE_SYSTEM_LLAMA`（新規）等。`BUILD_SHARED_LIBS=ON` の場合 dylib 同梱＋rpath 処理が必要、静的リンクなら `-DBUILD_SHARED_LIBS=OFF`。

---

## 2. llama.cpp (ggml-org/llama.cpp)

| 項目 | 結果 | ソース |
|---|---|---|
| 最新 bNNNN リリース | **`b11033`**（2026-09-18T09:55:12Z 公開）、commit **`8ed1a55efcd7424d2c592f6cbc9f97756db1d74d`**（"cmake : fix build when GGML_CPU=OFF and GGML_CUDA=ON (#29026)"）| `gh api repos/ggml-org/llama.cpp/releases?per_page=5`, `git/refs/tags/b11033` |
| 注意 | llama.cpp は **semver リリースも開始**: `releases/latest` は **`v0.4.1`**（2026-09-14、tag commit `b29c606e28a01b1bc8c1351026a0fa6e616bf6c4`、ggml v0.24.0）。v0.1.0〜v0.4.1 の tag あり。b11033 は v0.4.1 の 69 コミット先（behind 0）。bNNNN は 1 日に複数回出るので固定ピン推奨 | `releases/latest`, `git/matching-refs/tags/v`, `compare/v0.4.1...b11033` |
| リリースバイナリ | `llama-b11033-bin-macos-arm64.tar.gz` あり。実行確認: `version: 0.4.1-dev (build 11033, commit 8ed1a55ef)`。**dylib 構成（@rpath / @loader_path）、ad-hoc 署名（linker-signed）** → アプリ同梱時は再署名必須 | ダウンロードして `llama-server --version`, `codesign -dv`, `otool -L` |

### llama-server フラグ（b11033 の `common/arg.cpp` と実バイナリ `--help` の両方で確認）
| フラグ | 結果 | 補足 |
|---|---|---|
| `-m` / `--model` | 確認 | |
| `--host` | 確認 | default `127.0.0.1`。`.sock` 終端で UNIX socket |
| `--port` | 確認 | default 8080 |
| `--api-key` | 確認 | カンマ区切りで複数可。env `LLAMA_API_KEY`。`--api-key-file` もあり |
| `-c` / `--ctx-size` | 確認 | **default 0 = モデルから読み込み**（Qwen3-2507 はネイティブ 262k → KV キャッシュ肥大。明示指定推奨）|
| `-ngl` / `--gpu-layers` | 確認 | 数値 / `auto` / `all`、default `auto` |
| `--jinja` | 確認 | **default enabled**（`--no-jinja` で無効化）|
| `-np` / `--parallel` | 確認 | server では default -1 = auto |
| `--no-webui` | 確認 | `--ui/--webui/--no-ui/--no-webui`、default enabled |
| 参考 | `--offline`（"forces use of cache, prevents network access"）, `-hf` もあり | |

### /health と API キー（`tools/server/server-http.cpp@b11033`）
- **確認: `/health` と `/v1/health` は API キー検証の対象外**（`get_public_endpoints` L197-204、`server.cpp` L246-247 のコメント "public endpoint (no API key check)"）。
- **確認: ロード中は 503**: `middleware_server_state` が `is_ready` でない間、（UI 静的アセット以外の）全エンドポイントに `503 {"error":{"message":"Loading model","type":"unavailable_error","code":503}}` を返す（L250-270）。このチェックは API キー検証より先に実行（L300-305）。
- **確認: ready 後は 200 `{"status":"ok"}`**（`server-context.cpp` L4654-4663）。
- API キーは `Authorization: Bearer <key>` か `X-Api-Key`。不正時 401 `authentication_error`。

### response_format
**確認: `/v1/chat/completions` は `response_format: {"type":"json_object"}` を受け付ける**。`server-common.cpp` L1185-1198: `json_object`（schema なしなら `{}` = 任意 JSON の文法制約）、`json_object`+`schema`、`json_schema`（`json_schema.schema`）、`text` 対応。それ以外は `invalid_argument`。README L1316 にも同記載。

### CMake オプション（b11033 `CMakeLists.txt`）
| オプション | 結果 |
|---|---|
| `LLAMA_CURL` | **廃止**。`llama_option_depr(WARNING LLAMA_CURL)` → 指定すると "deprecated and will be ignored" 警告のみ（L195）|
| `LLAMA_BUILD_SERVER` | 存在、default standalone=ON。ただし `tools/` は `LLAMA_BUILD_COMMON AND LLAMA_BUILD_TOOLS` のときだけ追加されるので **server には `LLAMA_BUILD_TOOLS=ON` も必須**（`tools/CMakeLists.txt` の `if (LLAMA_BUILD_SERVER)` で `ui`, `cli`, `server` を追加）|
| `LLAMA_BUILD_TOOLS` | 存在、default standalone=ON |
| `LLAMA_BUILD_EXAMPLES` | 存在、default standalone=ON |
| `LLAMA_BUILD_TESTS` | 存在、default standalone=ON |
| `LLAMA_BUILD_COMMON` | 存在、default standalone=ON（新）|
| `LLAMA_BUILD_APP` | 存在、default standalone=ON（統合バイナリ `llama`）|
| **`LLAMA_OPENSSL`** | **存在、default ON**。cpp-httplib の HTTPS（`-hf` 等のモデル DL）用。`find_package(OpenSSL)` で見つからなければ "OpenSSL not found, HTTPS support disabled" 警告で続行（`vendor/cpp-httplib/CMakeLists.txt` L128-157）。`LLAMA_BUILD_BORINGSSL` / `LLAMA_BUILD_LIBRESSL`（未宣言=OFF）で FetchContent ビルドも可 |
| `LLAMA_HTTPLIB` | **存在しない**（b11033 CMakeLists に定義なし）。cpp-httplib は `vendor/` から常時ビルド |
| **`LLAMA_USE_PREBUILT_UI`** | **default ON**。`LLAMA_BUILD_UI`(default OFF) と組み合わさり、ビルド時に `tools/ui/dist` が無ければ **Hugging Face bucket `ggml-org/llama-ui` から dist.tar.gz を `file(DOWNLOAD)`**（sha256 検証付き、`scripts/ui-assets.cmake`）。オフライン/再現ビルドでは `-DLLAMA_USE_PREBUILT_UI=OFF`（UI 無しで警告付きビルド）|
| `LLAMA_SUBPROCESS` | default ON（macOS）。server tools / router mode 用 |
| `LLAMA_LLGUIDANCE` | default OFF |

---

## 3. Hugging Face（HF API `?blobs=true` / HEAD で確認、2026-09-18 取得）

### (a) ggerganov/whisper.cpp
- main commit: **`5359861c739e955e79d9a303bcbc70fb988958b1`**（lastModified 2024-10-29）、license: mit
- `ggml-large-v3-turbo-q5_0.bin`: size **574,041,195** bytes、sha256 **`394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`**
- 参考: `ggml-large-v3-turbo-q8_0.bin` 874,188,075 / `317eb69c...e259a1`、`ggml-large-v3-turbo.bin` 1,624,555,275 / `1fc70f77...e2bc69`
- `models/download-ggml-model.sh@v1.9.4` の src も `https://huggingface.co/ggerganov/whisper.cpp`、`large-v3-turbo-q5_0` を列挙

### (b) ggml-org/whisper-vad
- main commit: **`9ffd54a1e1ee413ddf265af9913beaf518d1639b`**（lastModified 2025-11-17）、license: mit
- `ggml-silero-v5.1.2.bin`: size **885,098**、sha256 **`29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf`**（HEAD の `x-repo-commit` / `x-linked-etag` とも一致）
- 参考: `ggml-silero-v6.2.0.bin` もあり（885,098 / `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987`）。`models/download-vad-model.sh@v1.9.4` は `silero-v5.1.2 silero-v6.2.0` の両方を列挙

### (c) Qwen3-30B-A3B-Instruct-2507 GGUF Q4_K_M
- **公式 `Qwen/Qwen3-30B-A3B-Instruct-2507-GGUF` は存在しない**（API 401 = 非公開/不存在。Qwen org の 2507 系は safetensors と FP8 のみ）。**`ggml-org/…-GGUF` の Q4_K_M も無し**（`ggml-org/Qwen3-30B-A3B-Instruct-2507-Q8_0-GGUF` のみ存在）。
- 上流 `Qwen/Qwen3-30B-A3B-Instruct-2507`: license **apache-2.0**（commit `0d7cf23991f47feeb3a57ecb4c9cee8ea4a17bfe`）

| repo | commit | ファイル | size (bytes) | sha256 | license(card) |
|---|---|---|---|---|---|
| unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF | `eea7b2be5805a5f151f8847ede8e5f9a9284bf77` | `Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf` | 18,556,686,752 | `6c997b8af17debdfb01d890214400ccbab00db6acc0ba8da5de1cc906c4774d0` | apache-2.0 |
| lmstudio-community/Qwen3-30B-A3B-Instruct-2507-GGUF | `02db009a02d5f8817f8a79e952cb0e8d79e9bd34` | `Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf` | 18,556,685,824 | `88168cc35481e44b7d3d03ce79f59a90d15197e4d633006555a0bc44c57886d8` | apache-2.0 |
| bartowski/Qwen_Qwen3-30B-A3B-Instruct-2507-GGUF | `6c6e8692f43e4ca663f7ece8229a1361090d3a4c` | `Qwen_Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf` | 18,632,183,808 | `382b4f5a164d200f93790ee0e339fae12852896d23485cfb203ce868fea33a95` | (card 未記載) |
| MaziyarPanahi/Qwen3-30B-A3B-Instruct-2507-GGUF | `2d147fafc20006086bef3d44210d58fd05118b17` | `Qwen3-30B-A3B-Instruct-2507.Q4_K_M.gguf` | 18,556,686,048 | `7256f5b531426fe2e3c68cef8c5c9bed9ccae7b08dbe3ed207107edacdbd5d48` | (card 未記載) |
| (参考) ggml-org/Qwen3-30B-A3B-Instruct-2507-Q8_0-GGUF | `c44c6e74a5f720e4f933d6e6fba8aa0b8f4e8a1d` | `qwen3-30b-a3b-instruct-2507-q8_0.gguf` | 32,483,930,432 | `66cbfc7624628ca4725a6a0581b95f2155aa6aa073a6ed4ff8d158794ee8fee3` | apache-2.0 |

### (d) Qwen3-4B-Instruct-2507 GGUF Q4_K_M
- **公式 `Qwen/Qwen3-4B-Instruct-2507-GGUF` は存在しない**（401）。ggml-org は Q8_0 のみ。上流 `Qwen/Qwen3-4B-Instruct-2507` license **apache-2.0**（commit `cdbee75f17c01a7cc42f958dc650907174af0554`）。

| repo | commit | ファイル | size | sha256 | license(card) |
|---|---|---|---|---|---|
| unsloth/Qwen3-4B-Instruct-2507-GGUF | `a06e946bb6b655725eafa393f4a9745d460374c9` | `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` | 2,497,281,120 | `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597` | apache-2.0 |
| lmstudio-community/Qwen3-4B-Instruct-2507-GGUF | `4edb920b6f14e3b9284d4502a6485103d72cde05` | `Qwen3-4B-Instruct-2507-Q4_K_M.gguf` | 2,497,280,448 | `8cdb57cbb880d313736a9bc4e3d3d2485f145b5e19cf33783746e753e82641fc` | (card 未記載) |
| bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF | `ae44f08e1392f39c0e474af10c3ff8355c8b6688` | `Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf` | 2,497,280,736 | `2fde00ce69dd4899c70d020845e2638353015bba0fdf161b3eb965f2bca4464e` | (card 未記載) |
| MaziyarPanahi/Qwen3-4B-Instruct-2507-GGUF | `aec29f0e8c31130ba811bec2c774c2ef44888f55` | `Qwen3-4B-Instruct-2507.Q4_K_M.gguf` | 2,497,280,448 | `953ba5b5511fbb2ec9bcb4e588b1e72cedef19b908dba1da0fb3fb340cfb1c3e` | (card 未記載) |
| (参考) ggml-org/Qwen3-4B-Instruct-2507-Q8_0-GGUF | `e6f794d44f9395d0184a966c27b5ae99ea356fcb` | `qwen3-4b-instruct-2507-q8_0.gguf` | 4,280,403,520 | `ae916ede1c010a26955ee8ae2e908bf8815a3f135ec860439ab924701c69d5f1` | apache-2.0 |

ダウンロード URL は `https://huggingface.co/<repo>/resolve/<commit>/<file>` の形で commit 固定可能（HEAD 応答に `x-repo-commit`, `x-linked-size`, `x-linked-etag`(=sha256) が付く）。

---

## 4. Docker `ghcr.io/astral-sh/uv:0.12.13-python3.12-trixie-slim`
- **確認: タグ存在**。manifest index digest **`sha256:87bc72093c0aa93cc962bd7c0498ddf416dad3ce9e1434724e936e02b72afe5d`**、platforms linux/amd64 + linux/arm64（+ attestation）。ghcr 匿名トークンで `GET /v2/astral-sh/uv/manifests/<tag>` → 200。
- uv GitHub リリース: `0.12.13`（2026-09-10、commit `0ebbd9274a55a8a53a13970be3b97e4209598e17`）存在。**最新は `0.12.16`（2026-09-18）**。直近: 0.12.14 (09-15), 0.12.15 (09-15), 0.12.16 (09-18)。
- 0.12.13 の派生タグ（ghcr tags/list 全 7,859 件から抽出）: `0.12.13`, `-alpine`, `-alpine3.22/3.23`, `-debian`, `-debian-slim`, `-trixie`, `-trixie-slim`, `-python3.9〜3.14-{alpine,alpine3.23,trixie,trixie-slim,dhi}`, `-python3.15-rc-*`, `*-dhi` 等。**`-bookworm-slim` 系は 0.12.13 には無い**（manifest 404）。
- `0.12.16-python3.12-trixie-slim` = `python3.12-trixie-slim` = `sha256:4940ff16874f43a0abe9154a3cd7f71b84007d18c175cae3572d683889e51e18`。

---

## 5. SwiftPM（Swift 6.4 / Xcode 27.0 でローカル実験済み）

**前提の重要事実**: Swift 6.4 の `swift build` は **デフォルトのビルドシステムが `swiftbuild`**（`swift build --help`: "--build-system ... (default: swiftbuild)"、`native` は deprecated 警告が出る）。

### (a) `.treatAllWarnings(as: .error)` (SE-0480)
- **確認: 利用可能。`@available(_PackageDescription 6.2)` → `// swift-tools-version: 6.2` 以上が必要**。SwiftSetting / CSetting / CXXSetting にあり、`treatWarning(_:as:)`、C/C++ 用 `enableWarning` / `disableWarning` も。`WarningLevel` は `.warning` / `.error`。（ローカル `PackageDescription.swiftmodule/arm64-apple-macos.swiftinterface` L33-86, L953）
- SE-0480: Status Implemented (Swift 6.2)。"When a target is remote (pulled from a package dependency rather than defined in the local package), the warning control settings specified in the manifest do not apply to it. SwiftPM will strip all of the warning control flags for remote targets and substitute them with options for suppressing warnings." → **リモート依存には適用されない（自パッケージのターゲットのみ）**。`-Xswiftc` 等の CLI フラグはマニフェスト由来フラグの **後** に付く。 https://github.com/swiftlang/swift-evolution/blob/main/proposals/0480-swiftpm-warning-control.md
- 実験: tools 6.2 + `.treatAllWarnings(as: .error)` で未使用変数を入れると `error: initialization of variable 'unused' was never used` でビルド失敗（期待通り）。

### (b) `swift build -Xswiftc -warnings-as-errors` とリモート依存
- **実験で確認: Swift 6.4 では衝突しない**。Yams 6.2.2（リモート依存）を含むパッケージで `swift build -v -Xswiftc -warnings-as-errors` → exit 0。コンパイル行を確認すると **Yams には `-suppress-warnings` のみ**、自ターゲット App には `-warnings-as-errors` が付与。`--build-system native` でも同じ結果（exit 0）。
- SE-0480 本文は `-suppress-warnings` が他の warning 制御フラグと mutually exclusive である旨に言及（旧ツールチェーンでの衝突の背景）。Swift 6.4 では SwiftPM がリモートターゲットから除去するため問題なし。6.2 未満の挙動はここでは未検証。

### (c) Swift Testing のタグ指定フィルタ
- **Swift 6.4 / Xcode 27.0 同梱版では CLI からタグで絞り込めない（実験で確認）**: `swift test --skip tag:integration` → タグ付きテストが実行された（無効）。`swift test --filter tag:integration` → "No matching test cases were run"（正規表現として test ID にマッチさせただけ）。`--filter/--skip` は test ID に対する正規表現のみ。同梱 `Testing.framework` バイナリに `tag:` 文字列なし。
- swift-testing main には **2026-08-07 に `tag:` プレフィックス対応がマージ済み**（PR #1531 "Add ability to filter/skip by tags using a special `tag:` prefix", follow-up #1829）。`Sources/Testing/ABI/EntryPoints/EntryPoint.swift` の `enum FilterPrefix { case id = "id:"; case tag = "tag:" }`。**将来のツールチェーンで使える見込みだが、現行 Xcode 27.0 では不可**。
- 慣用的な代替（実験で確認）: `@Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_INTEGRATION"] == "1"))` → 未設定で skipped、`RUN_INTEGRATION=1 swift test` で実行。もしくは統合テストを別スイート/別テストターゲット名にして `--skip <regex>`（`swift test --skip integrationTest` で除外を確認）。

### (d) swift format
- **確認: ツールチェーン同梱**（`xcrun --find swift-format` → `.../XcodeDefault.xctoolchain/usr/bin/swift-format`、`swift format` サブコマンドで起動）。`swift format --version` は `main` と表示（数値バージョンなし）。
- **`swift format lint --strict --recursive <paths>` は正しい構文**（`-s, --strict: Treat all findings as errors instead of warnings`、`-r, --recursive`、`-p, --parallel`、`--configuration`）。違反あり＋`--strict` → exit 1、`--strict` なし → warning 表示で exit 0。
- **落とし穴**: 存在しないパスを渡しても **何も出力せず exit 0**（`swift format lint --strict --recursive /nonexistent_dir` → exit 0）。CI ではパスの存在を別途保証すること。

### (e) `swiftLanguageModes: [.v6]`
- **確認**: `Package.init(..., swiftLanguageModes: [SwiftLanguageMode]? ...)`（interface L361/363）。`swiftLanguageVersions` は `@available(_PackageDescription, deprecated: 6, renamed: "swiftLanguageModes")`。ターゲット単位は `.swiftLanguageMode(.v6)`（`@available(_PackageDescription 6.0)`）。実験パッケージで `swiftLanguageModes: [.v6]` → `-swift-version 6` が付与されることを確認。
- 参考: `SupportedPlatform.MacOSVersion` に `.v26`, `.v27` まである（Xcode 27 SDK）。

---

## 6. GRDB.swift / Yams
- **GRDB 最新: `v7.11.1`**（2026-06-18、commit `b83108d10f42680d78f23fe4d4d80fc88dab3212`）。`Package.swift@v7.11.1`: `swift-tools-version:6.1`、`swiftLanguageModes: [.v6]`、platforms macOS 10.15+。ライブラリ本体は Swift 6 言語モード（=完全な strict concurrency チェック）でビルドされる。テストターゲットのみ `.swiftLanguageMode(.v5)`。
- **backup API（v7.11.1 ソースで確認）**:
  - `DatabaseReader`（extension、`DatabasePool`/`DatabaseQueue` 共通）: `public func backup(to writer: any DatabaseWriter, pagesPerStep: CInt = -1, progress: ((DatabaseBackupProgress) throws -> Void)? = nil) throws`（`GRDB/Core/DatabaseReader.swift` L470）
  - `Database`: `public func backup(to destDb: Database, pagesPerStep: CInt = -1, progress: ...) throws`（`GRDB/Core/Database.swift` L1892）
  - → `try dbPool.backup(to: DatabaseQueue(path: backupPath))` の形で使用可。**パス/URL を直接受け取る backup API は無い**（宛先 DatabaseWriter を開く必要あり）。
- **Yams 最新: `6.2.2`**（2026-05-26、commit `a27b21e0c81c5bf42049b897a62aaf387e80f279`）。Package.swift は `swift-tools-version:5.7`。Swift 6.4 でビルド成功を実験で確認。

---

## 7. GitHub Actions ホストランナー（actions/runner-images main の README / 各 Readme）
| ラベル | 実体 | Xcode |
|---|---|---|
| `macos-latest`, `macos-26`, `macos-26-xlarge` | macOS 26.6.2 arm64（image 20260907.0351.1）| 26.6 (default), 26.5, 26.4.1, 26.3, 26.2, 26.1.1, 26.0.1 — **Xcode 27 なし** |
| `macos-26-intel`, `macos-26-large`, `macos-latest-large` | macOS 26 x64 | (arm64 版と同系列、詳細省略) |
| `macos-15`, `macos-15-xlarge` | macOS 15.7.9 arm64（image 20260907.0337.1）| 16.4 (default), 16.0〜16.3, 26.0.1〜26.3 |
| `macos-15-intel`, `macos-15-large` | macOS 15 x64 | |
| `macos-14`, `macos-14-xlarge`, `macos-14-large` | **deprecated**（2026-11-02 完全サポート終了予定、issue #13518）| |
| **`xcode-27`, `xcode-27-xlarge`** | **preview**。macOS 27.0 (26A5406e) arm64（2026-09-16 に base OS を macOS 27 へ変更、image 20260912.0186.1）| **27.0 (27A266a) のみ**、パス `/Applications/Xcode_27_Release_Candidate.app`（`Xcode.app` にシンボリックリンク）|

- ローカルの Xcode 27.0 (27A266a) と `xcode-27` ランナーのビルド番号は一致。preview のためキュー待ちや不安定性の注意書きあり（issue #14404）。
- ソース: https://github.com/actions/runner-images/blob/main/README.md , `images/macos/macos-26-arm64-Readme.md`, `macos-15-arm64-Readme.md`, `xcode-27-arm64-Readme.md`, https://github.com/actions/runner-images/issues/14404
- **actions/checkout**: 最新 `v7.0.1`（2026-07-20）、SHA **`3d3c42e5aac5ba805825da76410c181273ba90b1`**（`v7` タグも同 SHA）。v7.0.0 で ESM 移行、`pull_request_target`/`workflow_run` でのフォーク PR checkout ブロック。
- **actions/cache**: 最新 `v6.1.0`（2026-06-26）、SHA **`55cc8345863c7cc4c66a329aec7e433d2d1c52a9`**（`v6` タグも同 SHA）。

---

## 8. Apple API（macOS 27.0 SDK ヘッダ / Apple Docs JSON）
- **`SMAppService.mainApp`**: 確認。`@property (class, readonly) SMAppService *mainAppService NS_SWIFT_NAME(mainApp) API_AVAILABLE(macos(13.0), macCatalyst(16.0));`（`ServiceManagement.framework/Headers/SMAppService.h` L91）
- **`NSApp.activate()`（引数なし）**: 確認。`- (void)activate API_AVAILABLE(macos(14.0));`（`NSApplication.h` L236）。`activateIgnoringOtherApps:` は `API_DEPRECATED("... Use NSApp.activate instead.", macos(10.0, API_TO_BE_DEPRECATED))`。
- **`NSRemovableVolumesUsageDescription`**: 確認。macOS 10.15+。Apple Docs: "The first time your app tries to access a file on a removable volume without implied user consent, the system prompts the user for permission to access removable volumes." Open/Save パネル選択・ドラッグ・Finder で開く、またはアプリが作成したファイルは暗黙の同意扱い。"The usage description is optional, but highly recommended." リセットは `tccutil`。（`https://developer.apple.com/tutorials/data/documentation/bundleresources/information-property-list/nsremovablevolumesusagedescription.json`）
- **非サンドボックスアプリでも TCC プロンプトが出るか**: Apple Docs の記述はサンドボックスに限定していない。Apple DTS (Quinn) は「10.15 以降は（非サンドボックスでも）追加のアクセス制御がある」「TCC は許可を記録するため安定した署名が必要」と回答（https://developer.apple.com/forums/thread/663889）。TCC サービス名は `kTCCServiceSystemPolicyRemovableVolumes`（Files and Folders > Removable Volumes、Catalina で導入: https://eclecticlight.co/2020/01/16/a-guide-to-catalinas-privacy-protection-3-new-protected-locations/ ）。→ **非サンドボックスでもプロンプト対象（ドキュメント＋DTS 回答ベース。本環境での実機確認は未実施）**。ad-hoc 署名（SwiftPM 素ビルド）だとビルド毎に TCC 許可が外れうる点に注意（DTS の「安定した署名が必要」より）。
- **`SecStaticCodeCheckValidity` + `kSecCSCheckAllArchitectures`**: 確認。`OSStatus SecStaticCodeCheckValidity(SecStaticCodeRef, SecCSFlags, SecRequirementRef __nullable)`（`SecStaticCode.h` L195）、`kSecCSCheckAllArchitectures = 1 << 0`（L176、"For multi-architecture (universal) Mach-O programs, validate all architectures"）。関連: `kSecCSStrictValidate = 1<<4`, `kSecCSCheckNestedCode = 1<<3`, `kSecCSCheckGatekeeperArchitectures = (1<<6)|kSecCSCheckAllArchitectures`, `SecStaticCodeCheckValidityWithErrors`。
- **`diskutil mount readOnly <device>`**: 確認。usage: `diskutil mount [readOnly] [nobrowse] [-mountOptions Opt[,Opt]*] [-mountPoint Path] DiskIdentifier|DeviceNode`。man: "If readOnly is specified, then the file system is mounted read-only ... equivalent to passing rdonly ... as -o arguments"。例: `diskutil mount readOnly disk4s1`（`/dev/disk4s1` も可）。（ローカル `diskutil mount` / `man diskutil`）

---

## 9. DJI Mic 3
| 項目 | 結果 | ソース |
|---|---|---|
| 内蔵ストレージ | 32 GB（外部ストレージ非対応）| DJI サポート FAQ https://www.dji.com/support/product/mic-3 |
| 形式 | WAV（24-bit / 32-bit float どちらも WAV）| FAQ https://www.dji.com/mic-3/faq |
| サンプルレート | **48 kHz** | Specs https://www.dji.com/mic-3/specs |
| ビット深度 | **32-bit float / 24-bit 切替式**（設定 "32-Bit Float Recording"）。どちらか一方ではない | Specs, User Manual p.13 |
| 録音時間 | 24-bit 単一 57.3h / デュアル 28.6h、32-bit float 単一 43.0h / デュアル 21.5h | Specs/FAQ |
| ファイル名 | 例 **`TX01_MIC002_20250527_202904_orig.wav`**。TX01 = 受信機がペアリング順で割り当てる送信機番号、`orig` = 未処理原音、`edit` = アルゴリズム処理版（デュアルファイル時に両方）| FAQ |
| フォルダ名 | 例 **`TX_MIC001_20250530_115001`**（TX=送信機内部収録、MIC001=フォルダ連番、**50 ファイル毎に新フォルダ**、日時=フォルダ作成時刻）| サポート FAQ |
| 分割 | 内部収録中 **30 分ごとにファイル保存**。Loop Recording 有効時は満杯で上書き | FAQ, User Manual |
| 取り出し | 送信機を磁気充電ケーブルで PC に接続、または充電ケースに入れてデータケーブルで接続（有線）、または DJI Mimo | FAQ, User Manual https://dl.djicdn.com/downloads/DJI%20Mic%203/20250828/UM/DJI_Mic_3_User_Manual_EN.pdf |
| **ファイルシステム (FAT32/msdos vs exFAT)** | **未確認**（公式 Specs/FAQ/User Manual に記載なし、コミュニティ情報でも確認できず）| — |
| **既定ボリューム名** | **未確認** | — |

→ 実装上は FS 種別 (`msdos`/`exfat`) とボリューム名に依存せず、`TX_MIC\d{3}_\d{8}_\d{6}/TX\d{2}_MIC\d{3}_\d{8}_\d{6}_(orig|edit)\.wav` のような構造で検出するのが安全。実機を Mac に接続して `diskutil info` で確認することを推奨。

---

## 付録: 実行した主なコマンド
- `gh api repos/ggml-org/whisper.cpp/{releases,git/refs/tags/v1.9.4,contents/...?ref=v1.9.4}`
- `gh api repos/ggml-org/llama.cpp/{releases,releases/latest,git/matching-refs/tags/v,contents/...?ref=b11033}`、release tarball DL → `llama-server --help/--version`
- `curl https://huggingface.co/api/models/<repo>?blobs=true`、`curl -I .../resolve/main/<file>`
- ghcr: `curl 'https://ghcr.io/token?scope=repository:astral-sh/uv:pull'` → `/v2/astral-sh/uv/manifests/<tag>`, `/v2/astral-sh/uv/tags/list`
- SwiftPM 実験パッケージ（scratchpad/spmtest）: `swift build [-v] [-Xswiftc -warnings-as-errors] [--build-system native]`, `swift test [--filter|--skip] ...`, `swift format lint --strict --recursive`
- SDK ヘッダ grep（MacOSX27.0.sdk）、`diskutil mount`, `man diskutil`
