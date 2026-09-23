// HomeLayout の検査（T-06 §5.12）。
import Foundation
import TestSupport
import Testing

@testable import VDContract

@Suite("HomeLayout")
struct HomeLayoutTests {
    static let root = URL(fileURLWithPath: "/tmp/VoiceDockHomeLayoutTests", isDirectory: true)

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let property: @Sendable (HomeLayout) -> URL
        let relative: String
        var testDescription: String { name }
    }

    /// T-06 §4.16 の表を逐語で。
    static let rows: [Row] = [
        Row(name: "configFile", property: { $0.configFile }, relative: "config.json"),
        Row(name: "database", property: { $0.database }, relative: "voicedock.sqlite"),
        Row(name: "inbox", property: { $0.inbox }, relative: "inbox"),
        Row(name: "staging", property: { $0.staging }, relative: "staging"),
        Row(name: "transcriptsParts", property: { $0.transcriptsParts }, relative: "transcripts/parts"),
        Row(name: "analysis", property: { $0.analysis }, relative: "analysis"),
        Row(name: "queueDelete", property: { $0.queueDelete }, relative: "queue/delete"),
        Row(name: "queueResult", property: { $0.queueResult }, relative: "queue/result"),
        Row(name: "queueRejected", property: { $0.queueRejected }, relative: "queue/rejected"),
        Row(name: "stateDirectory", property: { $0.stateDirectory }, relative: "state"),
        Row(name: "processedLog", property: { $0.processedLog }, relative: "state/processed.log"),
        Row(name: "reaperLock", property: { $0.reaperLock }, relative: "state/reaper.lock"),
        Row(name: "appLock", property: { $0.appLock }, relative: "state/app.lock"),
        Row(name: "runDirectory", property: { $0.runDirectory }, relative: "run"),
        Row(name: "llamaAPIKeyFile", property: { $0.llamaAPIKeyFile }, relative: "run/llama-api-key"),
        Row(name: "binDirectory", property: { $0.binDirectory }, relative: "bin"),
        Row(name: "reaperExecutable", property: { $0.reaperExecutable }, relative: "bin/voicedock-reaper"),
        Row(name: "reaperConf", property: { $0.reaperConf }, relative: "bin/reaper.conf"),
        Row(name: "modelsDirectory", property: { $0.modelsDirectory }, relative: "models"),
        Row(name: "logsDirectory", property: { $0.logsDirectory }, relative: "logs"),
        Row(name: "appLog", property: { $0.appLog }, relative: "logs/app.log"),
        Row(name: "reaperLog", property: { $0.reaperLog }, relative: "logs/reaper.log"),
        Row(name: "uiState", property: { $0.uiState }, relative: "ui-state.json"),
    ]

    @Test("全プロパティの相対パス（パラメータ化）", arguments: rows)
    func propertiesMatchLayout(_ row: Row) {
        let layout = HomeLayout(root: Self.root)
        #expect(layout.relativePath(of: row.property(layout)) == row.relative)
    }

    @Test("関数の相対パス")
    func functionsMatchLayout() {
        let layout = HomeLayout(root: Self.root)
        let slug = "a5d046dce76cfedc"
        let session = "43a71bce144be7a7"
        let relpath = "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
        func rel(_ url: URL) -> String? { layout.relativePath(of: url) }
        #expect(rel(layout.stagingDirectory(slug: slug)) == "staging/a5d046dce76cfedc")
        #expect(rel(layout.normalizedAudio(slug: slug)) == "staging/a5d046dce76cfedc/audio16k.wav")
        #expect(rel(layout.normalizedAudioTmp(slug: slug)) == "staging/a5d046dce76cfedc/audio16k.wav.tmp")
        #expect(rel(layout.whisperOutputBase(slug: slug)) == "staging/a5d046dce76cfedc/whisper")
        #expect(rel(layout.whisperJSON(slug: slug)) == "staging/a5d046dce76cfedc/whisper.json")
        #expect(rel(layout.transcript(slug: slug)) == "transcripts/parts/a5d046dce76cfedc.json")
        #expect(rel(layout.analysisJSON(sessionSlug: session)) == "analysis/43a71bce144be7a7.json")
        #expect(rel(layout.timelineJSON(sessionSlug: session)) == "analysis/43a71bce144be7a7.timeline.json")
        #expect(rel(layout.sourceJSON(sessionSlug: session)) == "analysis/43a71bce144be7a7.source.json")
        #expect(
            rel(layout.inboxFile(deviceID: "DJIMIC3", relpath: relpath))
                == "inbox/DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav")
        #expect(
            rel(layout.inboxPartial(deviceID: "DJIMIC3", relpath: relpath))
                == "inbox/DJIMIC3/TX_MIC001_20260829_071201/.TX01_MIC002_20260829_071204_orig.wav.partial")
        #expect(
            rel(layout.inboxPartial(deviceID: "DJIMIC3", relpath: "a_orig.wav")) == "inbox/DJIMIC3/.a_orig.wav.partial")
        #expect(rel(layout.models(kind: "llm")) == "models/llm")
        #expect(rel(layout.modelFile(kind: "llm", file: "x.gguf")) == "models/llm/x.gguf")
        #expect(rel(layout.modelPart(kind: "llm", file: "x.gguf")) == "models/llm/.x.gguf.part")
        #expect(rel(layout.modelResume(file: "x.gguf")) == "models/.x.gguf.resume")
        #expect(rel(layout.url(relative: "state/processed.log")) == "state/processed.log")
    }

    static let createdDirectories = [
        "inbox", "staging", "transcripts/parts", "analysis", "queue/delete", "queue/result", "queue/rejected",
        "state", "run", "models", "models/whisper", "models/vad", "models/llm", "logs",
    ]

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    @Test("bin を作らない（ロック 2-A）")
    func createDirectoriesDoesNotCreateBin() throws {
        let tmp = try TempDirectory()
        let root = tmp.url.appendingPathComponent("home", isDirectory: true)
        try HomeLayout(root: root).createDirectories()
        for relative in Self.createdDirectories {
            #expect(Self.isDirectory(root.appendingPathComponent(relative)), "\(relative) が無い")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bin").path))
    }

    @Test("2 回呼んでもよい")
    func createDirectoriesIsIdempotent() throws {
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        #expect(throws: Never.self) { try layout.createDirectories() }
    }

    @Test("配下でなければ nil")
    func relativePathOutsideIsNil() {
        let layout = HomeLayout(root: Self.root)
        #expect(layout.relativePath(of: Self.root) == nil)
        #expect(
            layout.relativePath(of: URL(fileURLWithPath: "/tmp/VoiceDockHomeLayoutTests-old/x", isDirectory: false))
                == nil)
        #expect(layout.relativePath(of: URL(fileURLWithPath: "/etc/passwd", isDirectory: false)) == nil)
    }

    @Test("本番の場所")
    func productionPath() {
        #expect(
            HomeLayout.production().root.path(percentEncoded: false) == NSHomeDirectory()
                + "/Library/Application Support/VoiceDock/")
    }
}
