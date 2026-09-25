// データの初期化（PLAN §8.12 の 8・§8.15・F-95）。<HOME> は一時ディレクトリ。消すもの・残すもの・断る条件を実ファイルで確かめる。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore

@testable import VDPipeline

@Suite("DataReset（F-95）")
struct DataResetTests {
    struct Scene {
        let tmp: TempDirectory
        let layout: HomeLayout
        let sink = CapturingLogSink()

        init() throws {
            tmp = try TempDirectory()
            layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
            try layout.createDirectories()
        }

        var log: AppLog {
            AppLog(
                sink: sink, level: .debug, unsafeContent: false, zone: PipelineFixtures.zone,
                clock: FixedClock(epochMillis: 1_788_040_812_000))
        }

        @discardableResult
        func put(_ url: URL, _ text: String = "x") throws -> URL {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AtomicFile.write(Data(text.utf8), to: url)
            return url
        }

        func exists(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path(percentEncoded: false), &info) == 0
        }

        /// 消すものと残すものを一通り置く。戻り値は (消えるべきもの, 残るべきもの)
        func populate() throws -> (gone: [URL], kept: [URL]) {
            let gone = [
                try put(layout.database), try put(layout.url(relative: "voicedock.sqlite-wal")),
                try put(layout.url(relative: "voicedock.sqlite-shm")),
                try put(layout.inbox.appendingPathComponent("VOICEDOCK/TX_MIC001_20260912_120950/a_orig.wav")),
                try put(layout.inbox.appendingPathComponent("VOICEDOCK/TX_MIC001_20260912_120950/.a_orig.wav.partial")),
                try put(layout.normalizedAudio(slug: "a5d046dce76cfedc")),
                try put(layout.transcriptsParts.appendingPathComponent("a5d046dce76cfedc.json")),
                try put(layout.analysis.appendingPathComponent("43a71bce144be7a7.json")),
                try put(layout.queueDelete.appendingPathComponent("r1.json")),
                try put(layout.queueResult.appendingPathComponent("r1.json")),
            ]
            let kept = [
                try put(layout.configFile, "{}"), try put(layout.uiState, "{}"),
                try put(layout.modelsDirectory.appendingPathComponent("whisper/ggml.bin")),
                try put(layout.appLog), try put(layout.processedLog), try put(layout.llamaAPIKeyFile),
                try put(layout.queueRejected.appendingPathComponent("bad.json")),
                try put(layout.url(relative: "config.json.bak")),
            ]
            return (gone, kept)
        }
    }

    @Test("予約が無ければ何も消さず、ログも出さない")
    func nothingHappensWithoutARequest() throws {
        let s = try Scene()
        let (gone, kept) = try s.populate()
        #expect(DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log) == .notRequested)
        #expect((gone + kept).allSatisfy { s.exists($0) })
        #expect(s.sink.lines.isEmpty)
    }

    @Test("予約があれば、DB・inbox・staging・transcripts・analysis・queue の要求と結果を消し、設定・モデル・ログなどは残す")
    func requestedResetRemovesDataAndKeepsSettings() throws {
        let s = try Scene()
        let (gone, kept) = try s.populate()
        #expect(DataReset.request(layout: s.layout))
        #expect(DataReset.isRequested(layout: s.layout))
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log)
        #expect(outcome == .completed(removed: 10, failed: 0))
        for url in gone { #expect(!s.exists(url), "残った: \(url.path(percentEncoded: false))") }
        for url in kept { #expect(s.exists(url), "消えた: \(url.path(percentEncoded: false))") }
        // 下位のディレクトリは消え、ルートのディレクトリは残る
        #expect(!s.exists(s.layout.inbox.appendingPathComponent("VOICEDOCK")))
        #expect(!s.exists(s.layout.stagingDirectory(slug: "a5d046dce76cfedc")))
        #expect(s.exists(s.layout.inbox))
        #expect(s.exists(s.layout.staging))
        #expect(s.exists(s.layout.transcriptsParts))
        // 予約は取り下げた（次の起動で消し直さない）
        #expect(!DataReset.isRequested(layout: s.layout))
        #expect(s.sink.lines.count == 1)
        #expect(s.sink.lines.first?.hasSuffix("INFO  data_reset count=10 failed=0") == true)
    }

    @Test("消す能力が残っていれば（削除が有効）何も消さず、予約だけ取り下げて WARNING")
    func deletionCapabilityRefusesTheReset() throws {
        let s = try Scene()
        let (gone, kept) = try s.populate()
        #expect(DataReset.request(layout: s.layout))
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: true, log: s.log)
        #expect(outcome == .refused(reason: "deletion_enabled"))
        #expect((gone + kept).allSatisfy { s.exists($0) })
        #expect(!DataReset.isRequested(layout: s.layout))
        #expect(s.sink.lines.count == 1)
        #expect(s.sink.lines.first?.hasSuffix("WARNING data_reset reason=deletion_enabled") == true)
    }

    @Test("予約が symlink なら取り下げられず、何も消さない（起動のたびに消し直さない）")
    func unremovableRequestRefusesTheReset() throws {
        let s = try Scene()
        let (gone, _) = try s.populate()
        let target = try s.put(s.tmp.url.appendingPathComponent("elsewhere"))
        try FileManager.default.createSymbolicLink(
            atPath: s.layout.dataResetRequest.path(percentEncoded: false),
            withDestinationPath: target.path(percentEncoded: false))
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log)
        #expect(outcome == .refused(reason: "request_not_removed"))
        #expect(gone.allSatisfy { s.exists($0) })
        #expect(s.exists(target))
        #expect(s.sink.lines.first?.hasSuffix("WARNING data_reset reason=request_not_removed") == true)
    }

    @Test("inbox の中の symlink は辿らず消さない（リンク先は残る）。消せなかった数を WARNING で出す")
    func symlinkInsideARootIsNotFollowed() throws {
        let s = try Scene()
        let outside = try s.put(s.tmp.url.appendingPathComponent("outside/keep.wav"))
        try FileManager.default.createDirectory(
            at: s.layout.inbox.appendingPathComponent("VOICEDOCK"), withIntermediateDirectories: true)
        let link = s.layout.inbox.appendingPathComponent("VOICEDOCK/link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path(percentEncoded: false),
            withDestinationPath: outside.deletingLastPathComponent().path(percentEncoded: false))
        try s.put(s.layout.database)
        #expect(DataReset.request(layout: s.layout))
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log)
        // DB 1 件を消し、symlink 1 件と、それが残ったので空にならない VOICEDOCK のディレクトリ 1 件は数えない（rmdir は
        // 中身があれば何もしない）→ failed は symlink の 1 件
        #expect(outcome == .completed(removed: 1, failed: 1))
        #expect(s.exists(outside))
        #expect(s.exists(link))
        #expect(!s.exists(s.layout.database))
        #expect(s.sink.lines.first?.hasSuffix("WARNING data_reset count=1 failed=1") == true)
    }

    @Test("DB の -wal を消せなければ本体を残す（古い WAL を新しい DB に当てない）")
    func databaseIsKeptWhenTheWALCannotBeRemoved() throws {
        let s = try Scene()
        try s.put(s.layout.database)
        // -wal をディレクトリにして消せなくする（SafeUnlink は通常ファイルしか消さない）
        try FileManager.default.createDirectory(
            at: s.layout.url(relative: "voicedock.sqlite-wal"), withIntermediateDirectories: true)
        try s.put(s.layout.url(relative: "voicedock.sqlite-shm"))
        #expect(DataReset.request(layout: s.layout))
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log)
        // -shm を消し、-wal の失敗 1 と本体を残した 1
        #expect(outcome == .completed(removed: 1, failed: 2))
        #expect(s.exists(s.layout.database))
        #expect(!s.exists(s.layout.url(relative: "voicedock.sqlite-shm")))
    }

    @Test("対照: 予約は run/ の下に書き、在るかどうかだけを見る")
    func requestIsAFileUnderRun() throws {
        let s = try Scene()
        #expect(!DataReset.isRequested(layout: s.layout))
        #expect(DataReset.request(layout: s.layout))
        #expect(s.layout.dataResetRequest.deletingLastPathComponent().lastPathComponent == "run")
        #expect(DataReset.isRequested(layout: s.layout))
    }
}
