// 削除の評価の舞台（PLAN §10.5）: 三重ロックを全部外し、Part 1 件を与えた状態の Session。ND と正の対照と削除フローのテストが共有する。
import Darwin
import Foundation
import Synchronization
import VDContract
import VDCore
import VDDevice
import VDNotes
import VDPipeline
import VDProcess
import VDStore

/// **`/Volumes` の下には触れない**（volumesRoot は必ず一時ディレクトリかディスクイメージの一時マウント点）。
public final class DeletionScene: Sendable {
    public static let deviceID = "DJIMIC3"
    public static let folder = "TX_MIC001_20260912_090000"
    public static let fileName = "TX00_MIC001_20260912_090000_orig.wav"
    public static let relpath = "TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"
    public static let partkey = "DJIMIC3/TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"
    public static let sessionKey = "DJIMIC3:20260912"
    public static let dayDate = "2026-09-12"
    public static let startedAt = "2026-09-12T09:00:00+09:00"
    /// 2026-09-12T09:01:00+09:00。偶数秒（FAT の 2 秒分解能でも変わらない）
    public static let sourceMtime: Double = 1_789_171_260
    /// FakeVolume.standardContent と同じ（b"x" × 4096）
    public static let content = Data(repeating: 0x78, count: 4096)
    /// 2026-09-12T12:00:00+09:00
    public static let now = Instant(epochMillis: 1_789_182_000_000)
    public static let transcriptText = "おはようございます。"

    public let tmp: TempDirectory
    /// <tmp>/home（createDirectories 済み。bin も作る）
    public let layout: HomeLayout
    /// <tmp>/vault（.obsidian を持つ）
    public let vault: URL
    /// <tmp>/Volumes、またはディスクイメージの volumesRoot
    public let volumesRoot: URL
    /// <volumesRoot>/DJIMIC3
    public let deviceRoot: URL
    /// layout.database
    public let store: Store
    /// now
    public let clock: FixedClock
    /// Asia/Tokyo
    public let zone: ZonedTime
    public let sink: CapturingLogSink
    /// DEBUG、unsafeContent false
    public let log: AppLog
    public let verifier: FakeSignatureVerifier
    public let runner: ScriptedProcessRunner
    public let locks: LockEvaluator
    /// ディスクイメージなら SystemVolumeOpener、それ以外 FakeVolumeOpener()
    public let opener: any VolumeOpener

    /// 置いた後に lstat した原本の mtime（FAT は 2 秒刻み。偽のボリュームでは sourceMtime のまま）
    private let originalMtime: Double
    private let state: Mutex<State>

    private struct State {
        var config: AppConfig
        var deviceRelpaths: Set<String>
        /// Session ごとの Raw に載せる Part（追加順）
        var rawMembers: [String: [String]]
    }

    /// 既定: Part を RAW_SAVED、Session を SAVED まで進め、Raw ノートと transcript を置き、三重ロックを全部外す。
    /// readiness は評価しない（署名と版のキャッシュは空で始まる）。
    public init(
        status: PartStatus = .rawSaved, errorCode: ErrorCode? = nil, sessionStatus: SessionStatus = .saved,
        reaperVersionOutput: String = AppVersion.string + "\n",
        in tmp: TempDirectory? = nil, diskImage: DiskImageVolume? = nil
    ) throws {
        // 1.
        let tmp = try tmp ?? TempDirectory()
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        // テストの舞台なので bin を作ってよい
        try FileManager.default.createDirectory(at: layout.binDirectory, withIntermediateDirectories: true)
        // 2.
        let vault = tmp.url.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent(".obsidian", isDirectory: true), withIntermediateDirectories: true)
        // 3.
        let volumesRoot = diskImage?.volumesRoot ?? tmp.url.appendingPathComponent("Volumes", isDirectory: true)
        let deviceRoot = volumesRoot.appendingPathComponent(Self.deviceID, isDirectory: true)
        if diskImage == nil {
            try FileManager.default.createDirectory(at: deviceRoot, withIntermediateDirectories: true)
        }
        // 4.
        let originalMtime = try Self.writeOnDevice(deviceRoot: deviceRoot, relpath: Self.relpath)
        // 5.
        guard let tokyo = TimeZone(identifier: "Asia/Tokyo") else { throw StorePathError("Asia/Tokyo が無い") }
        let clock = FixedClock(now: Self.now)
        let zone = ZonedTime(timeZone: tokyo)
        let sink = CapturingLogSink()
        let log = AppLog(sink: sink, level: .debug, unsafeContent: false, zone: zone, clock: clock)
        // 6.
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        config.vault.path = vault.path(percentEncoded: false)
        config.cleanup.deleteSourceAudio = true
        config.device.mountMode = "rw"
        // 7.
        try Self.writeReaperStub(layout)
        try ReaperConf(deleteSourceAudio: true, volumesRoot: volumesRoot.path(percentEncoded: false)).render()
            .write(to: layout.reaperConf)
        // 8.
        let verifier = FakeSignatureVerifier(valid: true)
        let runner = ScriptedProcessRunner(results: [ScriptedProcessRunner.version(reaperVersionOutput)])
        let locks = LockEvaluator(layout: layout, verifier: verifier, runner: runner, log: log)
        // 9.
        let opener: any VolumeOpener = diskImage == nil ? FakeVolumeOpener() : SystemVolumeOpener()
        // 10.
        let store = try Store(url: layout.database, clock: clock, zone: zone)
        try store.insertSession(NewSession(sessionKey: Self.sessionKey, dayDate: Self.dayDate, deviceID: Self.deviceID))

