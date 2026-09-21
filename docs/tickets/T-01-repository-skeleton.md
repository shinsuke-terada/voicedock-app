# T-01 リポジトリの骨組み

| 項目 | 値 |
|---|---|
| ID | T-01 |
| 題 | リポジトリ・Package.swift・モジュール・VERSION・.xcode-version・.swift-format・Makefile・docs/PLAN.md |
| Phase | 1 |
| 前提 | P0（`docs/POC.md` 章 14 で BUNDLE_ID・TEAM_ID・Xcode の版が決まっていること） |
| 見積もり | 手で書く行 約 450（Package.swift 約 100、Makefile 約 70、.swift-format 約 80、TestSupport 約 105、テスト約 45、その他）。docs のコピーは数えない |

## 目的

全員が同じ構成・同じ設定でビルドとテストを始められる骨組みを作る。以後のチケットはこの上にファイルを足すだけにする。

## 参照

- PLAN §3.1〜§3.4、§10.1（環境変数でのテストの有効化）、§10.2（TestSupport）、§11.4（VERSION）、§12.1（進め方）
- 00-api-map §14（テストのターゲット）、README（共通の書き方）

## 作るもの

リポジトリのルートは `/Users/terada/Projects/voicedock_app`（GitHub の名前は `shinsuke-terada/voicedock-app`、非公開）。

| パス | 内容 |
|---|---|
| `.gitignore` | 下記の全文 |
| `README.md` | 下記の全文（仮。T-43 で書き直す） |
| `identity.env` | 下記の全文（値は P0 の章 14 から写す） |
| `docs/PLAN.md` | `tmp/witty-gliding-clover.md`（計画書 v1.1）を**バイト単位でそのまま**コピー |
| `docs/POC.md` | P0 の記録（P0 で書いたもの） |
| `docs/tickets/*.md` | 既存のチケット一式（そのままコミット） |
| `docs/porting-notes/**` | 既存の移植メモ（V1〜V7・BRIEFING・R1・R2 など）と機械検査 `check-tickets.py`（そのままコミット。CLAUDE.md と ticket-brief が参照する） |
| `CLAUDE.md`, `.claude/**` | 既存の AI 開発ハーネス（そのままコミット。新しく書かない） |
| `Package.swift` | 下記の全文 |
| `Package.resolved` | `swift package resolve` が生成したもの（手で書かない。下記の値になることを確かめる） |
| `VERSION` | `0.1.0` と改行 1 つ |
| `.xcode-version` | `27.0` と改行 1 つ（P0 の章 14 の Xcode の版） |
| `.swift-format` | 下記の全文 |
| `Makefile` | 下記の全文 |
| `Sources/<モジュール>/ModuleMarker.swift` | 11 のライブラリそれぞれに下記の 2 行 |
| `Sources/VoiceDockApp/main.swift` | 下記の 1 行（コメントだけ） |
| `Sources/voicedock-reaper/main.swift` | 下記の 1 行（コメントだけ） |
| `Tests/<ターゲット>/TargetMarker.swift` | PolicyTests を除く 15 のテストターゲットそれぞれに下記の 2 行 |
| `Tests/TestSupport/PackageRoot.swift` | 下記の全文 |
| `Tests/TestSupport/TestEnvironment.swift` | 下記の全文 |
| `Tests/TestSupport/TempDirectory.swift` | 下記の全文 |
| `Tests/TestSupport/Tags.swift` | 下記の全文 |
| `Tests/PolicyTests/RepositoryLayoutTests.swift` | 下記の全文 |

11 のライブラリ: `VDContract` `VDCore` `VDStore` `VDProcess` `VDAudio` `VDDevice` `VDTranscribe` `VDLLM` `VDNotes` `VDModels` `VDPipeline`。
16 のテストターゲット: `VDContractTests` `VDCoreTests` `VDStoreTests` `VDProcessTests` `VDAudioTests` `VDDeviceTests` `VDTranscribeTests` `VDLLMTests` `VDNotesTests` `VDModelsTests` `VDPipelineTests` `VoiceDockAppTests` `NoDeleteTests` `ReaperTests` `PolicyTests` `LLMAcceptance`。

