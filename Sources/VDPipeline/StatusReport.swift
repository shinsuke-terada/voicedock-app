// 「状態の詳細」（PLAN §8.12。voicedock status.py 相当）。DB が無ければ全 0。DB を作らない。
import Foundation
import VDContract
import VDCore
import VDDevice
import VDStore

/// 未処理の件数と長さ（ReadOnlyStore.backlog() の写し。パネルの上端と状態の詳細が共有する）。
public struct BacklogCounts: Equatable, Sendable {
    public var count: Int = 0
    public var seconds: Double = 0
    public var unknownDuration: Int = 0

    public init(count: Int = 0, seconds: Double = 0, unknownDuration: Int = 0) {
        self.count = count
        self.seconds = seconds
        self.unknownDuration = unknownDuration
    }

    public static let empty = BacklogCounts()
}

/// 「状態の詳細」の値（PLAN §8.12）。
public struct StatusReport: Equatable, Sendable {
    public struct FailedPart: Equatable, Sendable {
        public let partkey: String
        public let startedAt: String
        /// DB の error_code の**生の文字列**（`RecordingRow.errorCodeRaw`。未知のコードもそのまま出す。M-1）
        public let errorCode: String?
        public let retryCount: Int

        public init(partkey: String, startedAt: String, errorCode: String?, retryCount: Int) {
            self.partkey = partkey
            self.startedAt = startedAt
            self.errorCode = errorCode
            self.retryCount = retryCount
        }

        /// 「<yyyy-MM-dd HH:mm>  <error_code か unknown>  retry <n>/<max>」（間は半角空白 2 つ。voicedock status.py:104-116）
        public func detail(maxAttempts: Int) -> String {
            let stamp = String(startedAt.prefix(16)).replacingOccurrences(of: "T", with: " ")
            return stamp + "  " + (errorCode ?? "unknown") + "  retry " + String(retryCount) + "/"
                + String(maxAttempts)
        }
    }

    /// 消せないまま完了にした録音 1 件（F-69）
    public struct UndeletablePart: Equatable, Sendable {
        public let partkey: String
        /// 原因の語（DeletionReason.cause*、F-78 の打ち切りは reaper の理由語。Part の error_message。無ければ nil）
        public let cause: String?
        public let presence: SourcePresence

        public init(partkey: String, cause: String?, presence: SourcePresence) {
            self.partkey = partkey
            self.cause = cause
            self.presence = presence
        }

        /// 「<原因>、<デバイスでの在否>」
        public var detail: String {
            let causeText = cause.flatMap(StatusReporter.causeText) ?? "原因不明"
            return causeText + "、" + (StatusReporter.presenceTexts[presence] ?? "")
        }
    }

    public struct Device: Equatable, Sendable {
        public let deviceID: String
        public let writability: DeviceWritability
        public let freeBytes: Int64?
    }

    /// 表示順。0 件も含む
    public let partCounts: [(PartStatus, Int)]
    public let sessionCounts: [(SessionStatus, Int)]
    /// count / seconds / unknownDuration
    public let backlog: BacklogCounts
    /// 最大 20 件
    public let failedParts: [FailedPart]
    public let failedTotal: Int
    public let maxAttempts: Int
    /// queue/delete の *.json の数
    public let deleteRequested: Int
    /// 結果待ちの Part の数
    public let awaitingDeleteResult: Int
    public let stagingBytes: Int64
    public let stagingMaxBytes: Int64
    public let inbox: InboxCounts
    /// バイト順。0 台なら空
    public let devices: [Device]
    /// false = まだ走査していない
    public let deviceSnapshotPresent: Bool
    /// 消せないまま完了にした録音（F-69。partkey 順に最大 20 件）。手で消したものも含めて全部
    public var undeletable: [UndeletablePart] = []
    public var undeletableTotal = 0

    /// タプルの配列は自動で Equatable にならないので、欄ごとに比べる。
    public static func == (a: StatusReport, b: StatusReport) -> Bool {
        a.partCounts.elementsEqual(b.partCounts, by: { $0.0 == $1.0 && $0.1 == $1.1 })
            && a.sessionCounts.elementsEqual(b.sessionCounts, by: { $0.0 == $1.0 && $0.1 == $1.1 })
            && a.backlog == b.backlog && a.failedParts == b.failedParts && a.failedTotal == b.failedTotal
            && a.maxAttempts == b.maxAttempts && a.deleteRequested == b.deleteRequested
            && a.awaitingDeleteResult == b.awaitingDeleteResult && a.stagingBytes == b.stagingBytes
            && a.stagingMaxBytes == b.stagingMaxBytes && a.inbox == b.inbox && a.devices == b.devices
            && a.deviceSnapshotPresent == b.deviceSnapshotPresent && a.undeletable == b.undeletable
            && a.undeletableTotal == b.undeletableTotal
    }

