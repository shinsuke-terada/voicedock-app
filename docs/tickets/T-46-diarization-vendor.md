# T-46 話者分離の外部バイナリとモデル（argmax-cli・SpeakerModels の同梱）

| 項目 | 値 |
|---|---|
| ID | T-46 |
| Phase | 8.5（話者分離。F-89） |
| 前提 | T-03（`Vendor/` の型と `check-linkage.sh`）、T-34（`make-app.sh`・`sign.sh`・`verify-bundle.sh`・`bundle-manifest.txt`） |
| 見積もり | スクリプト 約 150 行、Tests 約 80 行、fixture 1 本 |

## 1. 目的

話者分離（PLAN §8.4.1）で起動する `argmax-cli`（Argmax SpeakerKit の CLI）を、whisper-cli と同じようにソースからビルドして `Contents/Helpers/` に置く。
モデル（pyannote community-1 の CoreML 版、20 ファイル・13 MB）を固定したコミットから取り、sha256 を照合して `Contents/Resources/SpeakerModels/` に同梱する。Swift のコードは変えない。

## 2. 参照

- PLAN §3.3（argmax-oss-swift・話者分離のモデルの行）、§11.1、§11.2（話者分離の段落）、§8.4.1（argv）
- docs/POC.md 16 章（P0-13。ビルドのコマンド・`otool -L`・20 ファイルの sha256・`--help`）
- `Vendor/build-whisper.sh`（同じ手順の型）

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Vendor/versions.env`（変更） | `ARGMAX_OSS_REPO`・`ARGMAX_OSS_REF`・`ARGMAX_OSS_SHA`・`SPEAKER_MODELS_REPO`・`SPEAKER_MODELS_SHA` を足す |
| `Vendor/build-argmax.sh` | argmax-cli のビルド |
| `Vendor/fetch-speaker-models.sh` | モデルの取得と照合 |
| `Vendor/speaker-models.sha256` | 20 ファイルの `<sha256>  <相対パス>` |
| `Vendor/speaker-models-NOTICE.txt` | 出典（CC-BY-4.0）。`SpeakerModels/NOTICE.txt` として同梱する |
| `Tests/Fixtures/argmax-cli-diarize-help.txt` | `argmax-cli diarize --help` の出力（`--update-fixtures` で書く） |
| `Makefile`（変更） | `vendor` に 2 本を足す |
| `scripts/make-app.sh`（変更） | argmax-cli と SpeakerModels を入れる |
| `scripts/sign.sh`（変更） | argmax-cli を署名する |
| `scripts/verify-bundle.sh`（変更） | V-3 / V-4 の Mach-O に argmax-cli を足す |
| `Resources/bundle-manifest.txt`（変更） | argmax-cli・SpeakerModels の 21 ファイルを足す（辞書順） |
| `Tests/PolicyTests/ReleaseBundleTests.swift`（変更） | ヘルパーを 4 本に、SpeakerModels の検査を足す |

## 4. 仕様

### 4.1 `Vendor/versions.env` に足す行（そのまま）

```bash
ARGMAX_OSS_REPO=https://github.com/argmaxinc/argmax-oss-swift.git
ARGMAX_OSS_REF=v1.1.0
ARGMAX_OSS_SHA=1e2a163736dfa5a198e637ae44c114e1c6d5cc2d
SPEAKER_MODELS_REPO=argmaxinc/speakerkit-coreml
SPEAKER_MODELS_SHA=556fc52a13327837688f02289457cded017802e9
```

### 4.2 `Vendor/build-argmax.sh`

`build-whisper.sh` と同じ形（`set -euo pipefail`、`--update-fixtures` の引数、`work/argmax-oss-swift` に clone → `git rev-parse HEAD` を `ARGMAX_OSS_SHA` と照合、違えば `ERROR: argmax-oss-swift $ARGMAX_OSS_REF のコミットが違います（期待 …、実際 …）` で 1）。cmake の代わりに:

```bash
swift build --package-path "$work" -c release --product argmax-cli --arch arm64
built="$(swift build --package-path "$work" -c release --arch arm64 --show-bin-path)/argmax-cli"
install -m 0755 "$built" "$out/argmax-cli"
"$here/check-linkage.sh" "$out/argmax-cli"
help="$("$out/argmax-cli" diarize --help 2>&1 || true)"
for flag in --audio-path --model-path --rttm-path --use-exclusive-reconciliation; do
  grep -qE -- "(^|[[:space:],\[])${flag}([[:space:],=\]]|$)" <<<"$help" || { echo "ERROR: argmax-cli diarize --help に $flag がありません" >&2; exit 1; }
