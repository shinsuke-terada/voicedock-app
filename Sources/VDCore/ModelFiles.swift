// モデルファイルの置き場所と在否（PLAN §8.10。VDPipeline のガードと診断が使う。VDModels に依存しない）。
import Darwin
import Foundation
import VDContract

public enum ModelFiles {
    /// models/<kind>/<entry.file>
    public static func url(kind: ModelKind, entry: ModelEntry, layout: HomeLayout) -> URL {
        layout.modelFile(kind: kind.rawValue, file: entry.file)
    }

    /// custom:<sha256> なら models/llm/custom-<sha256 の先頭 16>.gguf。形が違えば nil。
    public static func customLLMURL(id: String, layout: HomeLayout) -> URL? {
        CustomModelID.sha256(of: id).map {
            layout.modelFile(kind: ModelKind.llm.rawValue, file: CustomModelID.fileName(sha256: $0))
        }
    }

    /// stat（symlink を辿る）が成功し S_ISREG で st_size == entry.bytes。
    public static func isPresent(_ e: ModelEntry, kind: ModelKind, layout: HomeLayout) -> Bool {
        var info = stat()
        let path = url(kind: kind, entry: e, layout: layout).path(percentEncoded: false)
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && Int64(info.st_size) == e.bytes
    }
}
