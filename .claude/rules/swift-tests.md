---
paths:
  - "Tests/**/*.swift"
---

# テストの書き方（`Tests/`）

正は `docs/PLAN.md` §10。ここはその索引。

- **Swift Testing**（`import Testing`、`@Test`、`#expect`、パラメータ化テスト）。**XCTest は使わない**
- ファイル: `Tests/<モジュール>Tests/<対象の型>Tests.swift`。スイートは `@Suite("<対象の型>") struct <対象の型>Tests`
- テスト関数名は lowerCamelCase の英語、**表示名は日本語**。規範の ID（CV / ND / RV / DR / PT / CR / PR）に対応するテストは**表示名を ID で始める**
  例: `@Test("ND-18 削除直前にサイズが変わると size_mismatch") func nd18SizeChangedJustBeforeDeletion()`
- テスト名・準備・期待は、チケット §5「テスト」の表の行をそのまま写す。**表の行を 1 つも落とさない**

## 必ず守る 2 つ

- **TEST-01: 実装を呼んで得た値を期待値にしない。** 期待値は仕様の表と固定値から書く。`#expect(x == sut.compute(...))` の右辺に実装が来る形は、何も検証していない
- **TEST-28: 空の入力（0 件・0 台・空文字）のテストを必ず 1 本入れる**

## 差し替えと隔離

- 一時ディレクトリは `TempDirectory()`（TestSupport）でテストごとに作り、終わりに消す
- 時計は `FixedClock` / `SteppingClock`、待ちは `RecordingSleeper`（実際には待たない）
- ファイルシステムのルート（`HomeLayout`・`volumesRoot`）・ツールのパス（`AppPaths`）・署名検証・`MountInspector`・`Remounter`・`Sleeper` は**すべて注入する**。本番のコードパスに「テストなら」の分岐を作らない（CR-25）
- 差し替えはテスト 1 本の範囲に閉じる（差し替えが最後の検証まで汚した事故。TEST-18）
- Swift Testing は既定で並行に走る。**ディスクイメージ・プロセスグループ・ポートを扱うスイートは `.serialized`**

## 環境変数で有効化するもの

`swift test` はタグで絞り込めない（Xcode 27.0 で確認済み）。次は `.enabled(if:)` と環境変数で有効化する。

| 種類 | 環境変数 |
|---|---|
| ディスクイメージ（hdiutil で FAT32 を作る） | `VOICEDOCK_DISK_TESTS=1` |
| 本物の whisper-cli / llama-server とモデル | `VOICEDOCK_REAL_TOOLS=1` |
| LLM 受け入れ試験 | `VOICEDOCK_LLM_MODEL=<id>` |

**環境変数を読むのは `Tests/TestSupport/TestEnvironment.swift` だけ**（本番コードは読まない。PT-18）。

**自分でこれらを設定しない。**実機が抜いてあることを利用者が確かめてからでないと、ディスクイメージのテストは回さない（`.claude/rules/safety.md`）。

## 実機に触れない

- ディスクイメージは `/Volumes` **以外**に attach した `DiskImageVolume` だけを使う
- それ以外は一時ディレクトリの `volumesRoot`（`FakeVolume`）
- ディスクイメージ（本物のマウント）のボリューム名に `VOICEDOCK`・`DJIMIC3`（実機の名前。大文字小文字を問わない）を使わない。
  一時ディレクトリの偽のボリューム（`FakeVolume`）は、名前の判定（既定の include など）を確かめるためにこの名前を使ってよい

## ネットワーク

`URLSessionConfiguration` は**注入されたファクトリ**から作る。テストでは `protocolClasses = [BlockingURLProtocol.self]` を設定したファクトリを渡してループバック以外を失敗させる（TEST-12）。「全スイートに付けるトレイト」では遮断を保証できない。