（PLAN §3.2 の木に無い `VDProcessTests` と `VoiceDockAppTests` を足している。T-12 の ProcessRunner と T-30 の AppModel の単体テストの置き場所。）

## 仕様

### 1. 手順（この順に行う）

1. P0 の `docs/POC.md` 章 14 が埋まっていることを確かめる
2. `cd /Users/terada/Projects/voicedock_app && git init -b main`
3. `.gitignore`・`README.md`・`identity.env` を下記のとおり作り、`docs/PLAN.md` に計画書をコピーする:
   ```bash
   cp tmp/witty-gliding-clover.md docs/PLAN.md
   cmp tmp/witty-gliding-clover.md docs/PLAN.md   # 何も出ないこと
   ```
   `tmp/` は `.gitignore` で除外する（消さない）。以後、計画の正は `docs/PLAN.md`
4. **main の最初のコミット**（ドキュメントだけ）:
   ```bash
   git add .gitignore README.md identity.env docs/PLAN.md docs/POC.md docs/tickets \
           docs/porting-notes CLAUDE.md .claude
   git commit -m "docs: 計画・チケット・PoC の記録"
   git branch develop
   ```
5. GitHub に非公開リポジトリを作って push する（**外部へ公開する操作なので、利用者の確認を得てから行う**）:
   ```bash
   gh repo create shinsuke-terada/voicedock-app --private --source . --remote origin
   git push -u origin main develop
   ```
6. `git switch -c feat/T-01-repository-skeleton develop`
7. 残りのファイル（Package.swift 以下）を作る
8. `swift package resolve` → `Package.resolved` が生成されることを確かめる
9. `make lint && make test` が通ることを確かめる
10. コミットして push、`develop` 向けの PR を作る（PR 本文は README の必須節）

### 2. `.gitignore`

```gitignore
# SwiftPM / Xcode
.build/
.swiftpm/
*.xcodeproj/
xcuserdata/
DerivedData/

# Vendor のビルド（T-03。成果物はコミットしない）
Vendor/work/
Vendor/build/

# .app と dmg（T-34）
dist/

# 計画書の元の置き場所（docs/PLAN.md が正）
tmp/

# 個人用の Claude Code の設定（ハーネス本体はコミットする）
.claude/settings.local.json

# macOS
.DS_Store
```

### 3. `README.md`（仮）

```markdown
# VoiceDock for Mac

DJI Mic 3 の録音を文字起こしして、Obsidian の Vault にノートを残す macOS のメニューバーアプリ。

- 計画: [docs/PLAN.md](docs/PLAN.md)
- タスク: [docs/tickets/README.md](docs/tickets/README.md)
- 開発: `make lint`、`make test`（Xcode は `.xcode-version` の版を使う）

利用者向けの説明は T-43 で書く。
```

### 4. `identity.env`

P0 の章 14 から写す（`TEAM_ID` は秘密ではない。署名の要件文字列に使う）:

```bash
# アプリの識別子（PLAN §3.1）。初回リリース後は変更禁止。
BUNDLE_ID=io.github.shinsuke-terada.VoiceDock
TEAM_ID=<P0 章 14 の 10 文字>
```

### 5. `Package.swift`（全文。`swift format` で整形済みの形）

