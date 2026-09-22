// パネルが見る観測の写し（PLAN §8.12「AppModel は … から来る値の写し」）。値だけで、I/O もアクターも持たない。
import Foundation
import VDContract
import VDCore
import VDDevice
import VDNotes
import VDPipeline

/// 未処理の件数と長さ（ReadOnlyStore.backlog() の写し）。
struct BacklogCounts: Equatable, Sendable {
    var count: Int = 0
    var seconds: Double = 0
    var unknownDuration: Int = 0
    static let empty = BacklogCounts()
}

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
    var backlog: BacklogCounts = .empty
    var vault: VaultStatus = .notConfigured
    var vaultPath: String? = nil
    var deletionEnabled: Bool = false
    var version: String = AppVersion.string
    // T-31 が models…、T-32 が attention / statusReport / diagnostics、T-40 が lockDisplay を足す

    init(now: Instant) {
        self.now = now
    }
}
