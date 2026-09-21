// 設定の読み込み・検証・書き込みの唯一の窓口（PLAN §6.1）。GUI と有効化フローの変更もここだけが書く。
import Foundation
import VDContract
import VDCore

/// 設定の読み込み・検証・書き込みの唯一の窓口（PLAN §6.1）。
/// PT-11: reaper.conf は注入された `observeReaperConf` で読む（このファイルにその語を書かない）。
public actor ConfigStore {
    static let fileKeyPath = "<file>"

    private let layout: HomeLayout
    private let catalog: ModelCatalog
    private let log: AppLog
    private let observeReaperConf: @Sendable () async -> ReaperConfObservation
    private let defaultTimeZone: @Sendable () -> String

    private var config: AppConfig?
    private var lastViolations: [ConfigViolation] = []
    private var created = false
    private var reconciler: (@Sendable () async -> Bool)?

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
    public func update(
        _ mutate: @Sendable (inout AppConfig) -> Void,
        reaperConfObservation: ReaperConfObservation? = nil
    ) async -> Result<AppConfig, [ConfigViolation]> {
        guard var c = config else {
            return .failure(lastViolations.isEmpty ? [violation("設定が読み込まれていません")] : lastViolations)
        }
        mutate(&c)
        let observation: ReaperConfObservation
        if let given = reaperConfObservation {
            observation = given
        } else {
            observation = await observeReaperConf()
        }
        let v = ConfigValidator.validate(c, catalog: catalog, reaperConfObservation: observation)
        if !v.isEmpty { return .failure(v) }
        do {
            try AtomicFile.write(ConfigLoader.encode(c), to: layout.configFile, permissions: 0o644)
        } catch {
            return .failure([violation("書けません: " + ErrorText.describe(error))])
        }
        config = c
        return .success(c)
    }

    /// ロック 1 の食い違い（CV-30）の修復口。本体は T-40（DeletionEnabler.reconcileLock1）。
    /// reconcile は reaper.conf を無効側（DELETE_SOURCE_AUDIO=false）に揃え、揃えたら true を返す。
    public func setLock1Reconciler(_ reconcile: @escaping @Sendable () async -> Bool) {
        reconciler = reconcile
    }

    /// load() の手順 1〜3（既定の書き出し・読み込み・CV-30 の修復）。
    private func loadResult(_ url: URL) async -> ConfigLoadResult {
        var info = stat()
        if lstat(url.path(percentEncoded: false), &info) != 0 && errno == ENOENT {
            let d = AppConfig.defaults(timeZone: defaultTimeZone())
            do {
                try AtomicFile.write(ConfigLoader.encode(d), to: url, permissions: 0o644)
            } catch {
                return .invalid([violation("既定の設定を書けません: " + ErrorText.describe(error))])
            }
            created = true
        }
        var result = await read(url)
        if case .invalid(let v) = result, v.contains(where: { $0.rule == "CV-30" }), let reconcile = reconciler {
            guard await reconcile() else { return result }
            guard let data = try? Data(contentsOf: url), var c = try? JSONDecoder().decode(AppConfig.self, from: data)
            else { return result }
            c.cleanup.deleteSourceAudio = false
            c.cleanup.deleteSkippedSource = false
            c.device.mountMode = "ro"
            do {
                try AtomicFile.write(ConfigLoader.encode(c), to: url, permissions: 0o644)
            } catch {
                return result
            }
            log.warning(
                .configWarning, [(.rule, "CV-30"), (.message, "reaper.conf と config.json の削除の設定を無効側に揃えました")])
            result = await read(url)
        }
        return result
    }

    private func read(_ url: URL) async -> ConfigLoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .invalid([violation("読めません: " + ErrorText.describe(error))])
        }
        return ConfigLoader.load(data: data, catalog: catalog, reaperConfObservation: await observeReaperConf())
    }

    private func violation(_ message: String) -> ConfigViolation {
        ConfigViolation(rule: "CV-39", code: .configInvalidValue, keyPath: ConfigStore.fileKeyPath, message: message)
    }
}

/// `update` の `Result<AppConfig, [ConfigViolation]>`（00-api-map §11）は失敗側が `Error` であることを要る。
/// 配列はそのままでは `Error` でないので、違反の配列にだけ準拠を足す（T-18 §11 の提案 12。利用者の判断待ち）。
// swift-format-ignore: AvoidRetroactiveConformances
extension Array: @retroactive Error where Element == ConfigViolation {}
