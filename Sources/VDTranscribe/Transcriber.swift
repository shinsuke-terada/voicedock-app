// whisper-cli を実行し正規化 transcript を保存する（PLAN §8.4）。状態遷移と DB 更新はしない。
import Foundation
import VDContract
import VDCore
import VDProcess

public enum TranscribePrerequisite: String, Sendable, CaseIterable, Equatable {
    case whisperMissing = "whisper_missing"  // PauseReason と同じ語（PLAN 付録 A.4）。ケース名は 00-api-map §7
    case modelMissing = "model_missing"
    case vadModelMissing = "vad_model_missing"
}

public struct TranscribeRequest: Sendable {
    public let partkey: String
    public let slug: String  // KeySlug.of(partkey)
    public let input: URL  // staging/<slug>/audio16k.wav
    public let durationSeconds: Double?
    public let startedAt: String  // Part の started_at（DB の文字列そのまま）

    public init(partkey: String, slug: String, input: URL, durationSeconds: Double?, startedAt: String) {
        self.partkey = partkey
        self.slug = slug
        self.input = input
        self.durationSeconds = durationSeconds
        self.startedAt = startedAt
    }
}

public struct TranscribeMetrics: Equatable, Sendable {
    public let elapsedSeconds: Double  // 丸めない（ログで Python 互換の round(…, 1) をかける）
    public let chars: Int  // text の Unicode スカラー数
    public let rtf: Double?  // round(elapsed / duration, 3)。duration が nil か 0 以下なら nil
    public let speechRatio: Double?  // round(Σmax(0, end − start) / duration, 3)。同上

    public init(elapsedSeconds: Double, chars: Int, rtf: Double?, speechRatio: Double?) {
        self.elapsedSeconds = elapsedSeconds
        self.chars = chars
        self.rtf = rtf
        self.speechRatio = speechRatio
    }
}

public enum TranscribeOutcome: Equatable, Sendable {
    case transcribed(PartTranscript, metrics: TranscribeMetrics)
    case noSpeech(PartTranscript, message: String)
    case prerequisiteMissing(TranscribePrerequisite)  // 遷移せずに待つ（ガード。PLAN §5.4）
    case failure(StageFailure)
    /// アプリの終了（`ProcessRunner.terminateAll`）が whisper を止めた、または閉じた後なので起動しなかった（F-82）。
    /// 失敗ではない。呼び手は行を動かさない（中途の状態は次回起動時の復旧が戻す。PLAN §8.15）
    case stopped
}

public struct Transcriber: Sendable {
    let runner: any ProcessRunning
    let paths: AppPaths
    let layout: HomeLayout
    let config: TranscriptionConfig
    let catalog: ModelCatalog
    let clock: any AppClock

    public init(
        runner: any ProcessRunning, paths: AppPaths, layout: HomeLayout,
        config: TranscriptionConfig, catalog: ModelCatalog, clock: any AppClock
    ) {
        self.runner = runner
        self.paths = paths
        self.layout = layout
        self.config = config
        self.catalog = catalog
        self.clock = clock
    }

    /// ガード（T-18）が使う。前提の欠けを宣言順で返す。
    public func missingPrerequisites() -> [TranscribePrerequisite] {
        var missing: [TranscribePrerequisite] = []
        if !Self.isExecutableFile(paths.whisperCLI) { missing.append(.whisperMissing) }
        if whisperModel() == nil { missing.append(.modelMissing) }
        if config.vad.enabled && vadModel() == nil { missing.append(.vadModelMissing) }
        return missing
    }

