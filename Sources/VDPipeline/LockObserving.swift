// ロックの観測の口（PLAN §8.9.2・§8.9.8）。診断・状態の詳細・パネルが読む。
// Phase 7 は DisabledLockObserver（常に「削除は無効」）、Phase 8 で T-36 の LockEvaluator が差し替える。
import Foundation
import VDContract
import VDCore
import VDDevice

/// 削除の前提がそろっているか（PLAN §8.9.2）。
public enum DeletionReadiness: Equatable, Sendable {
    case configured
    /// T-36 の DeletionReason の readiness の 5 語のどれか
    case disabled(String)
}

/// デバイスの書き込みの可否の観測（PLAN §8.9.2 の 2。#107 / #148）。
public enum DeviceWritability: Equatable, Sendable {
    /// snapshot が無い、またはそのデバイスが snapshot に無い（未接続）
    case absent
    /// readOnly == false（観測）
    case writable
    /// readOnly == true（観測）
    case readOnly
    /// readOnly == nil（観測できない。「読み書き可能」に丸めない。#107 / #148）
    case unknown

    /// PLAN §8.9.2 の 2。snapshot の観測だけを見る（設定値 mountMode を見ない）
    public static func observe(deviceID: String, snapshot: DeviceSnapshot?) -> DeviceWritability {
        guard let observation = snapshot?.devices[deviceID] else { return .absent }
        switch observation.readOnly {
        case .some(false): return .writable
        case .some(true): return .readOnly
        case .none: return .unknown
        }
    }
}

/// reaper の実行ファイルの状態（常時表示とキャッシュ）。
public enum ReaperStatus: Equatable, Sendable {
    case notInstalled
    case signatureInvalid
    /// --version の stdout から末尾の "\n" を 1 つ除いたもの。読めなければ nil
    case versionMismatch(found: String?)
    case valid(version: String)
}

/// ある時点のロックの観測（削除条件の 1 回の評価に渡す値）。
public struct LockObservation: Equatable, Sendable {
    public let readiness: DeletionReadiness
    public let snapshot: DeviceSnapshot?
    /// reaper の設定ファイルの VOLUMES_ROOT（reaper が開くのと同じボリュームの親。事前確認もここを開く）。設定が読めなければ nil
    public let volumesRoot: String?
    /// 設定ファイルの状態（表示の 1 行目。PT-11 のため別の名前にする）
    public let confState: LockDisplay.ConfState

    public init(
        readiness: DeletionReadiness, snapshot: DeviceSnapshot?, volumesRoot: String?, confState: LockDisplay.ConfState
    ) {
        self.readiness = readiness
        self.snapshot = snapshot
        self.volumesRoot = volumesRoot
        self.confState = confState
    }

    public func writability(_ deviceID: String) -> DeviceWritability {
        DeviceWritability.observe(deviceID: deviceID, snapshot: snapshot)
    }

    /// `locks.allReleased(for:)`（PLAN §8.9.2）= readiness == .configured && writability == .writable
    public func allReleased(for deviceID: String) -> Bool {
        readiness == .configured && writability(deviceID) == .writable
    }

    /// 鍵のバイト順の一覧（snapshot が無ければ nil）。表示の 3 行目が使う
    public var devices: [LockDisplay.Device]? {
        guard let snapshot else { return nil }
        return snapshot.devices.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map {
            LockDisplay.Device(deviceID: $0, writability: DeviceWritability.observe(deviceID: $0, snapshot: snapshot))
        }
    }
}

/// パネルの「元音声の削除」と DR-14 に出す 3 つのロックの個別表示（PLAN §8.9.8）。設定値と観測値を並べる。
public struct LockDisplay: Equatable, Sendable {
    public enum ConfState: Equatable, Sendable { case enabled, disabled, missing, invalid }

    public struct Device: Equatable, Sendable {
        public let deviceID: String
        public let writability: DeviceWritability

