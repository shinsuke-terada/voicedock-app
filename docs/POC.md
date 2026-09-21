# VoiceDock for Mac Phase 0 PoC 測定記録

`docs/PLAN.md` が「こう設計する」を書き、**本ファイルは「実際にこう動いた」を書く。**
両者が食い違う場合は本ファイルの実測値を正とし、**PLAN とチケットを直す PR を出す。**

## 0. 記録の規約

- **測定日・コマンド・生の出力**をそのまま貼る。要約した数値だけを書かない
- 判定は `✅ PASS` / `✗ FAIL` / `⬜ 未実施` / `— 対象外` のどれかで始める（空欄・散文にしない）
- 判定の根拠が生の出力のどれなのかを示す
- 代替手段で測った場合は**その限界**を明記する
- 実機（DJI Mic 3）で消す録音は、**この試験のために新しく録った 1 本だけ**にする

### Phase 0 の分割（2026-09-21 利用者の決定）

T-01 に要るのは章 14 の BUNDLE_ID・TEAM_ID・Xcode の版だけなので、Phase 0 を分割して進める。
章 1 と章 14 の識別子を先に埋めて T-01 に進み、残りの章は下の「実施の予定」の時点で埋める。
**P0 の受け入れ条件は、すべての章が埋まった時点で満たす**（それまで P0 は未完了）。

| 章 | 実施の予定 |
|---|---|
| 5・6・7・8・10 | T-03（vendor のビルド）の後。実機は使わない（音声は利用者が `~/VoiceDockPoC/audio/` にコピーしたもの） |
| 2・3・13 | T-13 / T-15 / T-28 に着手する前。実機の手順は【利用者が行う】 |
| 4・9 | T-31 / T-37 に着手する前。実機の手順は【利用者が行う】。章 4 が ✗ なら Phase 8 に入らない |
| 11 | T-02 で記入済み（対象外） |
| 12 | 任意。時間があれば章 2 と同時 |

| 章 | P0 | 内容 | 反映先 | 判定 |
|---|---|---|---|---|
| 1 | — | ホスト環境 | PLAN §3.3 | ✅ PASS（cmake は T-03 の前に導入する。下記） |
| 2 | P0-01 | マウント通知・TCC・列挙・システム設定の URL | PLAN §8.1 規則 5、§8.11 DR-11、T-13、T-32 | ⬜ 未実施 |
| 3 | P0-02 | 読み取り専用での再マウント・パスの変化・`-mountPoint` | PLAN §8.1、T-15 | ⬜ 未実施 |
| 4 | P0-03 | 子プロセスの unlink（ディスクイメージ・実機） | PLAN §8.9.3、RK-01、T-37 | ⬜ 未実施 |
| 5 | P0-04 | whisper.cpp v1.9.4（Metal）の RTF と JSON の形 | PLAN §8.4、RK-03、T-03、T-17 | ⬜ 未実施 |
| 6 | P0-05 | AVAudioConverter と ffmpeg の比較 | PLAN §8.3、RK-05、T-16 | ⬜ 未実施 |
| 7 | P0-06 | llama-server（Metal）と json_object・起動時間・メモリ | PLAN §8.5、RK-04、T-03、T-21 | ⬜ 未実施 |
| 8 | P0-07 | 1 日分（約 350,000 文字）の Map-Reduce | PLAN §10.6、T-24 | ⬜ 未実施 |
| 9 | P0-08 | SMAppService のログイン項目 | PLAN §8.12、RK-02、T-31 | ⬜ 未実施 |
| 10 | P0-09 | 1 日分の処理見込み（文字数で外挿） | PLAN §12.2、E2E-06 | ⬜ 未実施 |
| 11 | P0-10 | GitHub ランナーでのディスクイメージ | PLAN §10.8、RK-06、RK-33、T-02 | — 対象外（CI は開発機のセルフホストランナー。下記） |
| 12 | P0-11 | DADiskMountApprovalCallback（任意） | PLAN §8.1（v1 では採用しない） | ⬜ 未実施 |
| 13 | P0-12 | Vault が書類フォルダ・iCloud Drive にあるときの TCC | PLAN §8.7、§8.11 DR-10、T-28、T-32 | ⬜ 未実施 |
| 14 | — | Phase 0 で決めたこと | PLAN §3.1、§3.3、§8.1、`identity.env` | ⬜ 一部決定（識別子と Xcode は確定。下記） |

## 1. ホスト環境

測定日: 2026-09-21 11:21 JST

```text
$ sw_vers
ProductName:		macOS
ProductVersion:		26.6.2
BuildVersion:		25G83

$ uname -m
arm64

$ sysctl -n machdep.cpu.brand_string hw.memsize hw.physicalcpu hw.logicalcpu
Apple M4 Pro
68719476736
14
14

$ xcodebuild -version
Xcode 27.0
Build version 27A266a

$ swift --version
swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
Target: arm64-apple-macosx26.0

$ cmake --version
(eval):1: command not found: cmake

$ uv --version
uv 0.12.15 (Homebrew 2026-09-15 aarch64-apple-darwin)

$ security find-identity -v -p codesigning
  1) D7154F1903F827645A3F2AFA853B4B81BBD58161 "Apple Distribution: Aperza Inc (VM6XJJ4U42)"
  2) AE683676C0492FAC5C67E9F49136D47C0C845910 "Apple Distribution: Shinsuke Terada (ZCWP35H248)"
  3) C4915E9D13AF4005AD2857253ED6D4F7AB89D03C "Apple Development: Shinsuke Terada (2F65F29TYH)"
     3 valid identities found
```

