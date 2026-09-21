# T-14 VDDevice: ファイルの走査・安定性判定・コピー・登録（＋ VDAudio の AudioProbe）

| 項目 | 値 |
|---|---|
| ID | T-14 |
| Phase | 3（取り込み） |
| 前提 | T-11（`Store`・`NewRecording`・`RecordingField`・問い合わせ）、T-13（`DeviceReader` の列挙・`ErrnoError`・`FakeVolume.oldMtime` / `addNoise`・`ScriptedProcessRunner`）。T-10（`BlockingIO`・`AppLog`・`ZonedTime`・`SafeUnlink`・`FileHasher`・`FixedClock` ほか）、T-06（`RecordingName`・`PartKey`・`RelPath`・`HomeLayout`・`TempDirectory`）はその前提に含まれる。T-07（TestSupport の `FakeVolume` 本体）は T-13 が要る前提（README の索引への追加は T-13 のヘッダに記載） |
| 見積もり | 実装 約 600 行、テスト 約 700 行（TestSupport の `BWFWriter` を含む） |

## 1. 目的

判定を通ったデバイス 1 台について、ファイルを走査し、取り込みの候補を選び、安定性を判定し、1 本ずつ inbox へコピーして DB に登録する（PLAN §8.1 のファイルの走査・安定性判定・コピー）。
**本体（inbox の確定）が先、記録（DB）が後**の順序を守る（DEV-16・PT-16）。登録時の長さの測定に使う `AudioProbe`（VDAudio）もここで作る。
再マウント・snapshot の公開・走査の起動契機は T-15。

## 2. 参照

- PLAN §8.1（ファイルの走査・安定性判定・コピー）、§2.1（`BlockingIO`）、§2.3（inbox のパス）、§4.1・§4.2・§4.3、§5.7（ISO 文字列）、§7.2（recordings の列）、§8.3（`hashChunkBytes`）、付録 A.4（`part_discovered`・`copy_completed`・`copy_failed`・`file_not_stable`・`unparsable_filename`）、PT-10・PT-12・PT-16
- voicedock@d3d595e: `helper/voicedock-ingest:319-518`（`_scan_dir`・`_sample_all`・`check_stability`・`copy_candidates`）、`src/voicedock/discover.py:120-190`（`_ended_at`：`(started_at + timedelta(seconds=duration)).isoformat(timespec="seconds")`）、
  `tests/unit/test_helper_ingest.py:118-256, 618-673`、`tests/fixtures/fake_tree.py`、`tests/fixtures/make_wav.py`
- 移植メモ V1 §6.2〜§6.4、V4 §4.2

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDDevice/DeviceReader.swift` | （T-13 のファイルに追記）`FileStat`、`ScanListing`、`CopyError`、`ChunkReading`、`DeviceFileHandle`、`scan`・`stat`・`openForCopy`・`fullPath` |
| `Sources/VDDevice/InboxWriter.swift` | `InboxWriter` |
| `Sources/VDDevice/StabilityChecker.swift` | `StabilityChecker` |
| `Sources/VDDevice/IngestDependencies.swift` | `IngestDependencies`（T-15 がフィールドを 2 つ足す） |
| `Sources/VDDevice/IngestService.swift` | `IngestService` actor の骨組みと、1 台分の取り込み（`ingestDevice`・`selectCandidates`・`copyOne`・`registerCopied`） |
| `Sources/VDAudio/AudioProbe.swift` | `AudioProbe` |
| `Tests/TestSupport/BWFWriter.swift` | 実機と同じ BWF を作る（作り手は T-14。T-16・T-18 も使う。00-api-map §15） |
| `Tests/TestSupport/FakeChunkReader.swift` | `ChunkReading` の差し替え（読み取りエラー・短い読み取り） |
| `Tests/VDDeviceTests/DeviceReaderScanTests.swift` | |
| `Tests/VDDeviceTests/InboxWriterTests.swift` | |
| `Tests/VDDeviceTests/StabilityCheckerTests.swift` | |
| `Tests/VDDeviceTests/IngestCopyTests.swift` | |
| `Tests/VDAudioTests/AudioProbeTests.swift` | |
| `Tests/VDAudioTests/BWFWriterTests.swift` | 偽物そのもののテスト（TEST-05。voicedock の make_wav とのバイト一致） |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 5 キーを消す（§5.7） |

## 4. 仕様

### 4.1 `DeviceReader.swift` への追記

```swift
/// デバイス上の原本の size と mtime（DEL-12: 必ず原本の値。inbox のコピーの値を入れない）
public struct FileStat: Equatable, Hashable, Sendable {
    public let size: Int64
    public let mtime: Double        // st_mtimespec.tv_sec + tv_nsec / 1e9
    public init(size: Int64, mtime: Double)
}

public struct ScanListing: Equatable, Sendable {
    public let relpaths: Set<String>        // ファイル規則に一致し日時も正しい通常ファイル（_orig も denoised も）
    public let origCandidates: [String]     // そのうち _orig（UTF-8 のバイト順）
    public let unparsable: [String]         // 規則の形には一致するが日時が不正・relpath が不健全（バイト順）
    public let complete: Bool               // 走査中に 1 つでも列挙に失敗したら false
    static let incomplete = ScanListing(relpaths: [], origCandidates: [], unparsable: [], complete: false)   // internal（地図に無い。モジュールの中だけで使う）
    public init(relpaths: Set<String>, origCandidates: [String], unparsable: [String], complete: Bool)
}

public enum CopyError: Error, Equatable, Sendable {
    case changed                // 開いた原本の size / mtime が安定性判定の値と違う・通常ファイルでない
    case readError(Int32)       // 原本を開けない・読めない（抜かれた等）
    case sizeMismatch           // 書いたバイト数が size と違う
    case writeError(Int32)      // inbox 側の作成・書き込み・fsync・rename・DB 登録の失敗
    /// copy_failed の reason 語（付録 A.4）
    public var reason: String {
        switch self {
        case .changed: "changed"
        case .readError: "read_error"
        case .sizeMismatch: "copy_size_mismatch"
        case .writeError: "write_error"
        }
    }
}

/// 塊で読む元（DeviceFileHandle と、テストの FakeChunkReader）
public protocol ChunkReading {
    /// 最大 maxBytes を読む。空の Data は終わり
    func read(maxBytes: Int) throws(ErrnoError) -> Data
}

/// デバイス上の原本の読み取り専用の fd。BlockingIO の閉包の中で作って使い、外へ出さない（Sendable にしない）
public final class DeviceFileHandle: ChunkReading {
    public func read(maxBytes: Int) throws(ErrnoError) -> Data
    func close()                   // internal。2 回呼んでもよい
    deinit                         // 閉じていなければ閉じる
}

