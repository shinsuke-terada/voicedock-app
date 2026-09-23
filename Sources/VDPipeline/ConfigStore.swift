// 設定の読み込み・検証・書き込みの唯一の窓口（PLAN §6.1）。GUI と有効化フローの変更もここだけが書く。
import Foundation
import VDContract
import VDCore

/// 設定の読み込み・検証・書き込みの唯一の窓口（PLAN §6.1）。
/// PT-11: reaper.conf は注入された `observeReaperConf` で読む（このファイルにその語を書かない）。
public actor ConfigStore {
    /// F-83: 最後に読んでから config.json が変わっていたときの update の違反の文言（CV-39、keyPath は `<file>`）
    static let changedOnDiskMessage =
        "最後に読み込んだ後に config.json が変更されています。" + "「設定を読み直す」で読み直してから、もう一度操作してください"

    private let layout: HomeLayout
    private let catalog: ModelCatalog
    private let log: AppLog
    private let observeReaperConf: @Sendable () async -> ReaperConfObservation
    private let defaultTimeZone: @Sendable () -> String

    private var config: AppConfig?
    private var lastViolations: [ConfigViolation] = []
    private var created = false
    private var reconciler: (@Sendable () async -> Bool)?
    /// F-83: 最後に読んだ（または書いた）config.json の内容の SHA-256。update は書く前に今の内容と照らし、違えば書かない
    private var lastSeenDigest: String?

    /// 00-api-map §11 の `init(layout:catalog:log:observeReaperConf:)` はこの 4 つ。
    /// `defaultTimeZone:` は**既定値つきのテストの口**（本番の Bootstrap は渡さない。T-30 §4.2 の 7）。
    public init(
        layout: HomeLayout, catalog: ModelCatalog, log: AppLog,
        observeReaperConf: @escaping @Sendable () async -> ReaperConfObservation,
        defaultTimeZone: @escaping @Sendable () -> String = { TimeZone.current.identifier }
    ) {
        self.layout = layout
        self.catalog = catalog
        self.log = log
        self.observeReaperConf = observeReaperConf
        self.defaultTimeZone = defaultTimeZone
    }

    /// 読み込み（初回起動と「設定を読み直す」）。無ければ既定を書く。結果を current / violations に反映する。
    public func load() async -> ConfigLoadResult {
        let url = layout.configFile
        let result = await loadResult(url)
        switch result {
        case .valid(let c):
            config = c
            lastViolations = []
        case .invalid(let v):
            config = nil
            lastViolations = v
            for violation in v {
                log.error(
                    .configInvalid,
                    [
                        (.rule, .string(violation.rule)), (.key, .string(violation.keyPath)),
                        (.message, .string(violation.message)),
                    ])
            }
        }
        return result
    }

    /// 検証を通った設定。設定エラー中は nil。
    public func current() -> AppConfig? { config }

    public func violations() -> [ConfigViolation] { lastViolations }

    /// この起動で config.json を新しく書いたか（初回起動。パネルを自動で開く。PLAN §8.12）。
    public func didCreateDefaults() -> Bool { created }

    /// GUI と有効化フローの変更。**書く前に**変更後の値と reaper.conf の観測で検証し、違反なら書かない。
    /// reaperConfObservation が nil なら今の値（observeReaperConf()）で検証する。
    /// actor の再入: 観測を**先に**取り、`config` の読み出しから書き込みまでは await を挟まない
    /// （並行した 2 つの update が同じ古い値から始めて片方の変更を失わないため）。
    /// F-83: 書く前に config.json の今の内容を最後に読んだ（書いた）内容と照らし、違えば（手で編集された・消された・読めない）
    /// 書かずに違反（CV-39、`<file>`、`changedOnDiskMessage`）を返す。読み直していない手編集をメモリの古い値で黙って上書きしない
    /// （手で false にした `deleteSkippedSource` が、パネルでモデルを選ぶと true に戻った）。符号化できなければ書かずに違反を返す。
    public func update(
        _ mutate: @Sendable (inout AppConfig) -> Void,
        reaperConfObservation: ReaperConfObservation? = nil
    ) async -> ConfigUpdateResult {
        let observation: ReaperConfObservation
        if let given = reaperConfObservation {
            observation = given
        } else {
            observation = await observeReaperConf()
        }
        guard var c = config else {
            return .failure(lastViolations.isEmpty ? [violation("設定が読み込まれていません")] : lastViolations)
        }
        mutate(&c)
        let v = ConfigValidator.validate(c, catalog: catalog, reaperConfObservation: observation)
        if !v.isEmpty { return .failure(v) }
        guard let onDisk = try? Data(contentsOf: layout.configFile), FileHasher.sha256(onDisk) == lastSeenDigest else {
            return .failure([violation(ConfigStore.changedOnDiskMessage)])
        }
        let data: Data
        do {
            data = try ConfigLoader.encode(c)
        } catch {
            return .failure([violation("符号化できません: " + ErrorText.describe(error))])
        }
        do {
            try AtomicFile.write(data, to: layout.configFile, permissions: 0o644)
        } catch {
            return .failure([violation("書けません: " + ErrorText.describe(error))])
        }
        lastSeenDigest = FileHasher.sha256(data)
        config = c
        return .success(c)
    }

    /// ロック 1 の食い違い（CV-30）の修復口。本体は T-40（DeletionEnabler.reconcileLock1）。
    /// reconcile は reaper.conf を無効側（DELETE_SOURCE_AUDIO=false）に揃え、揃えたら true を返す。
    public func setLock1Reconciler(_ reconcile: @escaping @Sendable () async -> Bool) {
        reconciler = reconcile
    }

    /// load() の手順 1〜3（既定の書き出し・読み込み・CV-30 の修復）。
    /// actor の再入: 観測（と修復口）を待ってから、ファイルの読み出しと結果の反映までは await を挟まない。
    private func loadResult(_ url: URL) async -> ConfigLoadResult {
        let observation = await observeReaperConf()
        var result = readSync(url, observation: observation, writeDefaults: true)
        if case .invalid(let v) = result, v.contains(where: { $0.rule == "CV-30" }), let reconcile = reconciler {
            guard await reconcile() else { return readSync(url, observation: observation, writeDefaults: false) }
            let after = await observeReaperConf()
            guard let data = try? Data(contentsOf: url), var c = try? JSONDecoder().decode(AppConfig.self, from: data)
            else { return readSync(url, observation: after, writeDefaults: false) }
            c.cleanup.deleteSourceAudio = false
            c.cleanup.deleteSkippedSource = false
            c.device.mountMode = "ro"
            do {
                try AtomicFile.write(try ConfigLoader.encode(c), to: url, permissions: 0o644)
            } catch {
                return readSync(url, observation: after, writeDefaults: false)
            }
            log.warning(
                .configWarning, [(.rule, "CV-30"), (.message, "reaper.conf と config.json の削除の設定を無効側に揃えました")])
            result = readSync(url, observation: after, writeDefaults: false)
        }
        return result
    }

    /// 手順 1（無いときだけ既定を書く）と read()。同期（await しない）。
    private func readSync(_ url: URL, observation: ReaperConfObservation, writeDefaults: Bool) -> ConfigLoadResult {
        var info = stat()
        if writeDefaults && lstat(url.path(percentEncoded: false), &info) != 0 && errno == ENOENT {
            let d = AppConfig.defaults(timeZone: defaultTimeZone())
            do {
                try AtomicFile.write(try ConfigLoader.encode(d), to: url, permissions: 0o644)
            } catch {
                return .invalid([violation("既定の設定を書けません: " + ErrorText.describe(error))])
            }
            created = true
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            lastSeenDigest = nil
            return .invalid([violation("読めません: " + ErrorText.describe(error))])
        }
        // F-83: update が書く前に照らす内容（検証に通らなくても覚える。そのとき update は設定エラーで書かない）
        lastSeenDigest = FileHasher.sha256(data)
        return ConfigLoader.load(data: data, catalog: catalog, reaperConfObservation: observation)
    }

    private func violation(_ message: String) -> ConfigViolation {
        ConfigViolation(rule: "CV-39", code: .configInvalidValue, keyPath: ConfigLoader.fileKeyPath, message: message)
    }
}

/// `update` の結果（00-api-map §11）。`Result` の失敗側は `Error` を要り配列は `Error` でないため包み型にする
/// （利用者の決定 2026-09-22）。ケース名は `Result` と同じ（呼び手は `case .failure(let v)` で違反の配列を受ける）。
public enum ConfigUpdateResult: Sendable, Equatable {
    case success(AppConfig)
    case failure([ConfigViolation])
}
