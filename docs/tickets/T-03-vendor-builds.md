# T-03 whisper.cpp / llama.cpp のビルド（Vendor）

| 項目 | 値 |
|---|---|
| ID | T-03 |
| 題 | Vendor のビルドスクリプト（whisper / llama）と versions.env、`--help` の fixture |
| Phase | 1 |
| 前提 | T-01 |
| 見積もり | 約 250 行（スクリプト 3 本 約 130、versions.env 10、テスト約 80、fixture は生成物で数えない） |

## 目的

アプリに同梱する `whisper-cli` と `llama-server` を、固定した版のソースから同じ手順でビルドできるようにする。
リリースのバイナリは使わない（dylib 構成・ad-hoc 署名のため。PLAN §11.2）。ダウンロード能力（HTTPS）を持たないビルドにする。

## 参照

- PLAN §3.3（whisper.cpp v1.9.4・llama.cpp b11033 とコミット）、§8.4（whisper の argv）、§8.5（llama-server のフラグ・`LLAMA_OPENSSL=OFF`・`--offline`）、§11.2（ビルドの引数・`otool -L`）
- voicedock@d3d595e `Dockerfile`（whisper.cpp のビルド引数。CPU 版）
- 外部の事実（2026-09-18 の調査）: whisper.cpp `v1.9.4` は注釈付きタグで、タグのオブジェクトは `7d75b149…`、**コミットは `927cfce34f31707e17f2bff35c349632fb9e2c3a`**。`BUILD_SHARED_LIBS` の既定は ON なので OFF を明示する。`WHISPER_BUILD_SERVER` は何も切り替えないので、ビルドは `--target whisper-cli` で絞る。
  llama.cpp `b11033`（コミット `8ed1a55efcd7424d2c592f6cbc9f97756db1d74d`）では `LLAMA_CURL` は廃止済みで無視され、`LLAMA_OPENSSL` の既定は ON（HTTPS のダウンロード用）、`LLAMA_USE_PREBUILT_UI` の既定は ON（ビルド中に HF から UI を取得）、server には `LLAMA_BUILD_TOOLS=ON` が要る

## 作るもの

| パス | 内容 |
|---|---|
| `Vendor/versions.env` | 下記の全文 |
| `Vendor/build-whisper.sh` | 下記の全文（実行権 0755） |
| `Vendor/build-llama.sh` | 下記の全文（実行権 0755） |
| `Vendor/check-linkage.sh` | 下記の全文（実行権 0755。T-34 の `verify-bundle.sh` も使う） |
| `Tests/Fixtures/whisper-cli-help.txt` | `build-whisper.sh --update-fixtures` の出力（生成物。コミットする） |
| `Tests/Fixtures/llama-server-help.txt` | `build-llama.sh --update-fixtures` の出力（生成物。コミットする） |
| `Tests/PolicyTests/VendorFixtureTests.swift` | 下記の全文 |

## 仕様

### 1. `Vendor/versions.env`（全文）

```bash
# 外部バイナリの版（PLAN §3.3・§11.2）。更新は手動の PR だけで行う。
# *_SHA は注釈付きタグを剥がしたコミット（git rev-parse <tag>^{commit}）。タグのオブジェクトの SHA を書かない。
WHISPER_CPP_REPO=https://github.com/ggml-org/whisper.cpp.git
WHISPER_CPP_REF=v1.9.4
WHISPER_CPP_SHA=927cfce34f31707e17f2bff35c349632fb9e2c3a
LLAMA_CPP_REPO=https://github.com/ggml-org/llama.cpp.git
LLAMA_CPP_REF=b11033
LLAMA_CPP_SHA=8ed1a55efcd7424d2c592f6cbc9f97756db1d74d
```

- P0 の章 14 で llama.cpp の版を変えた場合は、その版の REF と SHA を書く（SHA は `git ls-remote https://github.com/ggml-org/llama.cpp.git "refs/tags/<REF>^{}"`、無ければ `refs/tags/<REF>` の値）
- 形式の検査は T-04 の PT-13（REF はタグ、SHA は 40 桁の小文字 16 進）

### 2. `Vendor/check-linkage.sh`（全文）

