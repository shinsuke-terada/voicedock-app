# T-07 VDContract: TargetIdentity（削除対象の同定。openat の連鎖と検証済みの親 fd）

| 項目 | 値 |
|---|---|
| Phase | 1（骨組みと防護柵） |
| 前提 | T-06（`RelPath`・`RecordingName`・`DeviceID`・`Contract`・`PosixIO`）。TestSupport の `TempDirectory`・`TestEnvironment`（T-01）は T-06 の前提として入っている |
| 見積もり | ソース約 250 行・テスト約 450 行・テスト部品約 250 行 |
| 後続 | T-36（アプリの事前確認）、T-37（reaper の RV-06〜RV-13）、T-13 / T-14（`FakeVolume` を使う） |

## 1. 目的

reaper の RV-06〜RV-12 そのもの（PLAN §4.6）を VDContract に実装する。**検証済みの親ディレクトリ fd を unlink まで保持する API** にして、realpath 比較や「検証してからパスを開き直す」TOCTOU の窓を消す。
アプリの事前確認（§8.9.5）も reaper も同じ関数を呼ぶ。あわせて、この関数を試すためのテスト部品 `FakeVolume`・`FakeVolumeOpener`・`DiskImageVolume` を作る（後続のチケットも使う）。

## 2. 参照

- PLAN §4.6、§4.3、§4.5、§8.9.4（処理の順序の表）、§8.9.5（`preIdentityCheck`）、§9.4（PT-10・PT-22）、§10.2（FakeVolume・DiskImageVolume）、§10.5（層 R2・R3）、付録 B.1（ND-18〜20・24・25・28・29・37 の R2）、付録 B.2（理由語）
- 00-api-map §1（`TargetIdentity.swift`）
- voicedock@d3d595e: `helper/voicedock-reaper:138-173`（`target_is_identical`。realpath 比較版の検証 5〜10）、`tests/unit/test_reaper.py:40-173`（ベンチと mtime の事例 `+120` / `+1`）、`tests/fixtures/fake_tree.py`（`DEVICE_MTIME_OFFSET`）
- 実機の確認（このチケットを書く時点で手元の macOS 26.6 / Xcode 27.0 で確かめた事実）:
  - `openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)` は、name が symlink のとき **ENOTDIR**（ELOOP ではない）、通常ファイル・FIFO のときも ENOTDIR、無いとき ENOENT
  - `hdiutil create -size 64m -fs "MS-DOS FAT32" -volname DJIMIC3 -layout NONE` → `hdiutil attach -nobrowse -noautoopen -noverify -mountpoint <dir>` で、`fstatfs` の `f_mntonname` は `<dir>` の realpath と一致し、`f_fstypename` は `msdos`。`-readonly` を付けると `f_flags & MNT_RDONLY` が立つ。`-fs HFS+` は `hfs`
  - FAT に mtime `1787000001` を設定すると `1787000000` として保存される（2 秒分解能・切り捨て）
  - 普通の一時ディレクトリに `fstatfs` すると `f_mntonname` は `/System/Volumes/Data`、`apfs`

## 3. 作るもの

- `Sources/VDContract/TargetIdentity.swift`（`TargetIdentity`・`VolumeOpenResult`・`VolumeHandle`・`VerifiedTarget`・`IdentityMismatch`・`IdentityReason`・`VolumeOpener`・`SystemVolumeOpener`。00-api-map が 1 ファイルに置くと決めている。PT-22 の許可場所がこのファイルだけなので分けない）
- `Tests/TestSupport/FakeVolume.swift`
- `Tests/TestSupport/FakeVolumeOpener.swift`
- `Tests/TestSupport/DiskImageVolume.swift`
- `Tests/VDContractTests/TargetIdentityTests.swift`（層 R2。常に走る）
- `Tests/VDContractTests/TargetIdentityDiskImageTests.swift`（`.diskImage`）
- `Tests/VDContractTests/FakeVolumeTests.swift`（偽物そのもののテスト。TEST-05）

`TargetIdentity.swift` には `O_WRONLY`・`O_RDWR`・`O_CREAT`・`O_TRUNC`・`O_APPEND`・`forWriting`・`forUpdating` を書かない（PT-10(b)）。`unlink` も書かない（unlink は reaper の `Unlinker.swift`）。

