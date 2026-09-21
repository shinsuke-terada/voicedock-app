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
| 2・3・13 | 済み（2026-09-21） |
| 4 | 済み（2026-09-22。✅） |
| 9 | T-31 に着手する前。【利用者が行う】 |
| 11 | T-02 で記入済み（対象外） |
| 12 | 任意。時間があれば章 2 と同時 |

| 章 | P0 | 内容 | 反映先 | 判定 |
|---|---|---|---|---|
| 1 | — | ホスト環境 | PLAN §3.3 | ✅ PASS（cmake は T-03 の前に導入する。下記） |
| 2 | P0-01 | マウント通知・TCC・列挙・システム設定の URL | PLAN §8.1 規則 5、§8.11 DR-11、T-13、T-32 | ✅ PASS（`access(2)` も EPERM になった。PLAN §8.1 規則 5 の理由の文を直す） |
| 3 | P0-02 | 読み取り専用での再マウント・パスの変化・`-mountPoint` | PLAN §8.1、T-15 | ✅ PASS（実機 18/20 が ro・パスは 18/18 保持、2 回は使用中で拒否。実機では `-mountPoint` は使えない → `useMountPoint: false`） |
| 4 | P0-03 | 子プロセスの unlink（ディスクイメージ・実機） | PLAN §8.9.3、RK-01、T-37 | ✅ PASS（アプリの子としてディスクイメージと実機の両方で消せた） |
| 5 | P0-04 | whisper.cpp v1.9.4（Metal）の RTF と JSON の形 | PLAN §8.4、RK-03、T-03、T-17 | ⬜ 未実施 |
| 6 | P0-05 | AVAudioConverter と ffmpeg の比較 | PLAN §8.3、RK-05、T-16 | ⬜ 未実施 |
| 7 | P0-06 | llama-server（Metal）と json_object・起動時間・メモリ | PLAN §8.5、RK-04、T-03、T-21 | ⬜ 未実施 |
| 8 | P0-07 | 1 日分（約 350,000 文字）の Map-Reduce | PLAN §10.6、T-24 | ⬜ 未実施 |
| 9 | P0-08 | SMAppService のログイン項目 | PLAN §8.12、RK-02、T-31 | ⬜ 未実施 |
| 10 | P0-09 | 1 日分の処理見込み（文字数で外挿） | PLAN §12.2、E2E-06 | ⬜ 未実施 |
| 11 | P0-10 | GitHub ランナーでのディスクイメージ | PLAN §10.8、RK-06、RK-33、T-02 | — 対象外（CI は開発機のセルフホストランナー。下記） |
| 12 | P0-11 | DADiskMountApprovalCallback（任意） | PLAN §8.1（v1 では採用しない） | ⬜ 未実施 |
| 13 | P0-12 | Vault が書類フォルダ・iCloud Drive にあるときの TCC | PLAN §8.7、§8.11 DR-10、T-28、T-32 | ✅ PASS（NSOpenPanel で選んだ Vault は再起動後もパネル無しで書ける。拒否の経路は再現できず） |
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

判定: ✅ PASS

測定日: 2026-09-21（macOS 26.6.2、DJI Mic 3。実機の操作は利用者が行った。アプリ PoCMenuBar は読み取りだけ）

### 1 回目（許可ダイアログが出ることの確認）

`tccutil reset SystemPolicyRemovableVolumes io.github.shinsuke-terada.VoiceDockPoC` → 起動 → 実機を挿す → **許可ダイアログが出た**（利用者は誤って「許可」を選んだ）。

その後 `tccutil reset SystemPolicyRemovableVolumes …` をもう一度実行してから挿し直したが、**ダイアログは出ず最初から読めた**（ログは下）。`SystemPolicyRemovableVolumes` のリセットでは許可が消えなかった。`tccutil reset All <bundle id>` では消えた（3 回目）。

```text
2026-09-21T22:55:44.594+09:00 launch pid=58340 bundle=io.github.shinsuke-terada.VoiceDockPoC
2026-09-21T22:55:55.216+09:00 mount /Volumes/DJIMIC3
2026-09-21T22:55:55.266+09:00   opendir ok
2026-09-21T22:55:55.271+09:00   access(R_OK)=0
```

### 拒否と許可（`tccutil reset All io.github.shinsuke-terada.VoiceDockPoC` の後）

利用者の記録: 実機を挿した時刻 22:58:30、ダイアログで「許可しない」を選んだ。その後「システム設定を開く」→ 許可を与える（アプリが再起動した）→ 抜き挿し → 「列挙する」。

```text
2026-09-21T22:58:27.055+09:00 launch pid=66563 bundle=io.github.shinsuke-terada.VoiceDockPoC
2026-09-21T22:58:40.551+09:00 mount /Volumes/DJIMIC3
2026-09-21T22:58:45.243+09:00   opendir errno=1 (Operation not permitted)
2026-09-21T22:58:45.266+09:00   access(R_OK)=-1 errno=1 (Operation not permitted)
2026-09-21T22:59:32.843+09:00 open settings -> true
2026-09-21T23:00:01.142+09:00 launch pid=69228 bundle=io.github.shinsuke-terada.VoiceDockPoC
2026-09-21T23:00:05.907+09:00 unmount /Volumes/DJIMIC3
2026-09-21T23:00:10.581+09:00 mount /Volumes/DJIMIC3
2026-09-21T23:00:10.614+09:00   opendir ok
2026-09-21T23:00:10.618+09:00   access(R_OK)=0
2026-09-21T23:00:17.218+09:00 enumerate /Volumes/Macintosh HD access(R_OK)=0 entries=["home", "usr", ".resolve", "bin", "sbin", ".file", "etc", "var", "Library", "System", ".VolumeIcon.icns", "private", ".vol", "Users", "Applications", "opt", "dev", "Volumes", ".nofollow", "tmp"]
2026-09-21T23:00:17.220+09:00 enumerate /Volumes/DJIMIC3 access(R_OK)=0 entries=[".Spotlight-V100", ".fseventsd", "TX_MIC001_20260915_165730", ".Trashes"]
```

