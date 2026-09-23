// 要対応（PLAN §8.11 の表）。**利用者の操作が要るものだけ**（OPS-12）。無人稼働の「何も起きない」を検出する（SM-24 / RK-23）。
import Darwin
import VDCore
import VDDevice
import VDNotes
import VDStore

/// 元ファイルがいまデバイスに在るか（F-69。SourcePresence.of）。
public enum SourcePresence: Equatable, Sendable {
    /// 接続中で一覧に在る
    case listed
    /// 接続中で列挙できた一覧に無い
    case notListed
    /// 観測できない（snapshot が無いか古い・抜いている・列挙できない・source_path が無い）
    case unobserved

    /// 元ファイルがデバイスの一覧に在るか。「一覧に在るか」の判定はここ 1 か所（F-80。削除の段の failureIsObserved の d と
    /// sourceIsObservedAbsent、要対応と状態の詳細が共有する）。新鮮さは呼び手が確かめる（削除の段は DEL-20、表示は
    /// snapshotMaxAgeSeconds。AttentionEvaluator.freshSnapshot）。
    /// snapshot が無い・デバイスが unavailable に在るか devices に無い（抜いている・列挙できない）・source_path が無いか空 → .unobserved、
    /// 一覧に在る（sameKey）→ .listed、無い → .notListed
    static func of(_ part: RecordingRow, in snapshot: DeviceSnapshot?) -> SourcePresence {
        guard let snapshot, snapshot.unavailable[part.deviceID] == nil,
            let observation = snapshot.devices[part.deviceID],
            let relpath = part.sourcePath, !relpath.isEmpty
        else { return .unobserved }
        return observation.relpaths.contains(where: { DeletionPolicy.sameKey($0, relpath) }) ? .listed : .notListed
    }
}

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
    /// 消せないまま完了にした録音で、デバイスの一覧にまだ在るものの本数（F-69。1 以上）
    case undeletableSources(Int)
    /// 書き直すと本文が消えるので Raw ノートを書かずに止めた Session の数（F-75。1 以上）
    case rawNoteBlocked(Int)

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
        case .rawNoteBlocked: 15
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
        case .undeletableSources, .rawNoteBlocked: [.openDetails]
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
    /// 削除が有効（アプリの設定の cleanup.deleteSourceAudio が真）。偽なら reaperUpdateRequired を出さない（F-80）
    public var deletionEnabled = false
    public var snapshotMaxAgeSeconds = 900
    /// 消せないまま完了にした録音で、デバイスの一覧にまだ在るものの本数（AttentionEvaluator.undeletableStillListed の件数。F-69）
    public var undeletableSources = 0
    /// 書き直すと本文が消えるので Raw ノートを書かずに止めた Session の数（AttentionEvaluator.rawNoteBlockedSessions。F-75）
    public var rawNoteBlocked = 0
    public var now: Instant

    public init(now: Instant) {
        self.now = now
    }

    /// DB から数える要対応の件数（F-69 の undeletableSources・F-75 の rawNoteBlocked）を入れる（F-80。LiveServices.read の配線を
    /// テストで固定できるようにここへ寄せた）。snapshot・now・snapshotMaxAgeSeconds を先に入れておく。
    /// snapshotMaxAgeSeconds より古い snapshot では「一覧に在る」と数えない（F-80。他の要対応と同じ新鮮さ）。読めない表の件数は 0 のまま
    public mutating func countStoredItems(from store: ReadOnlyStore) {
        let fresh = AttentionEvaluator.freshSnapshot(snapshot, now: now, maxAgeSeconds: snapshotMaxAgeSeconds)
        if let settled = try? store.completedParts(lastDetail: DeletionReason.notDeletable) {
            undeletableSources = AttentionEvaluator.undeletableStillListed(settled, snapshot: fresh).count
        }
        // FAILED は全件（上限を付けない）
        if let failed = try? store.failedParts(limit: Int.max) {
            rawNoteBlocked = AttentionEvaluator.rawNoteBlockedSessions(failed.rows)
        }
    }
}

/// 要対応の判定（PLAN §8.11）。
public enum AttentionEvaluator {
    /// lockMismatch を出す設定の規則（ロック 1 と reaper.conf の食い違い、ro のままの削除）
    static let lockRules: Set<String> = ["CV-30", "CV-33"]

    /// 再マウントの unmount は成功し mount が失敗したデバイスの unavailable の理由語（F-81 の IngestService が載せる。
    /// VDDevice の `RemountOutcome.mountFailedReason` そのもの（綴りを 1 か所に持つ）。deviceNeedsReplug に写す。F-80）
    static let mountFailedReason = RemountOutcome.mountFailedReason