## 4. 仕様

### 4.1 型（`TargetIdentity.swift`。先頭のコメント「// 削除対象の同定（PLAN §4.6。RV-06〜RV-12）。アプリの事前確認と reaper が同じ関数を使う。」）

```swift
public enum TargetIdentity {
    /// RV-06 / RV-07。<volumesRoot の realpath>/<deviceID> を開き、開いた fd に fstatfs する。
    public static func openVolume(volumesRoot: String, deviceID: String) -> VolumeOpenResult

    /// RV-08〜RV-12。検証が通れば、検証済みの親 fd を持つ VerifiedTarget を body に貸す。
    /// body を抜けたら（このメソッドが開いた）親 fd を閉じる。失敗なら body を呼ばない。
    public static func withVerifiedTarget<R>(volume: VolumeHandle, relpath: String,
                                             expectedSize: Int64, expectedMtime: Double,
                                             _ body: (VerifiedTarget) -> R) -> Result<R, IdentityMismatch>
}

public enum VolumeOpenResult: Sendable {
    case opened(VolumeHandle)
    case absent                          // device_absent（要求を残す）
    case rejected(IdentityMismatch)      // not_a_mount_point / unexpected_fs
}

/// 開いたボリュームのディレクトリ fd。deinit で閉じる。
/// 本番のコードで初期化子を呼んでよいのはこのファイルだけ（PT-22）。テストは @testable import で FakeVolumeOpener が使う。
public final class VolumeHandle: Sendable {
    public let fd: Int32
    /// 同じ fstatfs の f_flags & MNT_RDONLY（観測値）。reaper の RV-07 とアプリの事前確認が使う
    public let readOnly: Bool
    /// realpath 済みの <volumesRoot>/<deviceID>
    public let mountPath: String
    init(fd: Int32, readOnly: Bool, mountPath: String)
    deinit   // close(fd)
}

/// body の外へ持ち出さない（parentFD は body の後で閉じられる）。
public struct VerifiedTarget {
    public let parentFD: Int32
    public let name: String
}

public struct IdentityMismatch: Error, Equatable, Sendable {
    public let reason: String            // IdentityReason の定数のどれか
    public init(_ reason: String)
}

/// 理由語（PLAN 付録 B.2 の全語。逐語）。reaper とアプリが共有する。
public enum IdentityReason {
    public static let lock1 = "lock1"
    public static let confInvalid = "conf_invalid"
    public static let malformedRequestID = "malformed_request_id"
    public static let malformedRequest = "malformed_request"
    public static let replayed = "replayed"
    public static let partkeyMismatch = "partkey_mismatch"
    public static let deviceAbsent = "device_absent"
    public static let notAMountPoint = "not_a_mount_point"
    public static let unexpectedFS = "unexpected_fs"
    public static let mountReadonly = "mount_readonly"
    public static let relpathUnsafe = "relpath_unsafe"
    public static let pathContainsSymlink = "path_contains_symlink"
    public static let targetMissing = "target_missing"
    public static let targetIsSymlink = "target_is_symlink"
    public static let notRegularFile = "not_regular_file"
    public static let filenameRule = "filename_rule"
    public static let folderRule = "folder_rule"
    public static let sizeMismatch = "size_mismatch"
    public static let mtimeMismatch = "mtime_mismatch"
    public static let unlinkFailed = "unlink_failed"
    public static let stillPresent = "still_present"
    /// 上の 21 語をこの順に（SPEC 同期のテストが付録 B.2 と照合する）
    public static let all: [String]
}

/// アプリはボリュームをこのプロトコル経由で開く（テストで差し替えるため。CR-25）。reaper は openVolume を直接呼ぶ。
public protocol VolumeOpener: Sendable {
    func open(volumesRoot: String, deviceID: String) -> VolumeOpenResult
}

/// 本番の実装。openVolume を呼ぶだけ。
public struct SystemVolumeOpener: VolumeOpener {
    public init()
    public func open(volumesRoot: String, deviceID: String) -> VolumeOpenResult
}
```

### 4.2 `openVolume` の手順（RV-06・RV-07）