```text
$ mount | grep -i djimic
/dev/disk4 on /Volumes/DJIMIC3 (msdos, local, nodev, nosuid, noowners, noatime, fskit)
$ diskutil info /Volumes/DJIMIC3 | grep -E "Volume Name|Mount Point|File System Personality|Device Node|Read-Only|Removable|Protocol"
   Device Node:               /dev/disk4
   Volume Name:               DJIMIC3
   Mount Point:               /Volumes/DJIMIC3
   File System Personality:   MS-DOS FAT32
   Protocol:                  USB
   Media Read-Only:           No
   Volume Read-Only:          No
   Removable Media:           Removable
```

根拠:
- 検出: 挿した時刻 22:58:30（利用者が手で記録。±1 秒程度）→ `mount` 22:58:40.551 で約 10.5 秒。抜き挿しでは `unmount` 23:00:05.907 → `mount` 23:00:10.581 で約 4.7 秒。ほぼ全部がデバイス自体のマウントの時間で、通知は即時に届いている。合格の目安（10 秒）の境界だが、アプリ側で縮められる時間ではないので PASS とする
- 拒否時: `opendir errno=1 (Operation not permitted)`（EPERM）。ダイアログの応答を待ってから返った（22:58:40 → 22:58:45）
- 許可後: `opendir ok`、直下に録音フォルダ `TX_MIC001_20260915_165730` が見えた
- システム設定の URL: `open settings -> true`（開けた。開いた画面の名前は利用者の確認待ち）

所見と反映先:
- **`access(R_OK)` も拒否時に EPERM（-1）になった。**PLAN §8.1 規則 5 の「`access(2)` は TCC の拒否でも成功するので使わない（DEV-03）」の理由の文は、この OS では成り立たない。**設計（`access` に頼らず `opendir` の列挙で判定する）はそのままで正しい**ので、動作は変えない。PLAN の文を「`access(2)` の結果は OS の版で変わる（macOS 26.6 では EPERM、以前は成功）ので判定に使わない」に直す（P0 の PR で）
- ファイルシステムは `msdos` を **FSKit**（`fskit`）でマウントしている（macOS 26）。デバイスは `/dev/disk4`（パーティション無しの superfloppy。T-07 の `-layout NONE` と同じ形）
- 許可をやり直す案内（DR-11・T-32）は `tccutil reset SystemPolicyRemovableVolumes` では足りず、システム設定の「ファイルとフォルダ」で切り替えるのが確実。切り替えるとアプリが再起動した
- `.Spotlight-V100`・`.fseventsd`・`.Trashes` は macOS が作ったもの（アプリは書いていない）

## 3. P0-02 読み取り専用での再マウント

判定: ✅ PASS

測定日: 2026-09-21（macOS 26.6.2）。実機の操作は利用者が PoCMenuBar の「ro 再マウント ×20」で行った。各回の手順は P0-poc.md §4 のとおり（`-mountPoint` 付きで試し、失敗したら付けずに再試行。最後に rw へ戻す）。

### 実機（/Volumes/DJIMIC3、/dev/disk4、FAT32 を FSKit でマウント）

