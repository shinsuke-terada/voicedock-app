// DR-01〜17 のうち 15 件の本体（PLAN §8.11。DR-09 は LLMProbeCheck、DR-13 は取り下げ（PLAN F-61））。すべて読むだけ。
import Darwin
import Foundation
import VDAudio
import VDContract
import VDCore
import VDDevice
import VDLLM
import VDNotes
import VDProcess
import VDStore
import VDTranscribe

/// 15 件の検査の本体（voicedock doctor.py:115-586 に当たる）。何も書き換えない（PT-17・OPS-14）。
enum DiagnosticChecks {
    /// `--help` の時間の上限
    static let helpTimeout: Duration = .seconds(20)

    static func result(_ id: String, _ status: DiagnosticStatus, _ details: [String]) -> DiagnosticResult {
        DiagnosticResult(id: id, status: status, label: DiagnosticTexts.label(id), details: details)
    }

    // MARK: 致命の 3 つ

    /// DR-01 設定（致命）
    @Sendable static func dr01(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.config
        if ctx.config != nil && ctx.violations.isEmpty {
            return result(id, .ok, [DiagnosticTexts.configOK])
        }
        if ctx.violations.isEmpty {
            return result(id, .fail, [DiagnosticTexts.configUnreadable])
        }
        return result(id, .fail, ctx.violations.map(\.rendered))
    }

    /// DR-16 タイムゾーン（致命）。式を 2 か所に書かないため TimeZone(identifier:) をそのまま使う
    @Sendable static func dr16(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.timeZone
        guard let c = ctx.config else { return result(id, .fail, [DiagnosticTexts.configMissing]) }
        if TimeZone(identifier: c.timeZone) != nil {
            return result(id, .ok, [c.timeZone])
        }
        return result(id, .fail, [DiagnosticTexts.timeZoneUnresolved(c.timeZone)])
    }

