// パネルの静的な約束（T-31 §7）。NSOpenPanel でフォルダを作らせない（Vault も .gguf の選択も。DEL-06）。
import Foundation
import TestSupport
import Testing

@Suite("PanelPolicy")
struct PanelPolicyTests {
    @Test("VoiceDockApp のコードに canCreateDirectories = true が無い")
    func noOpenPanelCreatesDirectories() throws {
        let files = try SourceTree.load().filter { $0.module == "VoiceDockApp" }
        #expect(!files.isEmpty)
        // コメントと文字列を空白にしたコードで、空白の揺れを潰してから見る
        let offenders = files.filter { file in
            let code = file.scanned.codeText.split(whereSeparator: \.isWhitespace).joined()
            return code.contains("canCreateDirectories=true")
        }
        #expect(offenders.map(\.relativePath) == [])
    }
}
