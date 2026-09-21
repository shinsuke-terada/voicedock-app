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