1. `DeviceID.isValid(deviceID)` が偽 → `.rejected(IdentityMismatch(IdentityReason.notAMountPoint))`
2. `root = PosixIO.realpath(volumesRoot)`。nil（ボリュームの親が無い）→ `.absent`
3. `path = root + "/" + deviceID`（文字列の連結。`"\(a)/\(b)"` の形のリテラルを書かない: `root + "/" + deviceID` と書く。PT-06）
4. `fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`。失敗したら errno で分ける:
   - `ENOENT` → `.absent`
   - `ENOTDIR`・`ELOOP`（symlink・通常ファイル）→ `.rejected(notAMountPoint)`
   - その他（`EACCES`・`EPERM` など）→ `.absent`（開けないボリュームで要求を拒否すると processed.log に載って消費されてしまう。残して期限切れに任せる。PLAN §4.6 に明記済み（F-48））
5. `fstatfs(fd, &sfs)` が失敗 → `close(fd)`、`.rejected(notAMountPoint)`
6. `mnton = PosixIO.string(fromCTuple: sfs.f_mntonname)`。`mnton != path` → `close(fd)`、`.rejected(notAMountPoint)`（バイト列の完全一致。Unicode の正規化はしない）
7. `fstype = PosixIO.string(fromCTuple: sfs.f_fstypename)`。`fstype != Contract.expectedFilesystem` → `close(fd)`、`.rejected(IdentityMismatch(IdentityReason.unexpectedFS))`
8. `readOnly = (sfs.f_flags & UInt32(MNT_RDONLY)) != 0`（`f_flags` は `UInt32`）
9. `.opened(VolumeHandle(fd: fd, readOnly: readOnly, mountPath: path))`

- `statfs(path)` を使わない（`statfs` → `open` の間に差し替えられる窓を消す）
- ボリュームの fd は `VolumeHandle` の deinit が閉じる

### 4.3 `withVerifiedTarget` の手順（RV-08〜RV-12。この順に確かめ、最初に当たった理由語で `.failure` を返す）

1. `RelPath.isSafe(relpath)` が偽 → `relpath_unsafe`（RV-08）
2. `comps = RelPath.components(relpath)`、`name = comps.last`、`dirs = comps.dropLast()`
3. `current = volume.fd`（**借りる。閉じない**）、`owned: Int32? = nil`
4. `dirs` の各要素 `comp` について:
   - `next = openat(current, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`
   - 失敗: `owned` を閉じ、errno が `ENOTDIR` か `ELOOP` → `path_contains_symlink`（macOS では symlink も通常ファイルも FIFO も ENOTDIR になる）、`ENOENT` → `target_missing`、その他 → `target_missing`（RV-09）
   - 成功: `owned` があれば閉じ、`owned = next`、`current = next`
5. `parentFD = current`
6. `fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW)` が失敗 → `owned` を閉じ、`target_missing`（errno によらない。RV-09）
7. `(st.st_mode & S_IFMT) == S_IFLNK` → `target_is_symlink`、`!= S_IFREG` → `not_regular_file`（RV-10）
8. `RecordingName.parseFile(name)?.isOrig == true` でなければ `filename_rule`（RV-11）
9. `dirs.last.map(RecordingName.isFolder) ?? false` が偽 → `folder_rule`（RV-11。relpath が 1 要素＝ボリューム直下のファイルは常に `folder_rule`）
10. `Int64(st.st_size) != expectedSize` → `size_mismatch`（RV-12）
11. `mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9`、`abs(mtime - expectedMtime) < Contract.mtimeToleranceSeconds` でなければ `mtime_mismatch`（RV-12。`expectedMtime` が NaN なら比較が偽になり不一致。fail-closed）
12. `result = body(VerifiedTarget(parentFD: parentFD, name: name))` → `owned` を閉じる → `.success(result)`

- 7〜11 の失敗でも `owned` を閉じる（`defer` で閉じると 12 の body の後に閉じる順序も保てる。**body の中では parentFD が開いていること**）
- voicedock の reaper は整数秒の差 `>= 2` で不一致にしていた。本アプリは浮動小数の式に統一する（FAT の mtime は 2 秒刻みなので実害なし）
- 旧 reaper の `realpath_failed` / `outside_volume` / `stat_failed` は出ない（`IdentityReason` に入れない）

