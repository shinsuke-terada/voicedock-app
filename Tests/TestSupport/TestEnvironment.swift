// テストの有効化に使う環境変数を読む唯一の場所（PLAN §10.1。本番コードは読まない。PT-18）。
import Foundation

/// 環境変数で有効にするテストの判定。
public enum TestEnvironment {
    /// `VOICEDOCK_DISK_TESTS=1` のとき、ディスクイメージのテスト（`.diskImage`）を走らせる。
    public static var diskTests: Bool { value("VOICEDOCK_DISK_TESTS") == "1" }

    /// `VOICEDOCK_REAL_TOOLS=1` のとき、本物の whisper-cli / llama-server を使うテストを走らせる。
    public static var realTools: Bool { value("VOICEDOCK_REAL_TOOLS") == "1" }

    /// `VOICEDOCK_LLM_MODEL=<id>` の値。空なら LLM の受け入れ試験を走らせない。
    public static var llmModel: String? {
        guard let id = value("VOICEDOCK_LLM_MODEL"), !id.isEmpty else { return nil }
        return id
    }

    /// 環境変数の値。TestSupport の extension（T-25・T-24）もこれを通して読む（PLAN §10.1。ProcessInfo を読むのはこのファイルだけ）。
    static func value(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name]
    }
}