    /// パネルに出す行（逐語。T-32 §4.9 の表）
    public var lines: [String] {
        var out = ["Part"]
        for (status, n) in partCounts {
            let note = StatusReporter.partNotes[status].map { "（" + $0 + "）" } ?? ""
            out.append("  " + status.rawValue + ": " + String(n) + note)
        }
        out.append("Session")
        for (status, n) in sessionCounts {
            let note = StatusReporter.sessionNotes[status].map { "（" + $0 + "）" } ?? ""
            out.append("  " + status.rawValue + ": " + String(n) + note)
        }
        out.append(
            "未処理: "
                + StatusTexts.backlogLine(
                    count: backlog.count, seconds: backlog.seconds, unknownDuration: backlog.unknownDuration))
        out.append("削除キュー: 要求 " + String(deleteRequested) + " 件、結果待ち " + String(awaitingDeleteResult) + " 件")
        out.append("staging: " + StatusTexts.gib(stagingBytes) + " / " + StatusTexts.gib(stagingMaxBytes))
        out.append(
            "inbox: 処理待ち " + String(inbox.pendingCount) + " 件 " + StatusTexts.gib(inbox.pendingBytes) + "、取り残し "
                + String(inbox.leftoverCount) + " 件 " + StatusTexts.gib(inbox.leftoverBytes))
        out.append("デバイス: " + deviceLine)
        if failedTotal > 0 {
            out.append("失敗した Part（" + String(failedTotal) + " 件）")
            for p in failedParts {
                out.append("  " + p.partkey)
                out.append("    " + p.detail(maxAttempts: maxAttempts))
            }
            if failedTotal > failedParts.count {
                out.append("  … ほか " + String(failedTotal - failedParts.count) + " 件")
            }
        }
        if undeletableTotal > 0 {
            out.append("消せなかった録音（" + String(undeletableTotal) + " 件。消さずに完了にしたもの）")
            for p in undeletable {
                out.append("  " + p.partkey)
                out.append("    " + p.detail)
            }
            if undeletableTotal > undeletable.count {
                out.append("  … ほか " + String(undeletableTotal - undeletable.count) + " 件")
            }
        }
        return out
    }

    /// 「デバイス:」の観測（0 台を観測扱いにしない。nil を「読み書き可能」に丸めない。#107 / #148）
    var deviceLine: String {
        guard deviceSnapshotPresent else { return "まだ走査していません" }
        guard !devices.isEmpty else { return StatusTexts.writabilityWord(.absent) }
        return devices.map {
            $0.deviceID + " " + StatusTexts.writabilityWord($0.writability) + " 空き "
                + ($0.freeBytes.map(StatusTexts.gib) ?? "不明")
        }.joined(separator: "、")
    }
}

/// 「状態の詳細」を作る（読むだけ。DB は ReadOnlyStore で開き、無ければ作らない）。
public enum StatusReporter {
    /// 失敗した Part を並べる上限
    static let failedLimit = 20

    /// Part の表示順（**宣言順だが SKIPPED を FAILED の前に置く**。PLAN §8.12）
    public static let partOrder: [PartStatus] =
        PartStatus.allCases.filter { $0 != .skipped && $0 != .failed } + [.skipped, .failed]
    public static let sessionOrder: [SessionStatus] = SessionStatus.allCases
    /// エンティティごとの注記（**Part 用を Session へ流用しない**。voicedock status.py:78-90）
    public static let partNotes: [PartStatus: String] = [.failed: "次回接続時に再試行"]
    public static let sessionNotes: [SessionStatus: String] = [:]
    /// 消せなかった録音の原因の語 → 表示（F-69）
    public static let causeTexts: [String: String] = [
        DeletionReason.causeSourceInfo: "元の情報（場所・サイズ・時刻）が無い",
        DeletionReason.causePreIdentity: "事前確認で原本が合わない（サイズ・時刻・場所）",
        DeletionReason.causeTranscript: "文字起こしが無いか読めない",
        DeletionReason.causeRawNote: "Raw ノートの照合が合わない",
    ]
    /// 元ファイルの在否 → 表示（F-69）
    public static let presenceTexts: [SourcePresence: String] = [
        .listed: "デバイスに在る", .notListed: "デバイスの一覧に無い", .unobserved: "デバイスを観測できない",
    ]

