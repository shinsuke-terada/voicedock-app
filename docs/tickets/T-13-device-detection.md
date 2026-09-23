# T-13 VDDevice: デバイス判定・マウント情報・共存ガード

> （F-81 のレビュー・issue #119。2026-09-23。利用者の決定）`detect()` は規則 1 で `notIncluded` にした名前だけに、続けて規則 2（exclude・ネットワークの FS）・3・4・5・6 を当て（規則 8・9 は見ない）、
> 全部通れば `DetectionResult.notIncludedDevices`（名前の UTF-8 バイト順。internal の init の既定値は `[]`）に入れる（internal の `looksLikeDevice(name:path:remote:)`）。取り込みにも削除にも使わず、
> 走査が snapshot の `unavailable` に `not_included` で載せて「はじめに」の⑤が改名を案内する（T-15・T-31 の注記）。テストは `DeviceDetectorNetworkTests`（バックアップのメモリ・`NO NAME`・`DJIMIC3 1`・対象にしないもの・ネットワークの FS・include が空）。

> （F-81・issue #119。2026-09-23）`detect()` は最初に `inspector.allMounts()`（`getmntinfo(MNT_NOWAIT)`。待たない）から `MNT_LOCAL` の立っていないマウント点を集め、
> 規則 2 の続きとしてそのパスを `excluded` で外す（規則 3 以降の lstat・statfs・realpath・ボリューム名は応答しないネットワーク共有で止まるので呼ばない。新しい理由語は足さない）。
> `MountInfo` に `isLocal: Bool`（`f_flags & MNT_LOCAL`。公開の init は既定値 true の引数）を足した。`DeviceID.isValid` の「`.` で始まる」は先頭のスカラーで見る。
> 既定の `includeVolumes` は `["DJIMIC3"]`（T-09 の注記）になったので、`DeviceDetectorTests` の舞台は規則 1 を素通りさせるため `includeVolumes = []` にした（下の表の「既定の `[]`」は記録として残す）。
> テストは `DeviceDetectorNetworkTests`（ネットワークの FS・既定の include・include のバイト列の照合）と `KeyScalarTests`（VDContract）。

> （F-61 で共存ガードは外した。2026-09-22、利用者の決定）`CoexistenceGuard` と `CoexistenceGuardTests` は消した。以下の本文の共存ガードの記述は記録として残す。

| 項目 | 値 |
|---|---|
| ID | T-13 |
| Phase | 3（取り込み） |
| 前提 | T-09（`DeviceConfig`）、T-12（`ProcessRunning` / `ProcessSpec` / `ProcessEnvironment`）。T-06（`RecordingName` / `DeviceID`・`TempDirectory`）・T-10（`AppLog` 等）は T-09 / T-12 の前提として入っている。**T-07（TestSupport の `FakeVolume`）**（README の索引の `T-07, T-09, T-12` と一致） |
| 見積もり | 実装 約 450 行、テスト 約 500 行（TestSupport を含む） |

## 1. 目的

`/Volumes` 直下のエントリから「取り込み対象のデバイス」を決める規則（PLAN §8.1 のデバイス判定 規則 1〜9）と、その判定に要るマウント情報の取得（statfs / getmntinfo / ボリューム名）、
voicedock の Helper との共存ガードを作る。デバイス上の**ディレクトリの列挙**は `DeviceReader`（T-14 が本体を作る）の `listEntries` と `entryKind`（と internal の `isSymlink`）だけをここで先に作る。

## 2. 参照

- PLAN §8.1（起動契機・デバイス判定・読み取り専用の確保の前半）、§4.1（`RecordingName`）、§4.2（`DeviceID.isValid`）、§6.2（`device.*`）、§9.4（PT-10・PT-12・PT-18）、付録 A.4（`volume_skipped`・`coexistence_blocked`）
- voicedock@d3d595e: `helper/voicedock-ingest:219-312`（`matches_any`・`_is_recording_folder`・`_is_recording_file`・`_has_recordings`・`detect_devices`）、`helper/install.sh:17, 289-290`（`com.voicedock.ingest`、`launchctl print`）、
  `tests/unit/test_helper_ingest.py:513-641`（include / exclude / symlink / no recordings / not listable の固定事例）、`tests/fixtures/fake_tree.py`（偽ボリュームの木）
