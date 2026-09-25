// パネル上端の 1 行の文言（PLAN §8.12 の 1）。純関数。AppModel はこれを呼ぶだけ。
import VDCore
import VDDevice
import VDPipeline

/// パネル上端の 1 行の文言（PLAN §8.12 の 1）。
enum StatusLine {
    /// 上から順に判定し、最初に当たったものを返す。
    static func make(_ s: AppSnapshot) -> String {
        if !s.configPresent { return Strings.statusConfigInvalid }
        if s.ingestActivity.scanning && s.ingestActivity.total > 0 {
            return Strings.statusIngesting(
                device: s.ingestActivity.deviceID ?? Strings.unknownDevice, copied: s.ingestActivity.copied,
                total: s.ingestActivity.total)
        }
        if s.ingestActivity.scanning { return Strings.statusScanning }
        if s.worker.activity != .idle { return activityLine(s.worker.activity) }
        if !s.worker.paused.isEmpty { return Strings.statusPaused(s.worker.paused) }
        return Strings.statusIdle
    }

    /// 「最終接続: …」の右側
    static func lastConnected(_ s: AppSnapshot, zone: ZonedTime) -> String {
        if let devices = s.device?.devices, !devices.isEmpty {
            let names = devices.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            return Strings.connectedNow(names.joined(separator: "、"))
        }
        if let at = s.lastConnectedAt {
            // ZonedTime.iso の先頭 16 文字の T を空白に替える（voicedock status.py:104 と同じ作り方）
            return String(zone.iso(at).prefix(16)).replacingOccurrences(of: "T", with: " ")
        }
        return Strings.neverConnected
    }

    /// 「デバイスの空き容量: …」の右側。観測が 1 台も無ければ nil（行を出さない）
    static func deviceFree(_ s: AppSnapshot) -> String? {
        guard let devices = s.device?.devices else { return nil }
        let ids = devices.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        let parts = ids.compactMap { id -> String? in
            guard let bytes = devices[id]?.freeBytes else { return nil }
            return id + " " + StatusTexts.gib(bytes)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "、")
    }

    /// 「未処理: …」の右側（StatusTexts に委ねる）
    static func backlog(_ s: AppSnapshot) -> String {
        StatusTexts.backlogLine(
            count: s.backlog.count, seconds: s.backlog.seconds, unknownDuration: s.backlog.unknownDuration)
    }

    /// WorkerActivity → 文言（.idle は make の条件で来ない）。
    private static func activityLine(_ activity: WorkerActivity) -> String {
        switch activity {
        case .normalizing(_, let startedAt):
            Strings.statusNormalizing(ISOWallClock.hhmm(startedAt) ?? Strings.unknownTime)
        case .transcribing(_, let startedAt):
            Strings.statusTranscribing(ISOWallClock.hhmm(startedAt) ?? Strings.unknownTime)
        case .writingRawNote: Strings.statusWritingRawNote
        case .merging: Strings.statusMerging
        case .analyzing(_, let dayDate): Strings.statusAnalyzing(dayDate)
        case .writingDailyNote(_, let dayDate): Strings.statusWritingDailyNote(dayDate)
        case .idle: Strings.statusIdle
        }
    }
}
