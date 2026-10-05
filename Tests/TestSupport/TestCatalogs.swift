// テスト用の小さなモデルカタログ（T-09）。値は形式を満たす架空のもの。
import Foundation
import VDCore

public enum TestCatalogs {
    /// 既定の ID（large-v3-turbo-q8_0 / silero-v5.1.2）と LLM 1 つ（id "test-llm"）を持つ最小のカタログ。値は形式を満たす架空のもの。
    public static let minimal: ModelCatalog = {
        let commit = String(repeating: "0", count: 40)
        let sha = String(repeating: "a", count: 64)
        func item(_ id: String, _ file: String, llm: Bool) -> String {
            let extra = llm ? #", "minMemoryGB": 1, "verified": true"# : ""
            return """
                {"id": "\(id)", "displayName": "\(id)", "file": "\(file)", \
                "url": "https://huggingface.co/x/y/resolve/\(commit)/\(file)", \
                "sha256": "\(sha)", "bytes": 1, "license": "MIT"\(extra)}
                """
        }
        let json = """
            {"schema": 1,
             "whisper": [\(item("large-v3-turbo-q8_0", "ggml-large-v3-turbo-q8_0.bin", llm: false))],
             "vad": [\(item("silero-v5.1.2", "ggml-silero-v5.1.2.bin", llm: false))],
             "llm": [\(item("test-llm", "test-llm.gguf", llm: true))]}
            """
        guard case .success(let catalog) = ModelCatalog.load(Data(json.utf8)), catalog.rejected.isEmpty else {
            fatalError("TestCatalogs.minimal")
        }
        return catalog
    }()
}
