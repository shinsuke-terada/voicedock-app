// IngestService の 1 台分の取り込み（T-14 §5.4）。mountPath は FakeVolume の一時ディレクトリだけ（/Volumes に触れない）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDDevice

/// §5.4 の既定の木（BWFWriter の pcm24。mtime はすべて FakeVolume.oldMtime）
enum DefaultDeviceTree {
    static let orig120950 = "TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav"
    static let orig163444 = "TX_MIC001_20260912_163444/TX00_MIC001_20260912_163444_orig.wav"
    static let denoised163444 = "TX_MIC001_20260912_163444/TX00_MIC001_20260912_163444.wav"
    static let denoised090000 = "TX_MIC002_20260913_090000/TX01_MIC003_20260913_090000.wav"

    static func bytes120950() throws -> Data { try BWFWriter.build(seconds: 1.5, format: .pcm24, content: .speech) }
    static func bytes163444() throws -> Data { try BWFWriter.build(seconds: 2.0, format: .pcm24, content: .speech) }

    static func populate(_ fake: FakeVolume) throws {
        try fake.addFile(orig120950, data: try bytes120950(), mtime: FakeVolume.oldMtime)
        try fake.addFile(orig163444, data: try bytes163444(), mtime: FakeVolume.oldMtime)
        try fake.addFile(denoised163444, data: try bytes163444(), mtime: FakeVolume.oldMtime)
        try fake.addFile(
            denoised090000, data: try BWFWriter.build(seconds: 1.0, format: .pcm24, content: .silence),
            mtime: FakeVolume.oldMtime)
    }
}

@Suite("IngestService の 1 台分の取り込み", .serialized)
struct IngestCopyTests {
    static let deviceID = "DJIMIC3"
    static let pk120950 = "DJIMIC3/TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav"
    static let pk163444 = "DJIMIC3/TX_MIC001_20260912_163444/TX00_MIC001_20260912_163444_orig.wav"
    static let inbox120950 = "inbox/DJIMIC3/TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav"
    static let inbox163444 = "inbox/DJIMIC3/TX_MIC001_20260912_163444/TX00_MIC001_20260912_163444_orig.wav"
    /// 2026-09-21T13:33:20Z
    static let nowSeconds: Double = 1_790_000_000