```swift
// swift-tools-version: 6.2
// VoiceDock for Mac のパッケージ定義（PLAN §3.2〜§3.4）。依存は GRDB と Yams の 2 つだけ（exact で固定）。
import PackageDescription

/// 自分のターゲットだけに掛ける設定。依存（GRDB・Yams）には掛からない（SE-0480）。
let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")
let yams: Target.Dependency = .product(name: "Yams", package: "Yams")

/// TestSupport とテストが使うライブラリ（実行ファイルを除く全モジュール）。
let libraryModules: [Target.Dependency] = [
    "VDContract", "VDCore", "VDStore", "VDProcess", "VDAudio", "VDDevice",
    "VDTranscribe", "VDLLM", "VDNotes", "VDModels", "VDPipeline",
]

let package = Package(
    name: "VoiceDock",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "VoiceDockApp", targets: ["VoiceDockApp"]),
        .executable(name: "voicedock-reaper", targets: ["voicedock-reaper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .target(name: "VDContract", swiftSettings: strictSettings),
        .target(name: "VDCore", dependencies: ["VDContract"], swiftSettings: strictSettings),
        .target(name: "VDStore", dependencies: ["VDContract", "VDCore", grdb], swiftSettings: strictSettings),
        .target(name: "VDProcess", dependencies: ["VDCore"], swiftSettings: strictSettings),
        .target(name: "VDAudio", dependencies: ["VDContract", "VDCore"], swiftSettings: strictSettings),
        .target(
            name: "VDDevice",
            dependencies: ["VDContract", "VDCore", "VDProcess", "VDStore", "VDAudio"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "VDTranscribe", dependencies: ["VDContract", "VDCore", "VDProcess"], swiftSettings: strictSettings),
        .target(name: "VDLLM", dependencies: ["VDContract", "VDCore", "VDProcess"], swiftSettings: strictSettings),
        .target(name: "VDNotes", dependencies: ["VDContract", "VDCore", yams], swiftSettings: strictSettings),
        .target(name: "VDModels", dependencies: ["VDContract", "VDCore"], swiftSettings: strictSettings),
        .target(
            name: "VDPipeline",
            dependencies: [
                "VDContract", "VDCore", "VDStore", "VDProcess", "VDDevice",
                "VDAudio", "VDTranscribe", "VDLLM", "VDNotes",
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(name: "VoiceDockApp", dependencies: libraryModules, swiftSettings: strictSettings),
        .executableTarget(name: "voicedock-reaper", dependencies: ["VDContract"], swiftSettings: strictSettings),

        .target(
            name: "TestSupport", dependencies: libraryModules, path: "Tests/TestSupport", swiftSettings: strictSettings),

        .testTarget(
            name: "VDContractTests", dependencies: ["VDContract", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDCoreTests", dependencies: ["VDCore", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDStoreTests", dependencies: ["VDStore", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDProcessTests", dependencies: ["VDProcess", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDAudioTests", dependencies: ["VDAudio", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDDeviceTests", dependencies: ["VDDevice", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(
            name: "VDTranscribeTests", dependencies: ["VDTranscribe", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDLLMTests", dependencies: ["VDLLM", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDNotesTests", dependencies: ["VDNotes", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDModelsTests", dependencies: ["VDModels", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(
            name: "VDPipelineTests", dependencies: ["VDPipeline", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(
            name: "VoiceDockAppTests", dependencies: ["VoiceDockApp", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "NoDeleteTests", dependencies: ["VDPipeline", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(
            name: "ReaperTests",
            dependencies: ["VDContract", "voicedock-reaper", "TestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(name: "PolicyTests", dependencies: ["TestSupport"], swiftSettings: strictSettings),
        .testTarget(
            name: "LLMAcceptance", dependencies: ["VDPipeline", "VDLLM", "TestSupport"], swiftSettings: strictSettings),
    ],
    swiftLanguageModes: [.v6]
)
```

- 実行ファイルのターゲット名 `voicedock-reaper` のモジュール名は `voicedock_reaper`（SwiftPM がハイフンを置き換える）。テストから内部を触るときは `@testable import voicedock_reaper`
- `ReaperTests` は実行ファイルのターゲットに依存するので、`swift build --build-tests` で reaper の実行ファイルが必ずビルドされる（`ReaperBinary` が使う。PLAN §10.2）
- `TestSupport` は通常の `.target`（`path: "Tests/TestSupport"`）。`import Testing` してよい（Xcode 27.0 の `swift build` で通ることを確かめ済み）
- `Package.resolved` の期待値（`swift package resolve` の後にこうなること。`originHash` はツールが決める）:
  - `grdb.swift`: `https://github.com/groue/GRDB.swift.git`、revision `b83108d10f42680d78f23fe4d4d80fc88dab3212`、version `7.11.1`
  - `yams`: `https://github.com/jpsim/Yams.git`、revision `a27b21e0c81c5bf42049b897a62aaf387e80f279`、version `6.2.2`