### 4.4 `SystemVolumeOpener`

`func open(volumesRoot:deviceID:) -> VolumeOpenResult { TargetIdentity.openVolume(volumesRoot: volumesRoot, deviceID: deviceID) }` だけ。

### 4.5 テスト部品

```swift
// FakeVolume.swift — 一時ディレクトリに DJI Mic 3 と同じ木を作る（PLAN §10.2。voicedock tests/fixtures/fake_tree.py）。
public final class FakeVolume: Sendable {
    public let volumesRoot: URL          // <tmp>/Volumes
    public let root: URL                 // <tmp>/Volumes/<deviceID>
    public let deviceID: String
    /// 原本の mtime はコピー時刻の 4 時間 34 分前（voicedock の DEVICE_MTIME_OFFSET。DEL-12 を再現する）
    public static let deviceMtimeOffsetSeconds: Double = 16_440
    /// voicedock の reaper ベンチと同じ中身（b"x" * 4096）
    public static let standardContent = Data(repeating: 0x78, count: 4096)

    public init(in tmp: TempDirectory, deviceID: String = "DJIMIC3") throws     // root まで作る
    public func url(_ relpath: String) -> URL
    @discardableResult public func addFile(_ relpath: String, data: Data = FakeVolume.standardContent, mtime: Double) throws -> URL   // 親を作り、書き、utimes で mtime を設定
    @discardableResult public func addDirectory(_ relpath: String) throws -> URL
    public func addSymlink(_ relpath: String, destination: String) throws      // destination は与えた文字列のまま（相対・絶対）
    public func addFIFO(_ relpath: String) throws                              // mkfifo
    public func setMtime(_ relpath: String, _ mtime: Double) throws            // utimes（秒と μ秒）
    public func fileStat(_ relpath: String) -> (size: Int64, mtime: Double)?   // lstat
    /// 下の StandardTree を作る。原本の mtime = copyTime − deviceMtimeOffsetSeconds
    public func populateStandardTree(copyTime: Double) throws

    public enum StandardTree {
        /// 取り込みの候補（_orig、symlink でない、走査の深さ 3 以内、. 始まりでない）
        public static let origInScope: [String] = [
            "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
            "TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav",
            "a/b/TX01_MIC002_20260829_083000_orig.wav",
        ]
        public static let denoised: [String] = ["TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204.wav"]
        /// 深さ 4（maxScanDepth 3 の外）
        public static let beyondDepth: [String] = ["a/b/c/TX01_MIC002_20260829_090000_orig.wav"]
        /// . 始まり（黙って無視されるもの）
        public static let hidden: [String] = [
            "TX_MIC001_20260829_071201/._TX01_MIC002_20260829_071204_orig.wav",
            ".Spotlight-V100/Store-V2/x",
            ".Trashes/501/TX01_MIC002_20260829_071204_orig.wav",
            ".fseventsd/fseventsd-uuid",
        ]
        /// フォルダ規則に一致する名前の symlink（→ "TX_MIC001_20260829_071201"。走査が辿ってはいけない）
        public static let symlinkFolder = "TX_MIC001_20260829_080001"
    }
}
```

- `populateStandardTree` の中身: `origInScope`・`denoised`・`beyondDepth` を `standardContent` で、`hidden` を 82 バイトの 0x00 で作り、すべての mtime を `copyTime − 16_440` にする。`symlinkFolder` を相対の宛先 `TX_MIC001_20260829_071201` で作る
- 書き込みは `Data.write(to:)`（`Tests/` は PT の対象外）

```swift
// FakeVolumeOpener.swift — 普通のディレクトリを VolumeHandle に包む（マウント点・FS 種別の検査をしない）。
// アプリ層の ND と正の対照で使う（PLAN §4.6、§10.5）。@testable import VDContract。
public struct FakeVolumeOpener: VolumeOpener {
    public let readOnly: Bool
    public init(readOnly: Bool = false)
    /// <volumesRoot>/<deviceID> を open(O_RDONLY | O_DIRECTORY | O_NOFOLLOW)。ENOENT → .absent、その他の失敗 → .rejected(not_a_mount_point)、
    /// 成功 → .opened(VolumeHandle(fd:readOnly: self.readOnly, mountPath: <realpath したパス>))
    public func open(volumesRoot: String, deviceID: String) -> VolumeOpenResult
}
```

