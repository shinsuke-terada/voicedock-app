# T-02 CI（GitHub Actions）と P0-10

| 項目 | 値 |
|---|---|
| ID | T-02 |
| 題 | CI（PLAN §10.8）と P0-10（GitHub ランナーでのディスクイメージ）の反映 |
| Phase | 1 |
| 前提 | T-01 |
| 見積もり | 約 150 行（ci.yml 約 35、テスト約 80、POC.md の章 11） |

## 目的

PR ごとに lint → build → ND → policy → 残りのテストを 1 つの job で回し、`main` に入るものを必ず検証する。
あわせて、ランナーのラベル `xcode-27` が非公開リポジトリで使えるかと、ディスクイメージのテスト（`.diskImage`）が CI で動くか（P0-10）を確かめ、CI の形を確定する。

## 参照

- PLAN §10.8、§3.3、§12.2（P0-10）、§14（RK-06・RK-33）、§9.4 PT-13
- voicedock@d3d595e `.github/workflows/ci.yml`（ND を別 job にしていた。本アプリは 1 job の先頭ステップ。X-20）

## 作るもの

| パス | 内容 |
|---|---|
| `.github/workflows/ci.yml` | 下記の全文（P0-10 の結果で `env` の 1 行を足すか決める） |
| `Tests/PolicyTests/CIWorkflowTests.swift` | ci.yml と Makefile が同じコマンドを使うことの検査 |
| `docs/POC.md` 章 11 | P0-10 の記録（手順と生の出力） |
| （一時）`.github/workflows/p0-10-probe.yml` | P0-10 の測定用。**`probe/p0-10` ブランチにだけ置き、PR には含めない** |

## 安全の規則

- **テストと測定は `/Volumes` 配下の実機（利用者が挿している DJI Mic 3 など）に一切触れない。**`diskutil`・`hdiutil detach`・書き込み・削除・再マウントをしない
- §2 の `p0-10-probe.yml` は **GitHub のランナーの上でだけ**動かす。手元の Mac で同じコマンドを実行しない（`-mountPoint` を付けない `diskutil mount` が `/Volumes` に出るため）
- 手元の `.diskImage` のテスト（`make test-disk`）は、`DiskImageVolume`（TestSupport）が一時ディレクトリの下（`<tmp>/Volumes/DJIMIC3`）に `-mountpoint` 付きで attach し、再マウントも `-mountPoint` 付きで行う。テストが `/Volumes` に何かを出すことはない（出すテストを書かない）

## 仕様

### 1. `.github/workflows/ci.yml`（全文）

```yaml
name: ci
on:
  push: { branches: [main, develop] }
  pull_request: { branches: [main, develop, "feat/**"] }
concurrency: { group: "ci-${{ github.ref }}", cancel-in-progress: true }
permissions: { contents: read }
jobs:
  check:
    runs-on: xcode-27            # 手元と同じ Xcode 27.0（27A266a）。T-02 で確定（PLAN §10.8）
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1   # v7.0.1
      - run: sudo xcode-select -s "/Applications/Xcode_$(cat .xcode-version).app"
      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9      # v6.1.0。.build を Package.resolved と .xcode-version のハッシュで
        with:
          path: .build
          key: spm-${{ runner.os }}-${{ hashFiles('Package.resolved', '.xcode-version') }}
      - name: lint
        run: make lint
      - name: build
        run: swift build --build-tests
      - name: ND（削除禁止。最初に走らせる）
        run: swift test --skip-build --filter "NoDeleteTests|ReaperTests"
      - name: policy + spec sync
        run: swift test --skip-build --filter PolicyTests
      - name: other tests
        run: swift test --skip-build --skip "NoDeleteTests|ReaperTests|PolicyTests|LLMAcceptance"
```

- **P0-10 が ✅（ディスクイメージの attach・ro 再マウント・statfs・unlink がすべて CI で動いた）なら**、`timeout-minutes: 30` の次の行に次の 2 行を足す（job 全体に掛かる。`.diskImage` のテストは ND 以外のターゲットにもあるため）:
  ```yaml
      env:
        VOICEDOCK_DISK_TESTS: "1"
  ```