done
```

- `--update-fixtures` なら `printf '%s\n' "$help" | sed "s|$out/||g" > "$root/Tests/Fixtures/argmax-cli-diarize-help.txt"`（`更新: Tests/Fixtures/argmax-cli-diarize-help.txt`）
- 最後に `OK: $out/argmax-cli ($ARGMAX_OSS_REF $actual)`
- `--show-bin-path` の場所に無ければ（P0-13 では `.build/out/Products/Release/` に出た）`find "$work/.build" -name argmax-cli -type f -perm +111` の最初の 1 つを使い、それも無ければ `ERROR: argmax-cli のビルド成果物が見つかりません` で 1

### 4.3 `Vendor/fetch-speaker-models.sh`

1. `versions.env` を読む。出力先 `out="$here/build/SpeakerModels"`。作業は `"$here/work/SpeakerModels.tmp"`（先に `rm -rf`）
2. `Vendor/speaker-models.sha256` の各行（`<sha256>  <相対パス>`。`#` と空行は飛ばす）について `curl -fsSL --retry 3 -o "<tmp>/<path>" "https://huggingface.co/$SPEAKER_MODELS_REPO/resolve/$SPEAKER_MODELS_SHA/<path>"`（親ディレクトリは `mkdir -p`）
3. `(cd "$tmp" && shasum -a 256 -c "$here/speaker-models.sha256")` が通らなければ `ERROR: 話者分離のモデルの sha256 が一致しません` で `rm -rf "$tmp"` して 1
4. `install -m 0644 "$here/speaker-models-NOTICE.txt" "$tmp/NOTICE.txt"`、`rm -rf "$out" && mv "$tmp" "$out"`、`OK: $out（20 ファイル）`
5. 既に `$out` が在り `shasum -c` が通るならダウンロードしない（`OK: $out（取得済み）`）

### 4.4 `Vendor/speaker-models.sha256`

docs/POC.md 16.2 の 20 行（`./` を外した相対パス、辞書順、区切りは空白 2 つ）。値は P0-13 の実測:

```text
3e13c8f4df77ea27cbbcdd6d083c63f5e7b3f32566cc5bf223fab92d40b81b8b  speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/analytics/coremldata.bin
6f6820ccf221d4cc7c107101d0ae4d716eb224e4fdffaf8f7ca36af70ae64c40  speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/coremldata.bin
acc86b4a4f542d8e7eaf84fc290fe72bd8629b0ffcc16e5b1a9e13d777abd9d8  speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/metadata.json
209e641bf4d9c3868c9dc43ab8705094997917eb2df5f5d8c8fda09fed54b1d4  speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/model.mil
a1dbbb651a0a67fcfe5334672f459df090fa960917a6ee3a5423245a7ab92ced  speaker_clusterer/pyannote-v4/W32A32/PldaProjector.mlmodelc/weights/weight.bin
ba8405dfc9b9348ade705e052888b4bdc7fb8d079ef3ff71108a5f692d0209f2  speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/analytics/coremldata.bin
1597d6c037ac52436b5c2e1abc47e6c68483c19eeac75267dfb8795a78ec07c5  speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/coremldata.bin
29ea3421161c8344f6ea95db9b472217638a869f686f2494d10e5d11f11f4cda  speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/metadata.json
5eee9f6aa380aef88fee604d75c5deaa23adc83c9480cb8f6dedc72803973e77  speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/model.mil
a02861969f47cf3a67e3b0d276e54b3c8bc3a6e43d40d77d1cccbd57da0e5795  speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc/weights/weight.bin
ce9bef9fb3125a5401300b5c5998c5d8f211094692cae780645d3e2757410f2c  speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/analytics/coremldata.bin
b4ebd0b9ce5a84768672663aff426eb19f9648d4b9f74286f0e19fc753ad76ba  speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/coremldata.bin
789f81c17dc04d469611d253684e534565fb4a008e54c722b925f1608bf87fce  speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/metadata.json
42e552ebd7efb12ea813eceb474018dd0f46168e84ad3a1c54945bfc47be7a82  speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/model.mil
5f2c284bd22f1f7ab76901c1c6e57f82d4ebbf057fa0b924aad057f124f77a89  speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc/weights/weight.bin
40637aa0cb2a073bc303c7ca9ee79da35fa81d2cad1ead180e93b134005b95de  speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/analytics/coremldata.bin
6c356ed983b2a3332ce51299ca0f9747a35cb6c2a67b0ac24c69dbef3f989634  speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/coremldata.bin
2fd6aaf6beb17b3758f5d0c5b2cf5feeacb0cc0c9267dbcd7536b247b1a5860e  speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/metadata.json
423c358915acab0d440c99f5162c17456936c2c02f7394b05ab226b9a34c122a  speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/model.mil
75ff1725ef4e58dacf9176466ec274a8a13a6132c296d6b571fb78ddad5455c4  speaker_segmenter/pyannote-v3/W8A16/SpeakerSegmenter.mlmodelc/weights/weight.bin
```

