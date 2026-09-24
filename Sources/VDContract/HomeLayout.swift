// <HOME> 配下の全パス（PLAN §2.3）。パスはここからだけ得る。
import Foundation

public struct HomeLayout: Equatable, Sendable {
    public let root: URL

    /// root をそのまま持つ（標準化しない）
    public init(root: URL) {
        self.root = root
    }

    /// ~/Library/Application Support/VoiceDock。NSHomeDirectory() から組み立てる（環境変数を読まない。PT-18）
    public static func production() -> HomeLayout {
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("VoiceDock", isDirectory: true)
        return HomeLayout(root: root)
    }

    /// 下の表の「作る」列が ○ のディレクトリを順に FileManager.createDirectory(at:withIntermediateDirectories: true) で作る。bin は作らない
    /// （ロック 2-A: bin は削除の有効化フローだけが作る）。
    public func createDirectories() throws {
        let directories = [
            inbox, staging, transcriptsParts, analysis, queueDelete, queueResult, queueRejected,
            stateDirectory, runDirectory, modelsDirectory,
            models(kind: "whisper"), models(kind: "vad"), models(kind: "llm"),
            logsDirectory,
        ]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// root 配下なら root からの相対 POSIX パス（先頭の "/" 無し）。配下でなければ nil。
    /// realpath はしない（DB に保存する相対パスを作るための関数で、封じ込めの検査は SafeUnlink が行う）。
    public func relativePath(of url: URL) -> String? {
        let r = Self.withoutTrailingSlash(root.standardizedFileURL.path(percentEncoded: false))
        let p = Self.withoutTrailingSlash(url.standardizedFileURL.path(percentEncoded: false))
        guard p.hasPrefix(r + "/") else { return nil }
        return String(p.dropFirst(r.count + 1))
    }

    /// ディレクトリの URL の `path(percentEncoded: false)` は末尾に "/" が付くので、比べる前に落とす（"/" だけのときはそのまま）。
    private static func withoutTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// root.appendingPathComponent(relative)
    public func url(relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    // MARK: - ファイルとディレクトリ

    public var configFile: URL { file("config.json") }
    public var database: URL { file("voicedock.sqlite") }
    public var inbox: URL { directory("inbox") }
    public var staging: URL { directory("staging") }
    public var transcriptsParts: URL { directory("transcripts").appendingPathComponent("parts", isDirectory: true) }
    public var analysis: URL { directory("analysis") }
    public var queueDelete: URL { directory("queue").appendingPathComponent("delete", isDirectory: true) }
    public var queueResult: URL { directory("queue").appendingPathComponent("result", isDirectory: true) }
    public var queueRejected: URL { directory("queue").appendingPathComponent("rejected", isDirectory: true) }
    public var stateDirectory: URL { directory("state") }
    public var processedLog: URL { stateDirectory.appendingPathComponent("processed.log", isDirectory: false) }
    public var reaperLock: URL { stateDirectory.appendingPathComponent("reaper.lock", isDirectory: false) }
    /// アプリの単一起動のロック（F-76）。reaper.lock とは別。アプリが生きている間ずっと持つ
    public var appLock: URL { stateDirectory.appendingPathComponent("app.lock", isDirectory: false) }
    public var runDirectory: URL { directory("run") }
    public var llamaAPIKeyFile: URL { runDirectory.appendingPathComponent("llama-api-key", isDirectory: false) }
    /// ロック 2-A: createDirectories() では作らない。
    public var binDirectory: URL { directory("bin") }
    public var reaperExecutable: URL {
        binDirectory.appendingPathComponent(Contract.reaperFileName, isDirectory: false)
    }
    public var reaperConf: URL { binDirectory.appendingPathComponent("reaper.conf", isDirectory: false) }
    public var modelsDirectory: URL { directory("models") }
    public var logsDirectory: URL { directory("logs") }
    public var appLog: URL { logsDirectory.appendingPathComponent("app.log", isDirectory: false) }
    public var reaperLog: URL { logsDirectory.appendingPathComponent("reaper.log", isDirectory: false) }
    public var uiState: URL { file("ui-state.json") }

    // MARK: - 鍵ごとのパス

    public func stagingDirectory(slug: String) -> URL {
        staging.appendingPathComponent(slug, isDirectory: true)
    }

    public func normalizedAudio(slug: String) -> URL {
        stagingDirectory(slug: slug).appendingPathComponent("audio16k.wav", isDirectory: false)
    }

    public func normalizedAudioTmp(slug: String) -> URL {
        stagingDirectory(slug: slug).appendingPathComponent("audio16k.wav.tmp", isDirectory: false)
    }

    public func whisperOutputBase(slug: String) -> URL {
        stagingDirectory(slug: slug).appendingPathComponent("whisper", isDirectory: false)
    }

    public func whisperJSON(slug: String) -> URL {
        stagingDirectory(slug: slug).appendingPathComponent("whisper.json", isDirectory: false)
    }

    /// staging/<slug>/diarization.rttm（話者分離の出力。PLAN §8.4.1。F-89・F-90: 復旧と後始末も消す）
    public func diarizationRTTM(slug: String) -> URL {
        stagingDirectory(slug: slug).appendingPathComponent("diarization.rttm", isDirectory: false)
    }

    public func transcript(slug: String) -> URL {
        transcriptsParts.appendingPathComponent(slug + ".json", isDirectory: false)
    }

    public func analysisJSON(sessionSlug: String) -> URL {
        analysis.appendingPathComponent(sessionSlug + ".json", isDirectory: false)
    }

    public func timelineJSON(sessionSlug: String) -> URL {
        analysis.appendingPathComponent(sessionSlug + ".timeline.json", isDirectory: false)
    }

    public func sourceJSON(sessionSlug: String) -> URL {
        analysis.appendingPathComponent(sessionSlug + ".source.json", isDirectory: false)
    }

    public func inboxFile(deviceID: String, relpath: String) -> URL {
        var url = inbox.appendingPathComponent(deviceID, isDirectory: true)
        let parts = RelPath.components(relpath)
        for (index, part) in parts.enumerated() {
            url = url.appendingPathComponent(part, isDirectory: index < parts.count - 1)
        }
        return url
    }

    public func inboxPartial(deviceID: String, relpath: String) -> URL {
        var url = inbox.appendingPathComponent(deviceID, isDirectory: true)
        let parent = RelPath.parent(relpath)
        if !parent.isEmpty {
            for part in RelPath.components(parent) {
                url = url.appendingPathComponent(part, isDirectory: true)
            }
        }
        return url.appendingPathComponent("." + RelPath.lastComponent(relpath) + ".partial", isDirectory: false)
    }

    public func models(kind: String) -> URL {
        modelsDirectory.appendingPathComponent(kind, isDirectory: true)
    }

    public func modelFile(kind: String, file: String) -> URL {
        models(kind: kind).appendingPathComponent(file, isDirectory: false)
    }

    public func modelPart(kind: String, file: String) -> URL {
        models(kind: kind).appendingPathComponent("." + file + ".part", isDirectory: false)
    }

    public func modelResume(file: String) -> URL {
        modelsDirectory.appendingPathComponent("." + file + ".resume", isDirectory: false)
    }

    private func file(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: false)
    }

    private func directory(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }
}