```text
23:03:22.930+09:00 remount20 begin /Volumes/DJIMIC3
23:03:22.932+09:00 [1] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:23.221+09:00 unmount /Volumes/DJIMIC3
23:03:23.359+09:00 [1] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:23.359+09:00 [1] after unmount dir exists=false
23:03:23.429+09:00 [1] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:23.845+09:00 mount /Volumes/DJIMIC3
23:03:23.845+09:00   opendir ok
23:03:23.846+09:00   access(R_OK)=0 
23:03:23.963+09:00 [1] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:23.964+09:00 [1] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:24.016+09:00 unmount /Volumes/DJIMIC3
23:03:24.168+09:00 [1] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:24.239+09:00 [1] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:24.643+09:00 mount /Volumes/DJIMIC3
23:03:24.644+09:00   opendir ok
23:03:24.645+09:00   access(R_OK)=0 
23:03:24.766+09:00 [1] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:24.767+09:00 [2] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:25.830+09:00 unmount /Volumes/DJIMIC3
23:03:25.969+09:00 [2] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:25.970+09:00 [2] after unmount dir exists=false
23:03:26.045+09:00 [2] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:26.458+09:00 mount /Volumes/DJIMIC3
23:03:26.460+09:00   opendir ok
23:03:26.461+09:00   access(R_OK)=0 
23:03:26.584+09:00 [2] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:26.585+09:00 [2] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:26.647+09:00 unmount /Volumes/DJIMIC3
23:03:26.759+09:00 [2] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:26.829+09:00 [2] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:27.245+09:00 mount /Volumes/DJIMIC3
23:03:27.246+09:00   opendir ok
23:03:27.247+09:00   access(R_OK)=0 
23:03:27.364+09:00 [2] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:27.366+09:00 [3] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:28.444+09:00 unmount /Volumes/DJIMIC3
23:03:28.591+09:00 [3] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:28.593+09:00 [3] after unmount dir exists=false
23:03:28.667+09:00 [3] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:29.079+09:00 mount /Volumes/DJIMIC3
23:03:29.081+09:00   opendir ok
23:03:29.081+09:00   access(R_OK)=0 
23:03:29.216+09:00 [3] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:29.217+09:00 [3] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:29.278+09:00 unmount /Volumes/DJIMIC3
23:03:29.421+09:00 [3] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:29.492+09:00 [3] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:29.910+09:00 mount /Volumes/DJIMIC3
23:03:29.911+09:00   opendir ok
23:03:29.912+09:00   access(R_OK)=0 
23:03:30.045+09:00 [3] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:30.047+09:00 [4] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:31.143+09:00 unmount /Volumes/DJIMIC3
23:03:31.292+09:00 [4] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:31.293+09:00 [4] after unmount dir exists=false
23:03:31.369+09:00 [4] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:31.782+09:00 mount /Volumes/DJIMIC3
23:03:31.783+09:00   opendir ok
23:03:31.784+09:00   access(R_OK)=0 
23:03:31.901+09:00 [4] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:31.901+09:00 [4] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:31.955+09:00 unmount /Volumes/DJIMIC3
23:03:32.099+09:00 [4] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:32.170+09:00 [4] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:32.574+09:00 mount /Volumes/DJIMIC3
23:03:32.577+09:00   opendir ok
23:03:32.578+09:00   access(R_OK)=0 
23:03:32.694+09:00 [4] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:32.695+09:00 [5] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:33.736+09:00 unmount /Volumes/DJIMIC3
23:03:33.888+09:00 [5] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:33.888+09:00 [5] after unmount dir exists=false
23:03:33.965+09:00 [5] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:34.402+09:00 mount /Volumes/DJIMIC3
23:03:34.403+09:00   opendir ok
23:03:34.404+09:00   access(R_OK)=0 
23:03:34.540+09:00 [5] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:34.541+09:00 [5] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:34.611+09:00 unmount /Volumes/DJIMIC3
23:03:34.763+09:00 [5] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:34.844+09:00 [5] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:35.278+09:00 mount /Volumes/DJIMIC3
23:03:35.279+09:00   opendir ok
23:03:35.280+09:00   access(R_OK)=0 
23:03:35.391+09:00 [5] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:35.393+09:00 [6] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:36.544+09:00 unmount /Volumes/DJIMIC3
23:03:36.688+09:00 [6] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:36.689+09:00 [6] after unmount dir exists=false
23:03:36.773+09:00 [6] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:37.192+09:00 mount /Volumes/DJIMIC3
23:03:37.193+09:00   opendir ok
23:03:37.194+09:00   access(R_OK)=0 
23:03:37.308+09:00 [6] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:37.309+09:00 [6] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:37.381+09:00 unmount /Volumes/DJIMIC3
23:03:37.515+09:00 [6] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:37.599+09:00 [6] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:38.033+09:00 mount /Volumes/DJIMIC3
23:03:38.034+09:00   opendir ok
23:03:38.035+09:00   access(R_OK)=0 
23:03:38.143+09:00 [6] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:38.145+09:00 [7] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:39.209+09:00 unmount /Volumes/DJIMIC3
23:03:39.354+09:00 [7] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:39.355+09:00 [7] after unmount dir exists=false
23:03:39.440+09:00 [7] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:39.871+09:00 mount /Volumes/DJIMIC3
23:03:39.872+09:00   opendir ok
23:03:39.873+09:00   access(R_OK)=0 
23:03:40.005+09:00 [7] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:40.006+09:00 [7] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:40.079+09:00 unmount /Volumes/DJIMIC3
23:03:40.221+09:00 [7] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:40.303+09:00 [7] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:40.728+09:00 mount /Volumes/DJIMIC3
23:03:40.729+09:00   opendir ok
23:03:40.730+09:00   access(R_OK)=0 
23:03:40.849+09:00 [7] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:40.851+09:00 [8] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:41.999+09:00 unmount /Volumes/DJIMIC3
23:03:42.142+09:00 [8] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:42.143+09:00 [8] after unmount dir exists=false
23:03:42.223+09:00 [8] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:42.653+09:00 mount /Volumes/DJIMIC3
23:03:42.654+09:00   opendir ok
23:03:42.654+09:00   access(R_OK)=0 
23:03:42.787+09:00 [8] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:42.788+09:00 [8] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:42.861+09:00 unmount /Volumes/DJIMIC3
23:03:43.010+09:00 [8] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:43.093+09:00 [8] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:43.536+09:00 mount /Volumes/DJIMIC3
23:03:43.537+09:00   opendir ok
23:03:43.538+09:00   access(R_OK)=0 
23:03:43.663+09:00 [8] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:43.664+09:00 [9] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:44.760+09:00 unmount /Volumes/DJIMIC3
23:03:44.910+09:00 [9] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:44.911+09:00 [9] after unmount dir exists=false
23:03:44.992+09:00 [9] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:45.423+09:00 mount /Volumes/DJIMIC3
23:03:45.425+09:00   opendir ok
23:03:45.425+09:00   access(R_OK)=0 
23:03:45.537+09:00 [9] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:45.538+09:00 [9] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:45.613+09:00 unmount /Volumes/DJIMIC3
23:03:45.780+09:00 [9] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:45.861+09:00 [9] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:46.287+09:00 mount /Volumes/DJIMIC3
23:03:46.290+09:00   opendir ok
23:03:46.290+09:00   access(R_OK)=0 
23:03:46.434+09:00 [9] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:46.436+09:00 [10] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:47.452+09:00 unmount /Volumes/DJIMIC3
23:03:47.551+09:00 [10] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:47.552+09:00 [10] after unmount dir exists=false
23:03:47.632+09:00 [10] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:48.065+09:00 mount /Volumes/DJIMIC3
23:03:48.065+09:00   opendir ok
23:03:48.066+09:00   access(R_OK)=0 
23:03:48.185+09:00 [10] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:48.187+09:00 [10] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:48.256+09:00 unmount /Volumes/DJIMIC3
23:03:48.361+09:00 [10] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:48.445+09:00 [10] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:48.874+09:00 mount /Volumes/DJIMIC3
23:03:48.876+09:00   opendir ok
23:03:48.877+09:00   access(R_OK)=0 
23:03:48.996+09:00 [10] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:48.998+09:00 [11] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:50.029+09:00 unmount /Volumes/DJIMIC3
23:03:50.164+09:00 [11] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:50.166+09:00 [11] after unmount dir exists=false
23:03:50.252+09:00 [11] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:50.674+09:00 mount /Volumes/DJIMIC3
23:03:50.675+09:00   opendir ok
23:03:50.676+09:00   access(R_OK)=0 
23:03:50.792+09:00 [11] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:50.793+09:00 [11] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:50.863+09:00 unmount /Volumes/DJIMIC3
23:03:51.000+09:00 [11] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:51.080+09:00 [11] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:51.508+09:00 mount /Volumes/DJIMIC3
23:03:51.510+09:00   opendir ok
23:03:51.511+09:00   access(R_OK)=0 
23:03:51.634+09:00 [11] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:51.636+09:00 [12] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:52.762+09:00 unmount /Volumes/DJIMIC3
23:03:52.896+09:00 [12] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:52.897+09:00 [12] after unmount dir exists=false
23:03:52.979+09:00 [12] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:53.423+09:00 mount /Volumes/DJIMIC3
23:03:53.424+09:00   opendir ok
23:03:53.425+09:00   access(R_OK)=0 
23:03:53.544+09:00 [12] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:53.545+09:00 [12] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:53.618+09:00 unmount /Volumes/DJIMIC3
23:03:53.764+09:00 [12] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:53.851+09:00 [12] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:54.280+09:00 mount /Volumes/DJIMIC3
23:03:54.283+09:00   opendir ok
23:03:54.284+09:00   access(R_OK)=0 
23:03:54.426+09:00 [12] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:54.428+09:00 [13] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:55.676+09:00 [13] unmount rc=1 Volume DJIMIC3 on disk4 failed to unmount: dissented by PID 75766 (/bin/bash)
arent PPID 75765 (/Users/terada/VoiceDock/bin/voicedock-ingest-launcher)
23:03:55.677+09:00 [14] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:55.924+09:00 unmount /Volumes/DJIMIC3
23:03:56.057+09:00 [14] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:56.059+09:00 [14] after unmount dir exists=false
23:03:56.138+09:00 [14] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:56.579+09:00 mount /Volumes/DJIMIC3
23:03:56.580+09:00   opendir ok
23:03:56.580+09:00   access(R_OK)=0 
23:03:56.721+09:00 [14] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:56.721+09:00 [14] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:56.797+09:00 unmount /Volumes/DJIMIC3
23:03:56.955+09:00 [14] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:57.035+09:00 [14] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:57.474+09:00 mount /Volumes/DJIMIC3
23:03:57.476+09:00   opendir ok
23:03:57.476+09:00   access(R_OK)=0 
23:03:57.600+09:00 [14] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:03:57.601+09:00 [15] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:03:58.639+09:00 unmount /Volumes/DJIMIC3
23:03:58.772+09:00 [15] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:58.774+09:00 [15] after unmount dir exists=false
23:03:58.855+09:00 [15] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:03:59.292+09:00 mount /Volumes/DJIMIC3
23:03:59.292+09:00   opendir ok
23:03:59.293+09:00   access(R_OK)=0 
23:03:59.410+09:00 [15] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:03:59.411+09:00 [15] new path=/Volumes/DJIMIC3 ro=true kept=true
23:03:59.484+09:00 unmount /Volumes/DJIMIC3
23:03:59.622+09:00 [15] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:03:59.699+09:00 [15] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:04:00.132+09:00 mount /Volumes/DJIMIC3
23:04:00.133+09:00   opendir ok
23:04:00.133+09:00   access(R_OK)=0 
23:04:00.261+09:00 [15] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:04:00.262+09:00 [16] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:04:01.426+09:00 unmount /Volumes/DJIMIC3
23:04:01.567+09:00 [16] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:04:01.568+09:00 [16] after unmount dir exists=false
23:04:01.648+09:00 [16] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:04:02.076+09:00 mount /Volumes/DJIMIC3
23:04:02.078+09:00   opendir ok
23:04:02.078+09:00   access(R_OK)=0 
23:04:02.194+09:00 [16] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:04:02.195+09:00 [16] new path=/Volumes/DJIMIC3 ro=true kept=true
23:04:02.266+09:00 unmount /Volumes/DJIMIC3
23:04:02.421+09:00 [16] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:04:02.503+09:00 [16] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:04:02.929+09:00 mount /Volumes/DJIMIC3
23:04:02.930+09:00   opendir ok
23:04:02.931+09:00   access(R_OK)=0 
23:04:03.051+09:00 [16] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:04:03.052+09:00 [17] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:04:04.141+09:00 unmount /Volumes/DJIMIC3
23:04:04.277+09:00 [17] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:04:04.278+09:00 [17] after unmount dir exists=false
23:04:04.360+09:00 [17] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:04:04.793+09:00 mount /Volumes/DJIMIC3
23:04:04.794+09:00   opendir ok
23:04:04.795+09:00   access(R_OK)=0 
23:04:04.934+09:00 [17] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:04:04.936+09:00 [17] new path=/Volumes/DJIMIC3 ro=true kept=true
23:04:05.017+09:00 unmount /Volumes/DJIMIC3
23:04:05.165+09:00 [17] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:04:05.244+09:00 [17] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:04:05.677+09:00 mount /Volumes/DJIMIC3
23:04:05.678+09:00   opendir ok
23:04:05.679+09:00   access(R_OK)=0 
23:04:05.809+09:00 [17] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:04:05.810+09:00 [18] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:04:07.051+09:00 [18] unmount rc=1 Volume DJIMIC3 on disk4 failed to unmount
23:04:07.052+09:00 [19] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:04:07.371+09:00 unmount /Volumes/DJIMIC3
23:04:07.468+09:00 [19] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:04:07.469+09:00 [19] after unmount dir exists=false
23:04:07.548+09:00 [19] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:04:07.967+09:00 mount /Volumes/DJIMIC3
23:04:07.969+09:00   opendir ok
23:04:07.969+09:00   access(R_OK)=0 
23:04:08.075+09:00 [19] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:04:08.076+09:00 [19] new path=/Volumes/DJIMIC3 ro=true kept=true
23:04:08.150+09:00 unmount /Volumes/DJIMIC3
23:04:08.290+09:00 [19] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:04:08.373+09:00 [19] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:04:08.812+09:00 mount /Volumes/DJIMIC3
23:04:08.815+09:00   opendir ok
23:04:08.815+09:00   access(R_OK)=0 
23:04:08.930+09:00 [19] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:04:08.932+09:00 [20] before ro=false from=/dev/disk4 on=/Volumes/DJIMIC3
23:04:10.098+09:00 unmount /Volumes/DJIMIC3
23:04:10.254+09:00 [20] unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:04:10.255+09:00 [20] after unmount dir exists=false
23:04:10.339+09:00 [20] mount readOnly -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:04:10.809+09:00 mount /Volumes/DJIMIC3
23:04:10.811+09:00   opendir ok
23:04:10.812+09:00   access(R_OK)=0 
23:04:10.955+09:00 [20] fallback mount readOnly (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted
23:04:10.956+09:00 [20] new path=/Volumes/DJIMIC3 ro=true kept=true
23:04:11.056+09:00 unmount /Volumes/DJIMIC3
23:04:11.205+09:00 [20] restore unmount rc=0 Volume DJIMIC3 on disk4 unmounted
23:04:11.286+09:00 [20] restore mount -mountPoint rc=1 Mountpoint /Volumes/DJIMIC3 does not exist
23:04:11.737+09:00 mount /Volumes/DJIMIC3
23:04:11.738+09:00   opendir ok
23:04:11.739+09:00   access(R_OK)=0 
23:04:11.855+09:00 [20] restore fallback mount (no -mountPoint) rc=0 Volume DJIMIC3 on /dev/disk4 mounted now=/Volumes/DJIMIC3
23:04:11.856+09:00 remount20 end ro=18/20 pathKept=18 busy=0
```

