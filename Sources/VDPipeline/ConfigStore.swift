// 設定の読み込み・検証・書き込みの唯一の窓口（PLAN §6.1）。GUI と有効化フローの変更もここだけが書く。
import Foundation
import VDContract
import VDCore

/// 設定の読み込み・検証・書き込みの唯一の窓口（PLAN §6.1）。
/// PT-11: reaper.conf は注入された `observeReaperConf` で読む（このファイルにその語を書かない）。
public actor ConfigStore {
    /// F-83: 読み直した config.json（手の編集を含む）に変更を当てた値が検証に落ちたとき、違反に添える案内（CV-39、keyPath は `<file>`）
    static let reloadGuidance =
        "config.json は最後に読み込んだ後に変更されています（手の編集を含めて検証しました）。" + "「設定を読み直す」で内容を確かめてください"
    /// F-83: 読み直してから書く直前までに config.json がまた変わったときの update の違反の文言（CV-39、keyPath は `<file>`）
    static let changedWhileWritingMessage = "書き込む直前に config.json が変更されました。もう一度操作してください"

    private let layout: HomeLayout
    private let catalog: ModelCatalog
    private let log: AppLog
    private let observeReaperConf: @Sendable () async -> ReaperConfObservation
    private let defaultTimeZone: @Sendable () -> String

    private var config: AppConfig?
    private var lastViolations: [ConfigViolation] = []
    private var created = false
    private var reconciler: (@Sendable () async -> Bool)?
    /// F-83: 最後に読んだ（または書いた）config.json の内容の SHA-256（update が「手で変えられた」と案内するために比べる）
    private var lastSeenDigest: String?

    /// F-83: update が書く前に読み直した config.json
    enum CurrentFile {
        /// 無い（ENOENT）。update はメモリの値から作り直す
        case missing
        /// 在るが読めない（説明）
        case unreadable(String)
        case contents(Data)
    }

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
    /// actor の再入: 観測を**先に**取り、ファイルの読み直しから書き込みまでは await を挟まない
    /// （並行した 2 つの update が同じ古い値から始めて片方の変更を失わないため）。
    /// F-83（§6.1）: **書く前に今の config.json を読み直し、その値に mutate を当てて**検証して書く（メモリの古い値で書かない。
    /// 手で false にした `deleteSkippedSource` が、パネルでモデルを選ぶと true に戻った）。
    /// - 読み直しは load と同じ厳密な経路（`ConfigLoader.decodeStructure`。JSON・移行・キー・型）。読めない・構造が壊れていれば書かずに違反を返す
    /// - 検証するのは「読み直した値 ＋ mutate」だけで、観測は渡されたもの（F-37。変更前のファイルを今の reaper.conf で検証しない）
    /// - ファイルが無ければメモリの値に mutate を当てて作り直す（Vault・モデルの選択を失わない）
    /// - 手の編集を含めた値が検証に落ちたら、違反に `reloadGuidance` を添える。`load()` や修復口は呼ばない（無効化の中で呼ばれる）
    /// - 書く直前にもう一度読み、読み直した内容から変わっていれば書かない（`changedWhileWritingMessage`）
    /// - 書けたら `current()`・`violations()`・覚えた内容を同時に替える。符号化できなければ書かずに違反を返す
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
        guard let inMemory = config else {
            return .failure(lastViolations.isEmpty ? [violation("設定が読み込まれていません")] : lastViolations)
        }
        let url = layout.configFile
        let before = Self.readCurrent(url)
        var c: AppConfig
        switch before {
        case .missing:
            c = inMemory
        case .unreadable(let message):
            return .failure([violation("読めません: " + message)])
        case .contents(let data):
            switch ConfigLoader.decodeStructure(data: data) {
            case .invalid(let v):
                return .failure(v + [violation(ConfigStore.reloadGuidance)])
            case .valid(let decoded):
                c = decoded
            }
        }
        let beforeDigest = Self.digest(before)
        mutate(&c)
        let v = ConfigValidator.validate(c, catalog: catalog, reaperConfObservation: observation)
        if !v.isEmpty {
            return .failure(beforeDigest == lastSeenDigest ? v : v + [violation(ConfigStore.reloadGuidance)])
        }
        let data: Data
        do {
            data = try ConfigLoader.encode(c)
        } catch {
            return .failure([violation("符号化できません: " + ErrorText.describe(error))])
        }
        // 読み直してから書くまでの窓を縮める（書く直前にもう一度照らす）
        guard Self.digest(Self.readCurrent(url)) == beforeDigest else {
            return .failure([violation(ConfigStore.changedWhileWritingMessage)])
        }
        do {
            try AtomicFile.write(data, to: url, permissions: 0o644)
        } catch {
            return .failure([violation("書けません: " + ErrorText.describe(error))])
        }
        lastSeenDigest = FileHasher.sha256(data)
        lastViolations = []
        config = c
        return .success(c)
    }

    /// F-83: 削除を無効側にする 3 つの値（`deleteSourceAudio`・`deleteSkippedSource` = false、`mountMode` = ro）。
    /// CV-30 の修復・無効化のフロー・`disableDeletionInMemory` が同じ関数を使う（CR-06）
    static func turnDeletionOff(_ c: inout AppConfig) {
        c.cleanup.deleteSourceAudio = false
        c.cleanup.deleteSkippedSource = false
        c.device.mountMode = DeviceConfig.MountMode.ro.rawValue
    }

    /// F-83: 無効化のフローで config.json を書けなかったとき（壊れている・書けない・検証に落ちた）、**メモリの設定だけ**を無効側に倒す
    /// （IngestService が読み取り専用に戻し、削除の判定が止まる）。ファイルは書かない（reaper.conf は先に false で、
    /// 次の読み込みの CV-30 の修復が config を揃える）。設定エラー中（メモリに設定が無い）は何もしない
    func disableDeletionInMemory() {
        guard var c = config else { return }
        Self.turnDeletionOff(&c)
        config = c
    }

    /// update が書く前・書く直前に読む config.json（無い・読めない・中身）。同期
    static func readCurrent(_ url: URL) -> CurrentFile {
        var info = stat()
        if lstat(url.path(percentEncoded: false), &info) != 0 && errno == ENOENT {
            return .missing
        }
        do {
            return .contents(try Data(contentsOf: url))
        } catch {
            return .unreadable(ErrorText.describe(error))
        }
    }

    /// 読んだ内容の SHA-256（無い・読めないは nil。読めないものは update が先に断る）
    static func digest(_ file: CurrentFile) -> String? {
        if case .contents(let data) = file { return FileHasher.sha256(data) }
        return nil
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
            // F-83: 修復でも load と同じ厳密な経路で読む（緩い JSONDecoder と移行なしで読まない。CR-06）
            guard let data = try? Data(contentsOf: url), case .valid(var c) = ConfigLoader.decodeStructure(data: data)
            else { return readSync(url, observation: after, writeDefaults: false) }
            Self.turnDeletionOff(&c)
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
        // F-83: update が「手で変えられた」と案内するために比べる内容（検証に通らなくても覚える）
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
