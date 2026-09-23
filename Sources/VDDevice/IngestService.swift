// デバイス → inbox の取り込み（PLAN §8.1）。長い同期 I/O は BlockingIO で行い、actor は状態だけを持つ（§2.1）。
import Darwin
import Foundation
import VDAudio
import VDContract
import VDCore
import VDStore

public actor IngestService {
    let deps: IngestDependencies
    // 進捗（activity() が IngestActivity にまとめる）
    var progressDeviceID: String? = nil
    var progressCopied: Int = 0
    var progressTotal: Int = 0
    var lastActivityAt: Instant? = nil
    /// stop() が立て、start() が下ろす
    var stopRequested = false
    // 走査と公開（PLAN §8.1）
    var snapshot: DeviceSnapshot? = nil
    var generation: UInt64 = 0
    var connectEpoch: UInt64 = 0
    /// 走査のループが動いているか
    var scanning = false
    /// 走査中に届いた契機（1 つにまとめる）
    var rescanRequested = false
    /// 始めた走査の数（1 から）
    var startedScans: UInt64 = 0
    var waiters: [(minStart: UInt64, continuation: CheckedContinuation<UInt64?, Never>)] = []
    var ingestState: IngestState = .idle
    var previousUnavailable: [String: String] = [:]
    /// 再マウントで unmount は成功し mount が失敗して、マウント点でなくなったデバイスの名前（F-81）。
    /// アンマウントされたデバイスは /Volumes に現れないので、次の走査の判定では見えず「未接続」に見える。
    /// 名前が判定に戻る（挿し直し・手でマウント。not_a_mount_point のままは戻ったとみなさない）まで、毎回の snapshot の
    /// unavailable に mount_failed で載せ続ける。メモリだけで持つ（再起動で消える。抜いた後も挿し直すまで残る）。
    /// 鍵は名前のスカラー列（00-api-map §0。Set<String> の正準等価で別の名前とまとめない）、値は名前
    var unmountedByRemount: [[Unicode.Scalar]: String] = [:]
    var updateContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    var backgroundTasks: [Task<Void, Never>] = []
    var started = false
    static let lockAttempts = 130
    static let lockRetrySeconds = 1

    public init(deps: IngestDependencies) { self.deps = deps }

    /// 1 台分: 走査 → 候補の選択 → 安定性判定 → コピー。T-15 の走査がデバイスごとに呼ぶ
    func ingestDevice(deviceID: String, mountPath: String, config: AppConfig) async -> DeviceIngestResult {
        let reader = deps.reader
        let root = mountPath
        let depth = config.device.maxScanDepth
        let listing =
            await (try? BlockingIO.run { reader.scan(volumeRoot: root, maxDepth: depth) }) ?? .incomplete
        // 列挙の直後の statfs（F-81）。unmount と重なると、マウント点だった空のディレクトリや親の FS を「完全な一覧」と
        // 読みうるので、走査がこれを列挙の前の値と照らしてから snapshot に載せる。コピーの後ではなくここで取るのは、
        // 列挙からの間を短くして、抜いて挿し直した（同じ node・同じマウント点に戻った）間の一覧を見逃さないため
        let mountAfterListing = deps.inspector.mountInfo(path: root)
        for rel in listing.unparsable {
            deps.log.debug(.unparsableFilename, [(.relpath, .string(rel))])
        }
        let selection: CandidateSelection
        do {
            selection = try selectCandidates(deviceID: deviceID, origRelpaths: listing.origCandidates)
        } catch {
            deps.log.warning(.copyFailed, [(.reason, .string(CopyError.writeError(EIO).reason))])
            return DeviceIngestResult(listing: listing, copied: 0, mountAfterListing: mountAfterListing)
        }
        let stable = await StabilityChecker(config: config.device, clock: deps.clock, sleeper: deps.sleeper)
            .stableCandidates(selection.candidates, stat: { rel in reader.stat(volumeRoot: root, relpath: rel) })
        for rel in selection.candidates where stable[rel] == nil {
            deps.log.debug(.fileNotStable, [(.relpath, .string(rel))])
        }
        progressDeviceID = deviceID
        progressTotal += stable.count
        var copied = 0
        let ordered = stable.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        for rel in ordered {
            if stopRequested { break }
            guard let stat = stable[rel] else { continue }
            let outcome = await copyOne(
                deviceID: deviceID, mountPath: mountPath, relpath: rel, stat: stat,
                recopyRow: selection.recopyRows[rel], config: config)
            if case .copied = outcome { copied += 1 }
        }
        return DeviceIngestResult(listing: listing, copied: copied, mountAfterListing: mountAfterListing)
    }

    /// 取り込みの候補（PLAN §8.1 安定性判定の 1）: DB に行が無いか needs_recopy の行があり、imported_keys に無い _orig
    func selectCandidates(deviceID: String, origRelpaths: [String]) throws -> CandidateSelection {
        var keyOf: [String: String] = [:]
        for relpath in origRelpaths {
            guard let partkey = try? PartKey.make(deviceID: deviceID, relpath: relpath) else { continue }
            keyOf[relpath] = partkey
        }
        let known = try deps.store.knownPartkeys(Array(keyOf.values))
        var recopy: [String: RecordingRow] = [:]
        for row in try deps.store.recordingsNeedingRecopy() where row.deviceID == deviceID {
            recopy[row.partkey] = row
        }
        let imported = try deps.store.importedKeys()
        var candidates: [String] = []
        var recopyRows: [String: RecordingRow] = [:]
        for relpath in origRelpaths {
            guard let k = keyOf[relpath] else { continue }
            guard !known.contains(k) || recopy[k] != nil, !imported.contains(k) else { continue }
            candidates.append(relpath)
            if let row = recopy[k] { recopyRows[relpath] = row }
        }
        return CandidateSelection(candidates: candidates, recopyRows: recopyRows)
    }

    /// 1 本コピーして登録する。本体（inbox の確定）が先、記録（DB）が後（DEV-16・PT-16）
    func copyOne(
        deviceID: String, mountPath: String, relpath: String, stat: FileStat, recopyRow: RecordingRow?,
        config: AppConfig
    ) async -> CopyOutcome {
        guard let partkey = try? PartKey.make(deviceID: deviceID, relpath: relpath),
            let parsed = RecordingName.parseFile(RelPath.lastComponent(relpath))
        else { return .skipped }
        let final = deps.layout.inboxFile(deviceID: deviceID, relpath: relpath)
        let partial = deps.layout.inboxPartial(deviceID: deviceID, relpath: relpath)
        let reader = deps.reader
        let writer = InboxWriter(layout: deps.layout)
        let root = mountPath
        let chunk = config.audio.hashChunkBytes
        let written: Result<String, CopyError> =
            (try? await BlockingIO.run {
                switch reader.openForCopy(volumeRoot: root, relpath: relpath, expected: stat) {
                case .failure(let e): return .failure(e)
                case .success(let handle):
                    defer { handle.close() }
                    return writer.writePartial(
                        from: handle, expectedSize: stat.size, partial: partial, chunkBytes: chunk)
                }
            }) ?? .failure(.readError(EIO))
        let sha256: String
        switch written {
        case .failure(let error):
            logCopyFailed(partkey, error)
            return .failed(error)
        case .success(let digest):
            sha256 = digest
        }
        let committed =
            (try? await BlockingIO.run { writer.commitPartial(partial, to: final) })
            ?? .failure(.writeError(EIO))
        if case .failure(let error) = committed {
            logCopyFailed(partkey, error)
            return .failed(error)
        }
        let duration = (try? await BlockingIO.run { AudioProbe.durationSeconds(of: final) }) ?? nil
        let isNew: Bool
        do {
            isNew = try registerCopied(
                partkey: partkey, deviceID: deviceID, relpath: relpath, parsed: parsed, stat: stat, sha256: sha256,
                final: final, duration: duration, recopyRow: recopyRow)
        } catch {
            logCopyFailed(partkey, .writeError(EIO))
            return .failed(.writeError(EIO))
        }
        if isNew {
            var fields: [(LogKey, LogValue)] = [(.recordingKey, .string(partkey)), (.durationS, .of(duration))]
            if duration == nil { fields.append((.errorCode, .string(ErrorCode.audioProbeFailed.rawValue))) }
            deps.log.info(.partDiscovered, fields)
        }
        deps.log.info(
            .copyCompleted, [(.recordingKey, .string(partkey)), (.bytes, .of(stat.size)), (.recopy, .of(!isNew))])
        progressCopied += 1
        lastActivityAt = deps.clock.now()
        notifyUpdate()
        return .copied(isNew: isNew)
    }

    /// DB に登録する（新規なら true）。source_size / source_mtime は原本の stat の値（DEL-12。inbox のコピーを stat しない）
    func registerCopied(
        partkey: String, deviceID: String, relpath: String, parsed: ParsedFile, stat: FileStat, sha256: String,
        final: URL, duration: Double?, recopyRow: RecordingRow?
    ) throws -> Bool {
        guard let inboxRel = deps.layout.relativePath(of: final) else { throw CopyError.writeError(EINVAL) }
        if recopyRow != nil {
            // 状態は変えない（PLAN §5.4 の契機 4 が再評価する）
            try deps.store.updateRecording(
                partkey,
                [
                    .inboxPath(inboxRel), .sha256Helper(sha256), .sourceSize(stat.size), .sourceMtime(stat.mtime),
                    .needsRecopy(false),
                ])
            return false
        }
        let start = deps.zone.instant(of: parsed.local)  // ファイル名の時刻にタイムゾーンを付与するだけ（TIME-03）
        let endedAt = duration.flatMap(Self.durationMillis).map { deps.zone.iso(start.adding(milliseconds: $0)) }
        try deps.store.insertRecording(
            NewRecording(
                partkey: partkey, deviceID: deviceID, sourceFolder: RelPath.parent(relpath),
                transmitterID: parsed.transmitterID, micIndex: parsed.micIndex,
                startedAt: deps.zone.iso(start), durationSeconds: duration, endedAt: endedAt,
                sourcePath: relpath, sourceSize: stat.size, sourceMtime: stat.mtime,
                sha256Helper: sha256, inboxPath: inboxRel))
        return true
    }

    /// Python の `timedelta(seconds=s)` は µ 秒に偶数丸めし、`isoformat(timespec="seconds")` は切り捨てる。ms へは切り捨てで落とす。
    /// Int64 の µ 秒で表せない長さ（壊れたファイルが巨大なフレーム数を名乗る場合など）は nil（ended_at を書かない。トラップしない。PT-19）
    static func durationMillis(_ seconds: Double) -> Int64? {
        guard let micros = Int64(exactly: (seconds * 1_000_000).rounded(.toNearestOrEven)) else { return nil }
        return micros / 1000
    }

    /// copy_failed。changed だけ INFO、ほかは WARNING
    private func logCopyFailed(_ partkey: String, _ error: CopyError) {
        let fields: [(LogKey, LogValue)] = [(.recordingKey, .string(partkey)), (.reason, .string(error.reason))]
        if error == .changed {
            deps.log.info(.copyFailed, fields)
        } else {
            deps.log.warning(.copyFailed, fields)
        }
    }
}