```swift
// DiskImageVolume.swift — hdiutil の FAT32（または HFS+）イメージを一時ディレクトリにマウントする（.diskImage のテストだけが使う）。
public final class DiskImageVolume: Sendable {
    public enum Filesystem: Sendable { case fat32, hfsPlus }
    public let volumesRoot: URL          // <tmp>/Volumes
    public let mountPoint: URL           // <tmp>/Volumes/<deviceID>
    public let deviceID: String
    public let image: URL                // <tmp>/<deviceID>.dmg
    public let filesystem: Filesystem

    /// create → mountPoint を作る → attach（書き込み可）
    public init(in tmp: TempDirectory, deviceID: String = "DJIMIC3", filesystem: Filesystem = .fat32, sizeMB: Int = 64) throws
    /// detach → attach（readOnly なら -readonly）
    public func reattach(readOnly: Bool) throws
    /// hdiutil detach -force <mountPoint>（失敗は無視）
    public func detach()
    deinit   // detach()
}
public struct DiskImageError: Error, CustomStringConvertible { public let description: String }
```

コマンド（`Foundation.Process` で `/usr/bin/hdiutil` を起動し、終了コード 0 以外は `DiskImageError(description: <引数と stderr>)` を投げる）:
- 作成: `hdiutil create -size <sizeMB>m -fs "MS-DOS FAT32" -volname <deviceID> -layout NONE <image>`（HFS+ は `-fs HFS+`。DJI Mic 3 と同じくパーティションの無い superfloppy にする）
- マウント: `hdiutil attach -nobrowse -noautoopen -noverify -mountpoint <mountPoint> [-readonly] <image>`
- 外す: `hdiutil detach -force <mountPoint>`
- **`/Volumes` の下には決してマウントしない**（利用者の実機 `/Volumes/DJIMIC3` と衝突させない。mountPoint は必ず一時ディレクトリの下）
- **テストの安全**: このチケットのテストは `/Volumes` 配下の実機（利用者が挿している DJI Mic 3 など）に一切触れない。`openVolume`・`SystemVolumeOpener`・`FakeVolumeOpener` に渡す `volumesRoot` は必ず一時ディレクトリの下（`FakeVolume.volumesRoot` / `DiskImageVolume.volumesRoot`）にし、`Contract.volumesRoot`（`/Volumes`）を渡さない。`/Volumes` 配下に `diskutil`・`hdiutil detach`・書き込み・削除・再マウントを行わない（`hdiutil detach` は自分が attach した `mountPoint` だけ）

## 5. テスト

### 5.1 `TargetIdentityTests.swift`（層 R2。`@Suite("TargetIdentity") struct TargetIdentityTests`）

共通の準備（`makeBench()`）: `TempDirectory` に `FakeVolume`（deviceID `DJIMIC3`）を作り、`FOLDER = "TX_MIC001_20260912_090000"`、`FILE = "TX00_MIC001_20260912_090000_orig.wav"`、
`REL = FOLDER + "/" + FILE`、中身 `standardContent`（4096 バイト）、`MTIME = 1787000000.0` で置く（voicedock の reaper ベンチと同じ値）。
ボリュームは `FakeVolumeOpener().open(volumesRoot: fake.volumesRoot.path(percentEncoded: false), deviceID: "DJIMIC3")` の `.opened` を使う。各テストは**弾かせたい条件以外をすべて満たす**（TEST-19）。