### 6. `.swift-format`（全文）

ツールチェーン同梱の `swift format dump-configuration`（Xcode 27.0）の既定を元に、字下げ 4・行長 120・tab 幅 4 にし、強制アンラップ・`try!`・暗黙アンラップを禁じる 3 規則を有効にしたもの:

```json
{
  "fileScopedDeclarationPrivacy" : {
    "accessLevel" : "private"
  },
  "indentBlankLines" : false,
  "indentConditionalCompilationBlocks" : true,
  "indentSwitchCaseLabels" : false,
  "indentation" : {
    "spaces" : 4
  },
  "lineBreakAroundMultilineExpressionChainComponents" : false,
  "lineBreakBeforeControlFlowKeywords" : false,
  "lineBreakBeforeEachArgument" : false,
  "lineBreakBeforeEachGenericRequirement" : false,
  "lineBreakBetweenDeclarationAttributes" : false,
  "lineLength" : 120,
  "maximumBlankLines" : 1,
  "multiElementCollectionTrailingCommas" : true,
  "multilineTrailingCommaBehavior" : "keptAsWritten",
  "noAssignmentInExpressions" : {
    "allowedFunctions" : [
    ]
  },
  "orderedImports" : {
    "includeConditionalImports" : false,
    "shouldGroupImports" : true
  },
  "prioritizeKeepingFunctionOutputTogether" : false,
  "reflowMultilineStringLiterals" : "never",
  "respectsExistingLineBreaks" : true,
  "rules" : {
    "AllPublicDeclarationsHaveDocumentation" : false,
    "AlwaysUseLiteralForEmptyCollectionInit" : false,
    "AlwaysUseLowerCamelCase" : true,
    "AmbiguousTrailingClosureOverload" : true,
    "AvoidRetroactiveConformances" : true,
    "BeginDocumentationCommentWithOneLineSummary" : false,
    "DoNotUseSemicolons" : true,
    "DontRepeatTypeInStaticProperties" : true,
    "FileScopedDeclarationPrivacy" : true,
    "FullyIndirectEnum" : true,
    "GroupNumericLiterals" : true,
    "IdentifiersMustBeASCII" : true,
    "NeverForceUnwrap" : true,
    "NeverUseForceTry" : true,
    "NeverUseImplicitlyUnwrappedOptionals" : true,
    "NoAccessLevelOnExtensionDeclaration" : true,
    "NoAssignmentInExpressions" : true,
    "NoBlockComments" : true,
    "NoCasesWithOnlyFallthrough" : true,
    "NoEmptyLinesOpeningClosingBraces" : false,
    "NoEmptyTrailingClosureParentheses" : true,
    "NoLabelsInCasePatterns" : true,
    "NoLeadingUnderscores" : false,
    "NoParensAroundConditions" : true,
    "NoPlaygroundLiterals" : true,
    "NoVoidReturnOnFunctionSignature" : true,
    "OmitExplicitReturns" : false,
    "OneCasePerLine" : true,
    "OneVariableDeclarationPerLine" : true,
    "OnlyOneTrailingClosureArgument" : true,
    "OrderedImports" : true,
    "ReplaceForEachWithForLoop" : true,
    "ReturnVoidInsteadOfEmptyTuple" : true,
    "TypeNamesShouldBeCapitalized" : true,
    "UseEarlyExits" : false,
    "UseExplicitNilCheckInConditions" : true,
    "UseLetInEveryBoundCaseVariable" : true,
    "UseShorthandTypeNames" : true,
    "UseSingleLinePropertyGetter" : true,
    "UseSynthesizedInitializer" : true,
    "UseTripleSlashForDocumentationComments" : true,
    "UseWhereClausesInForLoops" : false,
    "ValidateDocumentationComments" : false
  },
  "spacesAroundRangeFormationOperators" : false,
  "spacesBeforeEndOfLineComments" : 2,
  "tabWidth" : 4,
  "version" : 1
}
```

