// パネルが見る観測の写し（PLAN §8.12「AppModel は … から来る値の写し」）。値だけで、I/O もアクターも持たない。
import Foundation
import VDContract
import VDCore
import VDDevice
import VDNotes
import VDPipeline

/// パネルが見る観測の写し。すべて Equatable（等しければ AppModel は書き換えない）。
struct AppSnapshot: Equatable, Sendable {
    var now: Instant
    /// 設定が読めているか（偽 = 設定エラー状態。PLAN §6.1）
    var configPresent: Bool = false
    var configViolations: [ConfigViolation] = []
    var timeZone: String = TimeZone.current.identifier
    var ingestState: IngestState = .idle
    var ingestActivity: IngestActivity = .idle
    var device: DeviceSnapshot? = nil
    /// devices が空でない snapshot を最後に見た時刻（AppModel が覚える。起動で忘れる）
    var lastConnectedAt: Instant? = nil
    var worker: WorkerStatus = WorkerStatus(activity: .idle, paused: [])
    /// BacklogCounts は VDPipeline（StatusReport.swift。状態の詳細と同じ型。T-32）
    var backlog: BacklogCounts = .empty
    var vault: VaultStatus = .notConfigured
    var vaultPath: String? = nil
    var deletionEnabled: Bool = false
    var version: String = AppVersion.string
    // T-31
    /// 設定の vault.marker の写し（Vault を選ぶときの VaultCheck に渡す）
    var vaultMarker = ".obsidian"
    /// カタログに載る whisper / vad の選択中の項目（設定の ID から引いたもの。CV-44 / CV-45 が保証する）
    var whisperEntry: ModelEntry? = nil
    var vadEntry: ModelEntry? = nil
    var whisperPresent = false
    var vadPresent = false
    var vadEnabled = true
    var llmModelID: String? = nil
    var llmPresent = false
    var llmChoices: [LLMChoice] = []
    var physicalMemoryBytes: UInt64 = 0
    var loginItem: LoginItemStatus = .notFound
    var uiState = UIState()
    /// 改名の案内を出すデバイス名（snapshot の devices と unavailable を合わせて集める）
    var renameCandidates: [String] = []
    // T-32
    var attention: [AttentionItem] = []
    /// 「詳細」を開いている間だけ作る（毎回 inbox を走査しない）
    var statusReport: StatusReport? = nil
    // T-40 が lockDisplay を足す

    init(now: Instant) {
        self.now = now
    }
}