struct DeviceIngestResult: Equatable, Sendable {
    let listing: ScanListing
    let copied: Int
    /// 列挙の直後の statfs（取れなければ nil）。走査が列挙の前の値と照らす（F-81）
    let mountAfterListing: MountInfo?
}

/// key = relpath
struct CandidateSelection: Equatable, Sendable {
    let candidates: [String]
    let recopyRows: [String: RecordingRow]
}

enum CopyOutcome: Equatable, Sendable {
    case copied(isNew: Bool)
    case failed(CopyError)
    case skipped
}

/// 取り込みの状態（PLAN §8.1。置き場所は 00-api-map §5）
public enum IngestState: Equatable, Sendable {
    case idle
    case scanning
    /// 設定エラー中（configProvider が nil）
    case disabled
}

// 起動契機の受け付けと 1 回の走査の手順（PLAN §8.1）
extension IngestService {
    /// 通知の購読・周期の走査・最初の走査
    public func start() {
        if started { return }
        started = true
        stopRequested = false
        let deps = self.deps
        backgroundTasks.append(
            Task {
                for await _ in deps.mountEvents.events() { self.requestScan() }
            })
        backgroundTasks.append(
            Task {
                while !Task.isCancelled {
                    let seconds = await deps.configProvider()?.device.scanIntervalSeconds ?? 300
                    do { try await deps.sleeper.sleep(seconds: seconds) } catch { return }
                    self.requestScan()
                }
            })
        requestScan()
    }

