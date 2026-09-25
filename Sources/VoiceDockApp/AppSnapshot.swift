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
    /// 起動で時刻帯とログに使った値のまま動いている設定（F-84。「設定を読み直す」では変わらず、再起動で変わる。設定エラー中は空）
    var settingsAwaitingRestart: [EffectiveSettings.Difference] = []
    var timeZone: String = TimeZone.current.identifier
    var ingestState: IngestState = .idle
    var ingestActivity: IngestActivity = .idle
    var device: DeviceSnapshot? = nil
    /// devices が空でない snapshot を最後に見た時刻（AppModel が覚え、ui-state.json に残す。F-70）
    var lastConnectedAt: Instant? = nil
    var worker: WorkerStatus = WorkerStatus(activity: .idle, paused: [])
    /// BacklogCounts は VDPipeline（StatusReport.swift。状態の詳細と同じ型。T-32）
    var backlog: BacklogCounts = .empty
    var vault: VaultStatus = .notConfigured
    var vaultPath: String? = nil
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
    // T-40
    /// 「元音声の削除」の 3 行・注意書き・trash（設定エラー中は nil）
    var deletion: DeletionPanelState? = nil
    /// 設定エラー中（deletion が nil）でも消す能力が残っているか（reaper.conf が有効か reaper が在る。PLAN §8.9.8 の常時表示）
    var deletionResidual: Bool = false
    // F-95
    /// この起動で行ったデータの初期化の結果（AppContext.dataResetOutcome の写し）
    var dataReset: DataReset.Outcome = .notRequested
    // T-51（F-89）
    /// 設定の transcription.diarization.enabled の写し（設定エラー中は false）
    var diarizationEnabled = false
    /// オンのときに欠けている部品（Diarizer.missingParts()。オフなら常に空）
    var diarizationMissing: [String] = []

    init(now: Instant) {
        self.now = now
    }
}