        public init(deviceID: String, writability: DeviceWritability) {
            self.deviceID = deviceID
            self.writability = writability
        }
    }

    public let appEnabled: Bool
    /// reaper の設定ファイルの状態（PT-11 のため別の名前にする）
    public let confState: ConfState
    public let reaper: ReaperStatus
    /// config.device.mountMode のまま
    public let mountMode: String
    /// nil = snapshot が無い（観測なし）、[] = 0 台
    public let devices: [Device]?
    public let readiness: DeletionReadiness

    public init(
        appEnabled: Bool, confState: ConfState, reaper: ReaperStatus, mountMode: String, devices: [Device]?,
        readiness: DeletionReadiness
    ) {
        self.appEnabled = appEnabled
        self.confState = confState
        self.reaper = reaper
        self.mountMode = mountMode
        self.devices = devices
        self.readiness = readiness
    }

    /// 3 行（逐語。PLAN §8.9.8）
    public var lines: [String] {
        let conf: String
        switch confState {
        case .enabled: conf = "有効"
        case .disabled: conf = "無効"
        case .missing: conf = "無し"
        case .invalid: conf = "不正"
        }
        let module: String
        switch reaper {
        case .notInstalled: module = "未導入"
        case .signatureInvalid: module = "導入済み（署名 NG）"
        case .valid(let v): module = "導入済み（署名 OK, 版 " + v + "）"
        case .versionMismatch(let f): module = "導入済み（署名 OK, 版 " + (f ?? "不明") + "）。削除モジュールの更新が必要です"
        }
        let observed: String
        if let devices {
            if devices.isEmpty {
                observed = StatusTexts.writabilityWord(.absent)
            } else {
                observed = devices.map { $0.deviceID + "=" + StatusTexts.writabilityWord($0.writability) + "（観測）" }
                    .joined(separator: ", ")
            }
        } else {
            observed = "観測=不明"
        }
        return [
            "ロック 1  : アプリ=" + (appEnabled ? "有効" : "無効") + ", reaper.conf=" + conf,
            "ロック 2-A: 削除モジュール=" + module,
            "ロック 2-B: 設定=" + mountMode + ", " + observed,
        ]
    }
}

/// ロックの観測の口。DiagnosticsDependencies・StatusReporter・パネルはこれだけを見る。
public protocol LockObserving: Sendable {
    func observe(config: AppConfig, snapshot: DeviceSnapshot?) async -> LockObservation
    func reaperStatus() async -> ReaperStatus
}

extension LockObserving {
    /// 3 行の個別表示（PLAN §8.9.8）。**式はここ 1 か所**（DR-14・T-40 のパネルが共有し、書き直さない）。
    public func display(config: AppConfig, snapshot: DeviceSnapshot?) async -> LockDisplay {
        let observation = await observe(config: config, snapshot: snapshot)
        return LockDisplay(
            appEnabled: config.cleanup.deleteSourceAudio,
            confState: observation.confState,
            reaper: await reaperStatus(),
            mountMode: config.device.mountMode,
            devices: observation.devices,
            readiness: observation.readiness)
    }
}

/// Phase 7 の既定（削除の機能がまだ無い間）。常に「削除は無効」。何も読まない・何も起動しない。
public struct DisabledLockObserver: LockObserving {
    /// T-36 の `DeletionReason.deleteSourceAudioDisabled` と同じ語。T-36 がこのファイルを変更して
    /// `DeletionReason.deleteSourceAudioDisabled` を参照するように直す（CR-06。T-36 §4.2）。
    public static let disabledReason = "delete_source_audio_disabled"

    public init() {}

    public func observe(config: AppConfig, snapshot: DeviceSnapshot?) async -> LockObservation {
        LockObservation(
            readiness: .disabled(Self.disabledReason), snapshot: snapshot, volumesRoot: nil, confState: .missing)
    }

    public func reaperStatus() async -> ReaperStatus { .notInstalled }
}