    public func transcribe(_ req: TranscribeRequest) async -> TranscribeOutcome {
        let target = layout.transcript(slug: req.slug)
        let rawJSON = layout.whisperJSON(slug: req.slug)
        let outBase = layout.whisperOutputBase(slug: req.slug)

        // 1. 冪等: 読める transcript が minChars 以上なら whisper を起動しない。
        if let data = try? Data(contentsOf: target), let existing = PartTranscriptCodec.decode(data),
            TextLimit.scalarCount(existing.text) >= config.minChars
        {
            return .transcribed(existing, metrics: metrics(existing, elapsed: 0, duration: req.durationSeconds))
        }

        // 2. 前提: 欠けていれば起動しない。何も消さない。
        if let first = missingPrerequisites().first { return .prerequisiteMissing(first) }
        guard let model = whisperModel() else { return .prerequisiteMissing(.modelMissing) }
        let vad: URL?
        if config.vad.enabled {
            guard let url = vadModel() else { return .prerequisiteMissing(.vadModelMissing) }
            vad = url
        } else {
            vad = nil
        }

        // 3. ここから先はどの経路でも whisper.json を消す。
        defer { try? SafeUnlink.remove(rawJSON, under: .staging, layout: layout) }
        // 起動の前に前回の whisper.json を消す（落ちた前回の残り。JSON を書かずに 0 で終わった whisper の結果を
        // 前回の JSON で成功にしない。RK-34・F-76）。消せなければ起動しない
        do {
            try SafeUnlink.remove(rawJSON, under: .staging, layout: layout, missingOK: true)
        } catch {
            let shown = layout.relativePath(of: rawJSON) ?? WhisperArgs.p(rawJSON)
            return .failure(StageFailure(.whisperFailed, "前回の生 JSON を消せません: \(shown)"))
        }

        // 4〜7. 起動と計測。
        let argv = WhisperArgs.build(
            model: model, input: req.input, outputBase: outBase, config: config, vadModel: vad,
            threads: WhisperArgs.resolvedThreads(config.threads))
        let timeout = Transcriber.timeoutSeconds(duration: req.durationSeconds, config: config)
        let start = clock.uptime()
        let result = await runner.run(
            ProcessSpec(executable: paths.whisperCLI, arguments: argv, environment: ProcessEnvironment.standard),
            timeout: .seconds(timeout))
        let d = clock.uptime() - start
        let elapsed = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18

        // 8. 結果の写し方。
        // アプリの終了で止めた・閉じた後で起動しなかったものは失敗として記録しない（F-82）。止める前に 0 で終わっていれば読む
        if Self.wasStopped(result) { return .stopped }
        let tail = Transcriber.stderrTail(result.stderrTail)
        switch result.termination {
        case .spawnFailed(let n):
            // 実行ファイルの問題だけが WHISPER_EXEC_MISSING。一時的な失敗（EAGAIN・EMFILE・ENOMEM など）は WHISPER_FAILED（F-82）
            let code: ErrorCode = Self.executableProblemErrnos.contains(n) ? .whisperExecMissing : .whisperFailed
            return .failure(StageFailure(code, "spawn: errno \(n)"))
        case .timedOut:
            return .failure(StageFailure(.whisperTimeout, "\(timeout) 秒を超えました"))
        case .exited(let n) where n != 0:
            return .failure(StageFailure(.whisperFailed, "終了コード \(n): \(tail)"))
        case .signaled(let n):
            return .failure(StageFailure(.whisperFailed, "シグナル \(n): \(tail)"))
        case .exited:
            break
        }

        // 9. RK-34: 成功は「終了 0 かつ JSON が在って読める」。
        guard let raw = try? Data(contentsOf: rawJSON),
            let parsed = WhisperOutputParser.parseReportingRepair(raw, fallbackLanguage: config.language)
        else {
            let shown = layout.relativePath(of: rawJSON) ?? WhisperArgs.p(rawJSON)
            return .failure(StageFailure(.whisperFailed, "生 JSON を読めません: \(shown)"))
        }
        // F-82（X-41）: 手前処理が生 JSON を直した（割れた多バイト文字・生の制御文字）ときは、直した文字（U+FFFD と
        // U+0000〜U+001F）を除いた文字数が minChars に届かなければ、無音（NO_SPEECH_DETECTED の SKIPPED。根拠 B で元の録音を
        // 消しうる）にも文字起こし済みにもせず、消さない側の失敗にする（transcript も書かない）
        if parsed.repaired {
            let readable = Self.readableScalarCount(parsed.text)
            if readable < config.minChars {
                let detail = "\(readable) 文字（min_chars=\(config.minChars)）"
                return .failure(StageFailure(.whisperFailed, "生 JSON に壊れた文字があり、無音と判定できません: \(detail)"))
            }
        }

        // 10〜11. ASR-09: 無音判定より前に保存する（根拠 B の証拠）。
        let t = PartTranscript(
            partkey: req.partkey, language: parsed.language, durationSeconds: req.durationSeconds,
            startedAt: req.startedAt, text: parsed.text, segments: parsed.segments)
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AtomicFile.write(PartTranscriptCodec.encode(t), to: target)
        } catch {
            return .failure(StageFailure(.whisperFailed, "正規化 transcript を書けません: \(Self.describe(error))"))
        }