        self.tmp = tmp
        self.layout = layout
        self.vault = vault
        self.volumesRoot = volumesRoot
        self.deviceRoot = deviceRoot
        self.store = store
        self.clock = clock
        self.zone = zone
        self.sink = sink
        self.log = log
        self.verifier = verifier
        self.runner = runner
        self.locks = locks
        self.opener = opener
        self.originalMtime = originalMtime
        self.state = Mutex(State(config: config, deviceRelpaths: [Self.relpath], rawMembers: [:]))

        // 11.（デバイスには 4 で置いた）
        try addPart(
            fileName: Self.fileName, startedAt: Self.startedAt, status: status, errorCode: errorCode, onDevice: false,
            transcript: true, inRawNote: true)
        // 12.
        try writeRawNote()
        try moveSession(to: sessionStatus)
    }

    public var config: AppConfig { state.withLock { $0.config } }

    public func updateConfig(_ mutate: (inout AppConfig) -> Void) {
        var copy = config
        mutate(&copy)
        state.withLock { $0.config = copy }
    }

    /// snapshot に載せる relpath の既定（デバイスに置いた Part の relpath）
    public var deviceRelpaths: Set<String> { state.withLock { $0.deviceRelpaths } }

    // MARK: - 観測と評価

    /// completedAt が nil なら clock.now()（古い snapshot は `completedAt: DeletionScene.now.adding(seconds: -901)` のように渡す）
    public func snapshot(
        generation: UInt64 = 1, readOnly: Bool? = false, relpaths: Set<String>? = nil, includeDevice: Bool = true,
        completedAt: Instant? = nil
    ) -> DeviceSnapshot {
        let devices: [String: DeviceObservation] =
            includeDevice
            ? [
                Self.deviceID: DeviceObservation(
                    deviceID: Self.deviceID, mountPath: deviceRoot.path(percentEncoded: false),
                    deviceNode: "/dev/disk9", readOnly: readOnly, freeBytes: 1_000_000_000,
                    relpaths: relpaths ?? deviceRelpaths)
            ] : [:]
        return DeviceSnapshot(
            generation: generation, completedAt: completedAt ?? clock.now(), connectEpoch: 1, devices: devices,
            unavailable: [:], notListableErrno: [:])
    }

    /// デバイスを実際に走査した snapshot（DeviceReader.scan の relpaths、SystemMountInspector の readOnly）。ディスクイメージの往復で使う
    public func scannedSnapshot(generation: UInt64) -> DeviceSnapshot {
        let root = deviceRoot.path(percentEncoded: false)
        let relpaths = DeviceReader().scan(volumeRoot: root, maxDepth: 3).relpaths
        let readOnly = SystemMountInspector().mountInfo(path: root)?.readOnly
        return snapshot(generation: generation, readOnly: readOnly, relpaths: relpaths)
    }

    public func context(
        snapshot: DeviceSnapshot?, locks: LockEvaluator? = nil, opener: (any VolumeOpener)? = nil,
        useCache: Bool = true
    ) async -> DeletionContext {
        let config = self.config
        let observation = await (locks ?? self.locks).observe(config: config, snapshot: snapshot, useCache: useCache)
        return DeletionContext(
            config: config, locks: observation, layout: layout, volumeOpener: opener ?? self.opener)
    }

    public func candidate(_ partkey: String = DeletionScene.partkey) throws -> DeletionCandidate {
        guard let c = try DeletionCandidate.load(partkey: partkey, store: store) else {
            throw StorePathError("\(partkey) の candidate が作れない")
        }
        return c
    }

    // MARK: - 組み立て

    /// 同じ Session に Part を足す。transcript が真なら transcripts/parts に置き transcript_path を書く。onDevice が真ならデバイスに置く。
    /// inRawNote が真なら Raw ノートに載せる対象にする（載せ直すのは writeRawNote）
    @discardableResult
    public func addPart(
        fileName: String, folder: String = DeletionScene.folder, startedAt: String, status: PartStatus,
        errorCode: ErrorCode? = nil, duplicateOf: String? = nil, sessionKey: String = DeletionScene.sessionKey,
        onDevice: Bool = true, transcript: Bool = true, inRawNote: Bool = true
    ) throws -> String {
        let relpath = folder + "/" + fileName
        let pk = try PartKey.make(deviceID: Self.deviceID, relpath: relpath)
        if onDevice {
            try placeOnDevice(relpath)
        }
        guard let start = zone.parseISO(startedAt) else { throw StorePathError("\(startedAt) が読めない") }
        try store.insertRecording(
            NewRecording(
                partkey: pk, deviceID: Self.deviceID, sourceFolder: folder, transmitterID: String(fileName.prefix(4)),
                micIndex: 1, startedAt: startedAt, durationSeconds: 60.0, endedAt: zone.iso(start.adding(seconds: 60)),
                sourcePath: relpath, sourceSize: 4096, sourceMtime: originalMtime,
                sha256Helper: FileHasher.sha256(Self.content), inboxPath: "inbox/" + Self.deviceID + "/" + relpath))
        let transcriptURL = layout.transcript(slug: KeySlug.of(pk))
        var fields: [RecordingField] = [.sessionKey(sessionKey)]
        if let duplicateOf { fields.append(.duplicateOf(duplicateOf)) }
        if transcript {
            guard let relative = layout.relativePath(of: transcriptURL) else {
                throw StorePathError("\(pk) の transcript の相対パスが作れない")
            }
            fields.append(.transcriptPath(relative))
        }
        try store.updateRecording(pk, fields)
        if transcript {
            try PartTranscriptCodec.encode(
                PartTranscript(
                    partkey: pk, language: "ja", durationSeconds: 60.0, startedAt: startedAt, text: Self.transcriptText,
                    segments: [TranscriptSegment(start: 0.0, end: 3.0, text: Self.transcriptText)])
            ).write(to: transcriptURL)
        }
        try StorePaths.advancePart(store, partkey: pk, to: status, errorCode: errorCode)
        if inRawNote {
            state.withLock { $0.rawMembers[sessionKey, default: []].append(pk) }
        }
        return pk
    }

    /// 別の日の Session を作る（OPEN）。重複の双子を別の日に置くため
    public func addSession(key: String, dayDate: String) throws {
        try store.insertSession(NewSession(sessionKey: key, dayDate: dayDate, deviceID: Self.deviceID))
    }

    /// Session の Raw ノートを書き直す（載せる対象の Part を RawNote.render で。DB の raw_output_path・raw_output_sha256 を更新）
    public func writeRawNote(sessionKey: String = DeletionScene.sessionKey) throws {
        guard let session = try store.session(sessionKey), let day = LocalDate(dashed: session.dayDate) else {
            throw StorePathError("\(sessionKey) の Session が無い")
        }
        let members = state.withLock { $0.rawMembers[sessionKey] ?? [] }
        var parts: [RawPart] = []
        for pk in members {
            guard let row = try store.recording(pk), let at = zone.parseISO(row.startedAt) else {
                throw StorePathError("\(pk) の行が無い")
            }
            parts.append(
                RawPart(
                    partkey: pk, startedAt: row.startedAt, endedAt: row.endedAt,
                    segments: [
                        AbsoluteSegment(at: at, endAt: at.adding(milliseconds: 3000), text: Self.transcriptText)
                    ],
                    zone: zone))
        }
        let obsidian = config.obsidian
        let text = RawNote.render(parts: parts, day: day, sessionKey: sessionKey, config: obsidian)
        let folder = RawNote.folder(config: obsidian, day: day)
        let baseName = RawNote.baseName(config: obsidian, day: day)
        let folderURL = try NoteFolder.ensure(relative: folder, vault: vault)
        let url = folderURL.appendingPathComponent(baseName + ".md")
        let sha = try NoteWriter.write(text, to: url)
        try store.updateSession(sessionKey, [.rawOutputPath(folder + "/" + baseName + ".md"), .rawOutputSHA256(sha)])
    }

    public func rawNoteURL(sessionKey: String = DeletionScene.sessionKey) throws -> URL {
        guard let relative = try store.session(sessionKey)?.rawOutputPath else {
            throw StorePathError("\(sessionKey) の raw_output_path が無い")
        }
        return vault.appendingPathComponent(relative, isDirectory: false)
    }

    /// ノートの中の文字列を置き換える。updateSHA が真なら DB の raw_output_sha256 を新しい SHA にする（鍵の包含だけを壊す）
    public func replaceInRawNote(
        _ target: String, with replacement: String, updateSHA: Bool, sessionKey: String = DeletionScene.sessionKey
    ) throws {
        let url = try rawNoteURL(sessionKey: sessionKey)
        let text = try String(contentsOf: url, encoding: .utf8)
        let data = Data(text.replacingOccurrences(of: target, with: replacement).utf8)
        try data.write(to: url)
        if updateSHA {
            try store.updateSession(sessionKey, [.rawOutputSHA256(FileHasher.sha256(data))])
        }
    }

    /// 末尾に追記する（SHA は更新しない。改竄）
    public func appendToRawNote(_ text: String, sessionKey: String = DeletionScene.sessionKey) throws {
        let url = try rawNoteURL(sessionKey: sessionKey)
        var data = try Data(contentsOf: url)
        data.append(Data(text.utf8))
        try data.write(to: url)
    }

    public func transcriptURL(_ partkey: String) -> URL {
        layout.transcript(slug: KeySlug.of(partkey))
    }

    /// content を書き mtime を sourceMtime に（utimes）。deviceRelpaths に足す
    public func placeOnDevice(_ relpath: String) throws {
        _ = try Self.writeOnDevice(deviceRoot: deviceRoot, relpath: relpath)
        _ = state.withLock { $0.deviceRelpaths.insert(relpath) }
    }

    /// ファイルを消し deviceRelpaths から除く
    public func removeFromDevice(_ relpath: String) throws {
        try FileManager.default.removeItem(at: deviceRoot.appendingPathComponent(relpath, isDirectory: false))
        _ = state.withLock { $0.deviceRelpaths.remove(relpath) }
    }

    /// StorePaths.advancePart
    public func movePart(_ partkey: String, to status: PartStatus, errorCode: ErrorCode? = nil) throws {
        try StorePaths.advancePart(store, partkey: partkey, to: status, errorCode: errorCode)
    }

    public func moveSession(to status: SessionStatus, sessionKey: String = DeletionScene.sessionKey) throws {
        try StorePaths.advanceSession(store, sessionKey: sessionKey, to: status)
    }

    /// "#!/bin/sh\nexit 0\n"、0o755
    public func installReaperStub() throws {
        try Self.writeReaperStub(layout)
    }

    public func removeReaper() throws {
        try FileManager.default.removeItem(at: layout.reaperExecutable)
    }

    /// ReaperConf(deleteSourceAudio:, volumesRoot: p(volumesRoot)).render()
    public func writeReaperConf(deleteSourceAudio: Bool) throws {
        try writeReaperConfRaw(
            ReaperConf(deleteSourceAudio: deleteSourceAudio, volumesRoot: volumesRoot.path(percentEncoded: false))
                .render())
    }

    public func writeReaperConfRaw(_ data: Data) throws {
        try data.write(to: layout.reaperConf)
    }

    public func removeReaperConf() throws {
        try FileManager.default.removeItem(at: layout.reaperConf)
    }

    /// queue/delete の . 始まりでない .json（名前のバイト順）
    public func requests() -> [URL] {
        Self.jsonFiles(in: layout.queueDelete)
    }

    /// queue/result の . 始まりでない .json（名前のバイト順）
    public func results() -> [URL] {
        Self.jsonFiles(in: layout.queueResult)
    }

    @discardableResult
    public func writeResult(partkey: String, requestID: String, status: DeleteResultStatus, detail: String) throws
        -> URL
    {
        let data = try ContractJSON.encode(
            DeleteResult(
                requestID: requestID, completedAt: zone.iso(clock.now()), reaperVersion: AppVersion.string,
                deviceID: Self.deviceID, partkey: partkey, status: status, detail: detail))
        let url = layout.queueResult.appendingPathComponent(requestID + ".json", isDirectory: false)
        try data.write(to: url)
        return url
    }

    /// sink.lines
    public var logLines: [String] { sink.lines }

    // MARK: - 内部

    /// content を書き、mtime を sourceMtime にし、lstat した mtime を返す
    private static func writeOnDevice(deviceRoot: URL, relpath: String) throws -> Double {
        let url = deviceRoot.appendingPathComponent(relpath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url)
        let path = url.path(percentEncoded: false)
        let seconds = Int(sourceMtime)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        guard utimes(path, &times) == 0 else { throw StorePathError("\(path) の utimes が失敗（errno \(errno)）") }
        var st = stat()
        guard lstat(path, &st) == 0 else { throw StorePathError("\(path) の lstat が失敗（errno \(errno)）") }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }

    private static func writeReaperStub(_ layout: HomeLayout) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: layout.reaperExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: layout.reaperExecutable.path(percentEncoded: false))
    }

    private static func jsonFiles(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return
            names
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map { directory.appendingPathComponent($0, isDirectory: false) }
    }
}
