// 三重ロックをまとめて外す・掛け直す唯一の場所（PLAN §8.9.8）。
// バンドル内の reaper を参照してよいのも <HOME>/bin/ へ書いてよいのもこのファイルだけ（D-5・PT-11）。
import Darwin
import Foundation
import Security
import VDContract
import VDCore

/// 段の名前（`disable()` の戻り値と `EnableError` が使う。逐語。ここ以外に書かない）
public enum DeletionStage {
    public static let copyReaper = "copy_reaper"
    public static let reaperConfFile = "reaper_conf"
    public static let config = "config"
    public static let removeReaper = "remove_reaper"
    public static let withdrawRequests = "withdraw_requests"
    public static let remount = "remount"
}

public enum EnableError: Error, Equatable, Sendable {
    /// `ENABLE` の完全一致でない（何も変えていない）
    case notConfirmed
    /// 複製に失敗した（段の説明。日本語）
    case install(String)
    /// 複製したファイルの署名検証に失敗した
    case signature
    /// bin/reaper.conf を書けない
    case reaperConfWrite(String)
    /// config.json の検証に落ちた・書けない
    case config([ConfigViolation])
    /// 設定が読み込まれていない（設定エラー中）
    case configNotLoaded
    /// 巻き戻しにも失敗した（`stages` は戻せなかった段の名前）
    case rollback(stages: [String])
}