- **✗ なら足さない**。その場合、README（T-43）に「CI の ND は層 R1・R2 だけ。R3 は手元の `make test-disk`」と書き、**削除に触れる PR は手元の `make test-disk` の結果を PR 本文に貼る**（PLAN §10.8）
- ランナーが `xcode-27` を使えなかった場合（下記 §3）、`runs-on:` を `macos-26` にし、コメントを `# Xcode 26.6。xcode-27 は非公開リポジトリで使えなかった（T-02）` に変える。同じ PR で `.xcode-version` を `26.6` にし、手元の Xcode も 26.6 にそろえる

### 2. P0-10 の手順（`probe/p0-10` ブランチ。結果を `docs/POC.md` 章 11 に貼る）

1. `git switch -c probe/p0-10 develop`
2. 次の `.github/workflows/p0-10-probe.yml` を作って push する（**この PR は作らない**。測り終えたらブランチを消す）:

```yaml
name: p0-10-probe
on:
  push: { branches: ["probe/p0-10"] }
permissions: { contents: read }
jobs:
  probe:
    runs-on: xcode-27
    timeout-minutes: 15
    steps:
      - name: environment
        run: |
          sw_vers
          uname -m
          xcodebuild -version
          ls -d /Applications/Xcode*.app
      - name: fat32 image
        run: |
          set -x
          tmp="$(cd "$RUNNER_TEMP" && pwd -P)/p010"
          mkdir -p "$tmp/Volumes"
          hdiutil create -size 64m -fs "MS-DOS FAT32" -volname DJIMIC3 "$tmp/img.dmg"
          hdiutil attach -nobrowse -mountpoint "$tmp/Volumes/DJIMIC3" "$tmp/img.dmg"
          mount | grep -F "$tmp/Volumes/DJIMIC3"
          node="$(mount | awk -v m="$tmp/Volumes/DJIMIC3" '$3 == m { print $1 }')"
          echo "node=$node"
          mkdir -p "$tmp/Volumes/DJIMIC3/TX_MIC001_20260918_120000"
          dd if=/dev/urandom of="$tmp/Volumes/DJIMIC3/TX_MIC001_20260918_120000/TX00_MIC001_20260918_120000_orig.wav" bs=1k count=64
          python3 -c "import os,sys; s=os.statvfs(sys.argv[1]); print('ST_RDONLY', bool(s.f_flag & os.ST_RDONLY))" "$tmp/Volumes/DJIMIC3"
          diskutil unmount "$tmp/Volumes/DJIMIC3"
          diskutil mount readOnly -mountPoint "$tmp/Volumes/DJIMIC3" "$node" || diskutil mount readOnly "$node"
          mount | grep -F "$node"
          python3 -c "import os,sys; s=os.statvfs(sys.argv[1]); print('ST_RDONLY', bool(s.f_flag & os.ST_RDONLY))" "$tmp/Volumes/DJIMIC3" || true
          touch "$tmp/Volumes/DJIMIC3/write-test" && echo "WRITABLE" || echo "READONLY"
          diskutil unmount "$node" || true
          diskutil mount -mountPoint "$tmp/Volumes/DJIMIC3" "$node" || diskutil mount "$node"
          mount | grep -F "$node"
          rm "$tmp/Volumes/DJIMIC3/TX_MIC001_20260918_120000/TX00_MIC001_20260918_120000_orig.wav" && echo "UNLINKED"
          hdiutil detach -force "$node"
      - name: hfs image (ND-39 unexpected_fs)
        run: |
          set -x
          tmp="$(cd "$RUNNER_TEMP" && pwd -P)/p010hfs"
          mkdir -p "$tmp/Volumes"
          hdiutil create -size 64m -fs "HFS+" -volname DJIMIC3 "$tmp/img.dmg"
          hdiutil attach -nobrowse -mountpoint "$tmp/Volumes/DJIMIC3" "$tmp/img.dmg"
          mount | grep -F "$tmp/Volumes/DJIMIC3"
          hdiutil detach -force "$tmp/Volumes/DJIMIC3"
```