`openVolume` の検査（普通のディレクトリでは本物の `openVolume` を呼ぶ）:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `rv06PlainDirectoryIsNotAMountPoint` | RV-06 普通のディレクトリはマウント点ではない | FakeVolume の root | `.rejected(not_a_mount_point)` |
| `rv06MissingDeviceIsAbsent` | RV-06 無いデバイスは device_absent | `deviceID: "NOPE"` | `.absent` |
| `rv06MissingVolumesRootIsAbsent` | RV-06 ボリュームの親が無ければ absent | `volumesRoot` に無いパス | `.absent` |
| `rv06SymlinkVolumeIsRejected` | RV-06 symlink のボリュームは not_a_mount_point | `Volumes/ESCAPE -> DJIMIC3` を作り `deviceID: "ESCAPE"` | `.rejected(not_a_mount_point)` |
| `rv06FileAsVolumeIsRejected` | RV-06 ファイルのボリュームは not_a_mount_point | `Volumes/FILEVOL` を通常ファイルで作る | `.rejected(not_a_mount_point)` |
| `rv06InvalidDeviceIDIsRejected` | RV-06 不正な device_id は not_a_mount_point（パラメータ化） | `""`・`"a:b"`・`".x"`・`"a/b"`・`"DJIMIC3/.."` | `.rejected(not_a_mount_point)`（ファイルシステムに触れる前に弾く） |
| `systemVolumeOpenerDelegates` | SystemVolumeOpener は openVolume と同じ結果 | 上の 2 つ（普通のディレクトリ・無いデバイス） | 結果の理由語が同じ |

`withVerifiedTarget`:

| 関数名 | 表示名 | 準備（ベンチからの変更） | 期待 |
|---|---|---|---|
| `positiveControl` | 正の対照 [R2] 正しい対象なら body が呼ばれ、親 fd と名前を渡す | 変更なし。body の中で `fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0` を確かめ 42 を返す | `.success(42)`、body が 1 回呼ばれた |
| `rv08UnsafeRelpath` | RV-08 不健全な relpath は relpath_unsafe（パラメータ化） | relpath `""`・`"/abs"`・`"a//b"`・`"./" + REL`・`FOLDER + "/../" + REL` | `relpath_unsafe` |
| `nd24ParentTraversal` | ND-24 [R2] relpath に ../ があれば relpath_unsafe | ボリュームの外（`tmp/outside/<FOLDER>/<FILE>`）に同じファイルを置き、relpath `"../outside/" + REL` | `relpath_unsafe`、外のファイルは残る |
| `nd28DotPrefixed` | ND-28 [R2] . 始まりの要素は relpath_unsafe | `.Trashes/501/<FILE>` を置き、その relpath | `relpath_unsafe`、ファイルは残る |
| `rv09IntermediateSymlink` | RV-09 経路の途中の symlink は path_contains_symlink | `FOLDER` を実ディレクトリ `real` への symlink にし、`real/<FILE>` を置く | `path_contains_symlink` |
| `nd25SymlinkEscapesVolume` | ND-25 [R2] symlink 経由でボリュームの外を指せば path_contains_symlink | `FOLDER` をボリュームの外の `tmp/outside/<FOLDER>` への絶対パスの symlink にし、外にファイルを置く | `path_contains_symlink`、外のファイルは残る |
| `nd20SymlinkInPath` | ND-20 [R2] 対象自身か経路の途中に symlink があれば他の場所に触れない（パラメータ化） | (a) `FILE` を別の実ファイルへの symlink、(b) `FOLDER` を symlink | (a) `target_is_symlink`、(b) `path_contains_symlink`。どちらも body が呼ばれない |
| `rv09IntermediateRegularFile` | RV-09 経路の途中が通常ファイルなら path_contains_symlink | `FOLDER` を通常ファイルにする | `path_contains_symlink` |
| `rv09MissingTarget` | RV-09 対象が無ければ target_missing（パラメータ化） | (a) ファイルを消す、(b) `FOLDER` ごと無い | どちらも `target_missing` |
| `rv10TargetIsSymlink` | RV-10 対象が symlink なら target_is_symlink | `FILE` を同じフォルダの別ファイルへの symlink | `target_is_symlink` |
| `rv10NotRegularFile` | RV-10 通常ファイルでなければ not_regular_file（パラメータ化） | (a) `FILE` の名前のディレクトリ、(b) `FILE` の名前の FIFO | `not_regular_file` |
| `rv11FilenameRule` | RV-11 ファイル名が _orig の規則に合わなければ filename_rule（パラメータ化） | 名前 `TX00_MIC001_20260912_090000.wav`・`TX00_MIC001_20260912_090000_orig.wav.partial`・`notes.txt`（それぞれ置いて relpath を合わせる） | `filename_rule` |
| `nd37Denoised` | ND-37 [R2] denoised のファイルは filename_rule | `TX00_MIC001_20260912_090000.wav` | `filename_rule`、ファイルは残る |
| `rv11FolderRule` | RV-11 親フォルダ名が規則に合わなければ folder_rule（パラメータ化） | (a) フォルダ `other`、(b) ボリューム直下の `FILE`（relpath 1 要素） | `folder_rule` |
| `nd29BadFolder` | ND-29 [R2] 親フォルダ名が規則外なら folder_rule | フォルダ `TX_MIC001_2026091_090000`（日付 7 桁） | `folder_rule` |
| `rv12SizeMismatch` | RV-12 size が違えば size_mismatch | `expectedSize: 4097` | `size_mismatch` |
| `nd18SizeChangedJustBeforeDeletion` | ND-18 [R2] 削除直前にサイズが変わると size_mismatch | 期待値を記録した後、ファイルに 1 バイト追記し mtime は元に戻す | `size_mismatch` |
| `rv12MtimeBoundary` | RV-12 mtime の差が 2.0 以上なら mtime_mismatch（パラメータ化） | expectedMtime を MTIME + d にする: d = 2.0・−2.0・120（voicedock の例） → 不一致、1.999・−1.999・1（voicedock の例）・0 → 一致 | 不一致は `mtime_mismatch`、一致は `.success` |
| `rv12NaNExpectedMtime` | RV-12 期待する mtime が NaN なら不一致（fail-closed） | `expectedMtime: .nan` | `mtime_mismatch` |
| `nd19MtimeChangedJustBeforeDeletion` | ND-19 [R2] 削除直前に mtime が変わると mtime_mismatch | 期待値を記録した後 mtime を +120 秒 | `mtime_mismatch` |
| `checksRunInOrder` | 検査の順序（パラメータ化） | (a) denoised の名前で size も違う、(b) フォルダも名前も違う、(c) symlink で名前も違う | (a) `filename_rule`、(b) `filename_rule`、(c) `target_is_symlink` |
| `bodyNotCalledOnMismatch` | 不一致のとき body を呼ばない | `expectedSize: 1` と、body で呼び出し回数を数える | 0 回 |
| `reasonsAreVerbatim` | 理由語の一覧（付録 B.2） | `IdentityReason.all` | 4.1 の 21 語をこの順に。重複が無い |

