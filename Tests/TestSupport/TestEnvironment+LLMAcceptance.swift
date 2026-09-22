// LLM 受け入れ試験のための TestEnvironment の追加（T-24）。型の作り手は T-01。
import Foundation

// LLM 受け入れ試験の環境変数（PLAN §10.1。環境変数を読むのは TestEnvironment だけ。PT-18）。
extension TestEnvironment {
    /// `VOICEDOCK_LLM_FIXTURES`。無ければ `<パッケージ>/Tests/Fixtures/llm-acceptance`。
    public static var llmFixtureDirectory: URL {
        if let path = value("VOICEDOCK_LLM_FIXTURES"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return PackageRoot.url.appendingPathComponent("Tests/Fixtures/llm-acceptance", isDirectory: true)
    }

    /// `VOICEDOCK_LLM_REPORT`。無ければ `NSTemporaryDirectory()/llm-acceptance-<model>.md`。
    public static func llmReportURL(model: String) -> URL {
        if let path = value("VOICEDOCK_LLM_REPORT"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: false)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("llm-acceptance-\(safeFileName(model)).md", isDirectory: false)
    }

    /// ファイル名に使う前に `[A-Za-z0-9._-]` 以外を `_` に置き換える（T-24 §4.6）。
    static func safeFileName(_ model: String) -> String {
        String(
            String.UnicodeScalarView(
                model.unicodeScalars.map { scalar in
                    let allowed =
                        ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
                        || scalar == "." || scalar == "_" || scalar == "-"
                    return allowed ? scalar : "_"
                }))
    }
}
