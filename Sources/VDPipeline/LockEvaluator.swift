// 三重ロックの評価（PLAN §8.9.2）。設定上の準備（待っても変わらない）とデバイスの観測（挿し直しで変わる）を分ける。
// 式はここに 1 つだけ置き、削除段・削除条件・常時表示・DR-14 が共有する（式を書き直さない）。
// DeletionReadiness / DeviceWritability / LockObservation / ReaperStatus / LockDisplay は LockObserving.swift（T-32）。
import Foundation
import VDContract
import VDCore
import VDDevice
import VDProcess

public actor LockEvaluator: LockObserving {
    /// 起動と検証の窓口（T-38 の runReaperIfNeeded もこれを使う。WorkerDependencies に reaper を別に持たない）
    public nonisolated let reaper: ReaperRunner
    private let layout: HomeLayout
    private let log: AppLog
    private var cache: CachedVerification?

    /// init は検証しない（キャッシュは空で始まる）。
    public init(layout: HomeLayout, verifier: any SignatureVerifier, runner: any ProcessRunning, log: AppLog) {
        self.reaper = ReaperRunner(layout: layout, runner: runner, verifier: verifier)
        self.layout = layout
        self.log = log
        self.cache = nil
    }

    /// `ReaperConf.observe(at: layout.reaperConf)`（ConfigStore の observeReaperConf もこれ）
    public func observeReaperConf() -> ReaperConfObservation {
        ReaperConf.observe(at: layout.reaperConf)
    }

    /// PLAN §8.9.2 の 1。この順に評価し、最初に当たった語を返す（先の段で決まったら後の段の子プロセス・署名検証をしない）。
    public func readiness(config: AppConfig, useCache: Bool = true) async -> DeletionReadiness {
        // 1.
        if config.cleanup.deleteSourceAudio == false {
            return .disabled(DeletionReason.deleteSourceAudioDisabled)
        }
        // 2. 不明（無い・不正）は安全側
        guard case .valid(let conf) = observeReaperConf(), conf.deleteSourceAudio == true else {
            return .disabled(DeletionReason.lockMismatch)
        }
        // 3. 不正な値も .ro（T-09）
        if config.device.mode == .ro {
            return .disabled(DeletionReason.mountModeRO)
        }
        // 4.
        switch await reaperStatus(useCache: useCache) {
        case .notInstalled:
            return .disabled(DeletionReason.reaperNotInstalled)
        case .signatureInvalid, .versionMismatch:
            return .disabled(DeletionReason.reaperInvalid)
        case .valid:
            return .configured
        }
    }

    /// `DeviceWritability.observe(deviceID:snapshot:)`（設定値 mountMode を見ない）
    public func writability(deviceID: String, snapshot: DeviceSnapshot?) -> DeviceWritability {
        DeviceWritability.observe(deviceID: deviceID, snapshot: snapshot)
    }

    public func allReleased(deviceID: String, config: AppConfig, snapshot: DeviceSnapshot?) async -> Bool {
        await observe(config: config, snapshot: snapshot).allReleased(for: deviceID)
    }

    // LockObserving の 2 つ（引数ラベルはプロトコルのとおり。既定引数つきの多重定義は準拠の証人にならない）

    public func observe(config: AppConfig, snapshot: DeviceSnapshot?) async -> LockObservation {
        await observe(config: config, snapshot: snapshot, useCache: true)
    }

    public func reaperStatus() async -> ReaperStatus {
        await reaperStatus(useCache: true)
    }

    // キャッシュを使わない版（T-38 の起動直前とテストが使う）

    public func observe(config: AppConfig, snapshot: DeviceSnapshot?, useCache: Bool) async -> LockObservation {
        let readiness = await readiness(config: config, useCache: useCache)
        let observed = observeReaperConf()
        let volumesRoot: String?
        let confState: LockDisplay.ConfState
        switch observed {
        case .missing:
            volumesRoot = nil
            confState = .missing
        case .invalid:
            volumesRoot = nil
            confState = .invalid
        case .valid(let c):
            volumesRoot = c.volumesRoot
            confState = c.deleteSourceAudio ? .enabled : .disabled
        }
        return LockObservation(readiness: readiness, snapshot: snapshot, volumesRoot: volumesRoot, confState: confState)
    }

    /// 署名と版のキャッシュ（PLAN §8.9.2「(inode, size, mtime) が変わらない限りキャッシュ」）。
    /// actor の再入: await の間に別の呼び出しが同じ検証をしてもよい（結果は同じ。キャッシュは最後の書き込みが残る）。
    /// キャッシュの鍵は検証の前に読んだ値で、検証中にファイルが替わっても次の呼び出しで鍵が一致せず検証し直す。
    public func reaperStatus(useCache: Bool) async -> ReaperStatus {
        // 1.
        guard case .present(let key) = reaper.installation() else {
            cache = nil
            return .notInstalled
        }
        // 2.
        if useCache, let cached = cache, cached.key == key {
            return Self.status(from: cached)
        }
        // 3. 署名の後に版（未検証のコードを実行しない）
        let signatureValid = reaper.signatureIsValid()
        let stdout = signatureValid ? await reaper.runVersion() : nil
        // 4.
        let entry = CachedVerification(key: key, signatureValid: signatureValid, stdout: stdout)
        cache = entry
        // 5. ログは検証したときだけ
        if !signatureValid {
            log.warning(.reaperFailed, [(.reason, .string(DeletionReason.signature))])
        } else if stdout != AppVersion.string + "\n" {
            log.warning(.reaperFailed, [(.reason, .string(DeletionReason.versionMismatch))])
        }
        // 6.
        return Self.status(from: entry)
    }

    private static func status(from entry: CachedVerification) -> ReaperStatus {
        if !entry.signatureValid { return .signatureInvalid }
        if entry.stdout == AppVersion.string + "\n" { return .valid(version: AppVersion.string) }
        return .versionMismatch(found: entry.stdout.map(dropOneTrailingNewline))
    }

    /// 末尾が "\n" なら 1 つだけ除く
    private static func dropOneTrailingNewline(_ s: String) -> String {
        s.hasSuffix("\n") ? String(s.dropLast()) : s
    }
}

private struct CachedVerification: Equatable, Sendable {
    let key: ReaperFileKey
    let signatureValid: Bool
    /// 署名が不正なら実行しないので nil
    let stdout: String?
}