（ND の表示名は ID の後に層 `[R2]` を書く。PLAN §10.3）

### 5.2 `TargetIdentityDiskImageTests.swift`（`@Suite("TargetIdentity on disk image", .serialized, .enabled(if: TestEnvironment.diskTests))`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `rv06Fat32IsOpened` | RV-06 FAT32 のマウント点は開ける | `DiskImageVolume(.fat32)` | `.opened`、`readOnly == false`、`mountPath == realpath(volumesRoot) + "/DJIMIC3"` |
| `rv06HfsIsUnexpectedFS` | RV-06 HFS+ は unexpected_fs | `DiskImageVolume(.hfsPlus)` | `.rejected(unexpected_fs)` |
| `rv07ReadOnlyIsObserved` | RV-07 読み取り専用のマウントを観測する | FAT32 を `reattach(readOnly: true)` | `.opened`、`readOnly == true` |
| `fullChainOnFat` | FAT の上で検証が通る | FAT32 に `FOLDER/FILE` を 4096 バイトで置き、mtime を読み直した値で `withVerifiedTarget` | `.success` |
| `rv12FatTwoSecondResolution` | RV-12 FAT の mtime の 2 秒分解能でも一致する | mtime `1787000001` を設定（FAT は `1787000000` で保存する）し、`expectedMtime: 1787000001` | `.success`（差 1.0 < 2.0） |

### 5.3 `FakeVolumeTests.swift`（偽物そのもののテスト。TEST-05）

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `standardTreeLayout` | 標準の木が StandardTree のとおり | `populateStandardTree(copyTime: 1787016440)` の後、`origInScope`・`denoised`・`beyondDepth`・`hidden` の全ファイルが在る。`symlinkFolder` が symlink で宛先が `TX_MIC001_20260829_071201` |
| `deviceMtimeIsOffset` | 原本の mtime はコピー時刻の 4 時間 34 分前 | 全ファイルの mtime が `1787000000`（= 1787016440 − 16440） |
| `origNamesParse` | 候補の名前は規則に一致する | `origInScope` の各最後の要素が `RecordingName.parseFile` で `isOrig == true` |
| `fakeOpenerSkipsMountCheck` | FakeVolumeOpener は普通のディレクトリを開く | `.opened`、`readOnly` が引数どおり |