    /// DR-02 データベース（致命）。無ければ作らない（ReadOnlyStore だけを使う。PT-17）
    @Sendable static func dr02(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.database
        let url = ctx.deps.layout.database
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return result(id, .notice, [DiagnosticTexts.dbNotCreated])
        }
        guard let ro = ReadOnlyStore.open(url: url) else {
            return result(id, .fail, [DiagnosticTexts.dbUnopenable])
        }
        // quick_check が投げたら「開けない」（空の結果を quick_check の文言で出さない）
        guard let qc = try? ro.quickCheck() else { return result(id, .fail, [DiagnosticTexts.dbUnopenable]) }
        guard qc == "ok" else { return result(id, .fail, [DiagnosticTexts.dbQuickCheck(qc)]) }
        let applied = (try? ro.appliedMigrations()) ?? []
        guard applied == Store.migrationIdentifiers else {
            return result(
                id, .fail,
                [DiagnosticTexts.dbMigrations(applied: applied.last, expected: Store.migrationIdentifiers.last)])
        }
        return result(id, .ok, [DiagnosticTexts.dbOK(applied.last ?? "")])
    }

    // MARK: 残り

    /// DR-03 空き容量（§8.3 の SpaceCheck を 1800 秒で呼ぶ。足りなければ notice）
    @Sendable static func dr03(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.space
        guard let c = ctx.config else { return result(id, .fail, [DiagnosticTexts.configMissing]) }
        switch SpaceCheck(config: c.audio, layout: ctx.deps.layout).check(
            durationSeconds: DiagnosticTexts.probeDurationSeconds)
        {
        case .ok:
            return result(id, .ok, freeBytes(ctx.deps.layout).map { [DiagnosticTexts.spaceOK($0)] } ?? [])
        case .insufficient(let m):
            return result(id, .notice, [m])
        }
    }

    /// SpaceCheck と同じ場所（staging が在ればそこ、無ければ <HOME>）の statfs の空き。取れなければ nil
    static func freeBytes(_ layout: HomeLayout) -> Int64? {
        var directory: ObjCBool = false
        let staging =
            FileManager.default.fileExists(atPath: layout.staging.path(percentEncoded: false), isDirectory: &directory)
            && directory.boolValue
        let target = staging ? layout.staging : layout.root
        var st = statfs()
        guard statfs(target.path(percentEncoded: false), &st) == 0 else { return nil }
        let (product, overflow) = Int64(clamping: st.f_bavail).multipliedReportingOverflow(
            by: Int64(clamping: st.f_bsize))
        return overflow ? Int64.max : product
    }

    /// DR-04 whisper-cli（VAD の 6 フラグ。VAD 無効なら無くても notice）
    @Sendable static func dr04(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.whisperCLI
        let exe = ctx.deps.paths.whisperCLI
        guard FileManager.default.fileExists(atPath: exe.path(percentEncoded: false)) else {
            return result(id, .fail, [DiagnosticTexts.executableMissing(exe)])
        }
        let r = await help(exe, ctx)
        guard r.termination == .exited(0) else {
            return result(id, .fail, [DiagnosticTexts.helpFailed(r.termination)])
        }
        let missing = WhisperHelpCheck.missingVADFlags(helpOutput: r.stdoutText + r.stderrText)
        if missing.isEmpty {
            return result(id, .ok, [DiagnosticTexts.vadFlagsOK(WhisperHelpCheck.vadFlags.count)])
        }
        if ctx.config?.transcription.vad.enabled == false {
            return result(id, .notice, [DiagnosticTexts.vadFlagsMissing(missing)])
        }
        return result(id, .fail, [DiagnosticTexts.vadFlagsMissing(missing)])
    }

    /// `<exe> --help` を 1 回（DR-04 / DR-07 が共有する）
    static func help(_ exe: URL, _ ctx: DiagnosticsContext) async -> ProcessResult {
        await ctx.deps.runner.run(
            ProcessSpec(executable: exe, arguments: ["--help"], environment: ProcessEnvironment.cLocale),
            timeout: helpTimeout)
    }

    /// DR-05 Whisper モデル
    @Sendable static func dr05(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.whisperModel
        guard let c = ctx.config else { return result(id, .fail, [DiagnosticTexts.configMissing]) }
        let entry = ctx.deps.catalog.entry(kind: .whisper, id: c.transcription.whisperModelID)
        return await modelCheck(id, kind: .whisper, entry: entry, config: c, ctx: ctx)
    }

    /// DR-06 VAD モデル（VAD 無効なら notice。ASR-02）
    @Sendable static func dr06(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.vadModel
        guard let c = ctx.config else { return result(id, .fail, [DiagnosticTexts.configMissing]) }
        guard c.transcription.vad.enabled else { return result(id, .notice, [DiagnosticTexts.vadDisabled]) }
        let entry = ctx.deps.catalog.entry(kind: .vad, id: c.transcription.vad.modelID)
        return await modelCheck(id, kind: .vad, entry: entry, config: c, ctx: ctx)
    }

    /// DR-07 llama-server（使うフラグがすべて --help に在る）
    @Sendable static func dr07(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.llamaServer
        let exe = ctx.deps.paths.llamaServer
        guard FileManager.default.fileExists(atPath: exe.path(percentEncoded: false)) else {
            return result(id, .fail, [DiagnosticTexts.executableMissing(exe)])
        }
        let r = await help(exe, ctx)
        guard r.termination == .exited(0) else {
            return result(id, .fail, [DiagnosticTexts.helpFailed(r.termination)])
        }
        let missing = LlamaArgs.missingFlags(helpOutput: r.stdoutText + r.stderrText)
        if missing.isEmpty {
            return result(id, .ok, [DiagnosticTexts.llamaFlagsOK(LlamaArgs.usedFlags.count)])
        }
        return result(id, .fail, [DiagnosticTexts.llamaFlagsMissing(missing)])
    }

    /// DR-08 LLM モデル（custom は SHA だけ。カタログのモデルはメモリも見る。式は ModelMemory の 1 か所）
    @Sendable static func dr08(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.llmModel
        guard let c = ctx.config else { return result(id, .fail, [DiagnosticTexts.configMissing]) }
        guard let modelID = c.llm.modelID else { return result(id, .fail, [DiagnosticTexts.llmNotSelected]) }
        let layout = ctx.deps.layout
        if let sha = CustomModelID.sha256(of: modelID), let url = ModelFiles.customLLMURL(id: modelID, layout: layout) {
            // カタログに bytes が無いのでサイズは見ない。minMemoryGB も不明なのでメモリも見ない
            guard fileStat(url) != nil else {
                return result(id, .fail, [DiagnosticTexts.modelMissing(url.lastPathComponent)])
            }
            guard await sha256(url, chunkBytes: c.audio.hashChunkBytes, ctx: ctx) == sha else {
                return result(id, .fail, [DiagnosticTexts.modelSHA])
            }
            return result(
                id, .ok, [DiagnosticTexts.customModelOK(String(sha.prefix(8))), DiagnosticTexts.customModelUnsupported])
        }
        let entry = ctx.deps.catalog.entry(kind: .llm, id: modelID)
        let r = await modelCheck(id, kind: .llm, entry: entry, config: c, ctx: ctx)
        guard r.status == .ok, let e = entry else { return r }
        if !ModelMemory.hasEnough(minMemoryGB: e.minMemoryGB, physicalMemoryBytes: ctx.deps.physicalMemoryBytes) {
            return result(
                id, .fail,
                r.details + [
                    DiagnosticTexts.notEnoughMemory(
                        required: e.minMemoryGB ?? 0, actual: ModelMemory.gb(ctx.deps.physicalMemoryBytes))
                ])
        }
        return r
    }

    /// DR-05 / DR-06 / DR-08 の共通の下請け（在否 → サイズ → SHA-256。SHA は ModelVerificationCache を通す。PLAN §8.10）
    static func modelCheck(
        _ id: String, kind: ModelKind, entry: ModelEntry?, config: AppConfig, ctx: DiagnosticsContext
    ) async -> DiagnosticResult {
        guard let entry else { return result(id, .fail, [DiagnosticTexts.modelNotSelected]) }
        let url = ModelFiles.url(kind: kind, entry: entry, layout: ctx.deps.layout)
        guard let info = fileStat(url) else { return result(id, .fail, [DiagnosticTexts.modelMissing(entry.file)]) }
        guard info.size == entry.bytes else {
            return result(id, .fail, [DiagnosticTexts.modelSize(actual: info.size, expected: entry.bytes)])
        }
        guard await sha256(url, chunkBytes: config.audio.hashChunkBytes, ctx: ctx) == entry.sha256 else {
            return result(id, .fail, [DiagnosticTexts.modelSHA])
        }
        return result(id, .ok, [DiagnosticTexts.modelOK(entry.displayName)])
    }

    /// stat（symlink を辿る）が成功した通常ファイルの (inode, size, mtime)。それ以外は nil
    static func fileStat(_ url: URL) -> (inode: UInt64, size: Int64, mtime: Double)? {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return (UInt64(info.st_ino), Int64(info.st_size), mtime)
    }

    /// (inode, size, mtime) が変わっていなければ記録の SHA-256 を使い、無ければ計算して記録する（PLAN §8.10）
    static func sha256(_ url: URL, chunkBytes: Int, ctx: DiagnosticsContext) async -> String? {
        guard let info = fileStat(url) else { return nil }
        let path = url.path(percentEncoded: false)
        let cache = ctx.deps.verificationCache
        if let known = await cache.verifiedSHA256(path: path, inode: info.inode, size: info.size, mtime: info.mtime) {
            return known
        }
        guard let sha = try? await BlockingIO.run({ try FileHasher.sha256(of: url, chunkBytes: chunkBytes) }) else {
            return nil
        }
        await cache.record(path: path, inode: info.inode, size: info.size, mtime: info.mtime, sha256: sha)
        return sha
    }

    /// DR-10 Vault（ファイルもフォルダも作らない。NOTE-16。「書けない」と「Vault でない」を別の文言で出す）
    @Sendable static func dr10(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.vault
        guard let c = ctx.config else { return result(id, .fail, [DiagnosticTexts.configMissing]) }
        let path = c.vault.path ?? ""
        let st = VaultCheck.evaluate(path: c.vault.path, marker: c.vault.marker)
        if case .notReadable(let e) = st, e == EPERM {
            return result(id, .fail, [st.message(path: path, marker: c.vault.marker), DiagnosticTexts.tccFolders])
        }
        guard st == .available else { return result(id, .fail, [st.message(path: path, marker: c.vault.marker)]) }
        guard access(path, W_OK) == 0 else {
            let code = errno
            return result(id, .fail, [DiagnosticTexts.vaultNotWritable(path, errno: code)])
        }
        return result(id, .ok, [path])
    }

    /// DR-11 デバイスの列挙（デバイス未接続なら skip）
    @Sendable static func dr11(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.devices
        guard let s = ctx.snapshot else { return result(id, .skip, [DiagnosticTexts.noSnapshot]) }
        // not_included（名前が設定に無い録音のボリューム）は改名の案内だけで、列挙の検査では数えない（「はじめに」の⑤。F-81）
        let unavailable = s.unavailable.filter { $0.value != DetectionReason.notIncluded.rawValue }
        if s.devices.isEmpty && unavailable.isEmpty {
            return result(id, .skip, [DiagnosticTexts.noDevice])
        }
        let bad = names(unavailable, DetectionReason.notListable.rawValue)
        if !bad.isEmpty {
            return result(
                id, .fail,
                bad.map { DiagnosticTexts.notListable($0, errno: s.notListableErrno[$0]) }
                    + [DiagnosticTexts.tccRemovableVolumes])
        }
        // 再マウントでアンマウントされたままのデバイスは「列挙できた」にしない（F-81。挿し直せば戻る）
        let unmounted = names(unavailable, RemountOutcome.mountFailedReason)
        if !unmounted.isEmpty {
            return result(id, .notice, unmounted.map(DiagnosticTexts.leftUnmounted))
        }
        return result(id, .ok, [DiagnosticTexts.devicesListed(s.devices.count)])
    }

    /// unavailable のうち理由が reason の名前（UTF-8 のバイト順）
    static func names(_ unavailable: [String: String], _ reason: String) -> [String] {
        unavailable.filter { $0.value == reason }.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// DR-12 ログイン項目（.enabled 以外は notice）
    @Sendable static func dr12(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.loginItem
        if ctx.loginItem == .enabled {
            return result(id, .ok, [DiagnosticTexts.loginItemEnabled])
        }
        return result(id, .notice, [DiagnosticTexts.loginItem(ctx.loginItem)])
    }

    /// DR-15 inbox の取り残し（自動では消さない。数え方は InboxScan の 1 か所。#120）
    @Sendable static func dr15(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.leftovers
        let layout = ctx.deps.layout
        guard let ro = ReadOnlyStore.open(url: layout.database) else {
            return result(id, .ok, [DiagnosticTexts.leftoversNone])
        }
        let paths = (try? ro.inboxPaths(statuses: PartStates.inboxLeftover)) ?? []
        let c = InboxScan.leftovers(layout: layout, relativePaths: paths)
        if c.count == 0 {
            return result(id, .ok, [DiagnosticTexts.leftoversNone])
        }
        return result(id, .notice, [DiagnosticTexts.leftovers(count: c.count, bytes: c.bytes)])
    }

    /// DR-17 アプリの署名（ad-hoc は notice）
    @Sendable static func dr17(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.signature
        let info = ctx.deps.signature.read(bundle: ctx.deps.bundleURL)
        guard info.valid else { return result(id, .notice, [info.message ?? DiagnosticTexts.signatureInvalid]) }
        guard let teamID = info.teamID else { return result(id, .notice, [DiagnosticTexts.adhocSignature]) }
        return result(id, .ok, [DiagnosticTexts.signatureOK(teamID)])
    }

    /// DR-14 元音声の削除（always。常に notice。3 行は LockDisplay.lines をそのまま使う。PLAN §8.9.8）
    @Sendable static func dr14(_ ctx: DiagnosticsContext) async -> DiagnosticResult {
        let id = DiagnosticID.deletion
        guard let c = ctx.config else { return result(id, .skip, [DiagnosticTexts.skipped]) }
        let d = await ctx.deps.locks.display(config: c, snapshot: ctx.snapshot)
        return result(id, .notice, d.lines)
    }
}