先頭に注釈 2 行（`# 話者分離のモデル（PLAN §3.3・§11.2。F-89）。argmaxinc/speakerkit-coreml@556fc52…の 20 ファイル。` と `# 更新は手動の PR だけで行う。`）。`shasum -c` は `#` の行を無視しないので、スクリプトは照合の前に `grep -v '^#' | grep -v '^$'` した一時ファイルを使う。

### 4.5 `Vendor/speaker-models-NOTICE.txt`（逐語）

```text
VoiceDock の話者分離のモデル

このフォルダのモデルは、pyannote.audio の speaker-diarization-community-1（pyannoteAI、CC-BY-4.0）を
Argmax, Inc. が Core ML に変換したもの（https://huggingface.co/argmaxinc/speakerkit-coreml、CC-BY-4.0）です。
コミット 556fc52a13327837688f02289457cded017802e9 の speaker_segmenter/pyannote-v3/W8A16、
speaker_embedder/pyannote-v3/W8A16、speaker_clusterer/pyannote-v4/W32A32 を変更せずに同梱しています。

ライセンス: Creative Commons Attribution 4.0 International（https://creativecommons.org/licenses/by/4.0/）
実行ファイル argmax-cli: argmax-oss-swift v1.1.0（MIT、https://github.com/argmaxinc/argmax-oss-swift）
```

### 4.6 `Makefile` の `vendor`

```make
vendor:
	$(call require_script,Vendor/build-whisper.sh,T-03)
	$(call require_script,Vendor/build-llama.sh,T-03)
	$(call require_script,Vendor/build-argmax.sh,T-46)
	$(call require_script,Vendor/fetch-speaker-models.sh,T-46)
	Vendor/build-whisper.sh
	Vendor/build-llama.sh
	Vendor/build-argmax.sh
	Vendor/fetch-speaker-models.sh
```

### 4.7 `scripts/make-app.sh`

- 手順 2 の `for tool in whisper-cli llama-server` を `whisper-cli llama-server argmax-cli` にする。続けて `[ -f "$root/Vendor/build/SpeakerModels/NOTICE.txt" ] || { echo "ERROR: Vendor/build/SpeakerModels がありません（make vendor を先に実行してください）" >&2; exit 1; }`
- 手順 3 で `install -m 0755 "$root/Vendor/build/bin/argmax-cli" "$app/Contents/Helpers/argmax-cli"`、`ditto "$root/Vendor/build/SpeakerModels" "$app/Contents/Resources/SpeakerModels"`（`ditto` は拡張属性を落とさないので、続けて `xattr -cr "$app/Contents/Resources/SpeakerModels"`）