この設定で後続のチケットが守ること（lint で落ちるので書き方を揃える）:
- `import` はバイト順（大文字が先）: `import Foundation` → `import TestSupport` → `import Testing` → `@testable import VDCore`（`@testable` の行は通常の import の後にまとめる）
- 5 桁以上の整数は `_` で 3 桁ごとに区切る（`65_536`、`2_147_483_648`）。16 進は `0x` の後 4 桁ごと
- ブロックコメント（`/* */`）を書かない。コメントは `//` と `///`
- 強制アンラップ・`try!`・`as!`・暗黙アンラップ型を書かない（テストは `try #require(...)`）

### 7. `Makefile`（全文）

```make
# VoiceDock の Makefile（PLAN §3.2）。CI と手元で同じコマンドを使う。
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := test

SWIFT ?= swift
FORMAT_PATHS := Sources Tests

# $(1) のスクリプトが無ければ、作るチケット $(2) を示して止める
define require_script
	@test -x "$(1)" || { echo "ERROR: $(1) がありません（$(2) で作る）" >&2; exit 1; }
endef

.PHONY: check-toolchain lint fmt build test test-nd test-policy test-other test-disk \
        vendor app golden llm-acceptance release clean

# .xcode-version と使っている Xcode が一致することを確かめる（CI と手元で同じコンパイラを使う。PLAN §3.3）
check-toolchain:
	@want="Xcode $$(cat .xcode-version)"; have="$$(xcodebuild -version | head -n 1)"; \
	  if [ "$$want" != "$$have" ]; then \
	    echo "ERROR: $$have を使っています。$$want に切り替えてください（sudo xcode-select -s <Xcode のパス>）" >&2; exit 1; \
	  fi

# swift format は存在しないパスを渡しても 0 で終わるので、先に確かめる（PLAN §3.3）
lint:
	@for d in $(FORMAT_PATHS); do test -d "$$d" || { echo "ERROR: $$d がありません" >&2; exit 1; }; done
	$(SWIFT) format lint --strict --recursive $(FORMAT_PATHS)

fmt:
	@for d in $(FORMAT_PATHS); do test -d "$$d" || { echo "ERROR: $$d がありません" >&2; exit 1; }; done
	$(SWIFT) format --in-place --recursive $(FORMAT_PATHS)

build: check-toolchain
	$(SWIFT) build --build-tests

# CI の check と同じ順（ND → policy → 残り。PLAN §10.8）
test: build
	$(SWIFT) test --skip-build --filter "NoDeleteTests|ReaperTests"
	$(SWIFT) test --skip-build --filter PolicyTests
	$(SWIFT) test --skip-build --skip "NoDeleteTests|ReaperTests|PolicyTests|LLMAcceptance"

test-nd: build
	$(SWIFT) test --skip-build --filter "NoDeleteTests|ReaperTests"

test-policy: build
	$(SWIFT) test --skip-build --filter PolicyTests

test-other: build
	$(SWIFT) test --skip-build --skip "NoDeleteTests|ReaperTests|PolicyTests|LLMAcceptance"

# ディスクイメージのテストを含めて全部（swift test はタグで絞れないので環境変数で有効化する。PLAN §10.1）
test-disk:
	VOICEDOCK_DISK_TESTS=1 $(MAKE) test

vendor:
	$(call require_script,Vendor/build-whisper.sh,T-03)
	$(call require_script,Vendor/build-llama.sh,T-03)
	Vendor/build-whisper.sh
	Vendor/build-llama.sh

app:
	$(call require_script,scripts/make-app.sh,T-34)
	scripts/make-app.sh debug

golden:
	$(call require_script,tools/golden/generate.sh,T-25)
	tools/golden/generate.sh

llm-acceptance: build
	@test -n "$(MODEL)" || { echo "ERROR: MODEL=<モデルの ID> を指定してください" >&2; exit 1; }
	VOICEDOCK_LLM_MODEL="$(MODEL)" $(SWIFT) test --skip-build --filter LLMAcceptance

release:
	$(call require_script,scripts/release.sh,T-34)
	scripts/release.sh

clean:
	rm -rf .build dist
```

