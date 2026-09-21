// PT の自己テスト: 違反を仕込むと落ち、コメント・文字列（文字列の検査はコード）では落ちない（PLAN §9.4・CR-17。T-04）。
import Foundation
import TestSupport
import Testing

@Suite("PolicySelf")
struct PolicySelfTests {
    /// 自己テストの語の一覧（docs に依存させない）。
    static let vocabulary = PolicyVocabulary(
        stateNames: ["FAILED", "RAW_SAVED"], errorCodeNames: ["SOURCE_IDENTITY_MISMATCH", "WHISPER_FAILED"])

    /// PT ごとの（違反を仕込んだファイル, 紛らわしいが違反でないファイル）。
    static let fixtures: [String: (violating: [SourceFile], decoy: [SourceFile])] = [
        "PT-01": (
            violating: [
                SourceFile(relativePath: "VDPipeline/Bad.swift", text: "func f(_ p: String) { unlink(p) }\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Bad.swift",
                    text:
                        "// unlink(p) で消す\nlet note = \"FileManager.default.removeItem(at:)\"\nfunc g(_ s: inout Set<Int>) { s.remove(1); SafeUnlink.remove(x) }\n"
                )
            ]
        ),
        "PT-02": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "let s = URLSession.shared\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift", text: "// URLSession を使わない\nlet t = \"URLSession.shared\"\n")
            ]
        ),
        "PT-03": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "let p = Process()\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text:
                        "// Process() を使わない\nlet name = \"Process()\"\nstruct ProcessedLog {}\nlet x = ProcessInfo.processInfo\n"
                )
            ]
        ),
        "PT-04": (
            violating: [
                SourceFile(relativePath: "VDProcess/Bad.swift", text: "let a = [\"/bin/sh\", \"-c\", \"ls\"]\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDProcess/Bad.swift",
                    text:
                        "// /bin/sh を使わない\nlet flag = \"-c\"\nlet shells = [root/bin/sh, root/bin/bash, root/bin/zsh, root/usr/bin/env]\n"
                )
            ]
        ),
        "PT-05": (
            violating: [
                SourceFile(
                    relativePath: "VDStore/Queries.swift",
                    text: "let sql = \"UPDATE recordings SET status = ? WHERE partkey = ?\"\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDStore/Queries.swift",
                    text:
                        "// UPDATE recordings SET status = ?\nlet sql = \"SELECT partkey FROM recordings WHERE status = ?\"\nfunc f() throws { try db.update(set: status) }\n"
                )
            ]
        ),
        "PT-06": (
            violating: [
                SourceFile(relativePath: "VDPipeline/Bad.swift", text: "let s = \"RAW_SAVED\"\n"),
                SourceFile(relativePath: "VDPipeline/Key.swift", text: "let k = \"\\(deviceID)/\\(relpath)\"\n"),
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Bad.swift",
                    text:
                        "// RAW_SAVED にする\nlet t = PartStatus.rawSaved\nlet u = \"WHISPER_FAILED_X\"\nlet RAW_SAVED = 1\nenum E { case WHISPER_FAILED }\n"
                )
            ]
        ),
        "PT-07": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "import VDStore\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text: "// import VDStore\nimport Foundation\nimport Synchronization\nlet s = \"import VDStore\"\n")
            ]
        ),
        "PT-08": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "func f() { print(\"x\") }\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text:
                        "// print(\"x\")\nlet s = \"print(1)\"\nstruct Printer { func print() {} }\nfunc g(_ p: Printer) { p.print() }\n"
                )
            ]
        ),
        "PT-09": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "let now = Date()\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text: "// Date() を使わない\nlet s = \"Date()\"\nlet d = Date(timeIntervalSince1970: 0)\n")
            ]
        ),
        "PT-10": (
            violating: [
                SourceFile(relativePath: "VDDevice/Scanner.swift", text: "let fd = open(path, O_RDONLY)\n"),
                SourceFile(relativePath: "VDDevice/DeviceReader.swift", text: "let flags = O_WRONLY\n"),
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDDevice/Scanner.swift",
                    text: "// open(path) はしない\nlet s = \"open(path)\"\nfunc g(_ h: Handle) { h.open() }\n")
            ]
        ),
        "PT-11": (
            violating: [
                SourceFile(relativePath: "VDPipeline/Worker.swift", text: "let u = layout.binDirectory\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Worker.swift",
                    text: "// binDirectory に書かない\nlet s = \"binDirectory\"\nlet v = Contract.reaperConfSchema\n")
            ]
        ),
        "PT-12": (
            violating: [
                SourceFile(relativePath: "VDPipeline/Bad.swift", text: "func f() throws { try data.write(to: url) }\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Bad.swift",
                    text:
                        "// data.write(to: url)\nlet s = \"write(to:)\"\nfunc g() throws { try file.write(from: buffer) }\n"
                )
            ]
        ),
        "PT-14": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "final class A: @unchecked Sendable {}\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift", text: "// @unchecked Sendable は使わない\nlet s = \"@unchecked\"\n")
            ]
        ),
        "PT-15": (
            violating: [
                SourceFile(relativePath: "voicedock-reaper/Bad.swift", text: "import VDCore\n"),
                SourceFile(relativePath: "voicedock-reaper/Tool.swift", text: "let s = \"diskutil\"\n"),
            ],
            decoy: [
                SourceFile(
                    relativePath: "voicedock-reaper/Bad.swift",
                    text: "// diskutil を呼ばない\nstruct ProcessedLog {}\nlet info = ProcessInfo.processInfo\n")
            ]
        ),
        "PT-16": (
            violating: [
                SourceFile(
                    relativePath: "VDDevice/IngestService.swift",
                    text: "func copyOne() {\n    registerCopied()\n    commitPartial()\n}\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDDevice/IngestService.swift",
                    text: "// registerCopied( を先に呼ばない\nfunc copyOne() {\n    commitPartial()\n    registerCopied()\n}\n"
                )
            ]
        ),
        "PT-17": (
            violating: [
                SourceFile(
                    relativePath: "VDPipeline/Diagnostics/Checks.swift",
                    text: "func f() throws { try AtomicFile.write(d, to: u) }\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Diagnostics/Checks.swift",
                    text: "// AtomicFile.write をしない\nlet s = \"AtomicFile\"\nlet r = ReadOnlyStore.open(url: u)\n")
            ]
        ),
        "PT-18": (
            violating: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift", text: "let e = ProcessInfo.processInfo.environment[\"X\"]\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text:
                        "// ProcessInfo.processInfo.environment を読まない\nlet s = \"getenv(X)\"\nlet c = ProcessInfo.processInfo.activeProcessorCount\n"
                )
            ]
        ),
        "PT-19": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "let x = try! f()\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text: "// try! は使わない\nlet s = \"fatalError()\"\nlet y = try? f()\nlet z = try !flag()\n")
            ]
        ),
        "PT-20": (
            violating: [
                SourceFile(relativePath: "VDCore/Bad.swift", text: "let r = try Regex(\"a+\")\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDCore/Bad.swift",
                    text: "// Regex は使わない\nlet s = \"Regex<Substring>\"\nlet t = NSRegularExpression.self\n")
            ]
        ),
        "PT-21": (
            violating: [
                SourceFile(
                    relativePath: "VDPipeline/Worker.swift",
                    text: "func f() throws { try store.record(kind: .recovery) }\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Worker.swift",
                    text: "// .recovery を使わない\nlet s = \".recovery\"\nfunc g() { log(.recoveryCompleted) }\n")
            ]
        ),
        "PT-22": (
            violating: [
                SourceFile(relativePath: "VDPipeline/Deletion.swift", text: "let h = VolumeHandle(fd: 3)\n")
            ],
            decoy: [
                SourceFile(
                    relativePath: "VDPipeline/Deletion.swift",
                    text: "// VolumeHandle( を作らない\nlet s = \"VolumeHandle(fd:)\"\nlet t: VolumeHandle? = nil\n")
            ]
        ),
    ]

    struct MissingFixture: Error {}

    static func check(_ id: String, _ files: [SourceFile]) -> [Violation] {
        switch id {
        case ImportPolicy.id: return ImportPolicy.check(files: files)
        case OrderingPolicy.id: return OrderingPolicy.check(files: files, required: true)
        default:
            let rule = PolicyCatalog.tokenRules(vocabulary: vocabulary).first { $0.id == id }
            return rule.map { PolicyEngine.check($0, files: files) } ?? [
                Violation(rule: id, path: "-", line: 0, what: "規則が無い")
            ]
        }
    }

    /// 違反のファイルそれぞれで 1 件以上見つかる（どのファイルも空振りしない）。
    static func expectDetects(_ id: String) throws {
        let fixture = try #require(fixtures[id])
        for file in fixture.violating {
            let found = check(id, [file])
            #expect(
                found.contains { $0.rule == id && $0.path == file.relativePath }, "\(id) が \(file.relativePath) で空振りした")
        }
    }

    static func expectIgnoresDecoys(_ id: String) throws {
        let fixture = try #require(fixtures[id])
        let found = check(id, fixture.decoy)
        #expect(found.isEmpty, "\(id) が誤検知した: \(found)")
    }

    @Test("PT-01 自己テスト: 違反を仕込むと検出する")
    func pt01DetectsViolation() throws {
        try Self.expectDetects("PT-01")
    }

    @Test("PT-01 自己テスト: コメント・文字列の中の語では検出しない")
    func pt01IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-01")
    }

    @Test("PT-02 自己テスト: 違反を仕込むと検出する")
    func pt02DetectsViolation() throws {
        try Self.expectDetects("PT-02")
    }

    @Test("PT-02 自己テスト: コメント・文字列の中の語では検出しない")
    func pt02IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-02")
    }

    @Test("PT-03 自己テスト: 違反を仕込むと検出する")
    func pt03DetectsViolation() throws {
        try Self.expectDetects("PT-03")
    }

    @Test("PT-03 自己テスト: コメント・文字列の中の語では検出しない")
    func pt03IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-03")
    }

    @Test("PT-04 自己テスト: 違反を仕込むと検出する")
    func pt04DetectsViolation() throws {
        try Self.expectDetects("PT-04")
    }

    @Test("PT-04 自己テスト: コメント・文字列の中の語では検出しない")
    func pt04IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-04")
    }

    @Test("PT-05 自己テスト: 違反を仕込むと検出する")
    func pt05DetectsViolation() throws {
        try Self.expectDetects("PT-05")
    }

    @Test("PT-05 自己テスト: コメント・文字列の中の語では検出しない")
    func pt05IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-05")
    }

    @Test("PT-06 自己テスト: 違反を仕込むと検出する")
    func pt06DetectsViolation() throws {
        try Self.expectDetects("PT-06")
    }

    @Test("PT-06 自己テスト: コメント・文字列の中の語では検出しない")
    func pt06IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-06")
    }

    @Test("PT-07 自己テスト: 違反を仕込むと検出する")
    func pt07DetectsViolation() throws {
        try Self.expectDetects("PT-07")
    }

    @Test("PT-07 自己テスト: コメント・文字列の中の語では検出しない")
    func pt07IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-07")
    }

    @Test("PT-08 自己テスト: 違反を仕込むと検出する")
    func pt08DetectsViolation() throws {
        try Self.expectDetects("PT-08")
    }

    @Test("PT-08 自己テスト: コメント・文字列の中の語では検出しない")
    func pt08IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-08")
    }

    @Test("PT-09 自己テスト: 違反を仕込むと検出する")
    func pt09DetectsViolation() throws {
        try Self.expectDetects("PT-09")
    }

    @Test("PT-09 自己テスト: コメント・文字列の中の語では検出しない")
    func pt09IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-09")
    }

    @Test("PT-10 自己テスト: 違反を仕込むと検出する")
    func pt10DetectsViolation() throws {
        try Self.expectDetects("PT-10")
    }

    @Test("PT-10 自己テスト: コメント・文字列の中の語では検出しない")
    func pt10IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-10")
    }

    @Test("PT-11 自己テスト: 違反を仕込むと検出する")
    func pt11DetectsViolation() throws {
        try Self.expectDetects("PT-11")
    }

    @Test("PT-11 自己テスト: コメント・文字列の中の語では検出しない")
    func pt11IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-11")
    }

    @Test("PT-12 自己テスト: 違反を仕込むと検出する")
    func pt12DetectsViolation() throws {
        try Self.expectDetects("PT-12")
    }

    @Test("PT-12 自己テスト: コメント・文字列の中の語では検出しない")
    func pt12IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-12")
    }

    @Test("PT-14 自己テスト: 違反を仕込むと検出する")
    func pt14DetectsViolation() throws {
        try Self.expectDetects("PT-14")
    }

    @Test("PT-14 自己テスト: コメント・文字列の中の語では検出しない")
    func pt14IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-14")
    }

    @Test("PT-15 自己テスト: 違反を仕込むと検出する")
    func pt15DetectsViolation() throws {
        try Self.expectDetects("PT-15")
    }

    @Test("PT-15 自己テスト: コメント・文字列の中の語では検出しない")
    func pt15IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-15")
    }

    @Test("PT-16 自己テスト: 違反を仕込むと検出する")
    func pt16DetectsViolation() throws {
        try Self.expectDetects("PT-16")
    }

    @Test("PT-16 自己テスト: コメント・文字列の中の語では検出しない")
    func pt16IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-16")
    }

    @Test("PT-17 自己テスト: 違反を仕込むと検出する")
    func pt17DetectsViolation() throws {
        try Self.expectDetects("PT-17")
    }

    @Test("PT-17 自己テスト: コメント・文字列の中の語では検出しない")
    func pt17IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-17")
    }

    @Test("PT-18 自己テスト: 違反を仕込むと検出する")
    func pt18DetectsViolation() throws {
        try Self.expectDetects("PT-18")
    }

    @Test("PT-18 自己テスト: コメント・文字列の中の語では検出しない")
    func pt18IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-18")
    }

    @Test("PT-19 自己テスト: 違反を仕込むと検出する")
    func pt19DetectsViolation() throws {
        try Self.expectDetects("PT-19")
    }

    @Test("PT-19 自己テスト: コメント・文字列の中の語では検出しない")
    func pt19IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-19")
    }

    @Test("PT-20 自己テスト: 違反を仕込むと検出する")
    func pt20DetectsViolation() throws {
        try Self.expectDetects("PT-20")
    }

    @Test("PT-20 自己テスト: コメント・文字列の中の語では検出しない")
    func pt20IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-20")
    }

    @Test("PT-21 自己テスト: 違反を仕込むと検出する")
    func pt21DetectsViolation() throws {
        try Self.expectDetects("PT-21")
    }

    @Test("PT-21 自己テスト: コメント・文字列の中の語では検出しない")
    func pt21IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-21")
    }

    @Test("PT-22 自己テスト: 違反を仕込むと検出する")
    func pt22DetectsViolation() throws {
        try Self.expectDetects("PT-22")
    }

    @Test("PT-22 自己テスト: コメント・文字列の中の語では検出しない")
    func pt22IgnoresDecoy() throws {
        try Self.expectIgnoresDecoys("PT-22")
    }

    /// PT-13 の自己テスト用のリポジトリを一時ディレクトリに作る。
    static func makeRoot(_ files: [String: String]) throws -> TempDirectory {
        let directory = try TempDirectory()
        for (path, text) in files {
            let url = directory.url.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return directory
    }

    static let pinnedFiles: [String: String] = [
        "Package.swift":
            "// from: \"1.0.0\" は使わない\nlet p = [.package(url: \"https://github.com/a/b.git\", exact: \"1.0.0\")]\n",
        "Package.resolved":
            "{\"pins\": [{\"identity\": \"b\", \"state\": {\"revision\": \"0123456789abcdef0123456789abcdef01234567\", \"version\": \"1.0.0\"}}], \"version\": 3}\n",
        ".xcode-version": "27.0\n",
        ".github/workflows/ci.yml":
            "jobs:\n  check:\n    runs-on: [self-hosted, macOS, ARM64]  # latest ではない\n    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n",
        ".github/workflows/nightly.yml":
            "jobs:\n  check:\n    runs-on:\n      - self-hosted  # latest ではない\n      - ARM64\n    steps:\n      - run: make test\n",
        "Vendor/versions.env":
            "WHISPER_CPP_REPO=https://github.com/ggml-org/whisper.cpp.git\nWHISPER_CPP_REF=v1.9.4\nWHISPER_CPP_SHA=927cfce34f31707e17f2bff35c349632fb9e2c3a\nLLAMA_CPP_REPO=https://github.com/ggml-org/llama.cpp.git\nLLAMA_CPP_REF=b11033\nLLAMA_CPP_SHA=8ed1a55efcd7424d2c592f6cbc9f97756db1d74d\n",
        "Resources/ModelCatalog.json":
            "{\"whisper\": [{\"url\": \"https://huggingface.co/a/b/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/m.bin\"}]}\n",
    ]

    @Test("PT-13 自己テスト: 固定されていない版・URL・action・ランナーを検出する")
    func pt13DetectsViolation() throws {
        var files = Self.pinnedFiles
        files["Package.swift"] = "let p = [.package(url: \"https://github.com/a/b.git\", from: \"1.0.0\")]\n"
        files["Package.resolved"] =
            "{\"pins\": [{\"identity\": \"b\", \"state\": {\"branch\": \"main\", \"revision\": \"0123456789abcdef0123456789abcdef01234567\"}}], \"version\": 3}\n"
        files["Vendor/versions.env"] = files["Vendor/versions.env", default: ""].replacingOccurrences(
            of: "REF=b11033", with: "REF=master")
        files["Resources/ModelCatalog.json"] =
            "{\"whisper\": [{\"url\": \"https://huggingface.co/a/b/resolve/main/m.bin\"}]}\n"
        files[".github/workflows/ci.yml"] =
            "jobs:\n  check:\n    runs-on: macos-latest\n    steps:\n      - uses: actions/checkout@v7.0.1\n"
        files[".github/workflows/nightly.yml"] =
            "jobs:\n  check:\n    runs-on:\n\n      - self-hosted\n      - macos-latest\n    steps:\n      - run: make test\n"
        files[".github/workflows/matrix.yml"] =
            "jobs:\n  check:\n    strategy:\n      matrix:\n        os: [macos-15, macos-latest]\n    runs-on: ${{ matrix.os }}\n"
        files[".xcode-version"] = "27.0\n\n"
        let root = try Self.makeRoot(files)
        defer { root.remove() }
        let found = PinningPolicy.check(root: root.url, requiredFiles: PolicyAnchors.requiredFiles)
        let paths = Set(found.map(\.path))
        #expect(
            paths == [
                "Package.swift", "Package.resolved", "Vendor/versions.env", "Resources/ModelCatalog.json",
                ".github/workflows/ci.yml", ".github/workflows/nightly.yml", ".github/workflows/matrix.yml",
                ".xcode-version",
            ])
        #expect(found.filter { $0.path == ".github/workflows/ci.yml" }.count == 2)
        #expect(found.filter { $0.path == ".github/workflows/nightly.yml" }.map(\.line) == [3])
        #expect(found.filter { $0.path == ".github/workflows/matrix.yml" }.map(\.line) == [5])
    }

    @Test("PT-13 自己テスト: コメントの中の語と固定された値では検出しない")
    func pt13IgnoresDecoy() throws {
        let root = try Self.makeRoot(Self.pinnedFiles)
        defer { root.remove() }
        let found = PinningPolicy.check(root: root.url, requiredFiles: PolicyAnchors.requiredFiles)
        #expect(found.isEmpty, "\(found)")
    }

    @Test("PT-13 自己テスト: 在るべきファイルが無ければ検出する")
    func pt13DetectsMissingRequiredFile() throws {
        var files = Self.pinnedFiles
        files["Vendor/versions.env"] = nil
        let root = try Self.makeRoot(files)
        defer { root.remove() }
        let found = PinningPolicy.check(root: root.url, requiredFiles: PolicyAnchors.requiredFiles)
        #expect(found.contains { $0.path == "Vendor/versions.env" && $0.what == "ファイルがありません" })
    }

    @Test("PT-16 自己テスト: 必須にした関数が無ければ検出する")
    func pt16DetectsMissingFunction() {
        let file = SourceFile(relativePath: "VDDevice/IngestService.swift", text: "func other() {}\n")
        #expect(!OrderingPolicy.check(files: [file], required: true).isEmpty)
        #expect(OrderingPolicy.check(files: [file], required: false).isEmpty)
    }

    @Test("PT-06 自己テスト: 語の一覧が空なら必ず違反にする（空で緑にしない）")
    func pt06EmptyVocabularyAlwaysFails() {
        let rule = PolicyCatalog.tokenRules(vocabulary: PolicyVocabulary(stateNames: [], errorCodeNames: []))
            .first { $0.id == "PT-06" }
        let file = SourceFile(relativePath: "VDCore/A.swift", text: "let s = \"anything\"\n")
        #expect(rule.map { !PolicyEngine.check($0, files: [file]).isEmpty } == true)
    }
}