        // 12. 無音（失敗ではない）。
        let n = TextLimit.scalarCount(t.text)
        if n < config.minChars {
            return .noSpeech(t, message: "\(n) 文字（min_chars=\(config.minChars)）")
        }

        // 13. 成功。
        return .transcribed(t, metrics: metrics(t, elapsed: elapsed, duration: req.durationSeconds))
    }

    /// 起動の失敗（posix_spawn の errno）のうち、実行ファイル（か起動の指定）の問題で、起動し直しても変わらないもの（F-82）。
    /// これだけを WHISPER_EXEC_MISSING（再試行 none）にし、ほか（EAGAIN・EMFILE・ENFILE・ENOMEM・ETXTBSY など）は WHISPER_FAILED
    static let executableProblemErrnos: Set<Int32> = [
        ENOENT, EACCES, EPERM, ENOEXEC, ENOTDIR, ELOOP, ENAMETOOLONG, EINVAL, EBADARCH, EBADEXEC, EBADMACHO,
    ]

    /// アプリの終了で止めた（terminateAll が SIGTERM を送り、0 で終わらなかった）か、閉じた後なので起動しなかった（ECANCELED。F-76）
    static func wasStopped(_ result: ProcessResult) -> Bool {
        if result.termination == .spawnFailed(errno: ProcessRunner.closedErrno) { return true }
        return result.stoppedByTerminateAll && result.termination != .exited(0)
    }

    /// 手前処理が直しうる文字（U+FFFD と U+0000〜U+001F）を除いたスカラー数（F-82。X-41）
    static func readableScalarCount(_ text: String) -> Int {
        text.unicodeScalars.filter { $0.value >= 0x20 && $0 != "\u{FFFD}" }.count
    }

    /// Int(min(max(duration × timeoutFactor, minTimeoutSeconds), maxTimeoutSeconds))。duration 不明なら maxTimeoutSeconds（ASR-08）。
    static func timeoutSeconds(duration: Double?, config: TranscriptionConfig) -> Int {
        guard let d = duration else { return config.maxTimeoutSeconds }
        return Int(
            min(max(d * config.timeoutFactor, Double(config.minTimeoutSeconds)), Double(config.maxTimeoutSeconds)))
    }

    /// ProcessResult.stderrTail を UTF-8（不正は置換）で読み、末尾 1000 Unicode スカラー。strip しない。
    static func stderrTail(_ data: Data) -> String {
        let s = String(decoding: data, as: UTF8.self)
        return String(String.UnicodeScalarView(s.unicodeScalars.suffix(1000)))
    }

    /// メトリクス。duration が nil か 0 以下なら rtf と speechRatio は nil。
    func metrics(_ t: PartTranscript, elapsed: Double, duration: Double?) -> TranscribeMetrics {
        let chars = TextLimit.scalarCount(t.text)
        guard let duration, duration > 0 else {
            return TranscribeMetrics(elapsedSeconds: elapsed, chars: chars, rtf: nil, speechRatio: nil)
        }
        let speech = t.segments.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        return TranscribeMetrics(
            elapsedSeconds: elapsed, chars: chars, rtf: PyRound.round(elapsed / duration, digits: 3),
            speechRatio: PyRound.round(speech / duration, digits: 3))
    }

    /// 在り、大きさがカタログどおりの Whisper モデルの URL。
    private func whisperModel() -> URL? {
        guard let entry = catalog.entry(kind: .whisper, id: config.whisperModelID),
            ModelFiles.isPresent(entry, kind: .whisper, layout: layout)
        else { return nil }
        return ModelFiles.url(kind: .whisper, entry: entry, layout: layout)
    }

    /// 在り、大きさがカタログどおりの VAD モデルの URL。
    private func vadModel() -> URL? {
        guard let entry = catalog.entry(kind: .vad, id: config.vad.modelID),
            ModelFiles.isPresent(entry, kind: .vad, layout: layout)
        else { return nil }
        return ModelFiles.url(kind: .vad, entry: entry, layout: layout)
    }

    /// 通常ファイルで実行権がある。
    private static func isExecutableFile(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    /// `"<型名>: <説明>"`
    private static func describe(_ error: any Error) -> String {
        "\(type(of: error)): \(error)"
    }
}