extension DeviceReader {
    func fullPath(volumeRoot: String, relpath: String) -> String   // internal（地図に無い。モジュールの中だけで使う）
    public func scan(volumeRoot: String, maxDepth: Int) -> ScanListing
    public func stat(volumeRoot: String, relpath: String) -> FileStat?
    public func openForCopy(volumeRoot: String, relpath: String, expected: FileStat) -> Result<DeviceFileHandle, CopyError>
}
```

- `fullPath`: `URL(fileURLWithPath: volumeRoot, isDirectory: true).appendingPathComponent(relpath, isDirectory: false).path(percentEncoded: false)`（文字列の連結で `/` を挟まない。PT-06）
- `FileStat` の作り方（internal `init(_ st: stat)`）: `size = Int64(st.st_size)`、`mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000`
- `stat(volumeRoot:relpath:)`: `lstat(fullPath, &st)` が失敗 → nil。`S_IFREG` でない（symlink を含む）→ nil。それ以外は `FileStat(st)`

`scan(volumeRoot:maxDepth:)` の手順（voicedock-ingest:321-352 と同じ深さ。**symlink は辿らない**）:
```text
relpaths = [], orig = [], unparsable = [], complete = true
walk(dir = volumeRoot, prefix = [], remaining = maxDepth)
walk(dir, prefix, remaining):
  if remaining < 1: return
  names = listEntries(of: dir)；失敗 → complete = false; return
  for name in names（バイト順）:
    if name が "." で始まる: continue                        // .Trashes・._*・.Spotlight-V100（DEV-09）。ログも出さない
    child = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(name, isDirectory: false).path(percentEncoded: false)
    components = prefix + [name]
    switch entryKind(child):
      .directory:   walk(child, components, remaining - 1)    // フォルダ規則を見ずに全部降りる
      .regularFile:
        if !RecordingName.matchesFilePattern(name): continue // NOTES.txt など。黙って無視
        rel = RelPath.join(components)
        parsed = RecordingName.parseFile(name)
        if !RelPath.isSafe(rel) || parsed == nil: unparsable.append(rel); continue
        relpaths.insert(rel)
        if parsed.isOrig: orig.append(rel)                   // Swift では `guard let parsed = … else { … }` で書き、強制アンラップを使わない
      それ以外（symlink・other・missing）: continue
return ScanListing(relpaths, orig をバイト順に並べたもの, unparsable をバイト順に並べたもの, complete)
```
- 深さ: ルート直下のファイルが 1 階層目。`maxDepth = 3` なら `root/a/b/file` まで、`root/a/b/c/file` は見ない
- `complete == false` の走査は、そのデバイスの relpath の一覧として**信用しない**（T-15 がそのデバイスを snapshot の `devices` に入れず `unavailable` に `not_listable` で載せる。一覧に載っていないことを「消えた」と誤読させないため）

`openForCopy(volumeRoot:relpath:expected:)`:
1. `fd = open(fullPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)`。負なら `.failure(.readError(errno))`（symlink は `ELOOP`）
2. `fstat(fd, &st)` が失敗 → `close(fd)`、`.failure(.readError(errno))`
3. `S_IFREG` でない → `close(fd)`、`.failure(.changed)`
4. `FileStat(st) != expected` → `close(fd)`、`.failure(.changed)`
5. `.success(DeviceFileHandle(fd: fd))`（internal init）

`DeviceFileHandle.read(maxBytes:)`:
```swift
var buffer = Data(count: maxBytes)
while true {
    let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, maxBytes) }
    if n >= 0 { buffer.count = n; return buffer }
    if errno == EINTR { continue }
    throw ErrnoError(errno)
}
```
- 閉じた後に `read` が呼ばれたら `ErrnoError(EBADF)` を投げる

### 4.2 `InboxWriter.swift`

```swift
// デバイスから読んだ原本を inbox の .partial へ書き、確定する（PLAN §8.1 コピー）。デバイスには書かない。
public struct InboxWriter: Sendable {
    public init(layout: HomeLayout)
    /// .partial を作って source を最後まで写し、SHA-256（小文字 16 進 64 文字）を返す。失敗したら .partial を消す
    public func writePartial(from source: any ChunkReading, expectedSize: Int64, partial: URL, chunkBytes: Int) -> Result<String, CopyError>
    /// .partial を最終の名前へ rename して確定する。失敗したら .partial を消す
    public func commitPartial(_ partial: URL, to final: URL) -> Result<Void, CopyError>
    /// .partial を消す（無ければ何もしない。失敗は無視する）
    public func discardPartial(_ partial: URL)
}
```

`writePartial` の手順:
1. `FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)`。投げたら `.failure(.writeError(EIO))`
2. `fd = open(partial.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o644)`。負なら `.failure(.writeError(errno))`
3. `var hasher = SHA256()`、`var total: Int64 = 0`
4. 繰り返し:
   - `chunk = try source.read(maxBytes: chunkBytes)`。投げたら `close(fd)` → `discardPartial` → `.failure(.readError(e.code))`（`ErrnoError` の欄は `code`。T-13）
   - `chunk.isEmpty` なら抜ける
   - `hasher.update(data: chunk)`
   - `chunk` を全部書く（`write` の部分書き込みは残りを続けて書く。`EINTR` は再試行）。`-1` なら `close(fd)` → `discardPartial` → `.failure(.writeError(errno))`
   - `total += Int64(chunk.count)`
5. `fsync(fd) != 0` → `close(fd)` → `discardPartial` → `.failure(.writeError(errno))`
6. `close(fd)`
7. `total != expectedSize` → `discardPartial` → `.failure(.sizeMismatch)`
8. `.success(hasher.finalize().map { String(format: "%02x", $0) }.joined())`

`commitPartial`: `rename(partial.path(percentEncoded: false), final.path(percentEncoded: false)) == 0` なら `.success(())`。そうでなければ `let e = errno` → `discardPartial` → `.failure(.writeError(e))`（既存の最終ファイルは rename が置き換える。needs_recopy の再コピーはこれで上書きする）

`discardPartial`: `try? SafeUnlink.remove(partial, under: .inbox, layout: layout, missingOK: true)`（inbox の外や symlink は SafeUnlink が拒否する。CR-10）

- 原本を読むのは 1 回だけ（コピーと SHA-256 を同時に。USB を 2 回読まない）
- デバイス上のファイルは `source` から読むだけで、パスを受け取らない

### 4.3 `StabilityChecker.swift`

```swift
// 安定性判定（PLAN §8.1。voicedock-ingest:354-431 の check_stability と同じ結果）。待ちはファイル数に比例しない（DEV-14）。
public struct StabilityChecker: Sendable {
    public init(config: DeviceConfig, clock: any AppClock, sleeper: any Sleeper)
    /// candidates のうち安定と判定したものを、最後に観測した FileStat と一緒に返す
    public func stableCandidates(_ candidates: [String], stat: @escaping @Sendable (String) -> FileStat?) async -> [String: FileStat]
}
```

手順:
```text
if candidates が空: return [:]                                        // 待たない
samples = await sample(candidates)                                   // [relpath: FileStat?]。BlockingIO.run で一括
nowSeconds = Double(clock.now().epochMillis) / 1000
ok = [:]
for r in candidates:
  if let s = samples[r], s.mtime <= nowSeconds - Double(config.stabilityFastPathSeconds): ok[r] = checks   // fast path（等号を含む）
  else: ok[r] = 0
