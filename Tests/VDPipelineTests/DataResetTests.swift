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

        /// 予約を書く（予約のログは別の箱に出し、実行のログと混ぜない）
        func reserve() -> Bool {
            DataReset.request(
                layout: layout, deletionCapable: false,
                log: AppLog(
                    sink: CapturingLogSink(), level: .debug, unsafeContent: false, zone: PipelineFixtures.zone,
                    clock: FixedClock(epochMillis: 1_788_040_812_000)))
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
                try put(layout.inbox.appendingPathComponent("VDT0095/TX_MIC001_20260912_120950/a_orig.wav")),
                try put(layout.inbox.appendingPathComponent("VDT0095/TX_MIC001_20260912_120950/.a_orig.wav.partial")),
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
        #expect(s.reserve())
        #expect(DataReset.isRequested(layout: s.layout))
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log)
        #expect(outcome == .completed(removed: 10, failed: 0))
        for url in gone { #expect(!s.exists(url), "残った: \(url.path(percentEncoded: false))") }
        for url in kept { #expect(s.exists(url), "消えた: \(url.path(percentEncoded: false))") }
        // 下位のディレクトリは消え、ルートのディレクトリは残る
        #expect(!s.exists(s.layout.inbox.appendingPathComponent("VDT0095")))
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
        #expect(s.reserve())
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: true, log: s.log)
        #expect(outcome == .refused(.deletionEnabled))
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
        #expect(outcome == .refused(.requestNotRemoved))
        #expect(gone.allSatisfy { s.exists($0) })
        #expect(s.exists(target))
        #expect(s.sink.lines.first?.hasSuffix("WARNING data_reset reason=request_not_removed") == true)
    }

    @Test("inbox の中の symlink は辿らず消さない（リンク先は残る）。消せなかった数を WARNING で出す")
    func symlinkInsideARootIsNotFollowed() throws {
        let s = try Scene()
        let outside = try s.put(s.tmp.url.appendingPathComponent("outside/keep.wav"))
        try FileManager.default.createDirectory(
            at: s.layout.inbox.appendingPathComponent("VDT0095"), withIntermediateDirectories: true)
        let link = s.layout.inbox.appendingPathComponent("VDT0095/link")
        try FileManager.default.createSymbolicLink(
            atPath: link.path(percentEncoded: false),
            withDestinationPath: outside.deletingLastPathComponent().path(percentEncoded: false))
        try s.put(s.layout.database)
        #expect(s.reserve())
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log)
        // DB 1 件を消し、symlink 1 件と、それが残ったので空にならない VDT0095 のディレクトリ 1 件は数えない（rmdir は
        // 中身があれば何もしない）→ failed は symlink の 1 件
        #expect(outcome == .completed(removed: 1, failed: 1))
        #expect(s.exists(outside))
        #expect(s.exists(link))
        #expect(!s.exists(s.layout.database))
        #expect(s.sink.lines.first?.hasSuffix("WARNING data_reset count=1 failed=1") == true)
    }

    @Test("DB の -wal が通常ファイルでなければ DB を 1 つも消さず、ほかのディレクトリにも触れない（古い WAL を新しい DB に当てない）")
    func databaseNotRemovableStopsTheWholeReset() throws {
        let s = try Scene()
        try s.put(s.layout.database)
        // -wal をディレクトリにする（SafeUnlink は通常ファイルしか消さない）
        try FileManager.default.createDirectory(
            at: s.layout.url(relative: "voicedock.sqlite-wal"), withIntermediateDirectories: true)
        let shm = try s.put(s.layout.url(relative: "voicedock.sqlite-shm"))
        let staged = try s.put(s.layout.normalizedAudio(slug: "a5d046dce76cfedc"))
        let transcript = try s.put(s.layout.transcriptsParts.appendingPathComponent("a5d046dce76cfedc.json"))
        #expect(s.reserve())
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log)
        #expect(outcome == .refused(.databaseNotRemoved))
        #expect(s.exists(s.layout.database))
        #expect(s.exists(shm))
        #expect(s.exists(staged))
        #expect(s.exists(transcript))
        #expect(!DataReset.isRequested(layout: s.layout))
        let expected = "WARNING data_reset reason=database_not_removed count=0 failed=1"
        #expect(s.sink.lines.first?.hasSuffix(expected) == true)
    }

    @Test("ルートのディレクトリ（inbox）が <HOME> の外への symlink なら辿らず、外の中身を残す")
    func symlinkedRootIsNotFollowed() throws {
        let s = try Scene()
        let outside = try s.put(s.tmp.url.appendingPathComponent("outside/VDT0095/a_orig.wav"))
        // inbox を外のディレクトリへの symlink に差し替える（createDirectories は既存の symlink を受け入れる）
        let inbox = s.layout.root.appendingPathComponent("inbox", isDirectory: false)
        try FileManager.default.removeItem(at: inbox)
        try FileManager.default.createSymbolicLink(
            atPath: inbox.path(percentEncoded: false),
            withDestinationPath: s.tmp.url.appendingPathComponent("outside").path(percentEncoded: false))
        let staged = try s.put(s.layout.normalizedAudio(slug: "a5d046dce76cfedc"))
        #expect(s.reserve())
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log)
        // staging の 1 件を消し、inbox のルートを確かめられなかった 1
        #expect(outcome == .completed(removed: 1, failed: 1))
        #expect(s.exists(outside))
        #expect(!s.exists(staged))
    }

    @Test("予約はあるが消すものが無い（空の <HOME>）なら 0 件で INFO（TEST-28）")
    func emptyHomeCompletesWithZero() throws {
        let s = try Scene()
        #expect(s.reserve())
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log)
        #expect(outcome == .completed(removed: 0, failed: 0))
        #expect(s.sink.lines == s.sink.lines.filter { $0.hasSuffix("INFO  data_reset count=0 failed=0") })
        #expect(s.sink.lines.count == 1)
    }

    @Test("予約: 消す能力が残っていれば書かずに WARNING、書けたら INFO requested")
    func requestRefusesWhileDeletionIsCapable() throws {
        let s = try Scene()
        #expect(DataReset.request(layout: s.layout, deletionCapable: true, log: s.log) == false)
        #expect(!DataReset.isRequested(layout: s.layout))
        #expect(DataReset.request(layout: s.layout, deletionCapable: false, log: s.log) == true)
        #expect(DataReset.isRequested(layout: s.layout))
        #expect(s.sink.lines.count == 2)
        #expect(s.sink.lines.first?.hasSuffix("WARNING data_reset reason=deletion_enabled") == true)
        #expect(s.sink.lines.last?.hasSuffix("INFO  data_reset reason=requested") == true)
    }

    @Test("予約: run/ が書けなければ偽で WARNING request_not_written")
    func requestReportsWriteFailure() throws {
        let s = try Scene()
        // run をファイルに差し替えて書けなくする
        try FileManager.default.removeItem(at: s.layout.runDirectory)
        try s.put(s.layout.url(relative: "run"))
        #expect(DataReset.request(layout: s.layout, deletionCapable: false, log: s.log) == false)
        #expect(s.sink.lines.first?.hasSuffix("WARNING data_reset reason=request_not_written") == true)
    }

    @Test("DB を消した後に落ちた（予約が db-removed で DB が無い）なら、次の起動は残りの中身を消して予約を取り下げる")
    func interruptedResetResumesTheContentStep() throws {
        let s = try Scene()
        let staged = try s.put(s.layout.normalizedAudio(slug: "a5d046dce76cfedc"))
        let analysis = try s.put(s.layout.analysis.appendingPathComponent("43a71bce144be7a7.json"))
        try AtomicFile.write(Data("data-reset db-removed\n".utf8), to: s.layout.dataResetRequest)
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log)
        #expect(outcome == .completed(removed: 2, failed: 0))
        #expect(!s.exists(staged))
        #expect(!s.exists(analysis))
        #expect(!DataReset.isRequested(layout: s.layout))
        #expect(s.sink.lines.first?.hasSuffix("INFO  data_reset count=2 failed=0") == true)
    }

    @Test("予約が db-removed でも DB が在れば（前回の初期化の後に使い始めている）何も消さず、予約だけ取り下げる")
    func staleRequestDoesNotWipeAgain() throws {
        let s = try Scene()
        let db = try s.put(s.layout.database)
        let staged = try s.put(s.layout.normalizedAudio(slug: "a5d046dce76cfedc"))
        try AtomicFile.write(Data("data-reset db-removed\n".utf8), to: s.layout.dataResetRequest)
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log)
        #expect(outcome == .refused(.staleRequest))
        #expect(s.exists(db))
        #expect(s.exists(staged))
        #expect(!DataReset.isRequested(layout: s.layout))
        #expect(s.sink.lines.first?.hasSuffix("WARNING data_reset reason=stale_request") == true)
    }

    @Test("予約の中身が読めない・知らない形でも requested として扱う（初めからやり直す）")
    func unknownRequestBodyIsTreatedAsRequested() throws {
        let s = try Scene()
        let db = try s.put(s.layout.database)
        try AtomicFile.write(Data("something else".utf8), to: s.layout.dataResetRequest)
        let outcome = DataReset.performIfRequested(layout: s.layout, deletionCapable: false, log: s.log)
        #expect(outcome == .completed(removed: 1, failed: 0))
        #expect(!s.exists(db))
    }

    @Test("対照: 予約は run/data-reset-requested に書き、在るかどうかだけを見る")
    func requestIsAFileUnderRun() throws {
        let s = try Scene()
        #expect(!DataReset.isRequested(layout: s.layout))
        #expect(s.reserve())
        #expect(s.layout.relativePath(of: s.layout.dataResetRequest) == "run/data-reset-requested")
        #expect(DataReset.isRequested(layout: s.layout))
    }
}