## 6. 破壊による証明

| # | 壊し方 | 落ちるべきテスト |
|---|---|---|
| 1 | `withVerifiedTarget` の中間要素の `O_NOFOLLOW` を消す | `rv09IntermediateSymlink`、`nd25SymlinkEscapesVolume`、`nd20SymlinkInPath`(b) |
| 2 | 最後の `fstatat` の `AT_SYMLINK_NOFOLLOW` を 0 にする | `rv10TargetIsSymlink`、`nd20SymlinkInPath`(a) |
| 3 | `RelPath.isSafe` の呼び出しを消す | `rv08UnsafeRelpath`、`nd28DotPrefixed`、`nd24ParentTraversal` |
| 4 | ファイル名の検査を `parseFile(name) != nil`（`isOrig` を見ない）にする | `rv11FilenameRule`、`nd37Denoised` |
| 5 | 親フォルダの検査を消す | `rv11FolderRule`、`nd29BadFolder` |
| 6 | mtime の比較を `<` から `<=` にする | `rv12MtimeBoundary`（d = 2.0・−2.0） |
| 7 | mtime の比較を `abs(...) >= 2.0 ならば不一致` に書き換える（NaN が一致になる） | `rv12NaNExpectedMtime` |
| 8 | `openVolume` の `f_mntonname` の比較を消す | `rv06PlainDirectoryIsNotAMountPoint` |
| 9 | `openVolume` の `DeviceID.isValid` を消す | `rv06InvalidDeviceIDIsRejected` |
| 10 | `openVolume` の FS 種別の検査を消す（`VOICEDOCK_DISK_TESTS=1` で） | `rv06HfsIsUnexpectedFS` |
| 11 | `readOnly` を常に false にする（同上） | `rv07ReadOnlyIsObserved` |
| 12 | 検査の順序で size を filename より先にする | `checksRunInOrder`(a) |

## 7. 受け入れ条件

- [ ] `TargetIdentity.swift` に書き込み系のフラグ・`unlink` が無い（PT-10(b)・PT-01）
- [ ] `VolumeHandle(` の呼び出しが `Sources/` では `TargetIdentity.swift` にしか無い（PT-22）
- [ ] 5.1 と 5.3 のテストが `make test` で通る。5.2 が `make test-disk` で通り、その出力を PR 本文に貼る
- [ ] ND-18・19・20・24・25・28・29・37 の `[R2]` のテストがある（層 R3 は T-37）
- [ ] 破壊による証明 12 項目の結果が PR 本文にある（10・11 は `make test-disk` で）
- [ ] テストとテスト部品が `/Volumes` 配下に触れない（`volumesRoot` と `mountPoint` がすべて一時ディレクトリの下。`Contract.volumesRoot` をテストで渡していない）

## 8. API 地図への変更提案

1. `IdentityMismatch` に公開の初期化子 `init(_ reason: String)` を足す（reaper がこの型で拒否理由を運ぶため） → 00-api-map に反映済み（2026-09-18）
2. `IdentityReason` に reaper の全理由語（`lock1`・`conf_invalid`・`malformed_request_id`・`malformed_request`・`replayed`・`partkey_mismatch`・`device_absent`・`mount_readonly`・`unlink_failed`・`still_present`）も入れ、`all` を公開する（付録 B.2 の語を 1 か所に置く。reaper とアプリと SPEC 同期が共有する） → 00-api-map に反映済み（2026-09-18）
3. `SystemVolumeOpener.init()` を公開する → 00-api-map に反映済み（2026-09-18）

## 9. SPEC の変更

`docs/SPEC.md` の付録 B.2 の理由語の列と `IdentityReason.all` を照合するテストは T-05 の SPEC 同期に足す（このチケットでは `reasonsAreVerbatim` で固定値と照合する）。

## 10. マージ後にやること

なし