```bash
#!/bin/bash
# Mach-O が /usr/lib と /System/Library 以外にリンクしておらず、libcurl・libssl・libcrypto も使っていないことを確かめる（PLAN §11.2）。
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "使い方: $0 <Mach-O> [<Mach-O>...]" >&2
  exit 2
fi

status=0
for bin in "$@"; do
  if [ ! -f "$bin" ]; then
    echo "ERROR: $bin がありません" >&2
    status=1
    continue
  fi
  while IFS= read -r lib; do
    case "$lib" in
      *libcurl*|*libssl*|*libcrypto*)
        echo "ERROR: $bin がネットワーク用のライブラリにリンクしています: $lib" >&2
        status=1
        ;;
      /usr/lib/*|/System/Library/*)
        ;;
      *)
        echo "ERROR: $bin が許されない場所のライブラリにリンクしています: $lib" >&2
        status=1
        ;;
    esac
  done < <(otool -L "$bin" | tail -n +2 | awk '{ print $1 }')
done
exit "$status"
```

- `otool -L` の 1 行目は対象のファイル名なので `tail -n +2` で飛ばす
- `@rpath/…` や `/opt/homebrew/…` は「許されない場所」に当たる

### 3. `Vendor/build-whisper.sh`（全文）

```bash
#!/bin/bash
# whisper.cpp を versions.env の版からソースでビルドする（PLAN §11.2）。成果物は Vendor/build/bin/whisper-cli。
# 使い方: Vendor/build-whisper.sh [--update-fixtures]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/.." && pwd -P)"
# shellcheck source=versions.env
source "$here/versions.env"

update_fixtures=0
case "${1:-}" in
  "") ;;
  --update-fixtures) update_fixtures=1 ;;
  *) echo "使い方: $0 [--update-fixtures]" >&2; exit 2 ;;
esac

command -v cmake >/dev/null || { echo "ERROR: cmake がありません（brew install cmake）" >&2; exit 1; }

work="$here/work/whisper.cpp"
out="$here/build/bin"
rm -rf "$work"
mkdir -p "$here/work" "$out"

git clone --quiet --depth 1 --branch "$WHISPER_CPP_REF" "$WHISPER_CPP_REPO" "$work"
actual="$(git -C "$work" rev-parse HEAD)"
if [ "$actual" != "$WHISPER_CPP_SHA" ]; then
  echo "ERROR: whisper.cpp $WHISPER_CPP_REF のコミットが違います（期待 ${WHISPER_CPP_SHA}、実際 ${actual}）" >&2
  exit 1
fi

cmake -S "$work" -B "$work/build" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_EXAMPLES=ON \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build "$work/build" --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)"

install -m 0755 "$work/build/bin/whisper-cli" "$out/whisper-cli"
"$here/check-linkage.sh" "$out/whisper-cli"

help="$("$out/whisper-cli" --help 2>&1 || true)"
for flag in --vad --vad-model --vad-threshold --vad-min-speech-duration-ms --vad-min-silence-duration-ms --vad-speech-pad-ms; do
  grep -qE -- "(^|[[:space:],])${flag}([[:space:],=]|$)" <<<"$help" || { echo "ERROR: whisper-cli --help に $flag がありません" >&2; exit 1; }
done

if [ "$update_fixtures" -eq 1 ]; then
  mkdir -p "$root/Tests/Fixtures"
  # ビルド先の絶対パス（usage 行の $0）を落とし、どこでビルドしても同じ fixture にする
  printf '%s\n' "$help" | sed "s|$out/||g" > "$root/Tests/Fixtures/whisper-cli-help.txt"
  echo "更新: Tests/Fixtures/whisper-cli-help.txt"
fi
echo "OK: $out/whisper-cli ($WHISPER_CPP_REF $actual)"
```

### 4. `Vendor/build-llama.sh`（全文）