- `swift test --filter` に一致するテストが無いときは警告（`No matching test cases were run`）を出して 0 で終わる（Xcode 27.0 で確認済み）。ND と Policy のテストが増える前でも `make test` は通る
- Makefile のレシピ行はタブで字下げする（上の表示のとおり）

### 8. プレースホルダ

`Sources/<ライブラリ>/ModuleMarker.swift`（11 個。`<名前>` をモジュール名に置き換える）:

```swift
// <名前> モジュールの目印（T-01）。このモジュールに最初の実ファイルを足すチケットで削除する。
enum ModuleMarker {}
```

`Sources/VoiceDockApp/main.swift`:

```swift
// VoiceDock アプリの入口（T-01 の仮置き）。T-30 で置き換える。
```

`Sources/voicedock-reaper/main.swift`:

```swift
// voicedock-reaper の入口（T-01 の仮置き）。T-37 で置き換える。
```

`Tests/<ターゲット>/TargetMarker.swift`（PolicyTests を除く 15 個。`<名前>` をターゲット名に置き換える）:

```swift
// <名前> の目印（T-01）。このターゲットに最初のテストを足すチケットで削除する。
import Testing
```

### 9. TestSupport（全文）

`Tests/TestSupport/PackageRoot.swift`:

```swift
// リポジトリのルートを求める（テストがリポジトリ内のファイルを読むため）。
import Foundation

/// リポジトリのルート（`Package.swift` のあるディレクトリ）。
public enum PackageRoot {
    /// このファイル（`Tests/TestSupport/PackageRoot.swift`）から 3 階層上。
    public static let url: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// ルートからの相対パスを URL にする。
    public static func file(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }
}
```

`Tests/TestSupport/TestEnvironment.swift`:

```swift
// テストの有効化に使う環境変数を読む唯一の場所（PLAN §10.1。本番コードは読まない。PT-18）。
import Foundation

/// 環境変数で有効にするテストの判定。
public enum TestEnvironment {
    /// `VOICEDOCK_DISK_TESTS=1` のとき、ディスクイメージのテスト（`.diskImage`）を走らせる。
    public static var diskTests: Bool { value("VOICEDOCK_DISK_TESTS") == "1" }

    /// `VOICEDOCK_REAL_TOOLS=1` のとき、本物の whisper-cli / llama-server を使うテストを走らせる。
    public static var realTools: Bool { value("VOICEDOCK_REAL_TOOLS") == "1" }

    /// `VOICEDOCK_LLM_MODEL=<id>` の値。空なら LLM の受け入れ試験を走らせない。
    public static var llmModel: String? {
        guard let id = value("VOICEDOCK_LLM_MODEL"), !id.isEmpty else { return nil }
        return id
    }

    private static func value(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }
}
```

`Tests/TestSupport/TempDirectory.swift`:

```swift
// テストごとの一時ディレクトリ（PLAN §10.1）。
import Foundation

/// テストごとに作る一時ディレクトリ。`remove()` か、参照が無くなったとき（deinit）に中身ごと消す。
public final class TempDirectory: Sendable {
    /// 作ったディレクトリ（realpath 済み。`/var` ではなく `/private/var`）。
    public let url: URL

    /// `NSTemporaryDirectory()` の下に `VoiceDockTests-<UUID>` を作る。
    public init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let dir = base.appendingPathComponent("VoiceDockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir
    }

    deinit {
        remove()
    }

    /// 中身ごと消す（テストの後片付け。失敗は無視する。何度呼んでもよい）。
    /// テストが `chmod 000` などにしたディレクトリも消せるよう、先に権限を 0o755 に戻す。
    public func remove() {
        Self.restorePermissions(url)
        try? FileManager.default.removeItem(at: url)
    }

    /// ディレクトリを 0o755 にしてから中を回る（000 の中は列挙できないため）。symlink は辿らない。
    private static func restorePermissions(_ item: URL) {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: item.path),
            attributes[.type] as? FileAttributeType == .typeDirectory
        else { return }
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
        for child in (try? manager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] {
            restorePermissions(child)
        }
    }
}
```

