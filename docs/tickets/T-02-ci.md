# T-02 CI（GitHub Actions）と P0-10

| 項目 | 値 |
|---|---|
| ID | T-02 |
| 題 | CI（PLAN §10.8。開発機のセルフホストランナー）と P0-10 の扱い |
| Phase | 1 |
| 前提 | T-01 |
| 見積もり | 約 150 行（ci.yml 約 35、テスト約 80、POC.md の章 11） |

## 目的

PR ごとに lint → build → ND → policy → 残りのテストを 1 つの job で回し、`main` に入るものを必ず検証する。
ランナーは**開発機（実機 DJI Mic 3 がつながることがある Mac）のセルフホストランナー**にする（2026-09-21 利用者の決定。GitHub の macOS ランナーは非公開リポジトリで分数が 10 倍になるため）。
開発機では実機を抜いてある保証が無いので、ディスクイメージのテスト（`.diskImage`）と P0-10 の probe は CI で走らせない。

## 参照

- PLAN §10.8、§3.3、§12.2（P0-10）、§14（RK-06・RK-33）、§9.4 PT-13
- voicedock@d3d595e `.github/workflows/ci.yml`（ND を別 job にしていた。本アプリは 1 job の先頭ステップ。X-20）

## 作るもの

| パス | 内容 |
|---|---|
| `.github/workflows/ci.yml` | 下記の全文（P0-10 の結果で `env` の 1 行を足すか決める） |
| `Tests/PolicyTests/CIWorkflowTests.swift` | ci.yml と Makefile が同じコマンドを使うことの検査 |
| `docs/POC.md` 章 11 | P0-10 を行わない理由と、セルフホストランナーの確認結果 |

## 安全の規則

- **テストと測定は `/Volumes` 配下の実機（利用者が挿している DJI Mic 3 など）に一切触れない。**`diskutil`・`hdiutil detach`・書き込み・削除・再マウントをしない
- P0-10 の probe（GitHub のランナーで `hdiutil` と `diskutil` を試す台本）は**作らない・走らせない**。セルフホストランナーは開発機そのもので、`-mountPoint` を付けない `diskutil mount` の逃げ道が `/Volumes` に出るため
- ci.yml に `VOICEDOCK_DISK_TESTS` を付けない（CI が走るたびに実機が抜いてあることを保証できない。safety.md の 4）
- ci.yml に `sudo` を書かない（セルフホストランナーは利用者の権限で動く。safety.md の 9）。Xcode の版は `make check-toolchain` で確かめるだけにし、切り替えは利用者が行う
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
    runs-on: [self-hosted, macOS, ARM64]   # 開発機のセルフホストランナー（Xcode 27.0）。利用者の決定（T-02）
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1   # v7.0.1
      - run: make check-toolchain
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

- `env: VOICEDOCK_DISK_TESTS: "1"` は**足さない**（上の安全の規則）。README（T-43。F-93 からは `docs/DEVELOPMENT.md`）に「CI の ND は層 R1・R2 だけ。R3 は手元の `make test-disk`」と書き、**削除に触れる PR は、実機を抜いたことを利用者が確かめたうえで手元の `make test-disk` を回し、その結果を PR 本文に貼る**（PLAN §10.8）
- `runs-on:` はセルフホストランナーの既定のラベル 3 つ（`self-hosted`・`macOS`・`ARM64`）で固定する（`latest` を使わない。PT-13）
- `make check-toolchain` は `.xcode-version` と開発機の Xcode が食い違ったら落ちる。`xcode-select` の切り替えは CI でしない

### 2. P0-10（行わない）

セルフホストランナーは開発機そのものなので、P0-10（GitHub のランナーでのディスクイメージ）は行わない。`docs/POC.md` の目次の章 11 の判定を `— 対象外` にし、章 11 に次を書く:

- 理由: CI のランナーを開発機のセルフホストランナーにした（2026-09-21 利用者の決定）。開発機には実機がつながることがあり、probe の `diskutil mount`（`-mountPoint` 無しの逃げ道）が `/Volumes` に出るため
- 代わり: ディスクイメージのテストは、実機を抜いたことを利用者が確かめてから手元の `make test-disk` で回す（R3 の層）

### 3. セルフホストランナーの確認（T-02 の PR の最初の push で行う）

1. 【利用者が行う】リポジトリの Settings → Actions → Runners から macOS / ARM64 のランナーを `~/actions-runner` に展開し、`./config.sh --url https://github.com/shinsuke-terada/voicedock-app --token <トークン> --name voicedock-local --unattended` → `./svc.sh install && ./svc.sh start`（LaunchAgent。sudo は要らない）
2. `gh api repos/shinsuke-terada/voicedock-app/actions/runners` で `voicedock-local` が `online` であることを確かめる
3. `feat/T-02-ci` を push し、PR を作る。`check` の job がランナーに割り当てられ、`make check-toolchain` のステップが通ることを確かめる
4. 結果（ランナー名・ラベル・job の URL・1 回の実行時間）を `docs/POC.md` 章 11 と章 14 の「CI のランナー」に書く

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

    /// ci.yml の `run:` の値を出現順に返す（`make check-toolchain` の行は除く）。
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
            if command == "make check-toolchain" { continue }
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
- [ ] `docs/POC.md` 章 11 に P0-10 を行わない理由（`— 対象外`）と、セルフホストランナーの確認結果がある。章 14 の「CI のランナー」が埋まっている
- [ ] ci.yml に `VOICEDOCK_DISK_TESTS` と `sudo` が無い
- [ ] ブランチ保護を設定した（または使えなかった応答を貼った）

## SPEC の変更

なし。

## マージ後にやること

- ブランチ保護が使えた場合、`main` への PR で `check` が必須になっていることを確かめる
- ランナーが止まっていると CI が「Waiting for a runner」のまま進まない。開発機を再起動したら `~/actions-runner/svc.sh status` を確かめる
