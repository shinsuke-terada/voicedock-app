# VoiceDock for Mac の開発

利用者向けの説明はリポジトリの `README.md` にあります。ここはビルド・テスト・設計の文書の入口です。

## コマンド

| コマンド | 内容 |
|---|---|
| `make test` | ディスクイメージと LLM 受け入れ試験を除く全テスト（削除禁止テスト → ポリシー → 残りの順。CI と同じ） |
| `make lint` | `swift format lint --strict` |
| `make vendor` | whisper.cpp・llama.cpp・argmax-oss-swift をソースからビルドし、話者分離のモデルを取得する（版は `Vendor/versions.env`） |
| `make app` | debug の `VoiceDock.app` を組み立てる（先に `make vendor`） |
| `make release` | 署名・公証・dmg（手元の Mac で行う。証明書は CI に置かない） |
| `make test-disk` | `make test` にディスクイメージのテストを足したもの（LLM 受け入れ試験は含まない。下の「ディスクイメージのテスト」） |

## 文書

- [docs/PLAN.md](PLAN.md): 設計
- [docs/SPEC.md](SPEC.md): 規範の表
- [docs/E2E.md](E2E.md): 実機試験
- [docs/POC.md](POC.md): 実測
- [docs/tickets/README.md](tickets/README.md): タスク

矛盾する場合は `docs/PLAN.md` を優先します。データの置き場所の 1 つずつのパスは `docs/PLAN.md` の §2.3 にあります。

## ディスクイメージのテスト

ディスクイメージのテストは CI では走らせません（CI は開発機のランナーで、実機が抜いてあることを保証できないため）。CI の削除禁止テストは、普通のディレクトリを相手にする層だけです。
削除に触れる PR では、実機を抜いたことを確かめてから手元で `make test-disk` を回し、その結果を PR に貼ります。

## ライセンスの表示

本体は Apache License 2.0（`LICENSE`・`NOTICE`）。同梱物の著作権表示とライセンス文は `THIRD_PARTY_NOTICES.md` にまとめ、`scripts/make-app.sh` が `LICENSE`・`NOTICE` と一緒に `VoiceDock.app/Contents/Resources/` へ入れます（PLAN F-93）。

`Vendor/versions.env` や `Package.resolved` の版を上げたときは、`THIRD_PARTY_NOTICES.md` の表と、ライセンス文（上流の `LICENSE` をそのまま写したもの）も合わせて直します。表の版とコミットが古いままだと `LicenseFilesTests` が落ちます。
同梱物を増やしたときは、`THIRD_PARTY_NOTICES.md` に節を足し、`Resources/bundle-manifest.txt` の許可リストも直します。

## 状態

| Phase | 状態 |
|---|---|
| 0 PoC | 一部実施（`docs/POC.md`。未実施の章はその表に） |
| 1〜7 取り込み・変換・文字起こし・ノート生成・配布 | 実装済み。実機試験は `docs/E2E.md` |
| 8 削除 | 実装済み。`docs/E2E.md` の「削除のゲート」は 2026-10-01 に開いた |
| 9 v1.0 | 1.0.0 を公開（2026-10-01）。1.0.1 で Whisper の既定を `large-v3-turbo-q8_0` に（PLAN F-104）。リリースの手順と記録は `docs/RELEASE.md` |

進捗の詳細と、作業を再開するときの手順は `docs/tickets/STATUS.md` にあります。