public actor DeletionEnabler {
    private let layout: HomeLayout
    private let paths: AppPaths
    private let config: ConfigStore
    private let verifier: any SignatureVerifier
    private let ingest: any IngestPort
    private let log: AppLog
    /// 最後に受け付けた操作（次の操作はこれの終わりを待ってから始める）。
    /// actor は await の間に別の呼び出しを受け付ける（再入）ので、操作の本体が await で止まっている間に
    /// 別の操作が割り込まないよう、受け付けた順に 1 本ずつ実行する（有効化の途中で来た無効化は、有効化の後に必ず走る）
    private var last: Task<Void, Never>?

    public init(
        layout: HomeLayout, paths: AppPaths, config: ConfigStore,
        verifier: any SignatureVerifier, ingest: any IngestPort, log: AppLog
    ) {
        self.layout = layout
        self.paths = paths
        self.config = config
        self.verifier = verifier
        self.ingest = ingest
        self.log = log
    }

    static let confirmationWord = DeletionStrings.confirmationWord
    /// 複製の読み込みの上限（reaper は数 MB。壊れた入力で巨大な確保をしない）
    static let maxReaperBytes = 64 * 1024 * 1024
    /// `AppConfig` の `device.mountMode` は String（T-09 §4）
    static let mountModeRW = "rw"
    static let mountModeRO = "ro"
    /// 根拠 B の有効化のログの reason
    static let skippedScope = "skipped_source"

    /// PLAN §8.9.8 の有効化。すべて成功するか、1 つも変えないか（受け付けた順に 1 本ずつ）
    public func enable(confirmation: String) async -> Result<Void, EnableError> {
        await serially { await $0.performEnable(confirmation: confirmation) }
    }

    /// 根拠 B（無音・重複も消す）。削除が有効なときだけ通る（受け付けた順に 1 本ずつ）
    public func enableSkippedDeletion(confirmation: String) async -> Result<Void, EnableError> {
        await serially { await $0.performEnableSkipped(confirmation: confirmation) }
    }

    /// PLAN §8.9.8 の無効化。**確認を求めない**。失敗した段の名前を順に返す（空なら全部成功。受け付けた順に 1 本ずつ）
    public func disable() async -> [String] {
        await serially { await $0.performDisable() }
    }

    /// PLAN §6.1。reaper.conf を無効側（DELETE_SOURCE_AUDIO=false）に揃える。揃えたら true（受け付けた順に 1 本ずつ）
    public func reconcileLock1() async -> Bool {
        await serially { await $0.performReconcile() }
    }

    /// 消す能力が残っているか（PLAN §8.9.8 の常時表示を設定エラー中にも出すため）。
    /// reaper.conf が `DELETE_SOURCE_AUDIO=true` で読めるか、bin/ に reaper の通常ファイルが在れば真
    public func hasRemainingCapability() -> Bool {
        if case .valid(let c) = ReaperConf.observe(at: layout.reaperConf), c.deleteSourceAudio { return true }
        var st = stat()
        return lstat(p(layout.reaperExecutable), &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// 前の操作の終わりを待ってから operation を実行する。last の差し替えは await を挟まずに行う（受け付けた順が保たれる）
    private func serially<T: Sendable>(_ operation: @escaping @Sendable (DeletionEnabler) async -> T) async -> T {
        let previous = last
        let task = Task { [self] () -> T in
            await previous?.value
            return await operation(self)
        }
        last = Task { _ = await task.value }
        return await task.value
    }

    /// 書き込み順: 複製 → reaper.conf → config
    private func performEnable(confirmation: String) async -> Result<Void, EnableError> {
        // 1.
        guard isConfirmed(confirmation) else { return .failure(.notConfirmed) }
        // 2. 設定エラー中は有効化しない
        guard await config.current() != nil else { return .failure(.configNotLoaded) }
        // 3. 控える（巻き戻しのため。ここではまだ何も書かない）
        let beforeConf: Data? = DeleteQueue.readSmallFile(layout.reaperConf)
        let beforeVolumesRoot = currentVolumesRoot()
        var st = stat()
        let reaperExisted = lstat(p(layout.reaperExecutable), &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
        // 4. 段 1「複製」。失敗しても戻すものは無い（installReaper が自分の tmp を消す）
        if case .failure(let e) = installReaper() {
            return .failure(e)
        }
        // 5. 段 2「reaper.conf」
        if case .failure(let e) = writeReaperConf(deleteSourceAudio: true, volumesRoot: beforeVolumesRoot) {
            let left = rollback(to: beforeConf, reaperExisted: reaperExisted, stages: [DeletionStage.copyReaper])
            if !left.isEmpty { return .failure(.rollback(stages: left)) }
            return .failure(.reaperConfWrite(ErrorText.describe(e)))
        }
        // 6. 段 3「config」
        let observation = ReaperConfObservation.valid(
            ReaperConf(deleteSourceAudio: true, volumesRoot: beforeVolumesRoot))
        let r = await config.update(
            { c in
                c.cleanup.deleteSourceAudio = true
                c.device.mountMode = DeletionEnabler.mountModeRW
            }, reaperConfObservation: observation)
        if case .failure(let v) = r {
            let left = rollback(
                to: beforeConf, reaperExisted: reaperExisted,
                stages: [DeletionStage.reaperConfFile, DeletionStage.copyReaper])
            if !left.isEmpty { return .failure(.rollback(stages: left)) }
            return .failure(.config(v))
        }
        // 7.
        log.info(.deletionEnabled, [])
        // 8.
        return .success(())
    }

    private func performEnableSkipped(confirmation: String) async -> Result<Void, EnableError> {
        // 1.
        guard isConfirmed(confirmation) else { return .failure(.notConfirmed) }
        // 2.
        guard let c = await config.current() else { return .failure(.configNotLoaded) }
        // 3. CV-43 と同じ条件を先に見る（違反の配列は空 = 「前提が無い」）
        guard c.cleanup.deleteSourceAudio else { return .failure(.config([])) }
        // 4. reaperConfObservation は渡さない（今の値で検証する）
        if case .failure(let v) = await config.update({ $0.cleanup.deleteSkippedSource = true }) {
            return .failure(.config(v))
        }
        // 5.
        log.info(.deletionEnabled, [(.reason, .string(DeletionEnabler.skippedScope))])
        return .success(())
    }

    /// 段の順は規約（消す能力に近いものから先に止める）: reaper.conf → reaper の削除 → config → 要求の取り下げ → 再マウント。
    /// 途中で失敗しても残りを続ける。
    private func performDisable() async -> [String] {
        var failed: [String] = []
        let volumesRoot = currentVolumesRoot()
        // 1. reaper.conf を false（reaper 側のロック 1 を先に掛ける）
        if case .failure = writeReaperConf(deleteSourceAudio: false, volumesRoot: volumesRoot) {
            failed.append(DeletionStage.reaperConfFile)
        }
        // 2. reaper を削除
        if unlink(p(layout.reaperExecutable)) != 0 && errno != ENOENT {
            failed.append(DeletionStage.removeReaper)
        }
        // 3. config を無効側。観測は「これから揃える先（false）」を渡す（F-37。自分の CV-30 に阻まれない）
        let observation = ReaperConfObservation.valid(ReaperConf(deleteSourceAudio: false, volumesRoot: volumesRoot))
        let r = await config.update(
            { c in
                c.cleanup.deleteSourceAudio = false
                c.cleanup.deleteSkippedSource = false
                c.device.mountMode = DeletionEnabler.mountModeRO
            }, reaperConfObservation: observation)
        if case .failure = r {
            failed.append(DeletionStage.config)
        }
        // 4. 要求の取り下げ
        let (_, f) = DeleteQueue.withdrawAllRequests(layout: layout)
        if f > 0 {
            failed.append(DeletionStage.withdrawRequests)
        }
        // 5. 再マウント（走査が見送られた = 読み取り専用に戻せていない）
        if await ingest.scanNow() == nil {
            failed.append(DeletionStage.remount)
        }
        // 6.
        if failed.isEmpty {
            log.info(.deletionDisabled, [])
        } else {
            log.warning(.deletionDisabled, [(.reason, .string(failed.joined(separator: ",")))])
        }
        // 7.
        return failed
    }

    /// config.json 側は書かない（ConfigStore.load() が真を受けてから書く）。reaper の削除と要求の取り下げもしない。
    private func performReconcile() async -> Bool {
        // 1.
        let volumesRoot = currentVolumesRoot()
        // 2.
        if case .failure(let e) = writeReaperConf(deleteSourceAudio: false, volumesRoot: volumesRoot) {
            log.warning(
                .configWarning,
                [
                    (.rule, .string("CV-30")),
                    (.message, .string("reaper.conf を無効側に揃えられません: " + ErrorText.describe(e))),
                ])
            return false
        }
        // 3.
        return true
    }

    // MARK: - 内部

    /// Swift の `==` は正準等価で比べるので使わない（00-api-map §0）
    private func isConfirmed(_ s: String) -> Bool {
        PyText.scalarsEqual(s, Self.confirmationWord)
    }

    /// reaper.conf が `.valid(c)` なら `c.volumesRoot`、それ以外は `Contract.volumesRoot`（テストの VOLUMES_ROOT を消さない）
    private func currentVolumesRoot() -> String {
        if case .valid(let c) = ReaperConf.observe(at: layout.reaperConf) {
            return c.volumesRoot
        }
        return Contract.volumesRoot
    }

    private func writeReaperConf(deleteSourceAudio: Bool, volumesRoot: String) -> Result<Void, AtomicFileError> {
        do {
            try AtomicFile.write(
                ReaperConf(deleteSourceAudio: deleteSourceAudio, volumesRoot: volumesRoot).render(),
                to: layout.reaperConf, permissions: 0o644)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// 書いた順の逆に戻す。戻せなかった段の名前を返す
    private func rollback(to beforeConf: Data?, reaperExisted: Bool, stages: [String]) -> [String] {
        var left: [String] = []
        // 1.
        if stages.contains(DeletionStage.reaperConfFile) {
            let restored: Bool
            if let beforeConf {
                restored = (try? AtomicFile.write(beforeConf, to: layout.reaperConf, permissions: 0o644)) != nil
            } else {
                restored = unlink(p(layout.reaperConf)) == 0 || errno == ENOENT
            }
            if !restored { left.append(DeletionStage.reaperConfFile) }
        }
        // 2. 元から在ったなら消さない（上書きしたのは同じバンドルの同じ実行ファイル）
        if stages.contains(DeletionStage.copyReaper) && !reaperExisted {
            if unlink(p(layout.reaperExecutable)) != 0 && errno != ENOENT {
                left.append(DeletionStage.copyReaper)
            }
        }
        return left
    }

    /// PLAN §8.9.3 の 6: `.voicedock-reaper.tmp` → fsync → 署名検証 → chmod 0755 → rename。
    /// AtomicFile は「tmp を作る」と「rename」の間に署名検証と chmod を挟めないので使わない（PT-12 の許可場所）。
    private func installReaper() -> Result<Void, EnableError> {
        // 1. ここから実行はしない（D-5）
        let src = paths.bundledReaperURL
        // 2.
        guard let bytes = readBundledReaper(src) else {
            return .failure(.install("同梱の削除モジュールを読めません"))
        }
        // 3. bin/ は HomeLayout.createDirectories() が作らない（ロック 2-A）
        try? FileManager.default.createDirectory(
            at: layout.binDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        // 4.
        let tmp = AtomicFile.tmpURL(for: layout.reaperExecutable)
        // 5.
        let out = open(p(tmp), O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o700)
        guard out >= 0 else {
            _ = unlink(p(tmp))
            return .failure(.install("削除モジュールを書けません"))
        }
        let written = Self.writeAll(fd: out, bytes) && fsync(out) == 0
        close(out)
        guard written else {
            _ = unlink(p(tmp))
            return .failure(.install("削除モジュールを書けません"))
        }
        // 6. 実行できる場所に置く前に、複製した方を確かめる
        guard verifier.verify(url: tmp) else {
            _ = unlink(p(tmp))
            return .failure(.signature)
        }
        // 7.
        guard chmod(p(tmp), 0o755) == 0 else {
            _ = unlink(p(tmp))
            return .failure(.install("削除モジュールの権限を設定できません"))
        }
        // 8.
        guard rename(p(tmp), p(layout.reaperExecutable)) == 0 else {
            _ = unlink(p(tmp))
            return .failure(.install("削除モジュールを配置できません"))
        }
        // 9.（どの失敗も無視）
        let dir = open(p(layout.binDirectory), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dir >= 0 {
            _ = fsync(dir)
            close(dir)
        }
        // 10.
        return .success(())
    }

    /// O_NOFOLLOW で開き、通常ファイルで maxReaperBytes 以下のときだけ全部読む。どの経路でも close
    private func readBundledReaper(_ src: URL) -> Data? {
        let fd = open(p(src), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= Self.maxReaperBytes else {
            return nil
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.count > Self.maxReaperBytes { return nil }
        }
        return data
    }

    /// 全部書けたら true
    private static func writeAll(fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }

    private func p(_ url: URL) -> String { url.path(percentEncoded: false) }
}
