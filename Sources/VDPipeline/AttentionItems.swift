// 要対応（PLAN §8.11 の表）。**利用者の操作が要るものだけ**（OPS-12）。無人稼働の「何も起きない」を検出する（SM-24 / RK-23）。
import Darwin
import VDCore
import VDDevice
import VDNotes
import VDStore

/// 要対応の項目に付ける操作ボタン（PLAN §8.11 の「操作ボタン」の列）。
public enum AttentionAction: Equatable, Sendable {
    /// 設定ファイルを Finder で表示
    case revealConfig
    /// 設定を読み直す
    case reloadConfig
    /// Vault を選び直す
    case chooseVault
    /// システム設定を開く
    case openSystemSettings
    /// モデルの節を開く
    case openModels
    /// 有効化フローを開く
    case openDeletionFlow
    /// 「詳細」を開いて診断を実行する（whisper-cli / llama-server が無いとき。PLAN §8.11）
    case runDiagnostics
    /// 「詳細・診断」を開く（消せなかった録音の一覧は状態の詳細に出る。F-69）
    case openDetails
}

/// PLAN §8.11 の表の 1 行。宣言順 = 表示順。
public enum AttentionItem: Equatable, Sendable {
    case configInvalid
    case vaultNotConfigured
    case vaultUnavailable(VaultStatus)
    case modelMissing(ModelKind)
    case llmNotSelected
    case llmInsufficientMemory
    /// whisper-cli / llama-server（T-32 §11 の 2）
    case toolMissing(ToolKind)
    case deviceNotListable(String)
    case deviceNeedsReplug(String)
    case deviceNameInvalid(String)
    case ingestSilent
    case diskSpaceLow
    case lockMismatch
    case reaperUpdateRequired
    /// 消せないまま完了にした録音で、まだデバイスに残りうるものの本数（F-69。1 以上）
    case undeletableSources(Int)

    public enum ToolKind: String, Equatable, Sendable { case whisperCLI, llamaServer }

    /// 表示の順（宣言順に振った 0 始まりの番号）
    public var order: Int {
        switch self {
        case .configInvalid: 0
        case .vaultNotConfigured: 1
        case .vaultUnavailable: 2
        case .modelMissing: 3
        case .llmNotSelected: 4
        case .llmInsufficientMemory: 5
        case .toolMissing: 6
        case .deviceNotListable: 7
        case .deviceNeedsReplug: 8
        case .deviceNameInvalid: 9
        case .ingestSilent: 10
        case .diskSpaceLow: 11
        case .lockMismatch: 12
        case .reaperUpdateRequired: 13
        case .undeletableSources: 14
        }
    }

    /// PLAN §8.11 の「操作ボタン」の列
    public var actions: [AttentionAction] {
        switch self {
        case .configInvalid: [.revealConfig, .reloadConfig]
        case .vaultNotConfigured: [.chooseVault]
        case .vaultUnavailable(.notReadable(errno: EPERM)): [.chooseVault, .openSystemSettings]
        case .vaultUnavailable: [.chooseVault]
        case .modelMissing, .llmNotSelected, .llmInsufficientMemory: [.openModels]
        case .toolMissing: [.runDiagnostics]
        case .deviceNotListable: [.openSystemSettings]
        case .deviceNeedsReplug, .deviceNameInvalid: []
        case .ingestSilent, .diskSpaceLow, .lockMismatch: []
        case .reaperUpdateRequired: [.openDeletionFlow]
        case .undeletableSources: [.openDetails]
        }
    }
}

/// 要対応の判定の入力（ファイルの口を持たない。ガードの判定は PauseReason をそのまま読む。§9.1 原則 2 / CR-06）。
public struct AttentionInput: Equatable, Sendable {
    public var configPresent = false
    public var violations: [ConfigViolation] = []
    public var ingestActivity: IngestActivity = .idle
    public var snapshot: DeviceSnapshot? = nil
    public var paused: [PauseReason] = []
    public var vault: VaultStatus = .notConfigured
    public var reaper: ReaperStatus = .notInstalled
    public var snapshotMaxAgeSeconds = 900
    /// 消せないまま完了にした録音で、まだデバイスに残りうるものの本数（AttentionEvaluator.remainingUndeletable の件数。F-69）
    public var undeletableSources = 0
    public var now: Instant