    /// 待つたびに原本へ 1 バイト足す（書き込み中のファイル）。書く先は FakeVolume の一時ディレクトリだけ
    struct GrowingSleeper: Sleeper {
        let target: URL
        func sleep(seconds: Int) async throws {
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x00]))
        }
    }

    struct Harness {
        let tmp: TempDirectory
        let fake: FakeVolume
        let layout: HomeLayout
        let store: Store
        let sink: CapturingLogSink
        let service: IngestService
        let config = AppConfig.defaults(timeZone: "Asia/Tokyo")

        init(sleeper: (FakeVolume) -> any Sleeper = { _ in RecordingSleeper() }) throws {
            tmp = try TempDirectory()
            fake = try FakeVolume(in: tmp, deviceID: IngestCopyTests.deviceID)
            layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
            try layout.createDirectories()
            let clock = FixedClock(epochMillis: 1_790_000_000_000)
            let zone = ZonedTime(timeZone: try #require(TimeZone(identifier: "Asia/Tokyo")))
            store = try Store(url: layout.database, clock: clock, zone: zone)
            sink = CapturingLogSink()
            let log = AppLog(sink: sink, level: .debug, unsafeContent: false, zone: zone, clock: clock)
            let config = self.config
            let deps = IngestDependencies(
                layout: layout, configProvider: { config }, store: store, inspector: FakeMountInspector(),
                remounter: FakeRemounter(outcomes: [.alreadyReadOnly]), mountEvents: FakeMountEventSource(),
                reader: DeviceReader(),
                coexistence: CoexistenceGuard(runner: ScriptedProcessRunner(results: []), uid: 501), clock: clock,
                sleeper: sleeper(fake), zone: zone, log: log,
                volumesRoot: fake.volumesRoot.path(percentEncoded: false))
            service = IngestService(deps: deps)
        }

        var mountPath: String { fake.root.path(percentEncoded: false) }

        func run() async -> DeviceIngestResult {
            await service.ingestDevice(deviceID: IngestCopyTests.deviceID, mountPath: mountPath, config: config)
        }

        func inboxURL(_ relative: String) -> URL { layout.url(relative: relative) }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

        func lines(containing text: String) -> [String] { sink.lines.filter { $0.contains(text) } }
    }

    /// デバイス上の全ファイルの（relpath・size・mtime・SHA-256）。symlink を辿らない
    static func deviceSnapshot(_ fake: FakeVolume) throws -> [String: String] {
        var result: [String: String] = [:]
        let root = fake.root.path(percentEncoded: false)
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return result }
        while let relative = enumerator.nextObject() as? String {
            guard let stat = fake.fileStat(relative) else { continue }
            let url = fake.url(relative)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            let digest = isDirectory.boolValue ? "dir" : FileHasher.sha256(try Data(contentsOf: url))
            result[relative] = "\(stat.size) \(stat.mtime) \(digest)"
        }
        return result
    }

    @Test("_orig だけをコピーする")
    func copiesOnlyOrig() async throws {
        let h = try Harness()
        try DefaultDeviceTree.populate(h.fake)
        let result = await h.run()
        #expect(result.copied == 2)
        #expect(h.exists(h.inboxURL(Self.inbox120950)))
        #expect(h.exists(h.inboxURL(Self.inbox163444)))
        #expect(!h.exists(h.inboxURL("inbox/DJIMIC3/TX_MIC001_20260912_163444/TX00_MIC001_20260912_163444.wav")))
        #expect(!h.exists(h.inboxURL("inbox/DJIMIC3/TX_MIC002_20260913_090000")))
        let rows = try h.store.recordings(status: .discovered)
        #expect(rows.map(\.partkey).sorted() == [Self.pk120950, Self.pk163444])
    }

    @Test("登録した行の全列が仕様どおり")
    func registeredRowIsExact() async throws {
        let h = try Harness()
        try DefaultDeviceTree.populate(h.fake)
        _ = await h.run()
        let row = try #require(try h.store.recording(Self.pk120950))
        #expect(row.deviceID == "DJIMIC3")
        #expect(row.sourceFolder == "TX_MIC001_20260912_120950")
        #expect(row.transmitterID == "TX00")
        #expect(row.micIndex == 1)
        #expect(row.startedAt == "2026-09-12T12:09:50+09:00")
        #expect(row.durationSeconds == 1.5)
        #expect(row.endedAt == "2026-09-12T12:09:51+09:00")
        #expect(row.sourcePath == DefaultDeviceTree.orig120950)
        #expect(row.sourceSize == 248_776)
        #expect(row.sourceMtime == FakeVolume.oldMtime)
        #expect(row.sha256Helper == FileHasher.sha256(try DefaultDeviceTree.bytes120950()))
        #expect(row.inboxPath == Self.inbox120950)
        #expect(row.sha256 == nil)
        #expect(row.needsRecopy == false)
        #expect(row.sessionKey == nil)
        #expect(row.status == .discovered)
        #expect(h.exists(h.inboxURL(Self.inbox120950)))
    }

    @Test("source_mtime はデバイス上の原本の値で inbox のコピーの時刻ではない（DEL-12）")
    func sourceMtimeIsTheDeviceValue() async throws {
        let h = try Harness()
        try DefaultDeviceTree.populate(h.fake)
        _ = await h.run()
        let row = try #require(try h.store.recording(Self.pk120950))
        #expect(row.sourceMtime == FakeVolume.oldMtime)
        var st = stat()
        #expect(lstat(h.inboxURL(Self.inbox120950).path(percentEncoded: false), &st) == 0)
        let inboxMtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        #expect(abs(inboxMtime - FakeVolume.oldMtime) >= 16_440)
    }

    @Test("2 回目は再コピーしない")
    func secondRunDoesNotRecopy() async throws {
        let h = try Harness()
        try DefaultDeviceTree.populate(h.fake)
        _ = await h.run()
        let second = await h.run()
        #expect(second.copied == 0)
        #expect(h.lines(containing: " copy_completed ").count == 2)
    }

    @Test("needs_recopy の行は再コピーして印を 0 に戻し、状態は変えない")
    func needsRecopyRowIsRecopied() async throws {
        let h = try Harness()
        try DefaultDeviceTree.populate(h.fake)
        _ = await h.run()
        try h.store.updateRecording(Self.pk120950, [.needsRecopy(true)])
        try Data("broken".utf8).write(to: h.inboxURL(Self.inbox120950))
        let second = await h.run()
        #expect(second.copied == 1)
        let original = try DefaultDeviceTree.bytes120950()
        #expect(try Data(contentsOf: h.inboxURL(Self.inbox120950)) == original)
        let row = try #require(try h.store.recording(Self.pk120950))
        #expect(row.needsRecopy == false)
        #expect(row.sha256Helper == FileHasher.sha256(original))
        #expect(row.status == .discovered)
        #expect(
            h.lines(containing: "copy_completed recording_key=\(Self.pk120950) bytes=248776 recopy=true").count == 1)
        #expect(h.lines(containing: " part_discovered ").count == 2)
    }

    @Test("imported_keys の録音はコピーしない（§8.13）")
    func importedKeyIsSkipped() async throws {
        let h = try Harness()
        try DefaultDeviceTree.populate(h.fake)
        #expect(try h.store.insertImportedKeys([(partkey: Self.pk120950, sourceNote: "Raw/old.md")]) == 1)
        let result = await h.run()
        #expect(result.copied == 1)
        #expect(!h.exists(h.inboxURL(Self.inbox120950)))
        #expect(h.exists(h.inboxURL(Self.inbox163444)))
        #expect(try h.store.recording(Self.pk120950) == nil)
        #expect(try h.store.recording(Self.pk163444) != nil)
    }

    @Test("デバイス上のファイルは 1 バイトも変わらない")
    func sourceDeviceIsNeverModified() async throws {
        let h = try Harness()
        try DefaultDeviceTree.populate(h.fake)
        let before = try Self.deviceSnapshot(h.fake)
        _ = await h.run()
        let after = try Self.deviceSnapshot(h.fake)
        #expect(!before.isEmpty)
        #expect(after == before)
    }

    @Test("書き込み中のファイルは見送る")
    func unstableFileIsDeferred() async throws {
        let h = try Harness(sleeper: { fake in GrowingSleeper(target: fake.url(DefaultDeviceTree.orig163444)) })
        try DefaultDeviceTree.populate(h.fake)
        try h.fake.setMtime(DefaultDeviceTree.orig163444, Self.nowSeconds)
        let result = await h.run()
        #expect(result.copied == 1)
        #expect(!h.exists(h.inboxURL(Self.inbox163444)))
        #expect(try h.store.recording(Self.pk163444) == nil)
        #expect(
            h.sink.lines.contains {
                $0.hasSuffix(
                    "DEBUG file_not_stable relpath=TX_MIC001_20260912_163444/TX00_MIC001_20260912_163444_orig.wav")
            })
        #expect(h.exists(h.inboxURL(Self.inbox120950)))
        #expect(try h.store.recording(Self.pk120950) != nil)
    }

    @Test("安定性判定の後に変わった原本はコピーしない")
    func changedAfterStabilityIsNotCopied() async throws {
        let h = try Harness()
        try DefaultDeviceTree.populate(h.fake)
        let outcome = await h.service.copyOne(
            deviceID: Self.deviceID, mountPath: h.mountPath, relpath: DefaultDeviceTree.orig120950,
            stat: FileStat(size: 248_776, mtime: FakeVolume.oldMtime - 10), recopyRow: nil, config: h.config)
        #expect(outcome == .failed(.changed))
        #expect(
            h.sink.lines.contains { $0.hasSuffix("INFO  copy_failed recording_key=\(Self.pk120950) reason=changed") })
        let partial = h.layout.inboxPartial(deviceID: Self.deviceID, relpath: DefaultDeviceTree.orig120950)
        #expect(!h.exists(partial))
        #expect(!h.exists(h.inboxURL(Self.inbox120950)))
        #expect(try h.store.recording(Self.pk120950) == nil)
    }

    @Test("長さが測れなくても NULL で登録する")
    func probeFailureRegistersNullDuration() async throws {
        let h = try Harness()
        try h.fake.addFile(DefaultDeviceTree.orig120950, data: Data("not a wav".utf8), mtime: FakeVolume.oldMtime)
        _ = await h.run()
        let row = try #require(try h.store.recording(Self.pk120950))
        #expect(row.durationSeconds == nil)
        #expect(row.endedAt == nil)
        #expect(
            h.sink.lines.contains {
                $0.hasSuffix(
                    "INFO  part_discovered recording_key=\(Self.pk120950) duration_s=null error_code=AUDIO_PROBE_FAILED"
                )
            })
    }

    @Test("ボリューム直下の録音は source_folder が空文字")
    func rootLevelRecordingHasEmptyFolder() async throws {
        let h = try Harness()
        try h.fake.addFile(
            "TX00_MIC001_20260912_120950_orig.wav", data: try DefaultDeviceTree.bytes120950(),
            mtime: FakeVolume.oldMtime)
        _ = await h.run()
        #expect(h.exists(h.inboxURL("inbox/DJIMIC3/TX00_MIC001_20260912_120950_orig.wav")))
        let row = try #require(try h.store.recording("DJIMIC3/TX00_MIC001_20260912_120950_orig.wav"))
        #expect(row.sourceFolder == "")
        #expect(row.inboxPath == "inbox/DJIMIC3/TX00_MIC001_20260912_120950_orig.wav")
    }

    @Test("日時が不正な名前は unparsable_filename を出してコピーしない")
    func unparsableIsLoggedAndSkipped() async throws {
        let h = try Harness()
        try h.fake.addFile("TX00_MIC001_20260230_120950_orig.wav", mtime: FakeVolume.oldMtime)
        let result = await h.run()
        #expect(result.copied == 0)
        #expect(
            h.sink.lines.contains {
                $0.hasSuffix("DEBUG unparsable_filename relpath=TX00_MIC001_20260230_120950_orig.wav")
            })
        #expect(try h.store.recordings(status: .discovered).isEmpty)
    }

    @Test("録音 0 件のデバイスは何もコピーしない（空の状態）")
    func emptyDeviceCopiesNothing() async throws {
        let h = try Harness()
        try h.fake.addDirectory("TX_MIC001_20260912_120950")
        let result = await h.run()
        #expect(result.copied == 0)
        #expect(result.listing.relpaths.isEmpty)
        #expect(result.listing.complete == true)
        #expect(try h.store.recordings(status: .discovered).isEmpty)
    }

    @Test("長さのミリ秒変換は Python の timedelta と同じ")
    func durationMillisMatchesPython() {
        #expect(IngestService.durationMillis(1.5) == 1500)
        #expect(IngestService.durationMillis(1799.9996) == 1_799_999)
        #expect(IngestService.durationMillis(0.0005) == 0)
        #expect(IngestService.durationMillis(0.0015) == 1)
        #expect(IngestService.durationMillis(1e300) == nil)  // Int64 に収まらない長さはトラップせず nil
    }
}