### ディスクイメージ（~/VoiceDockPoC/mnt/PoCDJI。/Volumes の外。実機は抜いた状態）

```text
23:06:44.212+09:00 remount20 begin /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:44.213+09:00 [1] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:44.473+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:44.614+09:00 [1] unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:44.615+09:00 [1] after unmount dir exists=true
23:06:44.819+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:44.820+09:00   opendir ok
23:06:44.820+09:00   access(R_OK)=0 
23:06:44.944+09:00 [1] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:44.945+09:00 [1] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:06:45.012+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:45.179+09:00 [1] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:45.371+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:45.373+09:00   opendir ok
23:06:45.373+09:00   access(R_OK)=0 
23:06:45.477+09:00 [1] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:45.478+09:00 [2] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:45.779+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:45.927+09:00 [2] unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:45.928+09:00 [2] after unmount dir exists=true
23:06:46.119+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:46.119+09:00   opendir ok
23:06:46.120+09:00   access(R_OK)=0 
23:06:46.236+09:00 [2] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:46.237+09:00 [2] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:06:46.313+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:46.434+09:00 [2] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:46.626+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:46.627+09:00   opendir ok
23:06:46.628+09:00   access(R_OK)=0 
23:06:46.742+09:00 [2] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:46.744+09:00 [3] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:47.043+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:47.215+09:00 [3] unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:47.216+09:00 [3] after unmount dir exists=true
23:06:47.424+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:47.425+09:00   opendir ok
23:06:47.426+09:00   access(R_OK)=0 
23:06:47.536+09:00 [3] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:47.537+09:00 [3] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:06:47.632+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:47.771+09:00 [3] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:47.972+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:47.973+09:00   opendir ok
23:06:47.974+09:00   access(R_OK)=0 
23:06:48.085+09:00 [3] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:48.087+09:00 [4] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:48.378+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:48.508+09:00 [4] unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:48.509+09:00 [4] after unmount dir exists=true
23:06:48.728+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:48.729+09:00   opendir ok
23:06:48.730+09:00   access(R_OK)=0 
23:06:48.846+09:00 [4] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:48.848+09:00 [4] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:06:48.944+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:49.099+09:00 [4] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:49.320+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:49.321+09:00   opendir ok
23:06:49.322+09:00   access(R_OK)=0 
23:06:49.429+09:00 [4] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:49.430+09:00 [5] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:49.730+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:49.842+09:00 [5] unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:49.843+09:00 [5] after unmount dir exists=true
23:06:50.070+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:50.071+09:00   opendir ok
23:06:50.071+09:00   access(R_OK)=0 
23:06:50.180+09:00 [5] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:50.182+09:00 [5] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:06:50.283+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:50.443+09:00 [5] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:50.651+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:50.652+09:00   opendir ok
23:06:50.652+09:00   access(R_OK)=0 
23:06:50.763+09:00 [5] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:50.764+09:00 [6] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:51.042+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:51.183+09:00 [6] unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:51.185+09:00 [6] after unmount dir exists=true
23:06:51.406+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:51.408+09:00   opendir ok
23:06:51.409+09:00   access(R_OK)=0 
23:06:51.526+09:00 [6] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:51.527+09:00 [6] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:06:51.629+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:51.737+09:00 [6] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:51.966+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:51.968+09:00   opendir ok
23:06:51.969+09:00   access(R_OK)=0 
23:06:52.085+09:00 [6] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:52.087+09:00 [7] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:52.378+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:52.533+09:00 [7] unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:52.534+09:00 [7] after unmount dir exists=true
23:06:52.757+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:52.759+09:00   opendir ok
23:06:52.759+09:00   access(R_OK)=0 
23:06:52.876+09:00 [7] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:52.877+09:00 [7] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:06:52.979+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:53.132+09:00 [7] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:53.357+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:53.358+09:00   opendir ok
23:06:53.360+09:00   access(R_OK)=0 
23:06:53.504+09:00 [7] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:53.506+09:00 [8] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:53.785+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:53.929+09:00 [8] unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:53.930+09:00 [8] after unmount dir exists=true
23:06:54.154+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:54.155+09:00   opendir ok
23:06:54.155+09:00   access(R_OK)=0 
23:06:54.271+09:00 [8] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:54.272+09:00 [8] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:06:54.371+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:54.528+09:00 [8] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:54.748+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:54.749+09:00   opendir ok
23:06:54.750+09:00   access(R_OK)=0 
23:06:54.870+09:00 [8] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:54.871+09:00 [9] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:55.147+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:55.290+09:00 [9] unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:55.292+09:00 [9] after unmount dir exists=true
23:06:55.514+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:55.515+09:00   opendir ok
23:06:55.516+09:00   access(R_OK)=0 
23:06:55.655+09:00 [9] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:55.656+09:00 [9] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:06:55.763+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:55.918+09:00 [9] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:56.141+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:56.144+09:00   opendir ok
23:06:56.144+09:00   access(R_OK)=0 
23:06:56.283+09:00 [9] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:56.285+09:00 [10] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:56.612+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:56.749+09:00 [10] unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:56.750+09:00 [10] after unmount dir exists=true
23:06:56.970+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:56.971+09:00   opendir ok
23:06:56.972+09:00   access(R_OK)=0 
23:06:57.109+09:00 [10] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:57.110+09:00 [10] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:06:57.213+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:57.347+09:00 [10] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:57.584+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:57.585+09:00   opendir ok
23:06:57.586+09:00   access(R_OK)=0 
23:06:57.719+09:00 [10] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:57.721+09:00 [11] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:58.056+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:58.195+09:00 [11] unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:58.197+09:00 [11] after unmount dir exists=true
23:06:58.419+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:58.420+09:00   opendir ok
23:06:58.421+09:00   access(R_OK)=0 
23:06:58.553+09:00 [11] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:58.553+09:00 [11] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:06:58.657+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:58.761+09:00 [11] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:58.988+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:58.989+09:00   opendir ok
23:06:58.990+09:00   access(R_OK)=0 
23:06:59.126+09:00 [11] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:59.127+09:00 [12] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:59.388+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:59.514+09:00 [12] unmount rc=0 Volume POCDJI on disk4 unmounted
23:06:59.515+09:00 [12] after unmount dir exists=true
23:06:59.740+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:06:59.742+09:00   opendir ok
23:06:59.743+09:00   access(R_OK)=0 
23:06:59.879+09:00 [12] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:06:59.880+09:00 [12] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:06:59.981+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:00.141+09:00 [12] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:00.366+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:00.367+09:00   opendir ok
23:07:00.367+09:00   access(R_OK)=0 
23:07:00.503+09:00 [12] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:00.505+09:00 [13] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:00.808+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:00.957+09:00 [13] unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:00.959+09:00 [13] after unmount dir exists=true
23:07:01.184+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:01.185+09:00   opendir ok
23:07:01.186+09:00   access(R_OK)=0 
23:07:01.311+09:00 [13] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:01.313+09:00 [13] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:07:01.414+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:01.571+09:00 [13] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:01.791+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:01.792+09:00   opendir ok
23:07:01.793+09:00   access(R_OK)=0 
23:07:01.920+09:00 [13] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:01.922+09:00 [14] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:02.193+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:02.332+09:00 [14] unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:02.333+09:00 [14] after unmount dir exists=true
23:07:02.560+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:02.561+09:00   opendir ok
23:07:02.561+09:00   access(R_OK)=0 
23:07:02.677+09:00 [14] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:02.679+09:00 [14] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:07:02.783+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:02.901+09:00 [14] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:03.127+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:03.128+09:00   opendir ok
23:07:03.129+09:00   access(R_OK)=0 
23:07:03.244+09:00 [14] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:03.245+09:00 [15] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:03.525+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:03.659+09:00 [15] unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:03.661+09:00 [15] after unmount dir exists=true
23:07:03.882+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:03.885+09:00   opendir ok
23:07:03.885+09:00   access(R_OK)=0 
23:07:03.997+09:00 [15] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:03.999+09:00 [15] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:07:04.097+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:04.251+09:00 [15] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:04.477+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:04.477+09:00   opendir ok
23:07:04.478+09:00   access(R_OK)=0 
23:07:04.588+09:00 [15] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:04.589+09:00 [16] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:04.866+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:05.021+09:00 [16] unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:05.023+09:00 [16] after unmount dir exists=true
23:07:05.250+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:05.251+09:00   opendir ok
23:07:05.251+09:00   access(R_OK)=0 
23:07:05.366+09:00 [16] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:05.367+09:00 [16] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:07:05.466+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:05.624+09:00 [16] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:05.845+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:05.847+09:00   opendir ok
23:07:05.848+09:00   access(R_OK)=0 
23:07:05.964+09:00 [16] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:05.965+09:00 [17] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:06.254+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:06.403+09:00 [17] unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:06.405+09:00 [17] after unmount dir exists=true
23:07:06.623+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:06.625+09:00   opendir ok
23:07:06.626+09:00   access(R_OK)=0 
23:07:06.754+09:00 [17] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:06.756+09:00 [17] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:07:06.860+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:06.997+09:00 [17] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:07.216+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:07.219+09:00   opendir ok
23:07:07.220+09:00   access(R_OK)=0 
23:07:07.337+09:00 [17] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:07.338+09:00 [18] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:07.610+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:07.718+09:00 [18] unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:07.719+09:00 [18] after unmount dir exists=true
23:07:07.951+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:07.953+09:00   opendir ok
23:07:07.954+09:00   access(R_OK)=0 
23:07:08.069+09:00 [18] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:08.071+09:00 [18] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:07:08.171+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:08.322+09:00 [18] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:08.550+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:08.551+09:00   opendir ok
23:07:08.552+09:00   access(R_OK)=0 
23:07:08.667+09:00 [18] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:08.669+09:00 [19] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:08.942+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:09.093+09:00 [19] unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:09.094+09:00 [19] after unmount dir exists=true
23:07:09.312+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:09.312+09:00   opendir ok
23:07:09.313+09:00   access(R_OK)=0 
23:07:09.431+09:00 [19] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:09.432+09:00 [19] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:07:09.532+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:09.650+09:00 [19] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:09.865+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:09.865+09:00   opendir ok
23:07:09.866+09:00   access(R_OK)=0 
23:07:09.971+09:00 [19] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:09.972+09:00 [20] before ro=false from=/dev/disk4 on=/Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:10.356+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:10.510+09:00 [20] unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:10.512+09:00 [20] after unmount dir exists=true
23:07:10.730+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:10.732+09:00   opendir ok
23:07:10.733+09:00   access(R_OK)=0 
23:07:10.864+09:00 [20] mount readOnly -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:10.866+09:00 [20] new path=/Users/terada/VoiceDockPoC/mnt/PoCDJI ro=true kept=true
23:07:10.967+09:00 unmount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:11.096+09:00 [20] restore unmount rc=0 Volume POCDJI on disk4 unmounted
23:07:11.314+09:00 mount /Users/terada/VoiceDockPoC/mnt/PoCDJI
23:07:11.315+09:00   opendir ok
23:07:11.316+09:00   access(R_OK)=0 
23:07:11.439+09:00 [20] restore mount -mountPoint rc=0 Volume POCDJI on /dev/disk4 mounted
23:07:11.439+09:00 remount20 end ro=20/20 pathKept=20 busy=0
```