    public init(now: Instant) {
        self.now = now
    }
}

/// 要対応の判定（PLAN §8.11）。
public enum AttentionEvaluator {
    /// lockMismatch を出す設定の規則（ロック 1 と reaper.conf の食い違い、ro のままの削除）
    static let lockRules: Set<String> = ["CV-30", "CV-33"]

    /// PLAN §8.11 の表の順に、条件を満たす項目だけを返す。
    public static func items(_ input: AttentionInput) -> [AttentionItem] {
        var items: [AttentionItem] = []
        let paused = Set(input.paused)
        if !input.configPresent { items.append(.configInvalid) }
        if paused.contains(.vaultNotConfigured) { items.append(.vaultNotConfigured) }
        if paused.contains(.vaultUnavailable) { items.append(.vaultUnavailable(input.vault)) }
        if paused.contains(.modelMissing) { items.append(.modelMissing(.whisper)) }
        if paused.contains(.vadModelMissing) { items.append(.modelMissing(.vad)) }
        if paused.contains(.llmModelMissing) { items.append(.modelMissing(.llm)) }
        if paused.contains(.llmNotSelected) { items.append(.llmNotSelected) }
        if paused.contains(.llmInsufficientMemory) { items.append(.llmInsufficientMemory) }
        if paused.contains(.whisperMissing) { items.append(.toolMissing(.whisperCLI)) }
        if paused.contains(.llamaServerMissing) { items.append(.toolMissing(.llamaServer)) }
        items += unavailable(input.snapshot, DetectionReason.notListable).map { .deviceNotListable($0) }
        items += unavailable(input.snapshot, DetectionReason.mountNameMismatch).map { .deviceNeedsReplug($0) }
        items += unavailable(input.snapshot, DetectionReason.invalidDeviceID).map { .deviceNameInvalid($0) }
        if isIngestSilent(input) { items.append(.ingestSilent) }
        if paused.contains(.diskSpaceLow) { items.append(.diskSpaceLow) }
        if input.violations.contains(where: { lockRules.contains($0.rule) }) { items.append(.lockMismatch) }
        if case .versionMismatch = input.reaper { items.append(.reaperUpdateRequired) }
        if input.undeletableSources > 0 { items.append(.undeletableSources(input.undeletableSources)) }
        return items
    }

    /// 消せないまま完了にした録音（ReadOnlyStore.completedParts(lastDetail: not_deletable)）のうち、まだデバイスに残りうるもの（F-69）。
    /// 元ファイルが無いと観測できたもの（F-64 と同じ観測。決着より後の走査で、接続中で列挙できた一覧に無い）は数えない（利用者が手で消した）。
    /// 未接続・列挙できない・snapshot が無いときは残りうるとして数える。過去分の削除で消えたものは source_deleted_at が入り、そもそも渡されない
    public static func remainingUndeletable(_ parts: [RecordingRow], snapshot: DeviceSnapshot?, zone: ZonedTime)
        -> [RecordingRow]
    {
        guard let snapshot else { return parts }
        return parts.filter { !DeletionRequester.sourceIsObservedAbsent($0, in: snapshot, zone: zone) }
    }

    /// 沈黙の検出（#117。コピー中に誤報しない）。テストから直接呼ぶ。
    public static func isIngestSilent(_ input: AttentionInput) -> Bool {
        // デバイスが接続されている
        guard let s = input.snapshot, !s.devices.isEmpty else { return false }
        // 走査中でもなく
        guard !input.ingestActivity.scanning else { return false }
        let last = max(s.completedAt.epochMillis, input.ingestActivity.lastActivityAt?.epochMillis ?? Int64.min)
        // ちょうどは沈黙ではない（DeviceSnapshot.isFresh の <= と裏表）
        return input.now.epochMillis - last > Int64(input.snapshotMaxAgeSeconds) * 1000
    }

    /// snapshot.unavailable のうち理由が reason の名前（バイト順）
    static func unavailable(_ snapshot: DeviceSnapshot?, _ reason: DetectionReason) -> [String] {
        guard let s = snapshot else { return [] }
        return s.unavailable.filter { $0.value == reason.rawValue }.keys
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}
