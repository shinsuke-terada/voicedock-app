// AppPaths の各パスの検査（PLAN §3.4・§11.1。T-10）。
import Foundation
import TestSupport
import Testing
import VDContract

@testable import VDCore

@Suite("AppPaths")
struct AppPathsTests {
    @Test("AppPaths の各パス")
    func appPathsLayout() {
        let paths = AppPaths(
            resources: URL(fileURLWithPath: "/App/Contents/Resources", isDirectory: true),
            helpers: URL(fileURLWithPath: "/App/Contents/Helpers", isDirectory: true))
        #expect(paths.promptsDirectory.path(percentEncoded: false) == "/App/Contents/Resources/prompts/")
        #expect(paths.modelCatalog.path(percentEncoded: false) == "/App/Contents/Resources/ModelCatalog.json")
        #expect(paths.whisperCLI.path(percentEncoded: false) == "/App/Contents/Helpers/whisper-cli")
        #expect(paths.llamaServer.path(percentEncoded: false) == "/App/Contents/Helpers/llama-server")
        #expect(paths.bundledReaperURL.path(percentEncoded: false) == "/App/Contents/Helpers/voicedock-reaper")
    }
}