`Tests/TestSupport/Tags.swift`:

```swift
// テストのタグ（PLAN §10.1。swift test はタグで絞れないので、意味を示すためだけに付ける）。
import Testing

extension Tag {
    /// hdiutil で FAT32 イメージを作るテスト。`TestEnvironment.diskTests` と組で使う。
    @Tag public static var diskImage: Self
    /// 本物の whisper-cli / llama-server とモデルが要るテスト。
    @Tag public static var realTools: Self
    /// 時間のかかるテスト。
    @Tag public static var slow: Self
}
```

- 使い方（後続のチケット）: `@Test("…", .tags(.diskImage), .enabled(if: TestEnvironment.diskTests))`
- **`TempDirectory`・`PackageRoot`・`TestEnvironment` の作り手はこのチケット**（T-06 より前に入る T-02〜T-05・T-25 が使うため）。後続のチケットは作り直さず、足す機能は extension か、このファイルへの追記（T-25 の `TestEnvironment.goldenWriteActual`）で足す。00-api-map §15 はこの 3 つの作り手を T-06 と書いているが、依存の順と合わないので T-01 とした（地図の修正を提案する）
- **テストの安全の規則（全チケット共通）**: テストは `/Volumes` 配下の実機（利用者が挿している DJI Mic 3 など）に一切触れない。`/Volumes` の代わりのボリュームのルートは注入し（`volumesRoot`）、ディスクイメージは一時ディレクトリの下に `-mountpoint` 付きで attach し、再マウントも `-mountPoint` 付きで行う（PLAN §10.2 `DiskImageVolume`）。実機を使う確認は E2E（T-35 / T-42）で利用者が明示的に行う
- `Tests/` は PT の対象外（PLAN §9.4）なので、`ProcessInfo.processInfo.environment` や `FileManager.removeItem` を使ってよい

### 10. `Tests/PolicyTests/RepositoryLayoutTests.swift`（全文）

```swift
// リポジトリの骨組みの検査（T-01）。
import Foundation
import TestSupport
import Testing

@Suite("RepositoryLayout")
struct RepositoryLayoutTests {
    static let sourceModules = [
        "VDContract", "VDCore", "VDStore", "VDProcess", "VDAudio", "VDDevice", "VDTranscribe",
        "VDLLM", "VDNotes", "VDModels", "VDPipeline", "VoiceDockApp", "voicedock-reaper",
    ]

    @Test("Sources の各モジュールのディレクトリが在る", arguments: sourceModules)
    func sourceModuleDirectoryExists(_ module: String) {
        var isDirectory: ObjCBool = false
        let path = PackageRoot.file("Sources/\(module)").path
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test("VERSION は SemVer 1 行で末尾に改行が 1 つ")
    func versionFileIsSemVer() throws {
        let text = try String(contentsOf: PackageRoot.file("VERSION"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+\\n$")
        let range = NSRange(location: 0, length: text.utf16.count)
        #expect(regex.firstMatch(in: text, range: range)?.range == range)
    }

    @Test(".xcode-version は 1 行で末尾に改行が 1 つ")
    func xcodeVersionFileIsOneLine() throws {
        let text = try String(contentsOf: PackageRoot.file(".xcode-version"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: "^[0-9]+\\.[0-9]+(\\.[0-9]+)?\\n$")
        let range = NSRange(location: 0, length: text.utf16.count)
        #expect(regex.firstMatch(in: text, range: range)?.range == range)
    }

    @Test("Package.resolved がコミットされている")
    func packageResolvedExists() {
        #expect(FileManager.default.fileExists(atPath: PackageRoot.file("Package.resolved").path))
    }
}
```

（`sourceModules` はモジュールの一覧そのものが検証対象の定義であって、実装から作った一覧ではない。TEST-01 に当たらない。）

## テスト