```bash
#!/bin/bash
# llama.cpp の llama-server を versions.env の版からソースでビルドする（PLAN §11.2）。成果物は Vendor/build/bin/llama-server。
# HTTPS（モデルのダウンロード）を持たないビルドにする: LLAMA_OPENSSL=OFF、ビルド中の UI の取得もしない: LLAMA_USE_PREBUILT_UI=OFF。
# 使い方: Vendor/build-llama.sh [--update-fixtures]
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/.." && pwd -P)"
# shellcheck source=versions.env
source "$here/versions.env"

update_fixtures=0
case "${1:-}" in
  "") ;;
  --update-fixtures) update_fixtures=1 ;;
  *) echo "使い方: $0 [--update-fixtures]" >&2; exit 2 ;;
esac

command -v cmake >/dev/null || { echo "ERROR: cmake がありません（brew install cmake）" >&2; exit 1; }

work="$here/work/llama.cpp"
out="$here/build/bin"
rm -rf "$work"
mkdir -p "$here/work" "$out"

git clone --quiet --depth 1 --branch "$LLAMA_CPP_REF" "$LLAMA_CPP_REPO" "$work"
actual="$(git -C "$work" rev-parse HEAD)"
if [ "$actual" != "$LLAMA_CPP_SHA" ]; then
  echo "ERROR: llama.cpp $LLAMA_CPP_REF のコミットが違います（期待 ${LLAMA_CPP_SHA}、実際 ${actual}）" >&2
  exit 1
fi

cmake -S "$work" -B "$work/build" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build "$work/build" --config Release --target llama-server -j "$(sysctl -n hw.ncpu)"

install -m 0755 "$work/build/bin/llama-server" "$out/llama-server"
"$here/check-linkage.sh" "$out/llama-server"

help="$("$out/llama-server" --help 2>&1 || true)"
for flag in --model --host --port --api-key-file --ctx-size --n-gpu-layers --jinja --parallel --no-webui --offline; do
  grep -qE -- "(^|[[:space:],])${flag}([[:space:],=]|$)" <<<"$help" || { echo "ERROR: llama-server --help に $flag がありません" >&2; exit 1; }
done

if [ "$update_fixtures" -eq 1 ]; then
  mkdir -p "$root/Tests/Fixtures"
  # ビルド先の絶対パス（usage 行の $0）を落とし、どこでビルドしても同じ fixture にする
  printf '%s\n' "$help" | sed "s|$out/||g" > "$root/Tests/Fixtures/llama-server-help.txt"
  echo "更新: Tests/Fixtures/llama-server-help.txt"
fi
echo "OK: $out/llama-server ($LLAMA_CPP_REF $actual)"
```

- `--help` の出力には機械ごとに変わる既定値（スレッド数など）が入るので、fixture は `--update-fixtures` を付けたときだけ書く（毎回の `make vendor` で差分を出さない）。fixture を更新するのは「版を上げる PR」だけ
- 変数の直後に全角文字が続くところは `${…}` で囲む。macOS の `/bin/bash` 3.2 は `$actual）` の全角文字の先頭バイトを変数名の一部として読み、`set -u` の下で `unbound variable` になる（「コミットが違います」が出ずに落ちる。T-03 の破壊による証明で見つけた）
- ビルドに使った cmake の版は PR 本文に貼る（`cmake --version`）。cmake の版は固定しない（Homebrew の最新でよい）が、記録は残す

### 5. `Tests/PolicyTests/VendorFixtureTests.swift`（全文）

```swift
// Vendor の --help の fixture に、アプリが渡すフラグがすべて在ることの検査（PLAN §8.4・§8.5・§11.2。T-03）。
import Foundation
import TestSupport
import Testing

@Suite("VendorFixture")
struct VendorFixtureTests {
    /// whisper-cli に渡すフラグ（PLAN §8.4 の argv）。T-17 で `WhisperHelpCheck.vadFlags` と argv の組み立てに置き換える。
    static let whisperFlags = [
        "-m", "-f", "-l", "-t", "--vad", "--vad-model", "--vad-threshold", "--vad-min-speech-duration-ms",
        "--vad-min-silence-duration-ms", "--vad-speech-pad-ms", "-oj", "-of", "-np",
    ]

    /// llama-server に渡すフラグ（PLAN §8.5）。T-21 で `LlamaArgs.usedFlags` に置き換える。
    static let llamaFlags = [
        "--model", "--host", "--port", "--api-key-file", "--ctx-size", "--n-gpu-layers", "--jinja",
        "--parallel", "--no-webui", "--offline",
    ]

    /// `flag` が help の中に「前後が空白・カンマ・行頭行末・=」で区切られた語として在るか。
    static func contains(_ help: String, flag: String) throws -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: flag)
        let regex = try NSRegularExpression(pattern: "(^|[\\s,])\(escaped)([\\s,=]|$)", options: [.anchorsMatchLines])
        return regex.firstMatch(in: help, range: NSRange(location: 0, length: help.utf16.count)) != nil
    }

    @Test("whisper-cli の --help に argv のフラグがすべて在る", arguments: whisperFlags)
    func whisperHelpHasFlag(_ flag: String) throws {
        let help = try String(contentsOf: PackageRoot.file("Tests/Fixtures/whisper-cli-help.txt"), encoding: .utf8)
        #expect(try Self.contains(help, flag: flag))
    }

    @Test("llama-server の --help に使うフラグがすべて在る", arguments: llamaFlags)
    func llamaHelpHasFlag(_ flag: String) throws {
        let help = try String(contentsOf: PackageRoot.file("Tests/Fixtures/llama-server-help.txt"), encoding: .utf8)
        #expect(try Self.contains(help, flag: flag))
    }

    @Test("フラグの判定は語の一部に一致しない")
    func flagMatchIsWholeWord() throws {
        #expect(try Self.contains("  --vad-model FNAME  path", flag: "--vad-model"))
        #expect(try !Self.contains("  --vad-model-x FNAME", flag: "--vad-model"))
        #expect(try Self.contains("  -m FNAME, --model FNAME", flag: "--model"))
        #expect(try !Self.contains("  --no-models", flag: "--model"))
    }

    @Test("versions.env に 6 つのキーがすべて在る")
    func versionsEnvHasAllKeys() throws {
        let text = try String(contentsOf: PackageRoot.file("Vendor/versions.env"), encoding: .utf8)
        let keys = text.split(separator: "\n")
            .filter { !$0.hasPrefix("#") && $0.contains("=") }
            .map { String($0.prefix { $0 != "=" }) }
        #expect(
            Set(keys)
                == [
                    "WHISPER_CPP_REPO", "WHISPER_CPP_REF", "WHISPER_CPP_SHA",
                    "LLAMA_CPP_REPO", "LLAMA_CPP_REF", "LLAMA_CPP_SHA",
                ])
    }
}
```