### 同じ名前のボリュームが 2 つあるときのパス（【利用者が行う】。実機は抜いた状態）

`-volname PoCDJI` のイメージを 2 つ `-mountpoint` 無しで attach すると `/Volumes/POCDJI` と `/Volumes/POCDJI 1` になった（**FAT のボリューム名は大文字で記録される**: `PoCDJI` → `POCDJI`）。1 つ目を `diskutil unmount /dev/disk4` すると `Unmount failed for /dev/disk4` で外れず（2 回試して 2 回とも）、再マウントのパスの変化は**測定できなかった**。

```text
/dev/disk4                                              /Volumes/POCDJI
/dev/disk5                                              /Volumes/POCDJI 1
== 2 つをマウントした直後
/dev/disk4 on /Volumes/POCDJI (msdos, local, nodev, nosuid, noowners, noatime, fskit, mounted by terada)
/dev/disk5 on /Volumes/POCDJI 1 (msdos, local, nodev, nosuid, noowners, noatime, fskit, mounted by terada)
A=/dev/disk4
/dev/disk5
Unmount failed for /dev/disk4
```

根拠と判断:
- 実機: 20 回中 18 回で `ro=true`。**`diskutil mount readOnly -mountPoint /Volumes/DJIMIC3 <node>` は毎回 `Mountpoint /Volumes/DJIMIC3 does not exist` で失敗**（アンマウントで DiskArbitration が `/Volumes/DJIMIC3` を消し、利用者は `/Volumes` に作れない）。`-mountPoint` 無しの `diskutil mount readOnly /dev/disk4` はパスを保った（18/18 が `/Volumes/DJIMIC3`）
- 実機の 2 回（[13]・[18]）は `failed to unmount`（[13] は `dissented by PID 75766 (/bin/bash)`）。使用中による拒否で、voicedock #107（34 回中 3 回）と同じ種類。T-15 の再試行で扱う
- ディスクイメージ（/Volumes の外）は、アンマウントの後もディレクトリが残り、`-mountPoint` 付きで 20/20 が ro・パス保持
- **決定（章 14）: 本番の再マウントは `-mountPoint` を使わない（T-15 の `DiskutilRemounter(useMountPoint: false)` を既定）。テストは一時ディレクトリに attach するので `useMountPoint: true`**
- 限界: 同じ名前のボリュームが 2 つあるときの再マウントのパスの変化は測れなかった。起きても T-13 の規則 8（マウント名とボリューム名の不一致 → `mount_name_mismatch` で取り込まない）が安全側に倒す
- FAT のボリューム名は大文字で記録される（`PoCDJI` → `POCDJI`）。DJI Mic 3 の既定名 `DJIMIC3` は元から大文字なので影響しないが、利用者が小文字を含む名前に改名した場合の照合（T-13）に関わる