### 4.8 `scripts/sign.sh` と `scripts/verify-bundle.sh`

- `sign.sh`: `for tool in whisper-cli llama-server argmax-cli`（hardened runtime、エンタイトルメントなし。CoreML は特別な権限を要らない）
- `verify-bundle.sh` の V-3: `machos` に `"$app/Contents/Helpers/argmax-cli"` を足す（V-4 は同じ配列を使う）

### 4.9 `Resources/bundle-manifest.txt`

`Contents/Helpers/argmax-cli` と、`Contents/Resources/SpeakerModels/NOTICE.txt` と 20 ファイル（`Contents/Resources/SpeakerModels/<4.4 の相対パス>`）を、既存の並び（Unicode スカラーの辞書順）を保って足す。

## 5. テスト

`Tests/PolicyTests/ReleaseBundleTests.swift`（変更・追加）:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `manifestListsTheFourHelpers`（`manifestListsTheThreeHelpers` を置き換え） | 許可リストにヘルパー 4 本が在る | manifest | whisper-cli・llama-server・voicedock-reaper・argmax-cli を含み、`Contents/Helpers/` の行はちょうど 4 |
| `manifestListsEverySpeakerModelFile` | 許可リストの SpeakerModels が speaker-models.sha256 と NOTICE に一致 | `Vendor/speaker-models.sha256` の注釈でない行のパス | `Contents/Resources/SpeakerModels/` の行の集合 = 20 のパス + `NOTICE.txt`（21 行） |
| `speakerModelHashesAreWellFormed` | speaker-models.sha256 は 20 行で、各行が 64 桁の小文字 16 進と相対パス | ファイル | 20 行。各行 `^[0-9a-f]{64}  [^/][^ ]*$`、`..` を含まない |
| `speakerModelsArePinnedToACommit` | versions.env の SPEAKER_MODELS_SHA と ARGMAX_OSS_SHA は 40 桁 | `Vendor/versions.env` | どちらも `^[0-9a-f]{40}$` |
| `argmaxHelpFixtureHasTheFlags` | argmax-cli の --help の fixture に 4 つのフラグが在る | `Tests/Fixtures/argmax-cli-diarize-help.txt` | `--audio-path`・`--model-path`・`--rttm-path`・`--use-exclusive-reconciliation` を含む |
| `emptyManifestSectionIsRejected` | SpeakerModels の行が 0 のとき検査が落ちる（TEST-28） | 空の配列を検査の関数に渡す | 不一致を報告する |

既存の「組み立てが許可リストの各ファイルを作る」は argmax-cli と SpeakerModels の行も対象になる（make-app.sh の文言で確かめている形に合わせて直す）。

## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| `bundle-manifest.txt` から `Contents/Helpers/argmax-cli` を消す | `manifestListsTheFourHelpers` |
| `bundle-manifest.txt` から SpeakerModels の 1 行を消す | `manifestListsEverySpeakerModelFile` |
| `speaker-models.sha256` の 1 行の sha256 を 63 桁にする | `speakerModelHashesAreWellFormed` |
| fixture から `--model-path` を消す | `argmaxHelpFixtureHasTheFlags` |
| `versions.env` の `SPEAKER_MODELS_SHA` を `main` にする | `speakerModelsArePinnedToACommit` |

## 7. 受け入れ条件

- [ ] `make vendor` が通り、`Vendor/build/bin/argmax-cli` と `Vendor/build/SpeakerModels/`（20 ファイル + NOTICE.txt）ができる
- [ ] `Vendor/check-linkage.sh Vendor/build/bin/argmax-cli` が 0
- [ ] `make app` の後の `scripts/verify-bundle.sh --files-only` が通る（V-1 の許可リスト・V-3・V-4）
- [ ] `sandbox-exec`（`(deny network*)`）の下で、同梱の argmax-cli が同梱のモデルで短い WAV を分けられる（手で 1 回。PR 本文に出力を貼る）
- [ ] `make lint && make test` が通る

## 8. SPEC の変更

なし

## 9. マージ後にやること

- 開発機で `make vendor && make app` を回し直す（`dist/VoiceDock.app` に argmax-cli とモデルが入る）