3. 実行ログ（両ステップの全出力）を `docs/POC.md` 章 11 に貼る
4. 判定（章 11 の判定欄）:
   - ✅: FAT32 イメージの attach、`mount` の出力が `msdos`、ro 再マウント後に `ST_RDONLY True` と `READONLY`、rw に戻した後の `UNLINKED`、HFS+ イメージの attach がすべて出た
   - ✗: どれかが失敗した（失敗したコマンドとエラーを貼る）
   - `-mountPoint` を付けた再マウントが失敗して付けない方で成功した場合は、その事実も書く（P0-02 の判断の材料）
5. `git push origin --delete probe/p0-10`（一時ブランチを消す）

### 3. ランナー `xcode-27` の確認（T-02 の PR の最初の push で行う）

1. `feat/T-02-ci` を push し、PR を作る
2. Actions の画面で `check` の job が **10 分以内に**ランナーに割り当てられ、`xcode-select` のステップが通ることを確かめる
3. 次のどれかなら `macos-26` に切り替える（§1 の最後の項）:
   - 「No runner matching the specified labels was found」で失敗する
   - 10 分たっても「Waiting for a runner」のまま
   - `/Applications/Xcode_27.0.app` が無い（`xcode-select` のステップが失敗）
4. 結果（使えたラベル・job の URL・待ち時間・1 回の実行時間）を `docs/POC.md` 章 11 と章 14 の「CI のランナー」に書く

### 4. lint の違反で落ちることの確認

1. T-02 の PR の中で、`Tests/PolicyTests/RepositoryLayoutTests.swift` の `import TestSupport` と `import Testing` の順を入れ替えたコミットを push する
2. CI の `lint` ステップが失敗し、以降のステップが走らないことを確かめる（run の URL を PR 本文に貼る）
3. そのコミットを `git revert` して push し、CI が緑に戻ることを確かめる

### 5. ブランチ保護

`main` の保護で `check` を必須にする（**GitHub の設定を変える操作なので、利用者の確認を得てから行う**）:

```bash
gh api -X PUT repos/shinsuke-terada/voicedock-app/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["check"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

- 非公開リポジトリのブランチ保護は GitHub Free では使えない（`403 Upgrade to GitHub Pro or make this repository public`）。その場合は応答をそのまま `docs/POC.md` 章 11 に貼り、「`main` への直接の push をしない・`develop` からの PR は CI が緑のときだけマージする」を README（T-43）に書く運用で代える。**使えないことを「設定した」と書かない**

### 6. `Tests/PolicyTests/CIWorkflowTests.swift`（全文）

```swift
// CI（.github/workflows/ci.yml）と Makefile が同じコマンドを同じ順で使うことの検査（PLAN §10.8。T-02）。
import Foundation
import TestSupport
import Testing

@Suite("CIWorkflow")
struct CIWorkflowTests {
    /// CI の check job が実行するコマンド（この順）。PLAN §10.8 の写し。
    static let expectedCIRuns = [
        "make lint",
        "swift build --build-tests",
        "swift test --skip-build --filter \"NoDeleteTests|ReaperTests\"",
        "swift test --skip-build --filter PolicyTests",
        "swift test --skip-build --skip \"NoDeleteTests|ReaperTests|PolicyTests|LLMAcceptance\"",
    ]