if ok の値がすべて checks: return 最新の samples が nil でないものだけ
repeat checks 回（checks = config.stabilityChecks）:
  saved = samples
  do { try await sleeper.sleep(seconds: config.stabilityIntervalSeconds) } catch { return [:] }   // 止められたらこの回は見送り
  samples = await sample(candidates)                                 // 毎回 全候補を取り直す（voicedock と同じ）
  for r in candidates where ok[r] < checks:
    if let cur = samples[r], let prev = saved[r], cur == prev: ok[r] += 1 else: ok[r] = 0
return [r: samples[r] for r in candidates where ok[r] >= checks and samples[r] != nil]   // 最後に観測した値
```
- `sample(_:)`: `await (try? BlockingIO.run { Dictionary(uniqueKeysWithValues: candidates.map { ($0, stat($0)) }) }) ?? [:]`
- 1 度でも不一致なら 0 に戻り、残りの回数では `checks` に届かないので、この回は見送りになる（「ちょうど checks 回回す」）
- 安定しなかったものは呼び手（`ingestDevice`）が `file_not_stable relpath=…`（DEBUG）を出す

### 4.4 `IngestDependencies.swift`

```swift
public struct IngestDependencies: Sendable {
    public let layout: HomeLayout
    public let configProvider: @Sendable () async -> AppConfig?   // 設定エラー中は nil
    public let store: Store
    public let inspector: any MountInspector
    public let reader: DeviceReader
    public let coexistence: CoexistenceGuard
    public let clock: any AppClock
    public let sleeper: any Sleeper
    public let zone: ZonedTime
    public let log: AppLog
    public let volumesRoot: String                                // 本番は Contract.volumesRoot。テストは必ず一時ディレクトリ
    public init(layout:configProvider:store:inspector:reader:coexistence:clock:sleeper:zone:log:volumesRoot:)   // 引数はこの順（T-15 が inspector の後に 2 つ挿む）
}
```
- T-15 が `remounter: any Remounter` と `mountEvents: any MountEventSource` を `inspector` の後に足す（フィールドと初期化子の引数の最終の並びは 00-api-map §5 の順: `layout, configProvider, store, inspector, remounter, mountEvents, reader, coexistence, clock, sleeper, zone, log, volumesRoot`）

### 4.5 `IngestService.swift`（T-14 が作る部分）

```swift
// デバイス → inbox の取り込み（PLAN §8.1）。長い同期 I/O は BlockingIO で行い、actor は状態だけを持つ（§2.1）。
public actor IngestService {
    let deps: IngestDependencies
    // 進捗（T-15 が IngestActivity にまとめる）
    var progressDeviceID: String? = nil
    var progressCopied: Int = 0
    var progressTotal: Int = 0
    var lastActivityAt: Instant? = nil
    var stopRequested = false          // T-15 の stop() が立てる

    public init(deps: IngestDependencies) { self.deps = deps }

    /// 1 台分: 走査 → 候補の選択 → 安定性判定 → コピー。T-15 の走査がデバイスごとに呼ぶ
    func ingestDevice(deviceID: String, mountPath: String, config: AppConfig) async -> DeviceIngestResult
    func selectCandidates(deviceID: String, origRelpaths: [String]) throws -> CandidateSelection
    func copyOne(deviceID: String, mountPath: String, relpath: String, stat: FileStat, recopyRow: RecordingRow?, config: AppConfig) async -> CopyOutcome
    func registerCopied(partkey: String, deviceID: String, relpath: String, parsed: ParsedFile, stat: FileStat, sha256: String, final: URL, duration: Double?, recopyRow: RecordingRow?) throws -> Bool   // 新規なら true
    static func durationMillis(_ seconds: Double) -> Int64
}

