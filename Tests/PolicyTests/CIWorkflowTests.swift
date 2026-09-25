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