## 4. P0-03 子プロセスの unlink

判定: ✅ PASS

測定日: 2026-09-22（macOS 26.6.2）。PoCMenuBar（Apple Development 署名）の「子に unlink させる」が `Contents/Helpers/pocunlink` を `posix_spawn`（`POSIX_SPAWN_SETPGROUP`、環境は `PATH=/usr/bin:/bin` だけ）で起動し、選んだ 1 つのパスを `unlink(2)` させた。実機の操作は利用者が行った。

### ディスクイメージ（`~/VoiceDockPoC/mnt/PoCDJI`。/Volumes の外。実機は抜いた状態）

`TX_MIC001_20260918_120000/TX00_MIC001_20260918_120000_orig.wav`（1 MiB の乱数）を作って消させた。FAT に書いたとき macOS が `._TX00_…`（AppleDouble）を自動で作ったが、本体の unlink で一緒に消えた。

### 実機（/Volumes/DJIMIC3。この試験のために 5 秒ずつ新しく録った 2 本だけを使った）

削除の前（読み取りの `ls -laT` だけ）:

```text
TX_MIC001_20260915_165730/
-rwx------  1 terada  staff  1189096 Sep 22 01:39:50 2026 TX00_MIC001_20260922_013951_orig.wav
-rwx------  1 terada  staff  1078216 Sep 22 01:40:02 2026 TX00_MIC002_20260922_014002_orig.wav
```