- 移植メモ V1 §6.1・§6.5・§6.7

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDDevice/DevicePath.swift` | `DevicePath` |
| `Sources/VDDevice/ErrnoError.swift` | `ErrnoError`（errno を運ぶエラー） |
| `Sources/VDDevice/MountInspector.swift` | `MountInfo`、`MountInspector`、`SystemMountInspector` |
| `Sources/VDDevice/DeviceReader.swift` | `DeviceReader` の `listEntries(of:)`・`entryKind(_:)`・internal の `isSymlink(_:)`（T-14 が同じファイルに走査とコピー用の読み取りを足す） |
| `Sources/VDDevice/DeviceDetector.swift` | `DetectionReason`、`DetectedDevice`、`SkippedVolume`、`DetectionResult`、`DeviceDetector` |
| `Sources/VDDevice/CoexistenceGuard.swift` | `CoexistenceGuard` |
| `Tests/TestSupport/FakeVolume+Noise.swift` | T-07 の `FakeVolume` への extension（`oldMtime` と `addNoise(wavBytes:)`。`FakeVolume` 本体は T-07 が作る。00-api-map §15） |
| `Tests/TestSupport/FakeMountInspector.swift` | `MountInspector` の差し替え |
| `Tests/TestSupport/ScriptedProcessRunner.swift` | `ProcessRunning` の差し替え（作り手は T-13。00-api-map §15） |
| `Tests/VDDeviceTests/MountInspectorTests.swift` | |
| `Tests/VDDeviceTests/DeviceReaderListingTests.swift` | |
| `Tests/VDDeviceTests/DeviceDetectorTests.swift` | |
| `Tests/VDDeviceTests/CoexistenceGuardTests.swift` | |
| `Tests/VDDeviceTests/FakeVolumeNoiseTests.swift` | ノイズの extension のテスト（TEST-05。`FakeVolume` 本体のテストは T-07 の `FakeVolumeTests`） |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 2 キーを消す（§5.6） |

## 4. 仕様

### 4.1 `DevicePath.swift`

```swift
// デバイス上のファイルの位置（PLAN §4・CR-11）。I/O を持たない値。開くのは DeviceReader だけ。
public struct DevicePath: Hashable, Sendable {
    public let deviceID: String
    public let relpath: String
    public init(deviceID: String, relpath: String) {
        self.deviceID = deviceID
        self.relpath = relpath
    }
}
```

- メソッドを足さない（`open` / `stat` / `unlink` を持たせない。CR-11）

### 4.2 `ErrnoError.swift`

```swift
// errno をそのまま運ぶエラー（ロケールに依存する説明文を持たない）。
public struct ErrnoError: Error, Equatable, Sendable {
    public let code: Int32
    public init(_ code: Int32) { self.code = code }
}
```

### 4.3 `MountInspector.swift`

```swift
// マウント情報の取得（PLAN §8.1 規則 4・8、読み取り専用の観測）。単体テストでは差し替える。
public struct MountInfo: Equatable, Sendable {
    public let mountOnName: String      // statfs の f_mntonname（例 "/Volumes/DJIMIC3"）
    public let mountFromName: String    // f_mntfromname（例 "/dev/disk4"）
    public let fsTypeName: String       // f_fstypename（例 "msdos"）
    public let readOnly: Bool           // f_flags & MNT_RDONLY != 0
    public let freeBytes: Int64?        // f_bavail × f_bsize。掛け算があふれたら nil
    public init(mountOnName: String, mountFromName: String, fsTypeName: String, readOnly: Bool, freeBytes: Int64?)
}

public protocol MountInspector: Sendable {
    /// path を含むファイルシステムの statfs。失敗なら nil（「観測できない」）
    func mountInfo(path: String) -> MountInfo?
    /// getmntinfo(MNT_NOWAIT) の全項目。失敗なら空配列
    func allMounts() -> [MountInfo]
    /// URLResourceValues.volumeName。取れなければ nil
    func volumeName(path: String) -> String?
    /// path が「それ自身がマウント点」か（規則 4）。statfs の f_mntonname == realpath(path)
    func isMountPoint(path: String) -> Bool
}

