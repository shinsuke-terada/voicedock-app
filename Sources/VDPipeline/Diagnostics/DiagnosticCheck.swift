// 1 件の検査の定義と、検査の間で共有する読み取り専用の値（voicedock doctor.py:80-112）。
import VDCore
import VDDevice

/// 1 件の検査の定義（voicedock doctor.py:100-112 の Check）。
struct DiagnosticCheck: Sendable {
    let id: String
    /// この検査が fail を出したら以降を skip にするか（PLAN §8.11 の「致命」列）
    let fatal: Bool
    /// 先行する致命的な検査が失敗しても実行するか（**DR-14 だけが真**。設定が読めていることは前提にする）
    let always: Bool
    let run: @Sendable (DiagnosticsContext) async -> DiagnosticResult
}

/// 検査の間で共有する読み取り専用の値（voicedock doctor.py:80-98 の Context）。
struct DiagnosticsContext: Sendable {
    let deps: DiagnosticsDependencies
    /// 読めなければ nil（DR-01 が fail を出している）
    let config: AppConfig?
    let violations: [ConfigViolation]
    let snapshot: DeviceSnapshot?
    let loginItem: LoginItemStatus
    let now: Instant
}

/// 診断の ID（PLAN §8.11 の表の ID。2 桁のゼロ詰め）。
enum DiagnosticID {
    static let config = "DR-01"
    static let database = "DR-02"
    static let space = "DR-03"
    static let whisperCLI = "DR-04"
    static let whisperModel = "DR-05"
    static let vadModel = "DR-06"
    static let llamaServer = "DR-07"
    static let llmModel = "DR-08"
    static let llmProbe = "DR-09"
    static let vault = "DR-10"
    static let devices = "DR-11"
    static let loginItem = "DR-12"
    static let deletion = "DR-14"
    static let leftovers = "DR-15"
    static let timeZone = "DR-16"
    static let signature = "DR-17"
    static let diarization = "DR-18"
}