1 本目をアプリの子で、2 本目をターミナルから直接消した:

```text
2026-09-22T01:37:51.598+09:00 child unlink /Users/terada/VoiceDockPoC/mnt/PoCDJI/TX_MIC001_20260918_120000/TX00_MIC001_20260918_120000_orig.wav spawn_rc=0 exit=0 out=ok exists_after=false
2026-09-22T01:42:07.656+09:00 child unlink /Volumes/DJIMIC3/TX_MIC001_20260915_165730/TX00_MIC001_20260922_013951_orig.wav spawn_rc=0 exit=0 out=ok exists_after=false
```

```text
$ ~/VoiceDockPoC/.build/release/pocunlink "/Volumes/DJIMIC3/TX_MIC001_20260915_165730/TX00_MIC002_20260922_014002_orig.wav"
ok
```

削除の後、フォルダ `TX_MIC001_20260915_165730` は空（フォルダ自体は残った）。

根拠:
- ディスクイメージ: `exit=0 out=ok exists_after=false`
- 実機: `spawn_rc=0 exit=0 out=ok exists_after=false`。**アプリの子として起動した reaper が実機の録音を消せる**（PLAN §8.9.3 の方式が成り立つ。RK-01 は解消）
- ターミナルから直接でも `ok`（このターミナルは以前にリムーバブルボリュームの許可を得ている。TCC の差はこの環境では観測できなかった）

