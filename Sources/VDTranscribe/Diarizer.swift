// argmax-cli で話者の区間を得る（PLAN §8.4.1。F-89）。状態遷移・DB・ログはしない。
import Foundation
import VDContract
import VDCore
import VDProcess

public enum DiarizeOutcome: Equatable, Sendable {
    case diarized([SpeakerTurn])
    /// reason は付録 A.4 の語（helper_missing・spawn_failed・timeout・exit_<n>・signal_<n>・rttm_unreadable）
    case failed(reason: String)
    /// アプリの終了で止めた・閉じた後の拒否（Transcriber.wasStopped と同じ判定）
    case stopped
}

public enum DiarizationReport: Equatable, Sendable {
    case completed(speakers: Int, elapsedSeconds: Double)
    case failed(reason: String)
}

public struct Diarizer: Sendable {
    public static let timeoutFactor = 0.5
    public static let minTimeoutSeconds = 120
    public static let rttmFileName = "diarization.rttm"

    let runner: any ProcessRunning
    let paths: AppPaths
    let layout: HomeLayout
    let maxTimeoutSeconds: Int

    public init(runner: any ProcessRunning, paths: AppPaths, layout: HomeLayout, maxTimeoutSeconds: Int) {
        self.runner = runner
        self.paths = paths
        self.layout = layout
        self.maxTimeoutSeconds = maxTimeoutSeconds
    }

    /// 欠けている部品（宣言順）: "argmax-cli"（通常ファイルで実行権が無い）、"SpeakerModels"（ディレクトリでない）。
    public func missingParts() -> [String] {
        var missing: [String] = []
        if !Transcriber.isExecutableFile(paths.argmaxCLI) { missing.append("argmax-cli") }
        if !Self.isDirectory(paths.speakerModels) { missing.append("SpeakerModels") }
        return missing
    }

    public func diarize(input: URL, slug: String, durationSeconds: Double?) async -> DiarizeOutcome {
        // 1. 部品が欠けていれば起動しない。
        if !missingParts().isEmpty { return .failed(reason: "helper_missing") }

        // 2. 起動の前に前回の RTTM を消す（前回の中身で成功にしない）。消せなければ起動しない。
        let rttm = layout.stagingDirectory(slug: slug).appendingPathComponent(Self.rttmFileName, isDirectory: false)
        do {
            try SafeUnlink.remove(rttm, under: .staging, layout: layout, missingOK: true)
        } catch {
            return .failed(reason: "rttm_unreadable")
        }

        // 3. ここから先はどの経路でも RTTM を消す。
        defer { try? SafeUnlink.remove(rttm, under: .staging, layout: layout, missingOK: true) }

        // 4. 起動。
        let timeout = Self.timeoutSeconds(duration: durationSeconds, maxTimeoutSeconds: maxTimeoutSeconds)
        let result = await runner.run(
            ProcessSpec(
                executable: paths.argmaxCLI,
                arguments: DiarizeArgs.build(input: input, models: paths.speakerModels, rttm: rttm),
                environment: ProcessEnvironment.standard),
            timeout: .seconds(timeout))

        // 5. アプリの終了で止めた・閉じた後の拒否。
        if Transcriber.wasStopped(result) { return .stopped }

        // 6. 終わり方の写し方。
        switch result.termination {
        case .spawnFailed:
            return .failed(reason: "spawn_failed")
        case .timedOut:
            return .failed(reason: "timeout")
        case .exited(let n) where n != 0:
            return .failed(reason: "exit_\(n)")
        case .signaled(let n):
            return .failed(reason: "signal_\(n)")
        case .exited:
            break
        }

        // 7. RTTM を読む。
        guard let data = try? Data(contentsOf: rttm), let text = String(data: data, encoding: .utf8),
            let turns = RTTMParser.parse(text)
        else { return .failed(reason: "rttm_unreadable") }

        // 8. 成功。
        return .diarized(turns)
    }

    /// Int(min(max(duration × 0.5, 120), maxTimeoutSeconds))。duration 不明なら maxTimeoutSeconds。
    static func timeoutSeconds(duration: Double?, maxTimeoutSeconds: Int) -> Int {
        guard let d = duration else { return maxTimeoutSeconds }
        return Int(min(max(d * timeoutFactor, Double(minTimeoutSeconds)), Double(maxTimeoutSeconds)))
    }

    /// ディレクトリである（symlink は辿る）。
    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }
}