| ファイル | 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|---|
| `Tests/PolicyTests/RepositoryLayoutTests.swift` | `sourceModuleDirectoryExists(_:)` | Sources の各モジュールのディレクトリが在る | 13 のモジュール名で parametrize | 各 `Sources/<名前>` がディレクトリ |
| 同上 | `versionFileIsSemVer()` | VERSION は SemVer 1 行で末尾に改行が 1 つ | — | 全体が `^[0-9]+\.[0-9]+\.[0-9]+\n$` に一致 |
| 同上 | `xcodeVersionFileIsOneLine()` | .xcode-version は 1 行で末尾に改行が 1 つ | — | 全体が `^[0-9]+\.[0-9]+(\.[0-9]+)?\n$` に一致 |
| 同上 | `packageResolvedExists()` | Package.resolved がコミットされている | — | ファイルが在る |

`make test` の出力に「Test run with 4 tests in 1 suite passed」（パラメータの 13 件を含む）が出ること。

## 破壊による証明

| 壊し方 | 落ちるべきもの |
|---|---|
| `Sources/VDCore/ModuleMarker.swift` に `func f() { let x = 1 }`（未使用の変数の警告）を足す | `make build`（警告がエラーになる。`treatAllWarnings` が効いている証明） |
| `VERSION` の中身を `0.1\n` にする | `versionFileIsSemVer()` |
| `.xcode-version` の末尾に空行を足す | `xcodeVersionFileIsOneLine()`（`make build` の `check-toolchain` は通る。`$(cat …)` のコマンド置換が末尾の改行をすべて落とすため。1 行であることの検査はこのテストが受け持つ） |
| `.xcode-version` の中身を `26.0` にする | `make build`（`check-toolchain`） |
| `Tests/PolicyTests/RepositoryLayoutTests.swift` の import の順を `Testing` → `TestSupport` にする | `make lint` |
| `Package.swift` の `exact: "7.11.1"` を `from: "7.11.1"` にする | （T-04 の PT-13 で落ちる。T-01 の時点では落ちるテストが無いことを PR に書く） |

## 受け入れ条件

- [ ] main の最初のコミットがドキュメントだけで、`develop` が main から切られている
- [ ] `docs/PLAN.md` が `tmp/witty-gliding-clover.md` とバイト単位で同じ（`cmp` の結果を PR に貼る）
- [ ] `swift package resolve` で `Package.resolved` が上記の revision・version になる
- [ ] `make lint` と `make test` が通る（出力を PR に貼る）
- [ ] `swift build` の成果物に `VoiceDockApp` と `voicedock-reaper` の実行ファイルがある（`ls "$(swift build --show-bin-path)"`）
- [ ] `identity.env` の TEAM_ID が P0 の章 14 と同じ
- [ ] `CLAUDE.md` と `.claude/`（rules・agents・skills・hooks・settings.json）が最初のコミットに入っている（`git ls-files .claude | wc -l` が 0 でない）

## SPEC の変更

なし（`docs/SPEC.md` は T-05 で作る）。

## マージ後にやること

- GitHub の既定ブランチが `main` であることを確かめる（`gh repo view --json defaultBranchRef`）
- T-02 に進む（CI とブランチ保護）

## API 地図への変更提案

- 00-api-map §14 のテストのターゲットの表に `VDProcessTests`（VDProcess, TestSupport）と `VoiceDockAppTests`（VoiceDockApp, TestSupport）を足す → 00-api-map に反映済み（2026-09-18）
- `BUNDLE_ID` と `TEAM_ID` の出所を `identity.env` に決めた。本番コードで使う定数（`ReaperSignature.requirement(bundleID:teamID:)` の引数、`os.Logger` の subsystem）の渡し方は T-34 / T-36 で決め、`identity.env` と一致することをテストで確かめる（モジュールをまたぐ API ではないので地図には載せない。このチケットで決定）
- 00-api-map §15 の `TempDirectory`・`PackageRoot`・`TestEnvironment` の作り手を T-06 から T-01 に直す（上の §9 の注記。T-02〜T-05・T-25 は T-06 に依存しないのに使う）