所見:
- **DJI Mic 3 は既存のフォルダ（`TX_MIC001_20260915_165730`、9 月 15 日の名前）に新しい録音（9 月 22 日の名前）を追加した。**フォルダ名の日時とファイル名の日時は一致しない。T-13 のフォルダ規則・T-07 の検証はどちらも名前の形だけを見るので影響しないが、partkey は親フォルダ名を含むので、同じフォルダに別の日の録音が入ることを前提にする（取り込み・Session の組み立ての確認は T-18 / T-22 と実機 E2E で）
- 2 本目のファイル名は `TX00_MIC002_…`（MIC の番号が 002）。1 本目は `MIC001`。T-06 の RecordingName の規則（`TX\d{2}_MIC\d{3}_…`）に合う
- 許可のダイアログは出なかった（以前の許可が残っていた）
- 削除の後、空のフォルダは残る（reaper はファイルだけを消す設計のまま）

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

判定: ✅ PASS（限界あり。下記）

測定日: 2026-09-21（macOS 26.6.2）。操作は利用者が PoCMenuBar の「Vault を試す」（NSOpenPanel で選ぶ）と「前回の Vault を再試行（パネル無し）」（UserDefaults に覚えたパスへ、パネルを出さずに opendir・access(W_OK)・`.poc-write-test.tmp` の作成と削除）で行った。

手順: `~/Documents/PoCVault/.obsidian` と `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/PoCVault/.obsidian` を作る → `tccutil reset SystemPolicyDocumentsFolder io.github.shinsuke-terada.VoiceDockPoC` → 書類の Vault をパネルで選ぶ → パネル無しで再試行 → 再起動してパネル無しで再試行 → `tccutil reset All io.github.shinsuke-terada.VoiceDockPoC` → 再起動してパネル無しで再試行 → iCloud の Vault をパネルで選ぶ → 再起動してパネル無しで再試行。**どの場面でも許可ダイアログは出なかった**（利用者の観察）。終わった後に 2 つの Vault を消した。

```text
2026-09-21T23:17:03.065+09:00 launch pid=99359 bundle=io.github.shinsuke-terada.VoiceDockPoC
2026-09-21T23:17:27.185+09:00 vault[panel] /Users/terada/Documents/PoCVault opendir ok access(W_OK)=0 
2026-09-21T23:17:27.185+09:00 vault create ok, unlink=ok
2026-09-21T23:18:02.975+09:00 vault[no-panel] /Users/terada/Documents/PoCVault opendir ok access(W_OK)=0 
2026-09-21T23:18:02.976+09:00 vault create ok, unlink=ok
2026-09-21T23:18:23.398+09:00 launch pid=1783 bundle=io.github.shinsuke-terada.VoiceDockPoC
2026-09-21T23:18:34.225+09:00 vault[no-panel] /Users/terada/Documents/PoCVault opendir ok access(W_OK)=0 
2026-09-21T23:18:34.226+09:00 vault create ok, unlink=ok
2026-09-21T23:19:22.456+09:00 launch pid=3861 bundle=io.github.shinsuke-terada.VoiceDockPoC
2026-09-21T23:19:30.553+09:00 vault[no-panel] /Users/terada/Documents/PoCVault opendir ok access(W_OK)=0 
2026-09-21T23:19:30.553+09:00 vault create ok, unlink=ok
2026-09-21T23:20:42.312+09:00 vault[panel] /Users/terada/Library/Mobile Documents/iCloud~md~obsidian/Documents/PoCVault opendir ok access(W_OK)=0 
2026-09-21T23:20:42.312+09:00 vault create ok, unlink=ok
2026-09-21T23:20:57.488+09:00 launch pid=6277 bundle=io.github.shinsuke-terada.VoiceDockPoC
2026-09-21T23:21:06.753+09:00 vault[no-panel] /Users/terada/Library/Mobile Documents/iCloud~md~obsidian/Documents/PoCVault opendir ok access(W_OK)=0 
2026-09-21T23:21:06.754+09:00 vault create ok, unlink=ok
```

根拠:
- NSOpenPanel で選んだ Vault（書類フォルダ・iCloud Drive の Obsidian の保管庫）は、ダイアログ無しで opendir・`access(W_OK)=0`・ファイルの作成と削除ができた
- **アプリを再起動した後も、パネルを出さずに同じパスへ書けた**（書類・iCloud とも）。本番のアプリ（T-31 の最初の設定で Vault を NSOpenPanel で選び、以後はパスで書く）の前提が成り立つ
- `tccutil reset All <bundle id>` の後でも、一度パネルで選んだ書類の Vault にはダイアログ無しで書けた

限界:
- **拒否（EPERM）の経路と、パネルで一度も選んでいない書類フォルダの場所に書いたときのダイアログは再現できなかった。**一度パネルで選ぶと、`tccutil reset SystemPolicyDocumentsFolder`・`tccutil reset All` の後も許可が残った（P0-01 のリムーバブルボリュームは `reset All` で消えたのと違う）。PLAN §8.7 の `.notReadable` の文言と DR-10 の案内文は、実測で直す材料が無いので**そのまま**にする
- Vault を別の場所（別のマシンから移した保管庫など）に変えたときも、T-31 の設定の画面で NSOpenPanel で選び直す前提を保つ（パスを文字列で入力させない）

## 14. Phase 0 で決めたこと

| 名前 | 値 | 根拠 |
|---|---|---|
| BUNDLE_ID | io.github.shinsuke-terada.VoiceDock | PLAN §3.1（2026-09-21 利用者が確定） |
| TEAM_ID | ZCWP35H248 | 章 1（`Apple Distribution: Shinsuke Terada (ZCWP35H248)`。2026-09-21 利用者が確定） |
| Xcode | 27.0（27A266a） | 章 1 |
| llama.cpp | b11033（8ed1a55efcd7424d2c592f6cbc9f97756db1d74d）。章 7 で問題があれば見直す | 章 7（未実施） |
| whisper.cpp | v1.9.4（927cfce34f31707e17f2bff35c349632fb9e2c3a） | 章 5（未実施） |
| 再マウントの -mountPoint | **使わない**（本番 `useMountPoint: false`。テストは一時ディレクトリなので `true`） | 章 3 |
| CI のランナー | 開発機のセルフホストランナー `voicedock-local`（self-hosted, macOS, ARM64。v2.337.0） | 章 11 |