判定: ✅ PASS — arm64（`uname -m`）、macOS 26.6.2（15 以上）、Xcode 27.0（27A266a）、Swift 6.4、メモリ 64 GiB（`hw.memsize` = 68719476736）。

所見:

- **cmake が入っていない**。T-03（vendor のビルド）の前に `brew install cmake` を行う
- **`Developer ID Application` の証明書が無い**。TEAM_ID は `Apple Distribution: Shinsuke Terada (ZCWP35H248)` の括弧の中から取った（`Apple Development` の括弧の `2F65F29TYH` は個人の識別子で Team ID ではない）。配布用の署名（T-34 / T-44）までに利用者が Developer ID Application の証明書を作る
- ffmpeg も入っていない（章 5・6 の比較に要る。章 5 の前に `brew install ffmpeg`）

## 2. P0-01 マウント通知・TCC・列挙

⬜ 未実施（T-13 の前に【利用者が行う】）

## 3. P0-02 読み取り専用での再マウント

⬜ 未実施（T-15 の前に【利用者が行う】）

## 4. P0-03 子プロセスの unlink

⬜ 未実施（T-37 の前に【利用者が行う】）

## 5. P0-04 whisper.cpp v1.9.4（Metal）

⬜ 未実施（T-03 の後）

## 6. P0-05 AVAudioConverter と ffmpeg

⬜ 未実施（T-03 の後）

## 7. P0-06 llama-server

⬜ 未実施（T-03 の後）

## 8. P0-07 1 日分の Map-Reduce

⬜ 未実施（T-03 の後）

## 9. P0-08 ログイン項目

⬜ 未実施（T-31 の前に【利用者が行う】）

## 10. P0-09 1 日分の処理見込み

⬜ 未実施（章 5・8 の後）

## 11. P0-10 GitHub ランナーでのディスクイメージ

— 対象外（2026-09-21 利用者の決定）

- **理由**: CI のランナーを開発機（この Mac）のセルフホストランナーにした（GitHub の macOS ランナーは非公開リポジトリで分数が 10 倍）。開発機には実機 DJI Mic 3 がつながることがあり、probe の `diskutil mount`（`-mountPoint` 無しの逃げ道）が `/Volumes` に出るため、P0-10 は行わない
- **代わり**: ディスクイメージのテスト（`.diskImage`）は CI で走らせない（ci.yml に `VOICEDOCK_DISK_TESTS` を付けない）。実機を抜いたことを利用者が確かめてから手元の `make test-disk` で回す（R3 の層）

### セルフホストランナーの確認（T-02）

測定日: 2026-09-21

```text
$ gh api repos/shinsuke-terada/voicedock-app/actions/runners -q '.runners[]|"\(.name) \(.status) \([.labels[].name]|join(","))"'
voicedock-local online self-hosted,macOS,ARM64
```

| run | コミット | 結果 | 時間 |
|---|---|---|---|
| https://github.com/shinsuke-terada/voicedock-app/actions/runs/35558211764 | 40696e8（T-02） | ✅ success（全ステップ緑） | 3m56s（初回。SwiftPM の依存の取得を含む） |
| https://github.com/shinsuke-terada/voicedock-app/actions/runs/35564125169 | b67976f（import の順を入れ替えた lint 違反） | ✗ failure（`lint` で落ち、build 以降は走らない） | — |
| https://github.com/shinsuke-terada/voicedock-app/actions/runs/35564826275 | becdaac（上の revert） | ✅ success | 5m20s |

- ランナーは `~/actions-runner` に v2.337.0 を展開し、`./svc.sh install` で LaunchAgent として常駐（利用者が登録）
- `make check-toolchain` のステップが通った（開発機の Xcode 27.0 と `.xcode-version` が一致）

### ブランチ保護（T-02 §5）

✗ 使えない（GitHub Free の非公開リポジトリ）。**保護は設定されていない。**

```text
$ gh api -X PUT repos/shinsuke-terada/voicedock-app/branches/main/protection --input - <<'JSON' …（T-02 §5 の JSON）
{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","documentation_url":"https://docs.github.com/rest/branches/branch-protection#update-branch-protection","status":"403"}
gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)
```

代わりの運用（README に書く。T-43）: `main` へ直接 push しない。`develop` からの PR は CI の `check` が緑のときだけマージする。

## 12. P0-11 DADiskMountApprovalCallback（任意）

⬜ 未実施

## 13. P0-12 Vault の TCC

⬜ 未実施（T-28 の前に【利用者が行う】）

## 14. Phase 0 で決めたこと

| 名前 | 値 | 根拠 |
|---|---|---|
| BUNDLE_ID | io.github.shinsuke-terada.VoiceDock | PLAN §3.1（2026-09-21 利用者が確定） |
| TEAM_ID | ZCWP35H248 | 章 1（`Apple Distribution: Shinsuke Terada (ZCWP35H248)`。2026-09-21 利用者が確定） |
| Xcode | 27.0（27A266a） | 章 1 |
| llama.cpp | b11033（8ed1a55efcd7424d2c592f6cbc9f97756db1d74d）。章 7 で問題があれば見直す | 章 7（未実施） |
| whisper.cpp | v1.9.4（927cfce34f31707e17f2bff35c349632fb9e2c3a） | 章 5（未実施） |
| 再マウントの -mountPoint | 未決（章 3 で決める。T-15 の前） | 章 3 |
| CI のランナー | 開発機のセルフホストランナー `voicedock-local`（self-hosted, macOS, ARM64。v2.337.0） | 章 11 |