    /// 原因の語 → 表示（F-69）。causeTexts に無く付録 B.2 の reaper の理由語なら（F-78 の打ち切り）
    /// 「削除モジュールの検証で拒否され続けた（<理由語>）」。どれでもなければ nil（呼び手が「原因不明」にする）
    static func causeText(_ cause: String) -> String? {
        if let text = causeTexts[cause] { return text }
        guard IdentityReason.all.contains(cause) else { return nil }
        return "削除モジュールの検証で拒否され続けた（" + cause + "）"
    }

    public static func build(
        layout: HomeLayout, config: AppConfig?, snapshot: DeviceSnapshot?, now: Instant, zone: ZonedTime
    ) -> StatusReport {
        // 1. DB が無ければこのまま全 0
        var parts = Dictionary(uniqueKeysWithValues: partOrder.map { ($0, 0) })
        var sessions = Dictionary(uniqueKeysWithValues: sessionOrder.map { ($0, 0) })
        var backlog = BacklogCounts.empty
        var failedParts: [StatusReport.FailedPart] = []
        var failedTotal = 0
        var awaiting = 0
        var leftoverPaths: [String] = []
        var undeletable: [StatusReport.UndeletablePart] = []
        // 2.
        if let ro = ReadOnlyStore.open(url: layout.database) {
            if let c = try? ro.statusCounts() {
                parts.merge(c.parts) { $1 }
                sessions.merge(c.sessions) { $1 }
            }
            if let b = try? ro.backlog() {
                backlog = BacklogCounts(count: b.count, seconds: b.seconds, unknownDuration: b.unknownDuration)
            }
            if let f = try? ro.failedParts(limit: failedLimit) {
                // errorCode?.rawValue ではなく errorCodeRaw（未知のコードを unknown に潰さない。T-11 §4.5）
                failedParts = f.rows.map {
                    StatusReport.FailedPart(
                        partkey: $0.partkey, startedAt: $0.startedAt, errorCode: $0.errorCodeRaw,
                        retryCount: $0.retryCount)
                }
                failedTotal = f.total
            }
            awaiting = (try? ro.awaitingDeleteResultCount()) ?? 0
            leftoverPaths = (try? ro.inboxPaths(statuses: PartStates.inboxLeftover)) ?? []
            // 決着した Part を全部（F-69。要対応は、このうち一覧にまだ在るものだけ）
            let settled = (try? ro.completedParts(lastDetail: DeletionReason.notDeletable)) ?? []
            undeletable = settled.map {
                StatusReport.UndeletablePart(
                    partkey: $0.partkey, cause: $0.errorMessage,
                    presence: AttentionEvaluator.sourcePresence($0, snapshot: snapshot))
            }
        }
        // 3.
        let inbox = InboxScan.counts(layout: layout, leftoverRelativePaths: leftoverPaths)
        // 4.
        let requests =
            (try? FileManager.default.contentsOfDirectory(atPath: layout.queueDelete.path(percentEncoded: false)))?
            .filter { $0.hasSuffix(".json") }.count ?? 0
        // 7.
        let devices = (snapshot?.devices ?? [:]).keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map {
            StatusReport.Device(
                deviceID: $0, writability: DeviceWritability.observe(deviceID: $0, snapshot: snapshot),
                freeBytes: snapshot?.devices[$0]?.freeBytes)
        }
        var report = StatusReport(
            partCounts: partOrder.map { ($0, parts[$0] ?? 0) },
            sessionCounts: sessionOrder.map { ($0, sessions[$0] ?? 0) },
            backlog: backlog, failedParts: failedParts, failedTotal: failedTotal,
            // 6.
            maxAttempts: config?.retry.maxAttempts ?? 0,
            deleteRequested: requests, awaitingDeleteResult: awaiting,
            // 5.
            stagingBytes: InboxScan.directoryBytes(layout.staging),
            stagingMaxBytes: Int64(config?.audio.stagingMaxBytes ?? 0),
            inbox: inbox, devices: devices, deviceSnapshotPresent: snapshot != nil)
        report.undeletable = Array(undeletable.prefix(failedLimit))
        report.undeletableTotal = undeletable.count
        return report
    }
}