struct DeviceIngestResult: Equatable, Sendable { let listing: ScanListing; let copied: Int }
struct CandidateSelection: Equatable, Sendable { let candidates: [String]; let recopyRows: [String: RecordingRow] }   // key = relpath
enum CopyOutcome: Equatable, Sendable { case copied(isNew: Bool), failed(CopyError), skipped }
```

`ingestDevice(deviceID:mountPath:config:)`:
1. `listing = await (try? BlockingIO.run { reader.scan(volumeRoot: mountPath, maxDepth: config.device.maxScanDepth) }) ?? .incomplete`（`reader = deps.reader` を先に let で取る）
2. `listing.unparsable` の各 relpath について `unparsable_filename relpath=<rel>`（DEBUG）
3. `selection = try selectCandidates(deviceID:origRelpaths: listing.origCandidates)`。投げたら `copy_failed reason=write_error`（WARNING、`recording_key` は付けない）を出し、`DeviceIngestResult(listing: listing, copied: 0)` を返す
4. `stable = await StabilityChecker(config: config.device, clock: deps.clock, sleeper: deps.sleeper).stableCandidates(selection.candidates, stat: { rel in reader.stat(volumeRoot: root, relpath: rel) })`（`root = mountPath`）
5. `selection.candidates` のうち `stable[rel] == nil` のものに `file_not_stable relpath=<rel>`（DEBUG）
6. `progressDeviceID = deviceID`、`progressTotal += stable.count`
7. `stable` のキーをバイト順に並べ、1 つずつ: `stopRequested` なら抜ける。`copyOne(…, stat: stable[rel], recopyRow: selection.recopyRows[rel], config: config)` が `.copied` なら `copied += 1`
8. `DeviceIngestResult(listing: listing, copied: copied)`

`selectCandidates(deviceID:origRelpaths:)`（取り込みの候補。PLAN §8.1 安定性判定の 1）:
1. 各 relpath に `PartKey.make(deviceID:relpath:)`（投げたら飛ばす）。`keyOf[relpath] = partkey`
2. `known = try deps.store.knownPartkeys(Array(keyOf.values))`
3. `recopy = try deps.store.recordingsNeedingRecopy().filter { $0.deviceID == deviceID }` を partkey で引ける辞書に
4. `imported = try deps.store.importedKeys()`
5. `candidates = origRelpaths.filter { k = keyOf[$0]; k != nil && (!known.contains(k) || recopy[k] != nil) && !imported.contains(k) }`（順序は入力のまま）
6. `recopyRows[relpath] = recopy[k]`（在るものだけ）

`copyOne(deviceID:mountPath:relpath:stat:recopyRow:config:)`（**この本体の中で `commitPartial(` を `registerCopied(` より前に書く。PT-16**）:
1. `guard let partkey = try? PartKey.make(deviceID: deviceID, relpath: relpath), let parsed = RecordingName.parseFile(RelPath.lastComponent(relpath)) else { return .skipped }`
2. `final = deps.layout.inboxFile(deviceID: deviceID, relpath: relpath)`、`partial = deps.layout.inboxPartial(deviceID: deviceID, relpath: relpath)`（`.<name>.partial`）
3. 読み取りと書き込み:
   ```swift
   let reader = deps.reader, writer = InboxWriter(layout: deps.layout), root = mountPath, chunk = config.audio.hashChunkBytes
   let written: Result<String, CopyError> = (try? await BlockingIO.run {
       switch reader.openForCopy(volumeRoot: root, relpath: relpath, expected: stat) {
       case .failure(let e): return .failure(e)
       case .success(let handle):
           defer { handle.close() }
           return writer.writePartial(
               from: handle, expectedSize: stat.size, partial: partial, chunkBytes: chunk)
       }
   }) ?? .failure(.readError(EIO))
   ```
   失敗なら `logCopyFailed(partkey, error)` → `.failed(error)`
4. `committed = (try? await BlockingIO.run { writer.commitPartial(partial, to: final) }) ?? .failure(.writeError(EIO))`。失敗なら `logCopyFailed` → `.failed`
5. `duration = (try? await BlockingIO.run { AudioProbe.durationSeconds(of: final) }) ?? nil`（有限でない値は nil にする）
6. `isNew = try registerCopied(…)`。投げたら `logCopyFailed(partkey, .writeError(EIO))` → `.failed(.writeError(EIO))`（inbox の最終ファイルは残る。行が無いので次の起動で inbox の孤児として消え、次の走査で再コピーされる）
7. ログ（新規のときだけ）: `part_discovered recording_key=<partkey> duration_s=<duration か null>`、duration が nil なら続けて `error_code=AUDIO_PROBE_FAILED`（`ErrorCode.audioProbeFailed.rawValue` を渡す。文字列で書かない。PT-06）（INFO）
8. `copy_completed recording_key=<partkey> bytes=<stat.size> recopy=<!isNew>`（INFO）
9. `progressCopied += 1`、`lastActivityAt = deps.clock.now()` → `.copied(isNew: isNew)`

`logCopyFailed(partkey, error)`: `copy_failed recording_key=<partkey> reason=<error.reason>`。（実装で変更）`errno=<n>` は足さない（`LogKey` に `errno` が無く、付録 A.4 の `copy_failed` のフィールドにも無い。§10 の提案 10）。レベルは `changed` だけ INFO、ほかは WARNING

`registerCopied(…)`:
1. `guard let inboxRel = deps.layout.relativePath(of: final) else { throw CopyError.writeError(EINVAL) }`
2. `recopyRow != nil` なら: `try deps.store.updateRecording(partkey, [.inboxPath(inboxRel), .sha256Helper(sha256), .sourceSize(stat.size), .sourceMtime(stat.mtime), .needsRecopy(false)])` → `false` を返す（状態は変えない。PLAN §5.4 の契機 4 が再評価する）
3. そうでなければ:
   ```swift
   let start = deps.zone.instant(of: parsed.local)          // ファイル名の時刻にタイムゾーンを付与するだけ（TIME-03）
   let endedAt = duration.map { deps.zone.iso(start.adding(milliseconds: Self.durationMillis($0))) }
   try deps.store.insertRecording(NewRecording(
       partkey: partkey, deviceID: deviceID, sourceFolder: RelPath.parent(relpath),
       transmitterID: parsed.transmitterID, micIndex: parsed.micIndex,
       startedAt: deps.zone.iso(start), durationSeconds: duration, endedAt: endedAt,
       sourcePath: relpath, sourceSize: stat.size, sourceMtime: stat.mtime,
       sha256Helper: sha256, inboxPath: inboxRel))
   ```
   → `true`
- `durationMillis(s)`: `Int64((s * 1_000_000).rounded(.toNearestOrEven)) / 1000`（Python の `timedelta(seconds=s)` は µ 秒に偶数丸めし、`isoformat(timespec="seconds")` は切り捨てる。ms へは切り捨てで落とす）
- `source_size` / `source_mtime` は**原本の stat の値**（`stat` 引数。安定性判定の最後の観測。DEL-12）。inbox のコピーを stat しない

### 4.6 `Sources/VDAudio/AudioProbe.swift`

```swift
// 音声ファイルの長さ（秒）を調べる（PLAN §8.1 の登録。voicedock の ffprobe の代わり）。
import AVFoundation
public enum AudioProbe {
    /// AVAudioFile で開き length / fileFormat.sampleRate。開けない・sampleRate が 0 以下なら nil
    public static func durationSeconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0 else { return nil }
        let seconds = Double(file.length) / rate
        return seconds.isFinite ? seconds : nil
    }
}
```

### 4.7 TestSupport

#### `BWFWriter.swift`（作り手は T-14。T-16 に書いた版（voicedock `tests/fixtures/make_wav.py` とのバイト一致を確かめたもの）を正としてここへ移した。00-api-map §15）

voicedock `tests/fixtures/make_wav.py` と**同じバイト列**を作る（ASR-15。実機の BWF と同じ構成で、ヘッダ約 32 KB）。T-16（変換のテスト）・T-18 も使う。

```swift
// テスト用の BWF（PLAN §10.2。voicedock tests/fixtures/make_wav.py と同じバイト列）。
import Foundation

public enum BWFFormat: String, Sendable, CaseIterable { case pcm24, float32, pcm16 }
public enum BWFContent: String, Sendable { case silence, speech }
public enum BWFError: Error, Equatable { case nonPositiveSeconds }

public enum BWFWriter {
    public static let sampleRate = 48_000
    public static let channels = 1
    public static let bextSize = 602
    public static let ixmlSize = 1_092
    public static let cueSize = 28
    public static let bwfHeaderBytes = 32_776
    public static let minimalHeaderBytes = 44
    /// 32776 − (12 + 8 × 5 + 16 + 602 + 1092 + 28 + 8) = 30978
    public static let padSize = 30_978

    public static func sampleWidth(_ f: BWFFormat) -> Int          // pcm16 2, pcm24 3, float32 4
    public static func byteRate(_ f: BWFFormat, sampleRate: Int = 48_000) -> Int
    public static func build(seconds: Double, format: BWFFormat = .pcm24, content: BWFContent = .silence,
                             minimalHeader: Bool = false, toneHz: Double = 220, sampleRate: Int = 48_000) throws(BWFError) -> Data
    @discardableResult
    public static func write(to url: URL, seconds: Double, format: BWFFormat = .pcm24, content: BWFContent = .silence,
                             minimalHeader: Bool = false, toneHz: Double = 220, sampleRate: Int = 48_000) throws -> URL
}
```

手順（make_wav.py の逐語の移植。演算の順序を変えない）:
- `seconds <= 0` → `BWFError.nonPositiveSeconds`
- `frames = Int((Double(sampleRate) * seconds).rounded(.toNearestOrEven))`（Python の `round`）
- 標本 `samples(frames:content:toneHz:sampleRate:) -> [Double]`（internal）:
  - silence → `0.0` を frames 個
  - speech → `period = 0.8 + 0.4`（**リテラル 1.2 と書かない**。浮動小数の和の値を使う）。各 `index` で `t = Double(index) / Double(sampleRate)`、`t.truncatingRemainder(dividingBy: period) >= 0.8` なら `0.0`、
    そうでなければ `angle = 2.0 * Double.pi * toneHz * t`、`0.1 * (sin(angle) + 0.5 * sin(2 * angle) + 0.25 * sin(4 * angle))`
- 量子化（リトルエンディアン）:
  - float32 → `Float(v)` の `bitPattern.littleEndian` の 4 バイト
  - pcm16 → `Int16(max(-1.0, min(1.0, v)) * 32767.0)`（`Int16(Double)` は 0 方向へ切り捨て）の 2 バイト
  - pcm24 → `Int32(max(-1.0, min(1.0, v)) * 8388607.0)` の下位 3 バイト（LE。負数は 2 の補数のまま）
- チャンク `chunk(id, payload)`: `id`（4 バイト ASCII）＋ `UInt32(payload.count)` LE ＋ payload ＋（奇数長なら `0x00` 1 バイト。サイズ欄に含めない）
- `fmt `: `tag`（float32 は 3、それ以外 1）・`channels`・`sampleRate`・`byteRate`・`width × channels`・`width × 8` を `<HHIIHH`（LE）で 16 バイト
- minimalHeader でなければ `fmt ` の後に `bext`（602 バイトの 0）、`iXML`（`<BWFXML></BWFXML>` の後を空白 0x20 で 1092 バイトまで埋める）、`cue `（28 バイトの 0）、`PAD `（30978 バイトの 0）
- 全体 = `"RIFF"` ＋ `UInt32(4 + body.count)` LE ＋ `"WAVE"` ＋ body（チャンクの連結 ＋ `data` チャンク）
- `write` は親ディレクトリを作ってから `Data.write(to:)`（TestSupport は PT の対象外）
- 本チケットのテストの長さ: pcm24 の 1.5 秒は 72000 フレーム → 32776 + 216000 = 248,776 バイト、2.0 秒は 320,776 バイト

#### `FakeChunkReader.swift`
```swift
/// ChunkReading の差し替え。bytes を chunk ごとに返し、failAfterChunks 回読んだ後は ErrnoError(failErrno) を投げる
public final class FakeChunkReader: ChunkReading {
    public init(bytes: Data, failAfterChunks: Int? = nil, failErrno: Int32 = EIO)
    public private(set) var requestedSizes: [Int]
    public func read(maxBytes: Int) throws(ErrnoError) -> Data
}
```

## 5. テスト

### 5.0 安全の約束（全テスト共通。必ず守る）

- **テストは `/Volumes` の実機に触れない。**利用者の DJI Mic 3 が `/Volumes/DJIMIC3`（`/dev/disk4`、msdos）にマウントされていることがある。テストが `/Volumes` 配下に対して diskutil（unmount / mount / 再マウント）・書き込み・削除を行うことを禁じる
- デバイス判定・走査・コピーのテストの volumesRoot は**必ず一時ディレクトリ**（`FakeVolume` の `<tmp>/Volumes`）。本番の `Contract.volumesRoot`（`/Volumes`）は `Bootstrap` が注入するだけで、テストでは使わない
- `SystemMountInspector` のテストは読み取りだけ（`/` の statfs・getmntinfo・ボリューム名）。一覧に実機が含まれていても、その項目に対して何もしない
- 共存ガードは `ScriptedProcessRunner` で試し、本物の launchctl を動かさない
- ディスクイメージを使うテスト（T-15 の `.diskImage`）は `/Volumes` 以外に attach する（T-15 §5.0）

共通: `TempDirectory()`、`HomeLayout(root: tmp/home)` に `createDirectories()`、`FixedClock(epochMillis: 1_790_000_000_000)`（2026-09-21T13:33:20Z）、`ZonedTime(timeZone: Asia/Tokyo)`、
`Store(url: layout.database, clock:, zone:)`、ログは TestSupport の `CapturingLogSink`（T-10）で DEBUG まで取る。

### 5.1 `DeviceReaderScanTests.swift`（`@Suite("DeviceReader の走査")`）
| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `listsOrigAndDenoised` / 「_orig も denoised も relpaths に載り、候補は _orig だけ」 | 既定の木（下記 5.4） | relpaths = 4 件（`…120950_orig.wav`・`…163444_orig.wav`・`…163444.wav`・`…090000.wav`）、origCandidates = 2 件（バイト順） |
| `dotEntriesAreIgnoredSilently` / 「`.` で始まるものは無視し unparsable にも入れない」 | `addNoise` | relpaths に `.Trashes`・`._` を含むものが無い、unparsable が空 |
| `nonRecordingFilesAreIgnored` / 「NOTES.txt は無視する」 | `NOTES.txt` | relpaths にも unparsable にも無い |
| `invalidDateIsUnparsable` / 「形は一致するが日時が不正なら unparsable」 | `TX_MIC001_20260912_120950/TX00_MIC001_20260230_120950_orig.wav` | unparsable = その relpath、relpaths に無い |
| `depthIsBounded` / 「CE device.maxScanDepth より深いファイルは見ない」 | `a/b/c/d/TX00_MIC009_20260101_000000_orig.wav` を maxDepth 2（既定の 3 でも届かない深さ）と maxDepth 5 | maxDepth 2 では relpaths に無く、5 では在る |
| `depthThreeReachesTwoFolders` / 「maxDepth 3 で root/a/b/file まで、root/a/b/c/file は見ない」 | 両方を置く | 前者だけ |
| `symlinksAreNotFollowed` / 「ファイルもディレクトリも symlink は辿らない」 | `TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav` へのファイルの symlink（別名）、フォルダの symlink | どちらも relpaths に無い |
| `rootLevelFileHasNoFolder` / 「ボリューム直下の録音の relpath はファイル名だけ」 | 直下に `TX00_MIC001_20260912_120950_orig.wav` | relpaths = その名前 |
| `unlistableSubdirectoryMakesIncomplete` / 「列挙できないサブディレクトリがあれば complete は偽」 | サブディレクトリを `chmod 000` | `complete == false` |
| `emptyVolumeIsCompleteAndEmpty` / 「録音 0 件のデバイスは空で complete（DEV-19）」 | フォルダだけ | relpaths 空、`complete == true` |
| `statReturnsFractionalMtime` / 「stat は原本の size と小数付きの mtime」 | mtime 1789214990.25 | `FileStat(size: n, mtime: 1789214990.25)` |
| `statOfSymlinkIsNil` / 「symlink と無いファイルの stat は nil」 | | nil |
| `openForCopyReadsBytes` / 「stat が一致すれば開けて全バイトを読める」 | | `.success`、読んだ内容が元と一致 |
| `openForCopyDetectsChange` / 「mtime か size が違えば changed」 | 期待値の mtime を +2 / size を +1 | `.failure(.changed)` |
| `openForCopyRejectsSymlink` / 「symlink は ELOOP の read_error」 | | `.failure(.readError(ELOOP))` |
| `openForCopyMissingIsENOENT` / 「無ければ ENOENT の read_error」 | | `.failure(.readError(ENOENT))` |

### 5.2 `InboxWriterTests.swift`（`@Suite("InboxWriter")`）
| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `writesPartialAndReturnsSHA` / 「.partial に書き SHA-256 を返す（まだ確定しない）」 | 100 KiB の既知のバイト、chunk 4096 | 戻り値 = `FileHasher.sha256(data)`、`.partial` が在り最終ファイルは無い |
| `commitRenamesToFinal` / 「確定で最終の名前になり .partial は消える」 | 続けて `commitPartial` | 最終ファイルの内容が一致、`.partial` が無い |
| `readErrorRemovesPartial` / 「読み取りエラーで .partial を消す（抜去）」 | `FakeChunkReader(failAfterChunks: 2)` | `.failure(.readError(EIO))`、`.partial` が無い |
| `shortReadIsSizeMismatch` / 「書いた量が size と違えば copy_size_mismatch で消す」 | 10 バイトを返す読み手、expectedSize 11 | `.failure(.sizeMismatch)`、`.partial` が無い |
| `readsInConfiguredChunks` / 「CE audio.hashChunkBytes ずつ読む」 | 同じ 100 KiB を chunk 1_048_576 と chunk 4096 で | `requestedSizes` がすべて 1_048_576 / すべて 4096（最後の端数を除く）。SHA-256 はどちらも同じ |
| `emptyFileHasEmptySHA` / 「0 バイトは空の SHA-256」 | 0 バイト、expectedSize 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `recopyOverwritesFinal` / 「既存の最終ファイルを確定で置き換える（再コピー）」 | 最終ファイルに別の内容を置いてから | 新しい内容 |

### 5.3 `StabilityCheckerTests.swift`（`@Suite("StabilityChecker")`）

`config.device` は既定（fast 60・interval 3・checks 2）。`stat` は台本（呼ばれた回ごとの値の表）を返す `@Sendable` の閉包。待ちは `RecordingSleeper`。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `emptyCandidatesDoNotWait` / 「候補 0 件は待たない（空の状態）」 | `[]` | `[:]`、sleeps `[]` |
| `oldFilesAreStableWithoutWaiting` / 「mtime が 60 秒以上前なら即安定（fast path）」 | mtime = now − 3600 | 全件、sleeps `[]` |
| `fastPathBoundaryIsInclusive` / 「ちょうど 60 秒前は fast path」 | mtime = now − 60 | 安定、sleeps `[]` |
| `newFileNeedsExactlyChecksRounds` / 「新しいファイルはちょうど checks 回（2 回）一致して安定」 | mtime = now、値は変わらない | 安定、sleeps `[3, 3]` |
| `changeInFirstRoundDefers` / 「1 回目で変われば見送り」 | 2 回目の観測で size +1 | 空 |
| `changeInLastRoundDefers` / 「最後の回で変われば見送り」 | 3 回目の観測で mtime +1 | 空 |
| `statFailureDefers` / 「stat が取れないものは見送り」 | 常に nil | 空 |
| `waitingDoesNotScaleWithFileCount` / 「25 件でも待ちは checks 回だけ（DEV-14）」 | 新しいファイル 25 件 | 全件安定、sleeps `[3, 3]` |
| `returnsLatestObservation` / 「返す FileStat は最後の観測」 | fast path の古いファイル 1 件と新しい 1 件。古い方の観測は 1 回目 A、以後 B | 古い方の値は B |
| `vanishedFastPathFileIsNotReturned` / 「fast path でも取り直しで消えていれば返さない」 | 古い 1 件（最初だけ値、以後 nil）と新しい 1 件 | 古い方は含まれない |
| `cancelledSleepReturnsNothing` / 「待ちが止められたらこの回は見送り」 | 投げる Sleeper | `[:]` |
| `checksOfOneNeedsOneRound` / 「CE device.stabilityChecks = 1 なら 1 回だけ待つ」 | checks 1、新しいファイル（既定の 2 なら 2 回） | sleeps `[3]` |
| `ceStabilityIntervalSeconds` / 「CE device.stabilityIntervalSeconds 5 にすると 5 秒ずつ待つ」 | interval 5、新しいファイル | 安定、sleeps `[5, 5]`（既定の 3 なら `[3, 3]`） |
| `ceStabilityFastPathSeconds` / 「CE device.stabilityFastPathSeconds 10 にすると 10 秒前でも即安定」 | fast 10、mtime = now − 10 | 安定、sleeps `[]`（既定の 60 では fast path に乗らず sleeps `[3, 3]`） |

### 5.4 `IngestCopyTests.swift`（`@Suite("IngestService の 1 台分の取り込み")`、`.serialized`）

既定の木（`FakeVolume` に `BWFWriter` の pcm24 を置く。mtime はすべて `FakeVolume.oldMtime`）:
- `TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav`（1.5 秒・発話。248,776 バイト）
- `TX_MIC001_20260912_163444/TX00_MIC001_20260912_163444_orig.wav`（2.0 秒・発話。320,776 バイト）と `TX_MIC001_20260912_163444/TX00_MIC001_20260912_163444.wav`（denoised）
- `TX_MIC002_20260913_090000/TX01_MIC003_20260913_090000.wav`（denoised だけ・1.0 秒・無音）

`IngestService(deps:)` を作り、`ingestDevice(deviceID: "DJIMIC3", mountPath: fake.root.path(percentEncoded: false), config: AppConfig.defaults(timeZone: "Asia/Tokyo"))` を呼ぶ。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `copiesOnlyOrig` / 「_orig だけをコピーする」 | 既定 | inbox に 2 ファイル（`inbox/DJIMIC3/TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav` と 163444 の _orig）、行は 2 件で DISCOVERED、`copied == 2` |
| `registeredRowIsExact` / 「登録した行の全列が仕様どおり」 | 既定 | 120950 の行: `device_id` DJIMIC3、`source_folder` `TX_MIC001_20260912_120950`、`transmitter_id` `TX00`、`mic_index` 1、`started_at` `2026-09-12T12:09:50+09:00`、`duration_seconds` 1.5、`ended_at` `2026-09-12T12:09:51+09:00`、`source_path` = relpath、`source_size` 248776、`source_mtime` = `FakeVolume.oldMtime`、`sha256_helper` = 原本の SHA-256、`inbox_path` = 上記の相対パス、`sha256` NULL、`needs_recopy` 0、`session_key` NULL |
| `sourceMtimeIsTheDeviceValue` / 「source_mtime はデバイス上の原本の値で inbox のコピーの時刻ではない（DEL-12）」 | 原本の mtime を `oldMtime`、コピー後の inbox の mtime は now 付近 | 行の `source_mtime == oldMtime`、inbox のファイルの mtime とは 16440 秒以上違う |
| `secondRunDoesNotRecopy` / 「2 回目は再コピーしない」 | 2 回呼ぶ | 2 回目 `copied == 0`、`copy_completed` は 2 行だけ |
| `needsRecopyRowIsRecopied` / 「needs_recopy の行は再コピーして印を 0 に戻し、状態は変えない」 | 1 回目の後、120950 の行に `.needsRecopy(true)`、inbox のファイルを壊れた内容で上書き | 2 回目: inbox の内容が原本と一致、`needs_recopy` 0、`sha256_helper` 一致、状態は DISCOVERED のまま、`copy_completed … recopy=true`、`part_discovered` は増えない |
| `importedKeyIsSkipped` / 「imported_keys の録音はコピーしない（§8.13）」 | 120950 の partkey を `insertImportedKeys` | 163444 だけコピー |
| `sourceDeviceIsNeverModified` / 「デバイス上のファイルは 1 バイトも変わらない」 | 前後で全ファイルの（relpath・size・mtime・SHA-256）を比べる | 一致、デバイスに新しいファイルが無い |
| `unstableFileIsDeferred` / 「書き込み中のファイルは見送る」 | 163444 の _orig の mtime を now にし、待つたびに 1 バイト足す Sleeper | 163444 はコピーされず行も無い、`file_not_stable relpath=TX_MIC001_20260912_163444/TX00_MIC001_20260912_163444_orig.wav`（DEBUG）、120950 はコピーされる |
| `changedAfterStabilityIsNotCopied` / 「安定性判定の後に変わった原本はコピーしない」 | `copyOne` を古い `FileStat`（mtime −10）で直接呼ぶ | `.failed(.changed)`、`copy_failed recording_key=… reason=changed`（INFO）、`.partial` も最終ファイルも行も無い |
| `probeFailureRegistersNullDuration` / 「長さが測れなくても NULL で登録する」 | 120950 の _orig の中身を `Data("not a wav".utf8)` にする | 行の `duration_seconds` と `ended_at` が NULL、`part_discovered recording_key=… duration_s=null error_code=AUDIO_PROBE_FAILED` |
| `rootLevelRecordingHasEmptyFolder` / 「ボリューム直下の録音は source_folder が空文字」 | 直下に `TX00_MIC001_20260912_120950_orig.wav` だけ | inbox は `inbox/DJIMIC3/TX00_…_orig.wav`、`source_folder` が `""` |
| `unparsableIsLoggedAndSkipped` / 「日時が不正な名前は unparsable_filename を出してコピーしない」 | `TX00_MIC001_20260230_120950_orig.wav` | DEBUG `unparsable_filename relpath=…`、行が無い |
| `emptyDeviceCopiesNothing` / 「録音 0 件のデバイスは何もコピーしない（空の状態）」 | フォルダだけ | `copied == 0`、`listing.relpaths` 空、`listing.complete == true` |
| `durationMillisMatchesPython` / 「長さのミリ秒変換は Python の timedelta と同じ」 | `durationMillis(1.5)`、`(1799.9996)`、`(0.0005)`、`(0.0015)` | 1500、1799999（µ 秒 1799999600 を ms に切り捨て）、0（µ 秒 500 → 0 ms）、1（µ 秒 1500 → 1 ms） |

### 5.5 `AudioProbeTests.swift`（`@Suite("AudioProbe")`）
| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `pcm24Duration` / 「48 kHz 24 bit の BWF の長さ」 | 1.5 秒 | 1.5（±0.000001） |
| `float32Duration` / 「32 bit float の BWF の長さ」 | 2.0 秒 | 2.0 |
| `minimalHeaderPCM16` / 「44 バイトヘッダ・16 kHz の長さ」 | pcm16・16 kHz・1.0 秒・minimalHeader | 1.0 |
| `garbageIsNil` / 「WAV でなければ nil」 | `"not a wav"` | nil |
| `missingIsNil` / 「無いファイルは nil」 | | nil |

### 5.6 `BWFWriterTests.swift`（`Tests/VDAudioTests/`。`@Suite("BWFWriter")`。TEST-05。T-16 に書いた版をここへ移した）

| 関数名 / 表示名 | 入力 | 期待 |
|---|---|---|
| `pcm24SpeechMatchesVoicedock` / 「pcm24 の発話 1 秒が voicedock の make_wav と同じバイト列」 | `build(seconds: 1, format: .pcm24, content: .speech)` | 長さ 176776、SHA-256 `e16eb9a53426118828d9d98c50caa3c4722db560e0c7d7bba81f236461fcc728` |
| `float32SpeechMatchesVoicedock` / 「float32 の発話 1 秒が同じバイト列」 | `.float32, .speech` | 長さ 224776、SHA-256 `b4873fc20687d19a1f16a79e6e7717b1cf8757f10b4f4f94f5a4803829c5e6aa` |
| `pcm16At16kMatchesVoicedock` / 「16 kHz の pcm16 が同じバイト列」 | `.pcm16, .speech, sampleRate: 16000` | 長さ 64776、SHA-256 `247a2cb88f5df09f85617402fa9f4550ce1201d4f4e47e5948afdbdaa97ee00a` |
| `minimalHeaderMatchesVoicedock` / 「44 バイトヘッダの無音が同じバイト列」 | `seconds: 0.5, .pcm24, .silence, minimalHeader: true` | 長さ 72044、SHA-256 `5fc6724ed1e828f823fb78ac79c4217d8551f0540fb2d9717b078ee752bc8cc3` |
| `pcm24SilenceTwoSecondsMatchesVoicedock` / 「2 秒の無音が同じバイト列」 | `seconds: 2, .pcm24, .silence` | 長さ 320776、SHA-256 `7b7dc0e1f420b6d4b524d0f5fc0112d353c12fd1d198c4c69e4ec20ae6671240` |
| `dataStartsAtBWFOffset` / 「data の開始が 32776」 | pcm24 1 秒 | バイト 32768〜32771 が `data`、`data` の先頭 24 バイトが 16 進 `000000d21a01003402ed4903005b04b265058b6806296207` |
| `headerBytes` / 「先頭 48 バイトが voicedock と同じ」 | pcm24 無音 1 秒 | 16 進 `5249464680b2020057415645666d7420100000000100010080bb00008032020003001800626578745a02000000000000` |
| `chunkOrder` / 「チャンクの並びと大きさ」 | pcm24 | `fmt `(16)・`bext`(602)・`iXML`(1092)・`cue `(28)・`PAD `(30978)・`data` の順 |
| `rejectsNonPositiveSeconds` / 「0 秒は作らない」 | `seconds: 0` | `BWFError.nonPositiveSeconds` |

期待値は voicedock@d3d595e の `make_wav.build_wav` を Python 3.12 で実行して得たもの（2026-09-18）。

### 5.7 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`device.maxScanDepth`・`device.stabilityFastPathSeconds`・`device.stabilityIntervalSeconds`・`device.stabilityChecks`・`audio.hashChunkBytes` の 5 行を消す（CE テストは §5.1・§5.2・§5.3）。

## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| `copyOne` で `registerCopied` を `commitPartial` より前に呼ぶ | PolicyTests の PT-16（T-04）、`registeredRowIsExact`（inbox_path の指すファイルが無い時点で登録される順序の確認は PT-16 が担う） |
| `registerCopied` の `sourceMtime` に inbox のファイルの mtime を入れる | `sourceMtimeIsTheDeviceValue` |
| `selectCandidates` で `needs_recopy` を無視する | `needsRecopyRowIsRecopied` |
| `selectCandidates` で `importedKeys` を無視する | `importedKeyIsSkipped` |
| `StabilityChecker` の fast path を `<` にする | `fastPathBoundaryIsInclusive` |
| `StabilityChecker` を候補ごとに待つ実装にする | `waitingDoesNotScaleWithFileCount` |
| 不一致で 0 に戻さず続ける | `changeInFirstRoundDefers` |
| `writePartial` の読み取りエラーで `discardPartial` を呼ばない | `readErrorRemovesPartial` |
| `scan` で `entryKind` の代わりに symlink を辿る `stat` を使う | `symlinksAreNotFollowed` |
| `scan` の `.` 始まりの除外を消す | `dotEntriesAreIgnoredSilently` |
| `openForCopy` から `O_NOFOLLOW` を外す | `openForCopyRejectsSymlink` |
| `durationMillis` を `(s * 1000).rounded()` にする | `durationMillisMatchesPython` |
| `BWFWriter` の pcm24 の量子化を `rounded()` にする | `pcm24SpeechMatchesVoicedock` |

## 7. 受け入れ条件

- [ ] `copyOne` の本体で `commitPartial(` が `registerCopied(` より前（PT-16 が通る）
- [ ] デバイス上のファイルを開くのは `DeviceReader.swift` だけで、`O_RDONLY | O_NOFOLLOW` のみ（PT-10）
- [ ] コピー・走査・stat の一括取得・probe はすべて `BlockingIO.run` の中（actor の中で長い同期 I/O をしない。§2.1）
- [ ] `source_size` / `source_mtime` は原本の stat の値
- [ ] テストは `/Volumes` の実機に触れない（5.0）。`mountPath` はテストで `FakeVolume` の一時ディレクトリ
- [ ] `BWFWriter` の出力の SHA-256 が voicedock の make_wav と一致する（5.6）
- [ ] 上記のテストがすべて緑、`make lint` が通る

## 8. SPEC の変更

なし（`copy_failed` の reason の `write_error`（付録 A.4・§8.1 コピーの 5）と、サブディレクトリの列挙に失敗した走査（`complete == false`）のデバイスを `not_listable` にすること（§8.1 ファイルの走査）は PLAN v1.1 に反映済み。F-48）

## 9. マージ後にやること

なし

## 10. API 地図への変更提案

1. `RecordingName.matchesFilePattern(_ name: String) -> Bool`（正規表現だけの一致。日時の妥当性は見ない）を VDContract に足す（`unparsable_filename` を出すため。T-06）→ 00-api-map に反映済み（2026-09-18）
2. `DeviceReader` に `fullPath(volumeRoot:relpath:)` と、`ScanListing` に `unparsable: [String]` と `complete: Bool`（と `static let incomplete`）を足す → `unparsable`・`complete` は 00-api-map に反映済み（2026-09-18）。`fullPath` と `incomplete` は地図に載らなかったので internal にした（モジュールの中だけで使う）
3. `CopyError` を `changed / readError(Int32) / sizeMismatch / writeError(Int32)` と `reason` で定義する。`DeviceFileHandle.read(maxBytes:)` は `throws(ErrnoError)`。`ChunkReading` プロトコルを足す → 00-api-map に反映済み（2026-09-18。`CopyError` の全ケースは本チケット。`DeviceFileHandle.close()` は internal）
4. `InboxWriter` の公開 API を `copy(…)` 1 つから `writePartial(from:expectedSize:partial:chunkBytes:)`・`commitPartial(partial:final:)`・`discardPartial(_:)` の 3 つに分ける（PT-16 が `IngestService.copyOne` の本体で `commitPartial(` と `registerCopied(` の順序を見るため、`commitPartial` を `copyOne` から直接呼ぶ必要がある）→ 00-api-map に反映済み（2026-09-18）。形は地図に合わせて `writePartial(from: any ChunkReading, …)`・`commitPartial(_ partial:, to final:)` にした
5. `StabilityChecker.stableCandidates` の `stat` を `@escaping @Sendable (String) -> FileStat?` にする（BlockingIO の閉包で一括取得するため）→ 00-api-map に反映済み（2026-09-18）
6. `IngestDependencies.configProvider` を `@Sendable () async -> AppConfig?` にする（`ConfigStore` は actor で、同期の閉包からは読めない）。フィールドの並びを 4.4 のとおりに固定し、T-15 が `remounter`・`mountEvents` を足す → 00-api-map に反映済み（2026-09-18）。並びは地図の順（`remounter`・`mountEvents` は `inspector` の後）に合わせた
7. `NewRecording` の初期化子を `init(partkey:deviceID:sourceFolder:transmitterID:micIndex:startedAt:durationSeconds:endedAt:sourcePath:sourceSize:sourceMtime:sha256Helper:inboxPath:)` に固定する（T-11）→ 00-api-map に反映済み（2026-09-18。init は T-11 で同じ形に固定）
8. `RelPath.parent` と `RelPath.lastComponent` は API 地図の追記どおり使う（直下のファイルの親は `""`）→ 00-api-map に反映済み（2026-09-18）
9. `BWFWriter` の作り手は T-14（T-16 の版を正とする）→ 00-api-map §15 に反映済み（2026-09-18）
10. （実装で追記）`LogKey` に `errno`（`case errno`）を足す（T-10 の `Log.swift`）。T-14 の `copy_failed` と T-15 の `volume_skipped … errno=<n>`（T-15 §4 の `recordSkip`）が使う。T-14 では `Log.swift` が §3 の表に無いため足さず、`copy_failed` に `errno` を出していない（付録 A.4 の `copy_failed` のフィールドは `recording_key`・`reason` だけなので、PLAN とは食い違わない）。T-15 では必要になる
11. （実装で追記）`DeviceReader.stat(volumeRoot:relpath:)` を足すと、型の中の `stat()`（Darwin の構造体の初期化）がこのメソッドに解決されるので、T-13 の `entryKind` の `var st = stat()` を `Darwin.stat()` に直した（振る舞いは同じ）