    /// ci.yml の `run:` の値を出現順に返す（`xcode-select` の行は除く）。
    static func ciRunCommands() throws -> [String] {
        let text = try String(contentsOf: PackageRoot.file(".github/workflows/ci.yml"), encoding: .utf8)
        var runs: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let body: Substring
            if trimmed.hasPrefix("- run: ") {
                body = trimmed.dropFirst("- run: ".count)
            } else if trimmed.hasPrefix("run: ") {
                body = trimmed.dropFirst("run: ".count)
            } else {
                continue
            }
            let command = String(body).trimmingCharacters(in: .whitespaces)
            if command.hasPrefix("sudo xcode-select") { continue }
            runs.append(command)
        }
        return runs
    }

    /// Makefile の `test:` のレシピの `swift test` の行を出現順に返す（`$(SWIFT)` を `swift` に置き換える）。
    static func makefileTestCommands() throws -> [String] {
        let text = try String(contentsOf: PackageRoot.file("Makefile"), encoding: .utf8)
        var inTest = false
        var commands: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("test:") {
                inTest = true
                continue
            }
            if inTest {
                guard line.hasPrefix("\t") else { break }
                let command = line.dropFirst().replacingOccurrences(of: "$(SWIFT)", with: "swift")
                if command.hasPrefix("swift test") { commands.append(command) }
            }
        }
        return commands
    }

    @Test("ci.yml の check は lint → build → ND → policy → 残りの順に実行する")
    func ciRunsExpectedCommandsInOrder() throws {
        #expect(try Self.ciRunCommands() == Self.expectedCIRuns)
    }

    @Test("Makefile の test は CI と同じ swift test を同じ順に実行する")
    func makefileTestMatchesCI() throws {
        let ciTests = Self.expectedCIRuns.filter { $0.hasPrefix("swift test") }
        #expect(try Self.makefileTestCommands() == ciTests)
    }

    @Test("ci.yml の最後のステップは ND と Policy をもう一度走らせない")
    func lastStepSkipsNDAndPolicy() throws {
        let last = try #require(try Self.ciRunCommands().last)
        #expect(last.contains("--skip \"NoDeleteTests|ReaperTests|PolicyTests|LLMAcceptance\""))
    }
}
```

## テスト

| ファイル | 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|---|
| `Tests/PolicyTests/CIWorkflowTests.swift` | `ciRunsExpectedCommandsInOrder()` | ci.yml の check は lint → build → ND → policy → 残りの順に実行する | リポジトリの ci.yml | `run:` の列が `expectedCIRuns` と一致 |
| 同上 | `makefileTestMatchesCI()` | Makefile の test は CI と同じ swift test を同じ順に実行する | リポジトリの Makefile | `test:` の `swift test` 3 行が CI の 3 行と一致 |
| 同上 | `lastStepSkipsNDAndPolicy()` | ci.yml の最後のステップは ND と Policy をもう一度走らせない | 同上 | 最後の `run:` が 4 つを `--skip` している |

（`uses:` の SHA 固定と `runs-on:` の `latest` 禁止は T-04 の PT-13 が検査する。ここでは重ねない。）

## 破壊による証明

| 壊し方 | 落ちるべきもの |
|---|---|
| ci.yml の ND と policy のステップの順を入れ替える | `ciRunsExpectedCommandsInOrder()` |
| Makefile の `test:` から Policy の行を消す | `makefileTestMatchesCI()` |
| ci.yml の最後のステップの `--skip` から `PolicyTests\|` を消す | `ciRunsExpectedCommandsInOrder()`、`lastStepSkipsNDAndPolicy()` |
| §4 のとおり import の順を入れ替えて push | CI の `lint` ステップ（run の URL を貼る） |

## 受け入れ条件

- [ ] `develop` 向けの PR で CI の `check` が緑（run の URL を PR に貼る）
- [ ] lint の違反を入れたコミットで CI が `lint` で落ちた（run の URL を PR に貼る）
- [ ] `docs/POC.md` 章 11 に P0-10 の生の出力・判定と、ランナーの確認結果がある。章 14 の「CI のランナー」が埋まっている
- [ ] P0-10 の判定に合わせて ci.yml の `env`（`VOICEDOCK_DISK_TESTS`）を足した／足さなかった理由が PR に書いてある
- [ ] ブランチ保護を設定した（または使えなかった応答を貼った）
- [ ] `probe/p0-10` ブランチを消した

## SPEC の変更

なし。

## マージ後にやること

- ブランチ保護が使えた場合、`main` への PR で `check` が必須になっていることを確かめる
- ランナーを `macos-26` に下げた場合は、PLAN §3.3・§10.8 と RK-33 の記述を直す PR を出す