    /// deviceNeedsReplug に写す unavailable の理由語（挿し直しを促す: mount_name_mismatch と mount_failed）
    static let replugReasons: Set<String> = [DetectionReason.mountNameMismatch.rawValue, mountFailedReason]

    /// PLAN §8.11 の表の順に、条件を満たす項目だけを返す。
    public static func items(_ input: AttentionInput) -> [AttentionItem] {
        var items: [AttentionItem] = []
        // 設定エラー中は Worker が段を回さず停止理由が古いまま残るので、停止理由から作る項目を出さない（F-80）
        let paused = input.configPresent ? Set(input.paused) : []
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
        items += unavailable(input.snapshot, [DetectionReason.notListable.rawValue]).map { .deviceNotListable($0) }
        items += unavailable(input.snapshot, replugReasons).map { .deviceNeedsReplug($0) }
        items += unavailable(input.snapshot, [DetectionReason.invalidDeviceID.rawValue]).map { .deviceNameInvalid($0) }
        if isIngestSilent(input) { items.append(.ingestSilent) }
        if paused.contains(.diskSpaceLow) { items.append(.diskSpaceLow) }
        if input.violations.contains(where: { lockRules.contains($0.rule) }) { items.append(.lockMismatch) }
        // 削除が無効なら、有効化をやり直すよう促さない（削除を有効にする側へ誘わない。F-80）
        if input.deletionEnabled, case .versionMismatch = input.reaper { items.append(.reaperUpdateRequired) }
        if input.undeletableSources > 0 { items.append(.undeletableSources(input.undeletableSources)) }
        if input.rawNoteBlocked > 0 { items.append(.rawNoteBlocked(input.rawNoteBlocked)) }
        return items
    }

    /// F-75: 渡された Part（countStoredItems は FAILED の全件を渡す）のうち、書き直すと本文が消えるので Raw ノートを書かずに
    /// FAILED にした Part（PartSteps.isRawNoteBlocked）が居る Session の数（session_key をスカラー列で数える）。
    /// transcript を戻すか Raw ノートの名前を変えて再試行し、RAW_SAVED になれば数えない。ほかの FAILED（一時的な失敗）は数えない
    static func rawNoteBlockedSessions(_ parts: [RecordingRow]) -> Int {
        var sessions = Set<[Unicode.Scalar]>()
        for part in parts where PartSteps.isRawNoteBlocked(part) {
            if let key = part.sessionKey { sessions.insert(Array(key.unicodeScalars)) }
        }
        return sessions.count
    }

    /// snapshot が now から maxAgeSeconds 以内（DeviceSnapshot.isFresh）ならそのまま、古いか無ければ nil（F-80。表示の側の新鮮さ）
    static func freshSnapshot(_ snapshot: DeviceSnapshot?, now: Instant, maxAgeSeconds: Int) -> DeviceSnapshot? {
        guard let snapshot, snapshot.isFresh(now: now, maxAgeSeconds: maxAgeSeconds) else { return nil }
        return snapshot
    }

    /// 消せないまま完了にした録音（ReadOnlyStore.completedParts(lastDetail: not_deletable)）のうち、
    /// snapshot でデバイスが接続中で一覧にまだ在るもの（SourcePresence.of が .listed）だけ（F-69）。要対応の件数はこの数。
    /// 抜いている間・一覧に無い（手で消した）・source_path が無いものは要対応に出さない（状態の詳細には出る）。
    /// snapshot は新鮮なものを渡す（呼び手が freshSnapshot で確かめる。F-80）
    static func undeletableStillListed(_ parts: [RecordingRow], snapshot: DeviceSnapshot?) -> [RecordingRow] {
        parts.filter { SourcePresence.of($0, in: snapshot) == .listed }
    }

    /// 沈黙の検出（#117。コピー中に誤報しない）。テストから直接呼ぶ。
    static func isIngestSilent(_ input: AttentionInput) -> Bool {
        // デバイスが接続されている
        guard let s = input.snapshot, !s.devices.isEmpty else { return false }
        // 走査中でもなく
        guard !input.ingestActivity.scanning else { return false }
        let last = max(s.completedAt.epochMillis, input.ingestActivity.lastActivityAt?.epochMillis ?? Int64.min)
        // ちょうどは沈黙ではない（DeviceSnapshot.isFresh の <= と裏表）
        return input.now.epochMillis - last > Int64(input.snapshotMaxAgeSeconds) * 1000
    }

    /// snapshot.unavailable のうち理由が reasons のどれかの名前（バイト順）
    static func unavailable(_ snapshot: DeviceSnapshot?, _ reasons: Set<String>) -> [String] {
        guard let s = snapshot else { return [] }
        return s.unavailable.filter { reasons.contains($0.value) }.keys
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}
