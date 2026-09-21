// LlamaArgs のテスト（T-21 §5.2）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess

@testable import VDLLM

@Suite("LlamaArgs")
struct LlamaArgsTests {
    static let model = URL(filePath: "/Users/x/Library/Application Support/VoiceDock/models/llm/m.gguf")
    static let keyFile = URL(filePath: "/Users/x/Library/Application Support/VoiceDock/run/llama-api-key")

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @Test("引数の並びが逐語")
    func buildIsExact() {
        #expect(
            LlamaArgs.build(model: Self.model, port: 40123, apiKeyFile: Self.keyFile, contextSize: 32768) == [
                "--model", "/Users/x/Library/Application Support/VoiceDock/models/llm/m.gguf",
                "--host", "127.0.0.1",
                "--port", "40123",
                "--api-key-file", "/Users/x/Library/Application Support/VoiceDock/run/llama-api-key",
                "--ctx-size", "32768",
                "--n-gpu-layers", "999",
                "--jinja",
                "--parallel", "1",
                "--no-webui",
                "--offline",
            ])
    }

    @Test("使うフラグは固定した版の --help に在る")
    func usedFlagsAreInTheHelp() throws {
        let url = PackageRoot.file("Tests/Fixtures/llama-server-help.txt")
        let help = try String(contentsOf: url, encoding: .utf8)
        #expect(!help.isEmpty)
        #expect(LlamaArgs.missingFlags(helpOutput: help) == [])
    }

    @Test("--help に無いフラグを返す")
    func missingFlagIsReported() {
        let help = """
            --model FNAME  model path
            --host HOST    ip address
            --port PORT    port to listen
            --api-key-file FNAME  keys
            -c,    --ctx-size N   size of the prompt context
            -ngl,  --n-gpu-layers N
            --jinja, --no-jinja
            -np,   --parallel N
            --ui,  --webui, --no-ui, --no-webui
            """
        #expect(LlamaArgs.missingFlags(helpOutput: help) == ["--offline"])
    }

    @Test("部分一致を数えない")
    func flagMustBeAWord() {
        let help =
            "--model --host --portable --api-key-file --ctx-size --n-gpu-layers --jinja --parallel --no-webui --offline"
        #expect(LlamaArgs.missingFlags(helpOutput: help) == ["--port"])
    }

    @Test("空の help ならすべてのフラグを返す")
    func emptyHelpMissesEverything() {
        #expect(
            LlamaArgs.missingFlags(helpOutput: "") == [
                "--model", "--host", "--port", "--api-key-file", "--ctx-size", "--n-gpu-layers", "--jinja",
                "--parallel", "--no-webui", "--offline",
            ])
    }

    @Test("短い形のフラグを使わない")
    func noShortForms() {
        let arguments = LlamaArgs.build(model: Self.model, port: 40123, apiKeyFile: Self.keyFile, contextSize: 32768)
        for short in ["-c", "-m", "-ngl", "-np"] {
            #expect(!arguments.contains(short), "\(short) がある")
        }
    }

    @Test("CE llm.contextSize が --ctx-size に渡る")
    func ceContextSize() {
        let standard = AppConfig.defaults(timeZone: "Asia/Tokyo").llm
        var changed = standard
        changed.contextSize = 8192
        let a = LlamaArgs.build(
            model: Self.model, port: 40123, apiKeyFile: Self.keyFile, contextSize: standard.contextSize)
        let b = LlamaArgs.build(
            model: Self.model, port: 40123, apiKeyFile: Self.keyFile, contextSize: changed.contextSize)
        #expect(Self.value(after: "--ctx-size", in: a) == "32768")
        #expect(Self.value(after: "--ctx-size", in: b) == "8192")
    }
}