    /// 新しい走査を始めない。待っている scanNow() に nil を返す
    public func stop() {
        stopRequested = true
        for task in backgroundTasks { task.cancel() }
        backgroundTasks = []
        for waiter in waiters { waiter.continuation.resume(returning: nil) }
        waiters = []
        for continuation in updateContinuations.values { continuation.finish() }
        updateContinuations = [:]
        started = false
    }

    /// 呼び出しの後に始まり完了した走査の generation。見送りなら nil。
    /// 走査中に呼ばれたら、今の走査ではなく次に始まる走査を待つ（§8.9.6 が reaper の後の観測を得るため）
    public func scanNow() async -> UInt64? {
        if stopRequested { return nil }
        let target = startedScans + 1
        return await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
            requestScan()
        }
    }

    public func latestSnapshot() -> DeviceSnapshot? { snapshot }

    public func activity() -> IngestActivity {
        IngestActivity(
            scanning: scanning, deviceID: progressDeviceID, copied: progressCopied, total: progressTotal,
            lastActivityAt: lastActivityAt)
    }

    public func state() -> IngestState { ingestState }

    /// 公開・状態の変化・1 本のコピーのたびに 1 つ流す（最新 1 つだけ溜める）
    public func updates() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        updateContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        return stream
    }

    /// 走査中に届いた契機は 1 つの再走査要求にまとめる（途中で 0 台の snapshot を作らない）
    func requestScan() {
        if stopRequested { return }
        if scanning {
            rescanRequested = true
            return
        }
        scanning = true
        Task { await self.runScans() }
    }

    func runScans() async {
        repeat {
            rescanRequested = false
            await performScan()
        } while rescanRequested && !stopRequested
        scanning = false
        notifyUpdate()
    }

    /// 1 回の走査（PLAN §8.1 の手順 2〜5。手順 1 は F-61 で取り下げた）
    func performScan() async {
        startedScans += 1
        let index = startedScans
        progressDeviceID = nil
        progressCopied = 0
        progressTotal = 0
        notifyUpdate()
        if stopRequested {
            finishWaiters(upTo: index, nil)
            return
        }
        guard let config = await deps.configProvider() else {
            setState(.disabled)
            finishWaiters(upTo: index, nil)
            return
        }
        setState(.scanning)
        guard let lock = await acquireReaperLock() else {
            setState(.idle)
            finishWaiters(upTo: index, nil)
            return
        }
        defer { lock.release() }
        let t0 = deps.clock.uptime()
        let detector = DeviceDetector(
            config: config.device, volumesRoot: deps.volumesRoot, inspector: deps.inspector, reader: deps.reader)
        let detection =
            (try? await BlockingIO.run { detector.detect() })
            ?? DetectionResult(devices: [], skipped: [], listingError: ErrnoError(EIO))
        // volumesRoot 自体を列挙できない = 観測できない。「0 台」として公開しない（DEL-32）。前回の snapshot を残す
        if detection.listingError != nil {
            setState(.idle)
            finishWaiters(upTo: index, nil)
            return
        }
        var unavailable: [String: String] = [:]
        var notListableErrno: [String: Int32] = [:]
        for skip in detection.skipped {
            recordSkip(
                name: skip.name, reason: skip.reason, errno: skip.listingError?.code, into: &unavailable,
                &notListableErrno)
        }
        carryUnmounted(detection, into: &unavailable)
        var observations: [String: DeviceObservation] = [:]
        var copiedTotal = 0
        for device in detection.devices {
            if stopRequested { break }
            var mountPath = device.mountPath
            var remounted = false
            var remountFailure: String? = nil
            if config.device.mode == .ro {
                switch await deps.remounter.remountReadOnly(path: mountPath, node: device.node ?? "") {
                case .alreadyReadOnly:
                    break
                case .remounted(let newPath):
                    remounted = true
                    mountPath = newPath
                    // 規則 8 の再判定
                    if URL(fileURLWithPath: newPath).lastPathComponent != device.deviceID
                        || !DeviceDetector.nameMatchesVolume(
                            device.deviceID, volumeName: deps.inspector.volumeName(path: newPath))
                    {
                        recordSkip(
                            name: device.deviceID, reason: .mountNameMismatch, errno: nil, into: &unavailable,
                            &notListableErrno)
                        continue
                    }
                case .failed(let reason):
                    // 取り込みは続ける（記録の保護）
                    remountFailure = reason
                    deps.log.warning(.remountFailed, [(.name, .string(device.deviceID)), (.reason, .string(reason))])
                }
            }
            // 再マウントの途中で外れた等。親の FS を観測しない（PLAN §8.1）
            // statfs は 1 回だけ。その f_mntonname が realpath と一致したときだけ同じ値を観測に使う（間で外れたら親の FS の値になる）。
            // statfs が取れなければ規則 4 の判定だけを行い、観測値は nil にする（DEL-32）
            let info = deps.inspector.mountInfo(path: mountPath)
            let isMountPoint =
                info.map { $0.mountOnName == SystemMountInspector.realPath(mountPath) }
                ?? deps.inspector.isMountPoint(path: mountPath)
            if !isMountPoint {
                deps.log.debug(
                    .volumeSkipped,
                    [(.name, .string(device.deviceID)), (.reason, .string(DetectionReason.notAMountPoint.rawValue))])
                // unmount は成功し mount が失敗して、アンマウントされたまま残った（F-81）。「未接続」に見せないよう
                // unavailable に載せ、次の走査からも名前が判定に戻るまで載せ続ける（unmountedByRemount）
                if remountFailure == RemountOutcome.mountFailedReason {
                    unmountedByRemount[Array(device.deviceID.unicodeScalars)] = device.deviceID
                    unavailable[device.deviceID] = RemountOutcome.mountFailedReason
                }
                continue
            }
            // 観測値。試行の成否から推論しない（DEL-31）
            let readOnly = info?.readOnly
            if remounted && readOnly != true {
                deps.log.warning(
                    .remountFailed, [(.name, .string(device.deviceID)), (.reason, .string("still_writable"))])
            }
            let result = await ingestDevice(deviceID: device.deviceID, mountPath: mountPath, config: config)
            copiedTotal += result.copied
            // 一覧を信用しない（「消えた」と誤読させない）。列挙の直後の statfs が列挙の前（info）と違う、つまり列挙が
            // unmount と重なったときも同じ（空の一覧を complete のまま公開すると F-64 / F-78 が「無い」と判断する。F-81）
            if !result.listing.complete || !Self.sameMount(info, result.mountAfterListing) {
                recordSkip(
                    name: device.deviceID, reason: .notListable, errno: nil, into: &unavailable, &notListableErrno)
                continue
            }
            observations[device.deviceID] = DeviceObservation(
                deviceID: device.deviceID, mountPath: mountPath, deviceNode: device.node, readOnly: readOnly,
                freeBytes: info?.freeBytes, relpaths: result.listing.relpaths)
        }
        // 途中で止めたら公開しない
        if stopRequested {
            setState(.idle)
            finishWaiters(upTo: index, nil)
            return
        }
        publish(
            observations, unavailable, notListableErrno, copied: copiedTotal, elapsed: deps.clock.uptime() - t0)
        finishWaiters(upTo: index, generation)
    }

    /// 利用者の操作が要る理由は unavailable に載せる。WARNING は前回の走査から変わったときだけ（OPS-12）
    func recordSkip(
        name: String, reason: DetectionReason, errno: Int32?, into unavailable: inout [String: String],
        _ notListableErrno: inout [String: Int32]
    ) {
        if reason.needsUserAction {
            unavailable[name] = reason.rawValue
            if let errno { notListableErrno[name] = errno }
        }
        var fields: [(LogKey, LogValue)] = [(.name, .string(name)), (.reason, .string(reason.rawValue))]
        // errno は detail に残す（PLAN §8.1 規則 5。付録 A.4 に errno のキーは無い）
        if let errno { fields.append((.detail, .int(Int64(errno)))) }
        if reason.needsUserAction && previousUnavailable[name] != reason.rawValue {
            deps.log.warning(.volumeSkipped, fields)
        } else {
            deps.log.debug(.volumeSkipped, fields)
        }
    }

    /// 前の走査の再マウントでアンマウントされたままのデバイス（unmountedByRemount）のうち、名前が判定に戻ったもの
    /// （devices か、not_a_mount_point 以外の理由の skipped）を外し、残りを unavailable に mount_failed で載せる（F-81）。
    /// not_a_mount_point は、アンマウントの後にマウント点のディレクトリが残っただけかもしれないので戻ったとみなさない。
    /// 名前はスカラー列で照らす（00-api-map §0）
    func carryUnmounted(_ detection: DetectionResult, into unavailable: inout [String: String]) {
        if unmountedByRemount.isEmpty { return }
        let back =
            detection.devices.map(\.deviceID)
            + detection.skipped.filter { $0.reason != .notAMountPoint }.map(\.name)
        for name in back {
            unmountedByRemount[Array(name.unicodeScalars)] = nil
        }
        for name in unmountedByRemount.values {
            unavailable[name] = RemountOutcome.mountFailedReason
        }
    }

    /// 列挙の前（before）と列挙の直後（after）の statfs が同じマウントか（F-81）。f_mntonname と f_mntfromname を
    /// スカラー列で比べる（00-api-map §0）。列挙の前に statfs が取れなかった（規則 4 だけで通した）ときは、列挙の後も
    /// 取れないときだけ同じとみなす（観測値を nil のまま載せる従来の扱い。DEL-32。本番の MountInspector は規則 4 も
    /// statfs で見るので、statfs が取れなければ列挙まで来ない）
    static func sameMount(_ before: MountInfo?, _ after: MountInfo?) -> Bool {
        guard let before else { return after == nil }
        guard let after else { return false }
        return PyText.scalarsEqual(before.mountOnName, after.mountOnName)
            && PyText.scalarsEqual(before.mountFromName, after.mountFromName)
    }

    /// 最大 130 回試し、試行の間に 1 秒待つ（待ちは最大 129 回）。取れなければ nil（この回を見送る）
    func acquireReaperLock() async -> FileLock? {
        for attempt in 1...Self.lockAttempts {
            if let lock = FileLock.tryAcquire(url: deps.layout.reaperLock) { return lock }
            if attempt == Self.lockAttempts || stopRequested { break }
            do { try await deps.sleeper.sleep(seconds: Self.lockRetrySeconds) } catch { break }
        }
        return nil
    }

    /// 公開は走査の最後に 1 回だけ
    func publish(
        _ observations: [String: DeviceObservation], _ unavailable: [String: String],
        _ notListableErrno: [String: Int32], copied: Int, elapsed: Duration
    ) {
        generation += 1
        // 前回が無いのは「0 台」と同じ扱い（voicedock の None と同じ）
        let previousEmpty = snapshot?.devices.isEmpty ?? true
        if previousEmpty && !observations.isEmpty { connectEpoch += 1 }
        snapshot = DeviceSnapshot(
            generation: generation, completedAt: deps.clock.now(), connectEpoch: connectEpoch, devices: observations,
            unavailable: unavailable, notListableErrno: notListableErrno)
        previousUnavailable = unavailable
        let c = elapsed.components
        let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
        let fields: [(LogKey, LogValue)] = [
            (.devices, .of(observations.count)), (.copied, .of(copied)),
            (.elapsedS, .double(PyRound.round(seconds, digits: 1))),
        ]
        if copied > 0 {
            deps.log.info(.scanCompleted, fields)
        } else {
            deps.log.debug(.scanCompleted, fields)
        }
        setState(.idle)
        notifyUpdate()
    }

    /// minStart <= index の待ち手に generation を返して取り除く
    func finishWaiters(upTo index: UInt64, _ generation: UInt64?) {
        var rest: [(minStart: UInt64, continuation: CheckedContinuation<UInt64?, Never>)] = []
        for waiter in waiters {
            if waiter.minStart <= index {
                waiter.continuation.resume(returning: generation)
            } else {
                rest.append(waiter)
            }
        }
        waiters = rest
    }

    /// 値が変わったときだけ書き換えて知らせる
    func setState(_ newState: IngestState) {
        guard ingestState != newState else { return }
        ingestState = newState
        notifyUpdate()
    }

    func notifyUpdate() {
        for continuation in updateContinuations.values { continuation.yield(()) }
    }

    func removeContinuation(_ id: UUID) {
        updateContinuations[id] = nil
    }
}
