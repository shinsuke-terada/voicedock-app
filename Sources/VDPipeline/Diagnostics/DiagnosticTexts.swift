// 診断の日本語のラベルと文言（PLAN §8.11）。ここ以外に書かない（CR-06）。
import Foundation
import VDProcess

/// 診断の日本語のラベルと文言（T-32 §4.5 の逐語）。
enum DiagnosticTexts {
    /// DR-03 に渡す想定の長さ（30 分）
    static let probeDurationSeconds: Double = 1800

    /// 検査のラベル（PLAN §8.11）。表に無い ID はそのまま返す
    static func label(_ id: String) -> String {
        switch id {
        case DiagnosticID.config: "設定"
        case DiagnosticID.database: "データベース"
        case DiagnosticID.space: "空き容量"
        case DiagnosticID.whisperCLI: "whisper-cli"
        case DiagnosticID.whisperModel: "Whisper モデル"
        case DiagnosticID.vadModel: "VAD モデル"
        case DiagnosticID.llamaServer: "llama-server"
        case DiagnosticID.llmModel: "LLM モデル"
        case DiagnosticID.llmProbe: "LLM の疎通"
        case DiagnosticID.vault: "Vault"
        case DiagnosticID.devices: "デバイスの列挙"
        case DiagnosticID.loginItem: "ログイン項目"
        case DiagnosticID.deletion: "元音声の削除"
        case DiagnosticID.leftovers: "inbox の取り残し"
        case DiagnosticID.timeZone: "タイムゾーン"
        case DiagnosticID.signature: "アプリの署名"
        default: id
        }
    }

    static let skipped = "先行する致命的な検査が失敗"
    static let configOK = "違反はありません"
    static let configUnreadable = "設定ファイルを読めません"
    static let configMissing = "設定が読めていません"
    static func timeZoneUnresolved(_ id: String) -> String { "タイムゾーン " + id + " を解決できません" }
    static let dbNotCreated = "まだ作られていません"
    static let dbUnopenable = "読み取り専用で開けません"
    static func dbQuickCheck(_ s: String) -> String { "PRAGMA quick_check が ok ではありません: " + s }
    static func dbMigrations(applied: String?, expected: String?) -> String {
        "適用済みのマイグレーションが " + (applied ?? "") + " です（最新は " + (expected ?? "") + "）"
    }
    static func dbOK(_ last: String) -> String { "quick_check ok、マイグレーション " + last }
    static func spaceOK(_ freeBytes: Int64) -> String { "空き " + StatusTexts.gib(freeBytes) }
    static func executableMissing(_ url: URL) -> String { url.path(percentEncoded: false) + " がありません" }
    static func helpFailed(_ t: ProcessResult.Termination) -> String {
        let reason: String
        switch t {
        case .exited(let n): reason = "exit " + String(n)
        case .signaled(let n): reason = "signal " + String(n)
        case .timedOut: reason = "時間切れ"
        case .spawnFailed(let e): reason = "起動できません（errno " + String(e) + "）"
        }
        return "--help が失敗しました（" + reason + "）"
    }
    static func vadFlagsOK(_ n: Int) -> String { "VAD のフラグ " + String(n) + " 個が在ります" }
    static func vadFlagsMissing(_ flags: [String]) -> String {
        "VAD のフラグがありません: " + flags.joined(separator: " ")
    }
    static let vadDisabled = "無音から幻覚が生成され、13 倍以上遅くなります"
    static func llamaFlagsOK(_ n: Int) -> String { "使うフラグ " + String(n) + " 個が在ります" }
    static func llamaFlagsMissing(_ flags: [String]) -> String {
        "使えないフラグがあります: " + flags.joined(separator: " ")
    }
    static let modelNotSelected = "選ばれていません"
    static let llmNotSelected = "LLM モデルが選ばれていません"
    static func modelMissing(_ file: String) -> String { file + " がありません" }
    static func modelSize(actual: Int64, expected: Int64) -> String {
        "サイズが " + String(actual) + " バイトです（期待 " + String(expected) + "）"
    }
    static let modelSHA = "SHA-256 が一致しません"
    static func modelOK(_ displayName: String) -> String { displayName + "（SHA-256 一致）" }
    static func customModelOK(_ shortSHA: String) -> String { "読み込んだモデル " + shortSHA + "（SHA-256 一致）" }
    static let customModelUnsupported = "動作保証外のモデルです"
    static func notEnoughMemory(required: Int, actual: Int) -> String {
        "メモリが足りません（" + String(required) + " GB 以上が必要。この Mac は " + String(actual) + " GB）"
    }
    static let tccFolders = "システム設定 → プライバシーとセキュリティ → ファイルとフォルダ で VoiceDock に許可してください"
    static func vaultNotWritable(_ path: String, errno code: Int32) -> String {
        path + " に書き込めません（errno " + String(code) + "）"
    }
    static let noSnapshot = "まだ走査していません"
    static let noDevice = "デバイスが接続されていません"
    static func devicesListed(_ n: Int) -> String { String(n) + " 台を列挙できました" }
    static func notListable(_ name: String, errno code: Int32?) -> String {
        guard let code else { return name + " を列挙できません（errno 不明）" }
        return name + " を列挙できません（errno " + String(code) + "）"
    }
    static let tccRemovableVolumes = "システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム"
    static let loginItemEnabled = "登録されています"
    static func loginItem(_ s: LoginItemStatus) -> String {
        switch s {
        case .enabled: loginItemEnabled
        case .requiresApproval: "許可が要ります"
        case .notRegistered: "登録されていません"
        case .notFound: "アプリの場所が不明です"
        }
    }
    static let leftoversNone = "ありません"
    static func leftovers(count: Int, bytes: Int64) -> String {
        String(count) + " 件 " + StatusTexts.gib(bytes) + "（自動では消しません）"
    }
    static let signatureInvalid = "署名が無効です"
    static let signatureUnreadable = "署名を読めません"
    static let adhocSignature = "ad-hoc 署名です。ビルドのたびにリムーバブルボリュームの許可が失効します"
    static func signatureOK(_ teamID: String) -> String { "有効（Team ID " + teamID + "）" }
    static func probeOK(model: String, seconds: Double) -> String {
        model + "（" + String(format: "%.1f", seconds) + "s）"
    }
    static func probeFailed(_ message: String) -> String { message }
    static let probeStopped = "終了中のため実行しませんでした"
}
