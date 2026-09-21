// golden の入力と期待値がそろっていることを確かめる（PLAN §10.4、T-25）。
import Foundation
import Testing

@testable import TestSupport

@Suite("GoldenInventory")
struct GoldenInventoryTests {
    /// 後続のチケットが使うグループ（T-25 の表と同じ）。名前を変えるときは使う側のチケットと同じ PR で直す。
    static let requiredGroups: Set<String> = [
        "analysis_json", "blocks", "daily_note", "daily_parts", "fingerprint", "frontmatter", "keys", "llm_as_json",
        "llm_bundles", "llm_chunks", "llm_dedupe", "llm_extract", "llm_prompt", "llm_repair_prompt",
        "llm_schema_block", "llm_strip_think", "llm_trim", "llm_validate", "note_filename", "numbers",
        "prompt_files", "pyjson", "pyjson_decode", "pyround", "pytext", "raw_note", "sanitize", "timeline",
        "timeline_decode", "transcript_json", "wiki",
    ]

    @Test("golden の入力のグループが決めたとおりそろっている")
    func groupsArePresent() throws {
        #expect(Set(try Golden.groupNames()) == Self.requiredGroups)
    }

    @Test("各ケースに期待値がちょうど 1 つあり、余分な期待値が無い")
    func everyCaseHasExactlyOneExpected() throws {
        let fileManager = FileManager.default
        for group in try Golden.groupNames() {
            let cases = try Golden.cases(group)
            #expect(!cases.isEmpty, "\(group) にケースがありません")
            let names = cases.map(\.name)
            #expect(Set(names).count == names.count, "\(group) のケース名が重複しています")
            for name in names {
                let allowed = "abcdefghijklmnopqrstuvwxyz0123456789_".unicodeScalars
                #expect(name.unicodeScalars.allSatisfy { allowed.contains($0) }, "\(group)/\(name): 名前は小文字の英数字と _")
                #expect(throws: Never.self) { _ = try Golden.expectedFile(group, name) }
            }
            let directory = Golden.expectedDirectory.appendingPathComponent(group, isDirectory: true)
            let files = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
            let expectedFiles = try names.map { try Golden.expectedFile(group, $0).lastPathComponent }.sorted()
            #expect(files == expectedFiles, "\(group) に入力の無い期待値があります")
        }
        let expectedGroups = try fileManager.contentsOfDirectory(atPath: Golden.expectedDirectory.path).sorted()
        #expect(expectedGroups == (try Golden.groupNames()), "入力の無い期待値のグループがあります")
    }

    @Test("GENERATED_BY.txt に生成の条件がそろっている")
    func generatedByIsComplete() throws {
        let text = try String(contentsOf: Golden.root.appendingPathComponent("GENERATED_BY.txt"), encoding: .utf8)
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            #expect(parts.count == 2, "形式が不正な行: \(line)")
            if parts.count == 2 {
                fields[parts[0]] = parts[1]
            }
        }
        #expect(Set(fields.keys) == ["voicedock_ref", "voicedock_commit", "python", "unicodedata", "uv", "generator"])
        #expect(fields["voicedock_ref"] == "d3d595e")
        #expect(fields["voicedock_commit"]?.hasPrefix("d3d595e") == true)
        #expect(fields["voicedock_commit"]?.count == 40)
        #expect(fields["python"]?.hasPrefix("3.12.") == true)
        #expect(fields["unicodedata"] == "15.0.0")
        #expect(fields["uv"]?.hasPrefix("uv ") == true)
        #expect(fields["generator"] == "tools/golden/generate.py")
        #expect(text.hasSuffix("\n"))
    }

    @Test("生成ツールがリポジトリに在り、generate.sh は実行できる")
    func generatorToolsExist() {
        let fileManager = FileManager.default
        for file in ["tools/golden/generate.sh", "tools/golden/generate.py", "tools/golden/make_inputs.py"] {
            #expect(fileManager.fileExists(atPath: PackageRoot.file(file).path), "\(file) がありません")
        }
        #expect(fileManager.isExecutableFile(atPath: PackageRoot.file("tools/golden/generate.sh").path))
    }
}
