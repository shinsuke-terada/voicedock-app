// デバイス → inbox の取り込み（PLAN §8.1）。長い同期 I/O は BlockingIO で行い、actor は状態だけを持つ（§2.1）。
import Darwin
import Foundation
import VDAudio
import VDContract
import VDCore
import VDStore

public actor IngestService {
    let deps: IngestDependencies
    // 進捗（T-15 が IngestActivity にまとめる）
    var progressDeviceID: String? = nil
    var progressCopied: Int = 0
    var progressTotal: Int = 0
    var lastActivityAt: Instant? = nil
    /// T-15 の stop() が立てる
    var stopRequested = false

    public init(deps: IngestDependencies) { self.deps = deps }

    /// 1 台分: 走査 → 候補の選択 → 安定性判定 → コピー。T-15 の走査がデバイスごとに呼ぶ
    func ingestDevice(deviceID: String, mountPath: String, config: AppConfig) async -> DeviceIngestResult {
        let reader = deps.reader
        let root = mountPath
        let depth = config.device.maxScanDepth
        let listing =
            await (try? BlockingIO.run { reader.scan(volumeRoot: root, maxDepth: depth) }) ?? .incomplete
        for rel in listing.unparsable {
            deps.log.debug(.unparsableFilename, [(.relpath, .string(rel))])
        }
        let selection: CandidateSelection
        do {
            selection = try selectCandidates(deviceID: deviceID, origRelpaths: listing.origCandidates)
        } catch {
            deps.log.warning(.copyFailed, [(.reason, .string(CopyError.writeError(EIO).reason))])
            return DeviceIngestResult(listing: listing, copied: 0)
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
        return DeviceIngestResult(listing: listing, copied: copied)
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