## テスト

| ファイル | 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|---|
| `Tests/PolicyTests/VendorFixtureTests.swift` | `whisperHelpHasFlag(_:)` | whisper-cli の --help に argv のフラグがすべて在る | fixture を読む。13 フラグで parametrize | すべて在る |
| 同上 | `llamaHelpHasFlag(_:)` | llama-server の --help に使うフラグがすべて在る | fixture を読む。10 フラグで parametrize | すべて在る |
| 同上 | `flagMatchIsWholeWord()` | フラグの判定は語の一部に一致しない | 文字列の例 | 部分一致を拒む（判定関数そのものの陽性・陰性の対照） |
| 同上 | `versionsEnvHasAllKeys()` | versions.env に 6 つのキーがすべて在る | versions.env | キーの集合が一致 |

## 破壊による証明

| 壊し方 | 落ちるべきもの |
|---|---|
| `Tests/Fixtures/llama-server-help.txt` から `--offline` の行を消す | `llamaHelpHasFlag("--offline")` |
| `Vendor/versions.env` の `LLAMA_CPP_SHA` を 1 文字変えて `Vendor/build-llama.sh` を実行 | スクリプトが「コミットが違います」で終了コード 1（出力を貼る） |
| `build-llama.sh` の `-DLLAMA_OPENSSL=OFF` を消してビルド（OpenSSL が入っている Mac で） | `check-linkage.sh` が `libssl` / `libcrypto` で落ちる（入っていなければ「OpenSSL not found」の警告だけになることを記録） |
| `build-whisper.sh` の `-DBUILD_SHARED_LIBS=OFF` を消してビルド | `check-linkage.sh` が `@rpath/libwhisper…` で落ちる |
| `flagMatchIsWholeWord` の正規表現の `([\s,=]\|$)` を消す | `flagMatchIsWholeWord()` |

## 受け入れ条件

- [ ] `make vendor` で `Vendor/build/bin/whisper-cli` と `llama-server` ができ、`check-linkage.sh` が通る（出力を PR に貼る）
- [ ] 両方の `--update-fixtures` で fixture を作り、コミットした
- [ ] `otool -L Vendor/build/bin/*` の全出力を PR に貼った（`/usr/lib/` と `/System/Library/` だけ）
- [ ] `strings Vendor/build/bin/llama-server | grep -c 'huggingface.co'` の結果を PR に貼り、HTTPS が無いビルドであることを `llama-server --model x -hf a/b` の失敗の出力で確かめた（ダウンロードが始まらない）
- [ ] `make test` が通る
- [ ] ビルドに使った `cmake --version` を PR に貼った

## SPEC の変更

なし。

## マージ後にやること

- T-17 で `whisperFlags` を `WhisperHelpCheck.vadFlags` と argv の組み立てから作る形に置き換える（同じ一覧を 2 か所に書かない。CR-06）
- T-21 で `llamaFlags` を `LlamaArgs.usedFlags` に置き換える