public struct SystemMountInspector: MountInspector {
    public init() {}
}
```

`SystemMountInspector` の実装（この通りに書く）:

1. `mountInfo(path:)`:
   ```swift
   var s = statfs()
   guard statfs(path, &s) == 0 else { return nil }
   return MountInfo(statfs: s)   // 下の internal init
   ```
   `MountInfo` の internal な `init(statfs s: statfs)`:
   - 固定長の C 配列（`f_mntonname` 等は `(CChar, CChar, …)` のタプル）は `withUnsafeBytes(of: s.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }` で文字列にする
     （`!` の強制アンラップは使わない: `guard let base = … else { return "" }`）。`f_mntfromname`・`f_fstypename` も同じ
   - `readOnly = (s.f_flags & UInt32(MNT_RDONLY)) != 0`
   - `freeBytes`: `let (v, o) = Int64(s.f_bavail).multipliedReportingOverflow(by: Int64(s.f_bsize))`、`o` なら nil、そうでなければ `v`
2. `allMounts()`:
   ```swift
   var buffer: UnsafeMutablePointer<statfs>?
   let count = getmntinfo(&buffer, MNT_NOWAIT)
   guard count > 0, let buffer else { return [] }
   return (0..<Int(count)).map { MountInfo(statfs: buffer[$0]) }
   ```
   （`getmntinfo` の領域は解放しない。libc が持つ静的な領域のため）
3. `volumeName(path:)`: `try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.volumeNameKey]).volumeName`
4. `isMountPoint(path:)`:
   - `guard let real = Self.realPath(path) else { return false }`（`realpath(path, nil)` の結果を `String(cString:)` にして `free`。nil なら偽）
   - `guard let info = mountInfo(path: path) else { return false }`
   - `return info.mountOnName == real`
   - **realpath で比べる**（テストの一時ディレクトリは `/var/folders` → `/private/var`。hdiutil の `f_mntonname` は realpath 側になる。PLAN §4.6）
5. `static func realPath(_ path: String) -> String?`（internal）: 上の 4 で使う。`realpath` は PT-10 の禁止語に当たらない

### 4.4 `DeviceReader.swift`（T-13 が作る部分）

```swift
// デバイス上のファイルを読む唯一の型（PLAN §8.1・CR-11・PT-10）。書き込み用のフラグを一切使わない。
public struct DeviceReader: Sendable {
    public init() {}

    /// dir の直下の名前（`.` と `..` を除く。`.` で始まる名前も含めて返す。捨てるのは呼び手）。
    /// 名前は UTF-8 のバイト順に並べる。opendir が失敗したら errno を返す（errno によらず失敗は失敗）
    public func listEntries(of dir: String) -> Result<[String], ErrnoError>

    /// lstat で symlink か（lstat が失敗したら false）。モジュールの中だけで使う（00-api-map の公開 API ではない）
    func isSymlink(_ path: String) -> Bool

    /// lstat の種類。symlink を辿らない
    public func entryKind(_ path: String) -> EntryKind
}

public enum EntryKind: Equatable, Sendable { case directory, regularFile, symlink, other, missing }
```

`listEntries(of:)` の実装:
```swift
errno = 0
guard let dirp = opendir(dir) else { return .failure(ErrnoError(errno)) }
defer { closedir(dirp) }
var names: [String] = []
while true {
    errno = 0
    guard let ent = readdir(dirp) else {
        if errno != 0 { return .failure(ErrnoError(errno)) }
        break
    }
    let name = withUnsafeBytes(of: ent.pointee.d_name) { raw -> String in
        let bytes = raw.bindMemory(to: CChar.self)
        guard let base = bytes.baseAddress else { return "" }
        return String(cString: base)
    }
    if name == "." || name == ".." { continue }
    names.append(name)
}
return .success(names.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
```
- `entryKind`: `var st = stat(); guard lstat(path, &st) == 0 else { return .missing }`、`st.st_mode & S_IFMT` が `S_IFLNK` → `.symlink`、`S_IFDIR` → `.directory`、`S_IFREG` → `.regularFile`、それ以外 → `.other`
- `isSymlink(path)` = `entryKind(path) == .symlink`

### 4.5 `DeviceDetector.swift`

```swift
// デバイス判定（PLAN §8.1 規則 1〜9）。判定の順序と理由語を変えない。
public enum DetectionReason: String, Sendable, CaseIterable {
    case notIncluded = "not_included"
    case excluded = "excluded"
    case symlink = "symlink"
    case notAMountPoint = "not_a_mount_point"
    case notListable = "not_listable"
    case noRecordings = "no_recordings"
    case mountNameMismatch = "mount_name_mismatch"
    case invalidDeviceID = "invalid_device_id"

    /// 利用者の操作が要る理由（snapshot の unavailable に載せ、変化したときだけ WARNING）
    public var needsUserAction: Bool { self == .notListable || self == .mountNameMismatch || self == .invalidDeviceID }
}

public struct DetectedDevice: Equatable, Sendable {
    public let deviceID: String     // = エントリ名
    public let mountPath: String    // <volumesRoot>/<エントリ名>（realpath しない。表示とログ用）
    public let node: String?        // mountInfo(path).mountFromName。取れなければ nil
}

public struct SkippedVolume: Equatable, Sendable {
    public let name: String
    public let reason: DetectionReason
    public let listingError: ErrnoError?   // notListable のときだけ（errno は listingError.code）
}

public struct DetectionResult: Equatable, Sendable {
    public let devices: [DetectedDevice]      // 名前の UTF-8 バイト順
    public let skipped: [SkippedVolume]       // 名前の UTF-8 バイト順
    public let listingError: ErrnoError?      // volumesRoot 自体を列挙できなかった（「0 台」と「観測できない」を分けるため。00-api-map への追加を整合修正の報告に記載）
}

public struct DeviceDetector: Sendable {
    public init(config: DeviceConfig, volumesRoot: String, inspector: any MountInspector, reader: DeviceReader)
    public func detect() -> DetectionResult
    /// 規則 8 を単独で評価する（再マウント後に T-15 が呼ぶ）。純粋関数: name と観測したボリューム名が一致するか（nil は不一致）
    public static func nameMatchesVolume(_ name: String, volumeName: String?) -> Bool
}
```

`detect()` の手順（この順。1 つ目に当たった理由で対象外）:
1. `reader.listEntries(of: volumesRoot)` が失敗 → `DetectionResult(devices: [], skipped: [], listingError: err)`
2. 名前ごとに（バイト順）:
   - `.` で始まる名前は**黙って飛ばす**（skipped にも入れない）
   - `path = URL(fileURLWithPath: volumesRoot, isDirectory: true).appendingPathComponent(name, isDirectory: false).path(percentEncoded: false)`（00-api-map §0。`isDirectory: false` にして末尾の `/` を付けない）
   - 規則 1: `config.includeVolumes` が空でなく、どのパターンにも `fnmatch(pattern, name, 0) == 0` でない → `notIncluded`
   - 規則 2: `config.excludeVolumes` のどれかで `fnmatch(pattern, name, 0) == 0` → `excluded`
   - 規則 3: `reader.isSymlink(path)` → `symlink`
   - 規則 4: `!inspector.isMountPoint(path: path)` → `notAMountPoint`
   - 規則 5: `reader.listEntries(of: path)` が失敗 → `notListable`（`listingError` に失敗の `ErrnoError` を入れる）
   - 規則 6: 規則 5 で得た名前のうち `.` で始まらないものに、「`reader.entryKind(子のパス) == .directory` かつ `RecordingName.isFolder(子)`」か
     「`entryKind == .regularFile` かつ `RecordingName.parseFile(子) != nil`」が 1 つも無い → `noRecordings`
     （symlink は数えない。voicedock は辿っていた）
   - 規則 7: 欠番（何もしない）
   - 規則 8: `!Self.nameMatchesVolume(name, volumeName: inspector.volumeName(path: path))` → `mountNameMismatch`
   - 規則 9: `!DeviceID.isValid(name)` → `invalidDeviceID`
   - 通過: `DetectedDevice(deviceID: name, mountPath: path, node: inspector.mountInfo(path: path)?.mountFromName)`
3. `nameMatchesVolume(_:volumeName:)`: `volumeName.map { PyText.scalarsEqual($0, name) } ?? false`（nil は不一致。観測できないものは取り込まない側。名前はスカラー列で比べる。00-api-map §0）
- `fnmatch` は Darwin の関数をそのまま呼ぶ（`import Darwin`）。パターンは設定の文字列そのもの（正規表現にしない。DEV-07）。空白を含む名前も 1 つのパターン（`"Macintosh HD"`）
- 判定はファイルを開かない（列挙・lstat・statfs だけ）。`access(2)` を使わない（DEV-03）

### 4.6 `CoexistenceGuard.swift`

```swift
// voicedock の Helper との共存ガード（PLAN §8.1 手順 1・DR-13）。
public struct CoexistenceGuard: Sendable {
    public static let label = "com.voicedock.ingest"
    public static let launchctl = URL(fileURLWithPath: "/bin/launchctl")
    public static let timeout: Duration = .seconds(10)
    public init(runner: any ProcessRunning, uid: uid_t)
    /// LaunchAgent が「登録されている」か（今動いているかではない）
    public func isVoicedockHelperLoaded() async -> Bool
    /// argv（テストでも使う）
    public static func arguments(uid: uid_t) -> [String] {
        ["print", ["gui", String(uid), Self.label].joined(separator: "/")]
    }
}
```
- 起動: `ProcessSpec(executable: Self.launchctl, arguments: Self.arguments(uid: uid), environment: ProcessEnvironment.cLocale)`、`runner.run(spec, timeout: Self.timeout)`
- 判定: `termination == .exited(0)` だけが真。それ以外（0 以外の終了・シグナル・タイムアウト・起動失敗）は偽
  （launchctl は macOS に必ず在る。起動できないことを「登録されている」とみなして取り込み全体を止めると、原因の分からない沈黙になるため。PLAN §8.1 の改訂と同じ）
- 引数の `gui/<uid>/<label>` は `["gui", String(uid), Self.label].joined(separator: "/")` で作る（文字列補間 `"gui/\(uid)/\(…)"` は PT-06 の `\(…)/\(…)` の形に当たるので使わない）

### 4.7 TestSupport

#### `FakeVolume+Noise.swift`（T-07 の `FakeVolume` への extension）

`FakeVolume` 本体（`init(in: TempDirectory, deviceID:)`・`addFile(_:data:mtime:)`・`addDirectory(_:)`・`addSymlink(_:destination:)`・`setMtime(_:_:)`・`deviceMtimeOffsetSeconds`・`standardContent`・`StandardTree`）は **T-07 が作る**（00-api-map §15）。本チケットは次だけを足す:

```swift
extension FakeVolume {
    /// 安定性判定の fast path を必ず通る古い時刻（2026-09-12T12:09:50Z = 1789214990）
    public static let oldMtime: Double = 1_789_214_990
    /// macOS が作るノイズ（voicedock fake_tree.py の _write_noise）を足す: `TX_MIC001_20260912_120950/._TX00_MIC001_20260912_120950_orig.wav`（"Mac OS X\0"×4）、
    /// `.Spotlight-V100/dummy`、`.fseventsd/dummy`、`.Trashes/TX_MIC001_20260901_101010/TX00_MIC001_20260901_101010_orig.wav`（中身 wavBytes）、`TX_MIC001_20260912_120950/NOTES.txt`（"memo\n"）。mtime はすべて oldMtime
    public func addNoise(wavBytes: Data) throws
}
```
- 書き込みは T-07 の `addFile(_:data:mtime:)` を使う（`.wav` の中身は呼び手が渡す。BWF は T-14 の `BWFWriter`）

#### `FakeMountInspector.swift`
`@unchecked Sendable` を使わない（テストでも使わない）ため、不変の値で持つ:
```swift
public struct FakeMountInspector: MountInspector {
    public var infos: [String: MountInfo]          // key = パス（volumesRoot 配下のエントリのパス、realpath しない）
    public var mountPoints: Set<String>            // isMountPoint が真になるパス
    public var volumeNames: [String: String]       // key = パス
    public var mounts: [MountInfo]                 // allMounts の戻り
    public init(infos: [String: MountInfo] = [:], mountPoints: Set<String> = [], volumeNames: [String: String] = [:], mounts: [MountInfo] = [])
    /// よく使う形: path をマウント点・ボリューム名 = 最後の要素・rw・msdos・/dev/disk4 で登録した値を返す
    public static func mounted(_ paths: [String], readOnly: Bool = false, node: String = "/dev/disk4", freeBytes: Int64 = 4_500_000_000) -> FakeMountInspector
}
```
- 呼ばれるたびに状態を変える必要があるテスト（再マウント）は T-15 の `FakeRemounter` が新しい `FakeMountInspector` を返す関数を持つ（T-15）

#### `ScriptedProcessRunner.swift`
```swift
/// ProcessRunning の差し替え。受け取った ProcessSpec を記録し、台本の結果を順に返す。
public actor ScriptedProcessRunner: ProcessRunning {
    public init(results: [ProcessResult])            // 足りなくなったら最後の要素を返し続ける。空なら .exited(0)
    public func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult
    public func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess   // 記録してから SpawnError.spawnFailed(errno: ENOSYS)（T-12 の型）を投げる
    public var recorded: [ProcessSpec] { get }
    public var recordedTimeouts: [Duration] { get }
    public static func exited(_ code: Int32) -> ProcessResult   // stdout / stderr は空
}
```

## 5. テスト

### 5.0 安全の約束（全テスト共通。必ず守る）

- **テストは `/Volumes` の実機に触れない。**利用者の DJI Mic 3 が `/Volumes/DJIMIC3`（`/dev/disk4`、msdos）にマウントされていることがある。テストが `/Volumes` 配下に対して diskutil（unmount / mount / 再マウント）・書き込み・削除を行うことを禁じる
- デバイス判定・走査・コピーのテストの volumesRoot は**必ず一時ディレクトリ**（`FakeVolume` の `<tmp>/Volumes`）。本番の `Contract.volumesRoot`（`/Volumes`）は `Bootstrap` が注入するだけで、テストでは使わない
- `SystemMountInspector` のテストは読み取りだけ（`/` の statfs・getmntinfo・ボリューム名）。一覧に実機が含まれていても、その項目に対して何もしない
- 共存ガードは `ScriptedProcessRunner` で試し、本物の launchctl を動かさない
- ディスクイメージを使うテスト（T-15 の `.diskImage`）は `/Volumes` 以外に attach する（T-15 §5.0）

### 5.1 `MountInspectorTests.swift`（`@Suite("MountInspector")`）
| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `rootIsAMountPoint` / 「/ はマウント点」 | `SystemMountInspector().isMountPoint(path: "/")` | 真 |
| `dotRootIsAMountPointAfterRealpath` / 「/. も realpath を通すとマウント点」 | `isMountPoint(path: "/.")`（realpath で `/` になる。`f_mntonname` は `/`） | 真 |
| `tempDirectoryIsNotAMountPoint` / 「一時ディレクトリはマウント点でない」 | `TempDirectory()` の中のディレクトリ | 偽 |
| `mountInfoOfRootIsObserved` / 「/ の statfs が取れる」 | `mountInfo(path: "/")` | nil でない、`mountOnName == "/"`、`freeBytes > 0` |
| `mountInfoOfMissingPathIsNil` / 「無いパスは観測できない（nil）」 | `/nonexistent-<uuid>` | nil |
| `allMountsContainsRoot` / 「getmntinfo に / が在る」 | `allMounts()` | `mountOnName == "/"` の項目が 1 つ以上 |
| `volumeNameOfRoot` / 「/ のボリューム名が取れる」 | `volumeName(path: "/")` | nil でない・空でない |

### 5.2 `DeviceReaderListingTests.swift`（`@Suite("DeviceReader の列挙")`）
| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `listsNamesInByteOrder` / 「名前を UTF-8 のバイト順で返す」 | `b`, `a`, `.hidden`, `あ` を作る | `[".hidden", "a", "b", "あ"]` |
| `emptyDirectoryListsNothing` / 「空のディレクトリは空配列」 | 空 | `.success([])` |
| `unlistableDirectoryReturnsErrno` / 「列挙できなければ errno を返す（EACCES）」 | ディレクトリを `chmod 000`（テスト後に 755 へ戻す） | `.failure(ErrnoError(EACCES))` |
| `missingDirectoryReturnsENOENT` / 「無いディレクトリは ENOENT」 | 無いパス | `.failure(ErrnoError(ENOENT))` |
| `entryKindDoesNotFollowSymlinks` / 「lstat で判定し symlink を辿らない」 | ファイル・ディレクトリ・ファイルへの symlink・ディレクトリへの symlink・無い名前 | `.regularFile` / `.directory` / `.symlink` / `.symlink` / `.missing` |

### 5.3 `DeviceDetectorTests.swift`（`@Suite("DeviceDetector")`）

共通の準備: `let tmp = try TempDirectory()`、`FakeVolume(in: tmp)`（T-07）に `addFile("TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav", data: Data("x".utf8), mtime: FakeVolume.oldMtime)` を置き、
`FakeMountInspector.mounted([<volumesRoot>/DJIMIC3])`、`DeviceConfig` は `AppConfig.defaults(timeZone: "Asia/Tokyo").device`（テストごとに include / exclude だけ変える）。**弾かせたい規則以外はすべて満たす**（TEST-19）。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `validDeviceIsDetected` / 「条件をすべて満たすと検出する（正の対照）」 | 共通 | `devices == [DetectedDevice(deviceID: "DJIMIC3", mountPath: <path>, node: "/dev/disk4")]`、`skipped == []` |
| `includeEmptyLetsEverythingThrough` / 「規則 1: include が空なら素通り」 | `includeVolumes = []` | 検出 |
| `includeGlobMatches` / 「規則 1: include の glob に一致すれば通る」 | `["DJIMIC*"]` | 検出 |
| `includeThatMatchesNothing` / 「CE device.includeVolumes 規則 1: どれにも一致しなければ not_included」 | `["NOPE"]`（既定の `[]` なら検出される） | `skipped == [SkippedVolume(name: "DJIMIC3", reason: .notIncluded, listingError: nil)]` |
| `patternsAreGlobsNotRegexes` / 「規則 1・2: `.*` は glob（`.` で始まる）で正規表現ではない」 | include `[".*"]` | not_included（正規表現なら全部に一致してしまう） |
| `excludeWithSpaceIsOnePattern` / 「CE device.excludeVolumes 規則 2: 空白を含む名前は 1 つのパターン（一致すれば excluded、しなければ検出）」 | ボリューム名を `My Device` にし（マウント点・ボリューム名も合わせる）、exclude `["My Device"]` → excluded。exclude `["My"]` → 検出 | 左記 |
| `defaultExcludesMacintoshHD` / 「規則 2: 既定の exclude は Macintosh HD と TimeMachine と `.` 始まり」 | `Macintosh HD` と `com.apple.TimeMachine.localsnapshots` のエントリ（どちらもマウント点扱い）| どちらも excluded |
| `symlinkedVolumeIsSkipped` / 「規則 3: エントリが symlink なら symlink（本物は検出）」 | `Escape -> DJIMIC3` の symlink、exclude `[]` | `Escape` は `.symlink`、`DJIMIC3` は検出 |
| `plainDirectoryIsNotAMountPoint` / 「規則 4: マウント点でないディレクトリは not_a_mount_point」 | `FakeMountInspector()`（何も登録しない） | `.notAMountPoint` |
| `unlistableVolumeIsNotListableEvenWithEACCES` / 「規則 5: 列挙できなければ errno によらず not_listable（EACCES）」 | ボリュームを `chmod 000` | `.notListable`、`listingError == ErrnoError(EACCES)`。`.noRecordings` ではない |
| `listableEmptyVolumeSaysNoRecordings` / 「規則 6: 読めるのに空なら no_recordings（陰性対照）」 | 中身を消す | `.noRecordings` |
| `directoryWithoutRecordingsIsNotADevice` / 「規則 6: 録音の無いディレクトリは no_recordings」 | `Documents/` だけ | `.noRecordings` |
| `emptyRecordingFolderStillCounts` / 「規則 6: フォルダ規則のディレクトリだけでも通る（録音 0 件のデバイス。DEV-19）」 | `TX_MIC001_20260912_120950/` だけ（中身なし） | 検出 |
| `rootLevelDenoisedFileCounts` / 「規則 6: 直下の denoised ファイルでも通る」 | 直下に `TX00_MIC001_20260912_120950.wav` だけ | 検出 |
| `dotEntriesDoNotCount` / 「規則 6: `.` で始まるものは数えない」 | `._TX00_MIC001_20260912_120950_orig.wav` と `.Trashes/TX_MIC001_20260901_101010/` だけ | `.noRecordings` |
| `symlinkToFolderDoesNotCount` / 「規則 6: symlink のフォルダは数えない」 | `TX_MIC001_20260912_120950 -> /tmp/…` だけ | `.noRecordings` |
| `invalidDateFileDoesNotCount` / 「規則 6: 日付が不正なファイル名は数えない」 | 直下に `TX00_MIC001_20260230_120950_orig.wav` だけ | `.noRecordings` |
| `nameMismatchIsSkipped` / 「規則 8: ボリューム名と違えば mount_name_mismatch（` 1` 付き）」 | エントリ `DJIMIC3 1`（マウント点）、`volumeNames` は `DJIMIC3` | `.mountNameMismatch` |
| `missingVolumeNameIsMismatch` / 「規則 8: ボリューム名が取れなければ mount_name_mismatch」 | `volumeNames` を空 | `.mountNameMismatch` |
| `nameMatchesVolumeComparesScalars` / 「規則 8: 名前とボリューム名はスカラー列で比べ、nil は不一致（純粋関数）」 | `nameMatchesVolume("が", volumeName: "か\u{3099}")`・`nameMatchesVolume("DJIMIC3", volumeName: nil)`・`nameMatchesVolume("DJIMIC3", volumeName: "DJIMIC3")` | 偽・偽・真（NFC と NFD を同じとみなさない。00-api-map §0） |
| `colonInNameIsInvalidDeviceID` / 「規則 9: `:` を含む名前は invalid_device_id」 | エントリ `DJI:MIC`（マウント点・ボリューム名とも `DJI:MIC`） | `.invalidDeviceID` |
| `spaceInNameIsValid` / 「規則 9: 空白は可（NO NAME）」 | エントリ `NO NAME` | 検出 |
| `dotEntryIsSilentlyIgnored` / 「`.` で始まるエントリは skipped にも入らない」 | `.Trashes` をマウント点扱いで置く | skipped に無い |
| `ruleOrderIsFixed` / 「最初に当たった規則の理由を返す（symlink かつ exclude なら excluded）」 | exclude に一致する symlink | `.excluded` |
| `multipleDevicesInByteOrder` / 「複数デバイスをバイト順で返す」 | `DJIMIC4` と `DJIMIC3` | `["DJIMIC3", "DJIMIC4"]` |
| `volumesRootListingFailure` / 「/Volumes 自体が読めなければ 0 台と listingError」 | 無い volumesRoot | `devices == []`、`listingError == ErrnoError(ENOENT)` |
| `zeroEntriesIsZeroDevices` / 「エントリ 0 件なら 0 台（空の状態）」 | 空の volumesRoot | `devices == []`、`skipped == []`、`listingError == nil` |
| `needsUserActionIsExactlyThree` / 「利用者の操作が要る理由は 3 つだけ」 | `DetectionReason.allCases.filter(\.needsUserAction)` | `[.notListable, .mountNameMismatch, .invalidDeviceID]` |

### 5.4 `CoexistenceGuardTests.swift`（`@Suite("CoexistenceGuard")`）
| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `argvIsExact` / 「launchctl の argv と環境が逐語どおり」 | `ScriptedProcessRunner(results: [ScriptedProcessRunner.exited(1)])`、uid 501 | `recorded[0].executable.path(percentEncoded: false) == "/bin/launchctl"`、`arguments == ["print", "gui/501/com.voicedock.ingest"]`（= `CoexistenceGuard.arguments(uid: 501)`）、`environment == ProcessEnvironment.cLocale`、timeout 10 秒 |
| `exitZeroMeansLoaded` / 「終了コード 0 なら登録されている」 | `.exited(0)` | 真 |
| `nonZeroMeansNotLoaded` / 「0 以外（113）なら登録されていない」 | `.exited(113)` | 偽 |
| `timeoutAndSpawnFailureAreNotLoaded` / 「タイムアウト・起動失敗・シグナルは偽」 | `termination` が `.timedOut` / `.spawnFailed(errno: ENOENT)` / `.signaled(9)` の `ProcessResult`（パラメータ化） | すべて偽 |

### 5.5 `FakeVolumeNoiseTests.swift`（`@Suite("FakeVolume のノイズ")`。TEST-05。本体のテストは T-07 の `FakeVolumeTests`）
| 関数名 / 表示名 | 期待 |
|---|---|
| `noiseMatchesTheRealDevice` / 「ノイズの木が fake_tree.py と同じ」 | `addNoise` の後、5 つのパスが在り、mtime がすべて `oldMtime` |

### 5.6 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`device.includeVolumes`・`device.excludeVolumes` の 2 行を消す（CE テストは §5.3）。

## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| `DeviceDetector` の規則 1 の `fnmatch` を `==` の比較に変える | `includeGlobMatches` |
| 規則 5 を「`errno == EPERM` のときだけ not_listable、それ以外は列挙結果を空として続ける」に変える | `unlistableVolumeIsNotListableEvenWithEACCES` |
| 規則 6 の `.` 始まりの除外を消す | 落ちるテストは無い（等価な変異。`.` で始まる名前はフォルダ規則・ファイル規則の先頭の `TX` に一致しないので、除外が無くても数えられない。除外は規則の正規表現が変わったときの多重の防御として残す。`dotEntriesDoNotCount` は `.` 始まりのノイズだけなら no_recordings になることを確かめる陰性対照） |
| 規則 6 で `entryKind` の代わりに `stat`（symlink を辿る）を使う | `symlinkToFolderDoesNotCount` |
| 規則 3 と規則 2 の順序を入れ替える | `ruleOrderIsFixed` |
| 規則 8（`nameMatchesVolume`）で `volumeName` が nil のとき一致とみなす | `missingVolumeNameIsMismatch` |
| `isMountPoint` で realpath を使わずに比べる | `dotRootIsAMountPointAfterRealpath`（`rootIsAMountPoint` は通る）。加えて T-15 の `.diskImage` テスト（`diskImageIsDetectedAndIngested`）が落ちる（手元で `make test-disk`） |
| `nameMatchesVolume` の `PyText.scalarsEqual` を `==` に変える | `nameMatchesVolumeComparesScalars` |
| `CoexistenceGuard` で `.exited(113)` も真にする | `nonZeroMeansNotLoaded` |

## 7. 受け入れ条件

- [ ] 規則 1〜9 の順序・理由語が PLAN §8.1 と一致する（規則 7 は欠番のまま）
- [ ] `VDDevice/` の中で `opendir` / `open` を使うのは `DeviceReader.swift` だけ（PT-10）
- [ ] `access(` を使っていない
- [ ] `SystemMountInspector` の比較は realpath 済みのパス
- [ ] テストは `/Volumes` の実機に触れない（5.0）。volumesRoot はテストで一時ディレクトリ
- [ ] 上記のテストがすべて緑、`make lint` が通る

## 8. SPEC の変更

なし（`volume_skipped` の理由語は付録 A.4 にある）

## 9. マージ後にやること

なし

## 10. API 地図への変更提案

1. `MountInspector` に `func isMountPoint(path: String) -> Bool` を足す → 00-api-map に反映済み（2026-09-18）
2. `DeviceReader.listEntries(of:)` の失敗型を `ErrnoError` に、`EntryKind` と `entryKind(_:)` を足す → 00-api-map に反映済み（2026-09-18）。`ErrnoError` のプロパティ名は地図どおり `code`。`isSymlink` は公開せず internal にした
3. `DetectionResult` / `SkippedVolume`（`listingError`）→ 00-api-map に反映済み（2026-09-18）。`nameMatchesVolume` は地図どおり `static func nameMatchesVolume(_ name: String, volumeName: String?) -> Bool`（純粋関数）に直した。
   **地図に無い追加**: `DetectionResult.listingError`（volumesRoot 自体を列挙できないとき。「0 台」と「観測できない」を分けるため。T-15 はこれが nil でなければ snapshot を公開しない。地図への追加が要る）
4. `DetectedDevice.node` の意味を「`mountInfo(path).mountFromName`」と明記する（地図の注記として追加が要る）
5. `CoexistenceGuard` の公開定数 → 00-api-map に反映済み（2026-09-18）。`arguments` は地図どおり `static func arguments(uid:)`
