# T-06 VDContract: 鍵・名前規則・削除要求の JSON・AtomicFile・HomeLayout・ReaperConf・FileLock

> （F-73・issue #113。2026-09-23）`RelPath` の分割・先頭の `/`・`.` 始まりの判定を Unicode スカラー（UTF-8 の 0x2F）で行うようにした（書記素で見ると `/` の直後の結合文字で区切りを見落とす。ASCII の入力の結果は変わらない）。
> `ReaperConf.observe` の open に `O_NONBLOCK`（FIFO で止まらない）、`FileLock.tryAcquire` の open に `O_NOFOLLOW`（symlink を辿らない）を足した。以下の本文の手順・フラグは記録として残す。
> テストは `RelPathScalarTests`・`FileLockNoFollowTests`（reaper.conf の FIFO は `ReaperDefenseTests`）。

> （F-76・issue #116。2026-09-23。マージ後の追記）`HomeLayout` に `appLock`（`state/app.lock`。アプリの単一起動のロック。reaper.lock とは別）を足した（§4.16 の表と `HomeLayoutTests` の「全プロパティ」の表）。

| 項目 | 値 |
|---|---|
| Phase | 1（骨組みと防護柵） |
| 前提 | T-01（Package.swift に `VDContract` / `VDContractTests` / `TestSupport` のターゲットがあり、`VERSION` がある） |
| 見積もり | ソース約 650 行・テスト約 700 行（600 行の目安を超える。レビューしやすいよう「作るもの」の A 群と B 群を別コミットにし、PR 本文でも分けて説明する） |
| 後続 | T-07（TargetIdentity）、T-08 以降のすべて、T-37（reaper） |

## 1. 目的

アプリと reaper が**同じソースを import して共有する規則**（PLAN §4）を VDContract に実装する。録音の名前規則・partkey / session_key / key_slug・relpath の健全性・削除要求と結果の JSON・reaper.conf の書式・`<HOME>` のパス・atomic な書き込み・ロックファイルを 1 か所に置き、「同じ規則を 2 か所に書かない」（§9.1 原則 2）を構造で守る。テストの基礎部品（`TempDirectory`・`PackageRoot`・`TestEnvironment`）は T-01 が作ったものを使う（このチケットでは作らない）。

## 2. 参照

- PLAN §2.3（データ配置）、§4.1〜§4.5・§4.7、§8.9.4（reaper.conf の書式）、§9.2（CR-01・CR-06）、§9.4（PT-06・PT-10・PT-12・PT-19・PT-20）、付録 B.2（理由語は T-07）、§10.1（テストの有効化）、§11.4（版）
- 00-api-map §1
- voicedock@d3d595e:
  - `src/voicedock/device.py:36-45`（名前規則の正規表現）、`:68-92`（`parse_filename`）
  - `src/voicedock/paths.py:108-125`（`is_safe_relpath`）、`:131-158`（`partkey_for`）、`:161-267`（session_key）、`:317-329`（`key_slug`）
  - `src/voicedock/cleaner.py:48-81, 391-458`（要求の JSON と request_id）
  - `helper/voicedock-reaper:180-197`（結果の JSON）
  - `tests/unit/test_device_parse.py`、`tests/unit/test_paths.py:153-168, 366-466`（固定例）

## 3. 作るもの

A 群（名前と鍵）:
- `Sources/VDContract/Version.swift`
- `Sources/VDContract/Contract.swift`
- `Sources/VDContract/LocalDateTime.swift`
- `Sources/VDContract/RecordingName.swift`
- `Sources/VDContract/DeviceID.swift`
- `Sources/VDContract/RelPath.swift`
- `Sources/VDContract/KeyError.swift`
- `Sources/VDContract/PartKey.swift`
- `Sources/VDContract/SessionKey.swift`
- `Sources/VDContract/KeySlug.swift`
- `Sources/VDContract/RequestID.swift`
- `Sources/VDContract/PatternMatch.swift`（internal。正規表現の全体一致）

B 群（ファイルと JSON）:
- `Sources/VDContract/DeleteRequest.swift`
- `Sources/VDContract/DeleteResult.swift`
- `Sources/VDContract/ContractJSON.swift`
- `Sources/VDContract/ReaperConf.swift`
- `Sources/VDContract/HomeLayout.swift`
- `Sources/VDContract/AtomicFile.swift`
- `Sources/VDContract/FileLock.swift`
- `Sources/VDContract/PosixIO.swift`（internal。errno を返す読み書きの補助。T-07 も使う）

テストの基礎部品（`Tests/TestSupport/`）: 作らない（`TempDirectory`・`PackageRoot`・`TestEnvironment` は T-01 が作る。4.20）

テスト（`Tests/VDContractTests/`）:
- `VersionTests.swift`、`LocalDateTimeTests.swift`、`RecordingNameTests.swift`、`DeviceIDTests.swift`、`RelPathTests.swift`、`PartKeyTests.swift`、`SessionKeyTests.swift`、`KeySlugTests.swift`、`RequestIDTests.swift`、
  `ContractJSONTests.swift`、`ReaperConfTests.swift`、`HomeLayoutTests.swift`、`AtomicFileTests.swift`、`FileLockTests.swift`

import は `Foundation`・`Darwin`・`CryptoKit` だけ（PLAN §3.4、PT-07）。VD の他モジュールを import しない（reaper が VDContract だけに依存するため）。

## 4. 仕様

各ファイルの先頭 1 行のコメントは括弧内の文を逐語で書く。

### 4.1 `Version.swift`（「// アプリと reaper の版。VERSION ファイルと一致させる（PLAN §11.4）。」）

```swift
public enum AppVersion {
    /// VERSION ファイルの中身（前後の空白・改行を除いたもの）と同じ文字列。版を上げる PR で両方を変える。
    public static let string = "<VERSION の中身>"

    /// "X.Y.Z"（各要素は ASCII の 10 進。符号・空要素・余計な要素は不可）を数値の組にする。形式外は nil。
    public static func components(_ s: String) -> (major: Int, minor: Int, patch: Int)?

    /// 両方が components で読め、3 つの数が等しいときだけ真。文字列の辞書順で比べない（"1.10.0" と "1.9.0"）。
    public static func isSame(_ a: String, _ b: String) -> Bool
}
```

`components` の手順:
1. `s.split(separator: ".", omittingEmptySubsequences: false)` の要素数が 3 でなければ nil
2. 各要素が空でなく、すべての Unicode スカラーが `"0"..."9"`（U+0030〜U+0039）でなければ nil
3. 各要素を `Int(_:)` で変換（失敗・桁あふれは nil）

`AppVersion.string` の初期値は T-01 が置いた `VERSION` の中身と同じにする（テストで照合）。

### 4.2 `Contract.swift`（「// アプリと reaper が共有する定数（PLAN §4.5）。」）

```swift
public enum Contract {
    /// RV-12。アプリの事前確認も同じ値を使う。
    public static let mtimeToleranceSeconds: Double = 2.0
    public static let requestSchema = 1
    public static let resultSchema = 1
    public static let reaperConfSchema = 1
    public static let reaperFileName = "voicedock-reaper"
    /// reaper.conf の VOLUMES_ROOT で上書きできる（テスト用）。
    public static let volumesRoot = "/Volumes"
    /// RV-06。DJI Mic 3 は MS-DOS FAT32（実機の mount 出力: msdos, local, nodev, nosuid, noowners, noatime, fskit）。
    public static let expectedFilesystem = "msdos"
    /// 要求ファイルと reaper.conf の上限（バイト）。
    public static let maxRequestBytes = 65_536
}
```

### 4.3 `LocalDateTime.swift`（「// オフセットを持たない壁時計の日時（ファイル名の時刻。PLAN §4.1）。」）

```swift
public struct LocalDateTime: Equatable, Hashable, Sendable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int

    /// 整数範囲で検査する（Calendar に任せない）。範囲外は nil。
    public init?(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int)

    /// "yyyyMMdd"（4 桁・2 桁・2 桁のゼロ埋め）。
    public var dayStamp: String { get }

    /// (year, month, day, hour, minute, second) の辞書順。
    public static func < (lhs: LocalDateTime, rhs: LocalDateTime) -> Bool

    /// グレゴリオ暦の月の日数。month が 1〜12 以外なら 0。
    public static func daysInMonth(year: Int, month: Int) -> Int
}
```

検査（すべて満たすときだけ値を作る）: `1 <= year <= 9999`、`1 <= month <= 12`、`1 <= day <= daysInMonth(year, month)`、`0 <= hour <= 23`、`0 <= minute <= 59`、`0 <= second <= 59`。
閏年は `(year % 4 == 0 && year % 100 != 0) || year % 400 == 0`。`daysInMonth`: 1,3,5,7,8,10,12 → 31、4,6,9,11 → 30、2 → 閏年 29・平年 28。
`dayStamp` は `String(format: "%04d%02d%02d", year, month, day)`。

### 4.4 `PatternMatch.swift`（internal。「// NSRegularExpression で文字列全体に一致するかを調べる（PLAN §4.1）。」）

```swift
enum PatternMatch {
    /// pattern を毎回コンパイルし（NSRegularExpression は Sendable が保証されないので static に持たない）、
    /// 範囲 NSRange(location: 0, length: s.utf16.count) で firstMatch を取り、一致範囲が文字列全体と等しいときだけ
    /// 捕捉グループの文字列（範囲が NSNotFound のグループは nil）を返す。コンパイル失敗・不一致・部分一致は nil。
    static func wholeMatch(_ pattern: String, _ s: String) -> [String?]?
}
```

- 戻り値の配列の要素数は `numberOfCaptureGroups + 1`（添字 0 は全体）。部分文字列は `Range(nsRange, in: s)` で取る
- `$` は末尾の改行の直前にも一致する（`"…wav\n"` で `{0, 36}` を返すことを確認済み）ので、**一致範囲の長さ == `s.utf16.count` の確認が要る**
- `try!` を使わない（PT-19）。`try?` で失敗は nil

### 4.5 `RecordingName.swift`（「// DJI Mic 3 の録音ファイル名とフォルダ名の規則（PLAN §4.1）。」）

```swift
public enum RecordingName {
    /// ファイル名。逐語（Swift のソースでは raw 文字列 #"…"# で書く）。
    public static let filePattern = #"^(TX[0-9]{2})_(MIC[0-9]{3})_([0-9]{8})_([0-9]{6})(_orig)?\.(wav|WAV)$"#
    /// フォルダ名。逐語。
    public static let folderPattern = #"^TX_(MIC[0-9]{3})_([0-9]{8})_([0-9]{6})$"#

    public static func parseFile(_ name: String) -> ParsedFile?
    /// ファイル名の規則の形だけを見る（日時の妥当性は見ない。走査で「形は一致するが日時が不正」＝ `unparsable_filename` を見分けるため。T-14）
    public static func matchesFilePattern(_ name: String) -> Bool
    public static func isFolder(_ name: String) -> Bool
}

public struct ParsedFile: Equatable, Sendable {
    /// "TX01"（文字列のまま）
    public let transmitterID: String
    /// "MIC002" → 2
    public let micIndex: Int
    /// ファイル名の年月日時分秒（オフセット無し。TIME-03: タイムゾーンは付与するだけで変換しない）
    public let local: LocalDateTime
    /// `_orig` が付いているか（取り込みも削除も `_orig` だけ。DEL-34）
    public let isOrig: Bool
    /// "wav" か "WAV"
    public let ext: String
}
```

`parseFile` の手順:
1. `PatternMatch.wholeMatch(filePattern, name)` が nil なら nil
2. グループ 1 → `transmitterID`、グループ 2（`MIC` + 3 桁）の先頭 3 文字を除いて `Int` → `micIndex`、グループ 5 が nil でない → `isOrig`、グループ 6 → `ext`
3. グループ 3（8 桁）を 4・2・2 桁に、グループ 4（6 桁）を 2・2・2 桁に分けて `Int` にし、`LocalDateTime(year:month:day:hour:minute:second:)`。nil なら nil（2/30・13 月・24 時などは例外にせず nil）
4. `ParsedFile` を返す

`matchesFilePattern`: `PatternMatch.wholeMatch(filePattern, name) != nil`（**日時の妥当性は見ない**。`parseFile` が nil でもこれが真なら「形は一致するが日時が不正」）。

`isFolder`: `PatternMatch.wholeMatch(folderPattern, name) != nil`（**日時の妥当性は見ない**。voicedock の `RECORDING_FOLDER_RE` と同じ）。

### 4.6 `DeviceID.swift`（「// device_id（= /Volumes 直下の名前）の健全性（PLAN §4.2）。」）

```swift
public enum DeviceID {
    /// 空・"/" を含む・":" を含む・"." で始まる・制御文字（U+0000〜U+001F, U+007F）を含む → 偽。空白は可（"NO NAME"）。
    public static func isValid(_ id: String) -> Bool
}
```

### 4.7 `RelPath.swift`（「// デバイス上の relpath の健全性と結合（PLAN §4.3。RV-08 とアプリの事前確認で共有）。」）

```swift
public enum RelPath {
    public static let maxUTF8Bytes = 1024

    /// 生の文字列を "/" で分割して（空要素を省かない）検査する。1 つでも当たれば偽:
    /// 空文字 / "/" で始まる / 空要素（"//"・末尾の "/"）/ 要素が "." か ".." / 要素が "." で始まる /
    /// 制御文字（U+0000〜U+001F, U+007F）/ "\" を含む / UTF-8 で 1024 バイト超。
    public static func isSafe(_ relpath: String) -> Bool

    /// `relpath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)`
    public static func components(_ relpath: String) -> [String]

    /// components を "/" でつなぐ（検査しない。relpath の組み立てはこれだけで行う。PT-06）
    public static func join(_ components: [String]) -> String

    /// 最後の要素を除いた部分（1 要素なら ""）
    public static func parent(_ relpath: String) -> String

    /// 最後の要素（`components(relpath).last ?? ""`）
    public static func lastComponent(_ relpath: String) -> String
}
```

- `isSafe` は voicedock より厳しい（`./a.wav` と `a//b.wav` を偽にする。voicedock の `PurePosixPath` は正規化して真にしていた）。この違いを doc コメントに書く
- `join` は `components.joined(separator: "/")`、`parent` は `join(Array(components(relpath).dropLast()))`

### 4.8 `KeyError.swift`（「// 鍵の組み立てと分解の失敗（プログラムの誤り。ErrorCode を持たない）。」）

```swift
public enum KeyError: Error, Equatable, Sendable {
    case invalidDeviceID
    case unsafeRelpath
    case invalidDayStamp
    case invalidOverflow
    case malformedKey
}
```

### 4.9 `PartKey.swift`（「// partkey の組み立てと分解。partkey を作るのはここだけ（PLAN §4.2、PT-06）。」）

```swift
public enum PartKey {
    /// 1. DeviceID.isValid が偽 → throw .invalidDeviceID
    /// 2. RelPath.isSafe が偽 → throw .unsafeRelpath
    /// 3. "\(deviceID)/\(relpath)"
    public static func make(deviceID: String, relpath: String) throws(KeyError) -> String

    /// 最初の "/" より前。"/" が無い・前が空なら nil
    public static func deviceID(of partkey: String) -> String?

    /// 最初の "/" より後。"/" が無い・後が空なら nil
    public static func relpath(of partkey: String) -> String?
}
```

`make` の doc コメントに逐語で書く: 「期待値を書き換えて通すな。規則を変えると、それ以前に保存した録音が永久に削除対象外になる（DEL-01、RK-27）。」

### 4.10 `SessionKey.swift`（「// session_key の組み立てと分解（PLAN §4.2）。」）

```swift
public enum SessionKey {
    /// 1. DeviceID.isValid が偽 → .invalidDeviceID
    /// 2. dayStamp が ASCII 数字ちょうど 8 桁で、LocalDateTime(year:month:day:hour:0,minute:0,second:0) が作れること。でなければ .invalidDayStamp
    /// 3. overflow < 1 → .invalidOverflow
    /// 4. overflow == 1 → "\(deviceID):\(dayStamp)"、それ以外 → "\(deviceID):\(dayStamp)#\(overflow)"（"#1" は作らない）
    public static func make(deviceID: String, dayStamp: String, overflow: Int = 1) throws(KeyError) -> String

    /// 最後の ":" より前。":" が無い・前が空なら nil
    public static func deviceID(of key: String) -> String?

    /// 最後の ":" より後から "#…" を除いた部分が ASCII 数字 8 桁ならそれ。でなければ nil
    public static func dayStamp(of key: String) -> String?

    /// "#" が無ければ 1。"#" の後が正規表現 ^[1-9][0-9]*$ に一致し、Int にでき、2 以上ならその値。それ以外は nil（"#1"・"#02"・"#x" は nil）
    public static func overflow(of key: String) -> Int?

    /// deviceID(of:)・dayStamp(of:)・overflow(of:) のどれかが nil → throw .malformedKey。
    /// そうでなければ make(deviceID:dayStamp:overflow: overflow + 1)（接尾辞無し → "#2"、"#n" → "#(n+1)"）
    public static func nextOverflow(_ key: String) throws(KeyError) -> String
}
```

- 「ASCII 数字」は Unicode スカラーが U+0030〜U+0039 であること（`Character.isNumber` は全角数字も真にするので使わない）
- 固定値のテストの doc コメントに 4.9 と同じ注意を書く

### 4.11 `KeySlug.swift`（「// key_slug = sha256(key の UTF-8) の 16 進の先頭 16 文字（PLAN §4.2）。」）

```swift
public enum KeySlug {
    /// CryptoKit の SHA256.hash(data: Data(key.utf8)) を小文字 16 進にし、先頭 16 文字。
    public static func of(_ key: String) -> String
}
```

16 進化は `digest.map { String(format: "%02x", $0) }.joined()`。

### 4.12 `RequestID.swift`（「// 削除要求の ID（PLAN §4.4）。UTC・Z 付き。」）

```swift
public enum RequestID {
    public static let pattern = "^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}-[0-9a-f]{6}$"

    /// "<gmtime の yyyyMMdd'T'HHmmss>Z-<KeySlug.of(partkey)>-<randomHex6>"。
    /// 時刻は gmtime_r で UTC に分解し String(format: "%04d%02d%02dT%02d%02d%02dZ", ...) で作る（Calendar・DateFormatter を使わない）。
    /// randomHex6 は検査しない（形式外なら isValid が偽になる文字列を返す。呼び手は randomHex6() の値だけを渡す）。
    public static func make(partkey: String, utcEpochSeconds: Int64, randomHex6: String) -> String

    /// PatternMatch.wholeMatch(pattern, id) != nil
    public static func isValid(_ id: String) -> Bool

    /// SystemRandomNumberGenerator から 3 バイト（UInt8.random(in: 0...255, using:) を 3 回）を小文字 16 進 6 文字に（PLAN §4.4）。
    public static func randomHex6() -> String
}
```

- `make` の `gmtime_r` が失敗（戻り値 nil）したら年月日時分秒をすべて 0 として書く（`00000000T000000Z-…`。形式としては有効だが、現実の時刻では起きない。例外にしない）
- `randomHex6()` は §8「API 地図への変更提案」の 1 で 00-api-map に反映済み

### 4.13 `DeleteRequest.swift` / `DeleteResult.swift`

```swift
// 削除要求（アプリが書き、reaper が読む。PLAN §4.4）。絶対パスを持たない。
public struct DeleteRequest: Equatable, Sendable {
    public let schema: Int           // Contract.requestSchema
    public let requestID: String     // JSON "request_id"
    public let createdAt: String     // JSON "created_at"（ZonedTime.iso の文字列。VDContract は書式を作らない）
    public let deviceID: String      // JSON "device_id"
    public let partkey: String       // JSON "partkey"
    public let sessionKey: String    // JSON "session_key"
    public let target: DeleteTarget  // JSON "targets" の 1 要素配列
    public init(schema: Int = Contract.requestSchema, requestID: String, createdAt: String, deviceID: String,
                partkey: String, sessionKey: String, target: DeleteTarget)
}

public struct DeleteTarget: Equatable, Sendable {
    public let relpath: String
    /// DB の source_size（デバイス上の原本の値。DEL-12）
    public let size: Int64
    /// DB の source_mtime（デバイス上の原本の値。DEL-12）
    public let mtime: Double
    public init(relpath: String, size: Int64, mtime: Double)
}
```

```swift
// 削除結果（reaper が書き、アプリが読む。PLAN §4.4）。
public struct DeleteResult: Equatable, Sendable {
    public let schema: Int           // Contract.resultSchema
    public let requestID: String     // "request_id"
    public let completedAt: String   // "completed_at"
    public let reaperVersion: String // "reaper_version"
    public let deviceID: String      // "device_id"
    public let partkey: String       // "partkey"
    public let status: DeleteResultStatus
    /// DELETED なら relpath、SOURCE_IDENTITY_MISMATCH なら理由語（どちらか一方。連結しない）
    public let detail: String
    public init(schema: Int = Contract.resultSchema, requestID: String, completedAt: String, reaperVersion: String,
                deviceID: String, partkey: String, status: DeleteResultStatus, detail: String)
}

public enum DeleteResultStatus: String, Sendable, CaseIterable {
    case deleted = "DELETED"
    case sourceIdentityMismatch = "SOURCE_IDENTITY_MISMATCH"   // PT-06 の例外として許可されている唯一の場所
}
```

### 4.14 `ContractJSON.swift`（「// 削除要求と結果の JSON の符号化と厳格な復号（PLAN §4.4）。アプリと reaper が共有する。」）

```swift
public enum ContractJSON {
    public static func encode(_ r: DeleteRequest) throws(ContractEncodeError) -> Data
    public static func encode(_ r: DeleteResult) throws(ContractEncodeError) -> Data
    public static func decodeRequest(_ data: Data) -> Result<DeleteRequest, ContractDecodeError>
    public static func decodeResult(_ data: Data) -> Result<DeleteResult, ContractDecodeError>

    public static let requestKeys: Set<String> = ["schema", "request_id", "created_at", "device_id", "partkey", "session_key", "targets"]
    public static let targetKeys: Set<String> = ["relpath", "size", "mtime"]
    public static let resultKeys: Set<String> = ["schema", "request_id", "completed_at", "reaper_version", "device_id", "partkey", "status", "detail"]
}

public enum ContractEncodeError: Error, Equatable, Sendable {
    case nonFiniteNumber            // mtime が NaN / ±∞（JSONEncoder が符号化できない）
}

public enum ContractDecodeError: Error, Equatable, Sendable {
    case notJSONObject              // UTF-8 でない・JSON でない・トップレベルがオブジェクトでない
    case keySetMismatch             // トップレベルのキー集合が期待と完全一致しない
    case wrongType(String)          // 値の型が違う（引数はキーのパス。例 "schema"、"targets.size"）
    case badSchema                  // schema が整数 1 でない
    case badTargets                 // targets が配列でない・要素数が 1 でない・要素のキー集合が違う
}
```

**符号化**（`encode`）:
1. internal の `Codable` な DTO（`RequestDTO` / `TargetDTO` / `ResultDTO`。プロパティ名を snake_case のキーと同じにするか `CodingKeys` で対応させる）へ写す。要求の `targets` は `[target]`
2. `JSONEncoder()`、`outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`、他は既定のまま（非有限の Double は既定で throw）
3. 符号化に失敗したら `throw ContractEncodeError.nonFiniteNumber`
4. 末尾に `"\n"`（0x0A）を 1 バイト足して返す

出力の例（下の固定テストで照合する。JSONEncoder の実出力を Xcode 27.0 で確認済み）:

```text
{
  "created_at" : "2026-09-12T18:00:00+09:00",
  "device_id" : "DJIMIC3",
  "partkey" : "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
  "request_id" : "20260912T090000Z-a5d046dce76cfedc-a1b2c3",
  "schema" : 1,
  "session_key" : "DJIMIC3:20260829",
  "targets" : [
    {
      "mtime" : 1787000000,
      "relpath" : "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
      "size" : 345600000
    }
  ]
}
```

（最後の `}` の後に改行が 1 つ。`mtime` の `1787000000.0` は `.0` 無しで出る。`1787000000.25` は `1787000000.25`）

**復号**（`decodeRequest`。この順に確かめ、最初に当たった誤りを返す）:
1. `String(data: data, encoding: .utf8)` が nil → `.notJSONObject`
2. `JSONSerialization.jsonObject(with: data, options: [])` が throw するか `[String: Any]` でない → `.notJSONObject`
3. `Set(dict.keys) != requestKeys` → `.keySetMismatch`
4. `schema`: `NSNumber` でない、または真偽値（`CFGetTypeID(n) == CFBooleanGetTypeID()`）→ `.wrongType("schema")`。
   `CFNumberIsFloatType(n)` が真（`1.0` などの浮動小数の表記）か `n.int64Value != 1` → `.badSchema`
5. `request_id`・`created_at`・`device_id`・`partkey`・`session_key` の順に、`String` でなければ `.wrongType("<キー>")`
6. `targets`: `[Any]` でない・要素数が 1 でない・要素が `[String: Any]` でない・要素のキー集合が `targetKeys` と一致しない → `.badTargets`
7. `targets[0].relpath` が `String` でない → `.wrongType("targets.relpath")`
8. `targets[0].size`: `NSNumber` でない・真偽値・浮動小数の表記（`CFNumberIsFloatType`）・`int64Value < 0` → `.wrongType("targets.size")`
9. `targets[0].mtime`: `NSNumber` でない・真偽値・`doubleValue` が有限でない → `.wrongType("targets.mtime")`（整数の表記も小数の表記も受ける）
10. `DeleteRequest` を作って返す

- **真偽値を数として受けない**: `JSONSerialization` の `true` は `NSNumber` で、`as? Int` が 1 として通ってしまう（確認済み）。必ず `CFBooleanGetTypeID` で弾く
- JSON の重複キーは `JSONSerialization` の既定（後勝ち）のまま受ける（reaper は RV-02b で request_id とファイル名の一致を別に見る）
- `request_id` の形式（`RequestID.isValid`）は復号では見ない（reaper の RV-02b とアプリの回収が見る）

**`decodeResult`** は同じ手順で、キー集合は `resultKeys`、文字列は `request_id`・`completed_at`・`reaper_version`・`device_id`・`partkey`・`status`・`detail` の順、
`status` は文字列で `DeleteResultStatus(rawValue:)` が nil なら `.wrongType("status")`、`targets` の段は無い。

### 4.15 `ReaperConf.swift`（「// bin/reaper.conf の書式（PLAN §8.9.4）。アプリの有効化フローと reaper が同じ関数で読み書きする。」）

```swift
public struct ReaperConf: Equatable, Sendable {
    public let schema: Int               // 常に Contract.reaperConfSchema
    public let deleteSourceAudio: Bool
    public let volumesRoot: String       // 既定 Contract.volumesRoot

    public init(deleteSourceAudio: Bool, volumesRoot: String = Contract.volumesRoot)   // schema = 1

    public static let keySchema = "SCHEMA"
    public static let keyDeleteSourceAudio = "DELETE_SOURCE_AUDIO"
    public static let keyVolumesRoot = "VOLUMES_ROOT"
    public static let linePattern = #"^[A-Z_]+=[^[:space:]]*$"#

    public static func parse(_ data: Data) -> Result<ReaperConf, ReaperConfError>
    public func render() -> Data
    public static func observe(at url: URL) -> ReaperConfObservation
}

public enum ReaperConfObservation: Equatable, Sendable {
    case missing
    case invalid(ReaperConfError)
    case valid(ReaperConf)
}

public enum ReaperConfError: Error, Equatable, Sendable {
    case unreadable                // 開けない（ENOENT 以外）・読めない・UTF-8 でない
    case tooLarge                  // 64 KiB（Contract.maxRequestBytes）超
    case notRegularFile            // symlink（O_NOFOLLOW で ELOOP）・通常ファイルでない
    case badLine(Int)              // 行番号（1 始まり）の行が linePattern に一致しない
    case unknownKey(String)
    case duplicateKey(String)
    case missingKey(String)
    case badValue(String)          // 引数はキー名
}
```

**`parse`**（fail-closed。最初に当たった誤りを返す）:
1. `data.count > Contract.maxRequestBytes` → `.tooLarge`
2. `String(data: data, encoding: .utf8)` が nil → `.unreadable`
3. `text.split(separator: "\n", omittingEmptySubsequences: false)` を 1 始まりの行番号 n で順に:
   - 行が空文字 → 飛ばす
   - 行が `#` で始まる → 飛ばす
   - `PatternMatch.wholeMatch(linePattern, line)` が nil → `.badLine(n)`（`\r` や空白を含む行、小文字のキーはここで落ちる）
   - key = 最初の `=` より前、value = 後
   - key が 3 つのキーのどれでもない → `.unknownKey(key)`
   - key を既に見た → `.duplicateKey(key)`
   - 覚える
4. `SCHEMA` が無い → `.missingKey("SCHEMA")`。値が `"1"` でない → `.badValue("SCHEMA")`
5. `DELETE_SOURCE_AUDIO` が無い → `.missingKey("DELETE_SOURCE_AUDIO")`。値が `"true"` / `"false"` 以外 → `.badValue("DELETE_SOURCE_AUDIO")`
6. `VOLUMES_ROOT` が無い → `Contract.volumesRoot`。在って `/` で始まらない（空を含む）→ `.badValue("VOLUMES_ROOT")`
7. `.success(ReaperConf(deleteSourceAudio:volumesRoot:))`

**`render`**: `"SCHEMA=1\nDELETE_SOURCE_AUDIO=\(deleteSourceAudio ? "true" : "false")\nVOLUMES_ROOT=\(volumesRoot)\n"` を UTF-8 にしたもの。書き込みは呼び手が `AtomicFile.write(_, to:, permissions: 0o644)` で行う（このファイルは書かない）。

**`observe(at:)`**:
1. `open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)`。失敗: `ENOENT` → `.missing`、`ELOOP` → `.invalid(.notRegularFile)`、その他 → `.invalid(.unreadable)`
2. `fstat`。失敗 → `.invalid(.unreadable)`。`(st_mode & S_IFMT) != S_IFREG` → `.invalid(.notRegularFile)`。`st_size > Contract.maxRequestBytes` → `.invalid(.tooLarge)`
3. `PosixIO.readAll(fd:, limit: Contract.maxRequestBytes + 1)`。失敗 → `.invalid(.unreadable)`
4. `close` → `parse` の結果を `.valid` / `.invalid` に写す
（どの経路でも fd を閉じる。2〜3 は private の `readRegularFile(fd:)` に分け、その直後に `close` してから `parse` する。fd を開いたまま parse しない）

### 4.16 `HomeLayout.swift`（「// <HOME> 配下の全パス（PLAN §2.3）。パスはここからだけ得る。」）

```swift
public struct HomeLayout: Equatable, Sendable {
    public let root: URL
    public init(root: URL)                          // root をそのまま持つ（標準化しない）
    /// ~/Library/Application Support/VoiceDock。NSHomeDirectory() から組み立てる（環境変数を読まない。PT-18）
    public static func production() -> HomeLayout
    /// 下の表の「作る」列が ○ のディレクトリを順に FileManager.createDirectory(at:withIntermediateDirectories: true) で作る。bin は作らない
    public func createDirectories() throws
    /// root 配下なら root からの相対 POSIX パス（先頭の "/" 無し）。配下でなければ nil
    public func relativePath(of url: URL) -> String?
    /// root.appendingPathComponent(relative)
    public func url(relative: String) -> URL
}
```

計算プロパティ（すべて `URL`。root からの相対パスは逐語）:

| プロパティ | 相対パス | 作る |
|---|---|---|
| `configFile` | `config.json` | |
| `database` | `voicedock.sqlite` | |
| `inbox` | `inbox` | ○ |
| `staging` | `staging` | ○ |
| `transcriptsParts` | `transcripts/parts` | ○ |
| `analysis` | `analysis` | ○ |
| `queueDelete` | `queue/delete` | ○ |
| `queueResult` | `queue/result` | ○ |
| `queueRejected` | `queue/rejected` | ○ |
| `stateDirectory` | `state` | ○ |
| `processedLog` | `state/processed.log` | |
| `reaperLock` | `state/reaper.lock` | |
| `appLock` | `state/app.lock`（F-76 で追加。アプリの単一起動のロック） | |
| `runDirectory` | `run` | ○ |
| `llamaAPIKeyFile` | `run/llama-api-key` | |
| `binDirectory` | `bin` | **作らない**（ロック 2-A） |
| `reaperExecutable` | `bin/voicedock-reaper` | |
| `reaperConf` | `bin/reaper.conf` | |
| `modelsDirectory` | `models` | ○（`models/whisper`・`models/vad`・`models/llm` も作る） |
| `logsDirectory` | `logs` | ○ |
| `appLog` | `logs/app.log` | |
| `reaperLog` | `logs/reaper.log` | |
| `uiState` | `ui-state.json` | |

関数:

| 関数 | 相対パス |
|---|---|
| `stagingDirectory(slug:)` | `staging/<slug>` |
| `normalizedAudio(slug:)` | `staging/<slug>/audio16k.wav` |
| `normalizedAudioTmp(slug:)` | `staging/<slug>/audio16k.wav.tmp` |
| `whisperOutputBase(slug:)` | `staging/<slug>/whisper` |
| `whisperJSON(slug:)` | `staging/<slug>/whisper.json` |
| `transcript(slug:)` | `transcripts/parts/<slug>.json` |
| `analysisJSON(sessionSlug:)` | `analysis/<s>.json` |
| `timelineJSON(sessionSlug:)` | `analysis/<s>.timeline.json` |
| `sourceJSON(sessionSlug:)` | `analysis/<s>.source.json` |
| `inboxFile(deviceID:relpath:)` | `inbox/<deviceID>/<relpath>` |
| `inboxPartial(deviceID:relpath:)` | `inbox/<deviceID>/<RelPath.parent(relpath)>/.<RelPath.lastComponent(relpath)>.partial`（parent が "" なら `inbox/<deviceID>/.<name>.partial`） |
| `models(kind:)` | `models/<kind>` |
| `modelFile(kind:file:)` | `models/<kind>/<file>` |
| `modelPart(kind:file:)` | `models/<kind>/.<file>.part` |
| `modelResume(file:)` | `models/.<file>.resume` |

- 組み立ては `appendingPathComponent(_:isDirectory:)` の連鎖で行う（`"\(a)/\(b)"` の文字列を作らない。PT-06）。ディレクトリを指すものは `isDirectory: true`
- `relativePath(of:)`: `let r` / `let p` は `root` / `url` の `standardizedFileURL.path(percentEncoded: false)` から末尾の `/` を落としたもの（ディレクトリの URL は末尾に `/` が付くため。`"/"` だけのときはそのまま。private の `withoutTrailingSlash(_:)`）。`p.hasPrefix(r + "/")` なら `String(p.dropFirst(r.count + 1))`、それ以外（root 自身を含む）は nil。**realpath はしない**（呼び手が DB に保存する相対パスを作るための関数で、封じ込めの検査は SafeUnlink が行う）
- `production()`: `URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)` → `Library` → `Application Support` → `VoiceDock`

### 4.17 `PosixIO.swift`（internal。「// errno を返す低水準の読み書き（AtomicFile・ReaperConf・TargetIdentity が使う）。」）

```swift
enum PosixIO {
    /// EINTR で再試行し、部分書き込みを続けて全部書く。成功で nil、失敗でそのときの errno
    static func writeAll(fd: Int32, _ data: Data) -> Int32?
    /// 最大 limit バイトまで読む（EINTR で再試行、0 で終わり）。失敗で errno
    static func readAll(fd: Int32, limit: Int) -> Result<Data, PosixError>
    /// realpath(3)。失敗で nil（返った領域は free する）
    static func realpath(_ path: String) -> String?
    /// statfs の f_mntonname / f_fstypename のような固定長の C 文字列（タプル）を String にする（NUL まで。UTF-8 として解釈）
    static func string<T>(fromCTuple tuple: T) -> String
}
struct PosixError: Error, Equatable, Sendable { let errno: Int32 }
```

`string(fromCTuple:)` は `withUnsafeBytes(of: tuple) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }`（確認済み）。

### 4.18 `AtomicFile.swift`（「// ファイルの書き換えの唯一の実装（CR-01）。tmp の後始末もここだけが行う。」）

```swift
public enum AtomicFile {
    /// url の親ディレクトリは在ること（作らない）。
    public static func write(_ data: Data, to url: URL, permissions: mode_t = 0o644, verifyReadBack: Bool = false) throws(AtomicFileError)
    /// 同じディレクトリの ".<ファイル名>.tmp"
    public static func tmpURL(for url: URL) -> URL
}

public enum AtomicFileError: Error, Equatable, Sendable {
    case open(errno: Int32)
    case write(errno: Int32)
    case fsync(errno: Int32)
    case readBackMismatch
    case rename(errno: Int32)
}
```

**`write` の手順**（途中のどこで失敗しても、tmp を作った後なら tmp を `unlink` で消し（その失敗は無視）、**元の誤りを投げる**。最終ファイルは差し替えない。CR-21）:
1. `tmp = tmpURL(for: url)`
2. `fd = open(tmp.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, permissions)`。失敗 → `.open(errno)`（tmp は作られていないので消さない）
3. `fchmod(fd, permissions)`（既存の tmp の権限や umask に左右されないようにする。失敗は無視）
4. `PosixIO.writeAll(fd:, data)`。失敗 → `.write(errno)`
5. `fsync(fd)`。失敗 → `.fsync(errno)`
6. `close(fd)`
7. `verifyReadBack` なら: tmp を `open(O_RDONLY | O_NOFOLLOW | O_CLOEXEC)` で開いて全部読み、`SHA256` が `data` の SHA256 と一致しなければ `.readBackMismatch`（開けない・読めない場合も `.readBackMismatch`）
8. `rename(tmp.path(percentEncoded: false), url.path(percentEncoded: false))`。失敗 → `.rename(errno)`
9. 親ディレクトリを `open(O_RDONLY | O_DIRECTORY | O_CLOEXEC)` → `fsync` → `close`（どれの失敗も無視）

- `url` が symlink なら rename が symlink そのものを置き換える（リンク先には書かない）
- この関数は `unlink(` を使ってよい（PT-01 の許可場所）。消すのは自分の tmp だけ

### 4.19 `FileLock.swift`（「// state/reaper.lock の排他ロック（PLAN §2.1）。アプリの IngestService と reaper が共有する。」）

```swift
public final class FileLock: Sendable {
    /// open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644) → flock(fd, LOCK_EX | LOCK_NB)。
    /// 開けない・ロックが取れない（EWOULDBLOCK を含む）なら fd を閉じて nil。待たない（待つのは呼び手）。
    public static func tryAcquire(url: URL) -> FileLock?
    /// flock(fd, LOCK_UN)。何度呼んでもよい（fd は閉じない。閉じるのは deinit）。
    public func release()
    deinit   // close(fd)（閉じればロックも外れる）
    private let fd: Int32
}
```

- 親ディレクトリ（`state/`）は在ること（`HomeLayout.createDirectories()` が作る。無ければ nil）
- ロックファイルの中身は書かない。消さない
- このファイルは `O_CREAT` を使ってよい（PT-12 の許可場所）

### 4.20 テストの基礎部品（`Tests/TestSupport/`）

`TempDirectory`・`PackageRoot`・`TestEnvironment` は **T-01 が作る**（T-01 §9 の全文。T-02〜T-05・T-25 がこのチケットより前に使うため）。このチケットでは作らず、使うだけ:

- 一時ディレクトリは `let tmp = try TempDirectory()` の `tmp.url`（realpath 済み）。参照が無くなると（deinit）中身ごと消える。テストが `chmod 0o555` / `000` にしたディレクトリも、消す前に権限を 0o755 に戻す（T-01）
- リポジトリのファイルは `PackageRoot.url` / `PackageRoot.file(_:)`、環境変数は `TestEnvironment.diskTests` など

（00-api-map §15 はこの 3 つの作り手を T-06 と書いているが、依存の順と合わないので T-01 とした。整合修正の報告に記載）

## 5. テスト

すべて `import Testing`、`@testable import VDContract`、`import TestSupport`。一時ファイルは `TempDirectory`。

### 5.1 `VersionTests.swift`（`@Suite("AppVersion") struct VersionTests`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `stringMatchesVersionFile` | VERSION ファイルと AppVersion.string が一致する | `PackageRoot.url/VERSION` を読み、前後の空白・改行を除く | `AppVersion.string` と等しい |
| `componentsParsesThreeNumbers` | X.Y.Z を数値の組にする | `"1.10.0"` | `(1, 10, 0)` |
| `componentsRejectsMalformed` | 形式外は nil | `""`・`"1.0"`・`"1.0.0.0"`・`"1..0"`・`"v1.0.0"`・`"1.0.-1"`・`"１.0.0"`（全角） | すべて nil |
| `isSameComparesNumerically` | 版を数値の組で比べる | `("1.10.0", "1.10.0")`、`("1.10.0", "1.9.0")`、`("1.0.0", "1.0.x")` | 真・偽・偽 |

### 5.2 `LocalDateTimeTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `acceptsValidDates` | 実在する日時は作れる | `(2026,8,29,7,12,4)`・`(2024,2,29,0,0,0)`・`(2000,2,29,23,59,59)`・`(9999,12,31,0,0,0)`・`(1,1,1,0,0,0)` が non-nil |
| `rejectsInvalidDates` | 存在しない日時は nil | `(2026,2,29,…)`（平年）・`(1900,2,29,…)`・`(2026,2,30,…)`・`(2026,13,1,…)`・`(2026,0,1,…)`・`(2026,4,31,…)`・`(0,1,1,…)`・`(10000,1,1,…)`・`(2026,1,1,24,0,0)`・`(…,60,0)`・`(…,0,60)`・`(…,0,-1)` が nil |
| `dayStampIsZeroPadded` | dayStamp は yyyyMMdd | `(2026,8,9,…)` → `"20260809"`、`(1,1,1,…)` → `"00010101"` |
| `ordersLexicographically` | 年月日時分秒の辞書順 | `(2026,8,29,7,12,4) < (2026,8,29,7,12,5)`、`(2025,12,31,23,59,59) < (2026,1,1,0,0,0)` |

### 5.3 `RecordingNameTests.swift`

| 関数名 | 表示名 | 入力 | 期待 |
|---|---|---|---|
| `parsesDenoisedName` | denoised の名前を読む | `TX01_MIC002_20260829_071204.wav` | tx `TX01`、mic 2、`2026-08-29 07:12:04`、isOrig 偽、ext `wav` |
| `parsesOrigName` | _orig の名前を読む | `TX01_MIC002_20260829_071204_orig.wav` | isOrig 真 |
| `acceptsUppercaseExtension` | 拡張子の大文字を受ける | `…_071204.WAV`・`…_071204_orig.WAV` | ext `WAV`、読める |
| `acceptsBoundaryNumbers` | 境界値と実機の名前 | `TX00_MIC000_20260829_071204_orig.wav`・`TX99_MIC999_20260829_071204_orig.wav`・`TX00_MIC001_20260912_120950_orig.wav` | 読める（mic 0・999・1） |
| `rejectsMalformedNames` | 規則外の名前は nil（パラメータ化） | `TX1_MIC002_20260829_071204.wav`、`TX001_MIC002_…`、`TX01_MIC02_…`、`TX01_MIC0002_…`、日付 7 桁 `2026082`、時刻 5 桁 `07120`、`….mp3`、`…_ORIG.wav`、`…_orig_orig.wav`、`…_orig.Wav`、`._TX01_MIC002_20260829_071204_orig.wav`、`prefix_TX01_…_orig.wav`、`…_orig.wav.partial`、`…_orig.wav.meta.json`、`…_orig.wav\n`（末尾改行）、`TX01_MIC002_２0260829_071204_orig.wav`（全角数字） | すべて nil |
| `rejectsImpossibleDates` | 存在しない日時は例外にせず nil | `…_20260230_…`、`…_20261301_…`、`…_20260829_251204…`、`…_20260829_076104…`、`TX01_MIC002_00000000_000000_orig.wav` | すべて nil |
| `matchesFilePatternIgnoresDate` | 形だけの判定は日時を見ない | `TX01_MIC002_20260230_071204_orig.wav`・`TX01_MIC002_20260829_071204.wav`・`TX01_MIC002_20260829_071204_orig.wav.partial`・`…_orig.wav\n`（末尾改行） | 1 つ目と 2 つ目は真（1 つ目は `parseFile` が nil）、3 つ目・4 つ目は偽 |
| `timeIsAttachedNotConverted` | 時刻はファイル名のまま（TIME-03） | `TX01_MIC002_20260829_071204_orig.wav` | `local.hour == 7`、`local.minute == 12`（タイムゾーンに依存しない） |
| `folderRule` | フォルダ名の規則 | 右の各名前で `isFolder` | `TX_MIC001_20260829_071201` → 真。`TX_MIC01_20260829_071201`・`TX01_MIC001_20260829_071201`・`TX_MIC001_20260829_071201_x`・`tx_MIC001_…`・`.TX_MIC001_…`・末尾改行 → 偽。`TX_MIC001_20260230_071201` → **真**（日時は見ない） |
| `patternsAreVerbatim` | 正規表現の文字列が PLAN §4.1 と逐語で同じ | 定数を読む | `filePattern == #"^(TX[0-9]{2})_(MIC[0-9]{3})_([0-9]{8})_([0-9]{6})(_orig)?\.(wav\|WAV)$"#`、`folderPattern == #"^TX_(MIC[0-9]{3})_([0-9]{8})_([0-9]{6})$"#` |

### 5.4 `DeviceIDTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `acceptsTypicalNames` | 実機の名前と空白入りの名前を受ける | `DJIMIC3`・`NO NAME`・`DJI MIC 3`・`デバイス` → 真 |
| `rejectsUnsafeNames` | 危険な名前を拒む | `""`・`a/b`・`a:b`・`.hidden`・`.`・`..`・`a\u{0}b`・`a\u{1f}b`・`a\u{7f}b`・`a\nb` → 偽 |

### 5.5 `RelPathTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `acceptsSafeRelpaths` | 健全な relpath | `TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav`・`a.wav`・`a/b/c.wav` → 真 |
| `rejectsUnsafeRelpaths` | RV-08 の全拒否条件（パラメータ化） | `""`・`/TX01/a.wav`・`../a.wav`・`TX01/../a.wav`・`.Trashes/a.wav`・`TX01/.fseventsd`・`TX01/a\nb.wav`・`TX01/a\u{7f}b.wav`・`./a.wav`・`a//b.wav`・`a/`・`a\\b.wav`・`a/./b.wav`・`..`・`.` → 偽 |
| `rejectsOverlongRelpath` | UTF-8 で 1024 バイト超は偽 | `"a/" + String(repeating: "b", count: 1022)`（1024 バイト）→ 真、1 バイト足す → 偽、`"あ"` を 342 個（1026 バイト）→ 偽 |
| `stricterThanVoicedock` | voicedock が真にしていた ./a と a//b を偽にする | `./a.wav`・`a//b.wav` → 偽（doc コメントに voicedock との差を書く） |
| `componentsKeepEmpty` | components は空要素を省かない | `"a//b"` → `["a", "", "b"]`、`"a/"` → `["a", ""]` |
| `joinParentLast` | 結合・親・最後の要素 | `join(["a","b"])` = `"a/b"`、`parent("a/b/c")` = `"a/b"`、`parent("c")` = `""`、`lastComponent("a/b/c")` = `"c"` |

### 5.6 `PartKeyTests.swift`

```swift
/// 期待値を書き換えて通すな。規則を変えると、それ以前に保存した録音が永久に削除対象外になる（DEL-01、RK-27）。
@Test("partkey の固定値") func fixedPartkey()
```

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `fixedPartkey` | partkey の固定値 | `make("DJIMIC3", "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav")` が `"DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"` とバイト単位で等しい |
| `acceptsSpaceInDeviceID` | NO NAME でも作れる | `make("NO NAME", "a.wav")` = `"NO NAME/a.wav"` |
| `rejectsInvalidInputs` | 不正な入力を拒む | `("", rel)`・`("a/b", rel)`・`(".hidden", rel)`・`("a:b", rel)` → `.invalidDeviceID`、`(dev, "../escape.wav")`・`(dev, "/absolute.wav")`・`(dev, ".Trashes/x.wav")` → `.unsafeRelpath` |
| `splitsAtFirstSlash` | 分解は最初の "/" | `deviceID(of: "DJIMIC3/a/b.wav")` = `"DJIMIC3"`、`relpath(of:)` = `"a/b.wav"`、`"noslash"`・`"/a"`・`"a/"` は該当する側が nil |
| `roundTrip` | 組み立てと分解が往復する | 上の固定値で `deviceID(of:)` と `relpath(of:)` が元に戻る |

### 5.7 `SessionKeyTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `fixedSessionKey` | session_key の固定値（4.9 と同じ doc コメント） | `make("DJIMIC3", "20260829")` = `"DJIMIC3:20260829"` |
| `overflowSuffix` | 溢れた分は #2 から | `overflow: 2` → `"DJIMIC3:20260829#2"`、`overflow: 1` → 接尾辞無し |
| `rejectsInvalid` | 不正な入力 | device `""`・`"a:b"`・`"a/b"`・`".x"` → `.invalidDeviceID`、day `"2026082"`・`"202608290"`・`"2026-08-29"`・`"20260230"`・`"２0260829"` → `.invalidDayStamp`、overflow `0`・`-1` → `.invalidOverflow` |
| `parsesComponents` | 分解は最後の ":" | `deviceID(of: "NO NAME:20260829#3")` = `"NO NAME"`、`dayStamp` = `"20260829"`、`overflow` = 3。`overflow(of: "DJIMIC3:20260829")` = 1 |
| `rejectsBadOverflowSuffix` | #1・#02・#x は不正 | `overflow(of:)` が `"…#1"`・`"…#02"`・`"…#x"`・`"…#"`・`"…#-2"` で nil |
| `nextOverflow` | 次の溢れ | `"DJIMIC3:20260829"` → `"…#2"`、`"…#2"` → `"…#3"`、`"…#9"` → `"…#10"`、`"bad"` → throw `.malformedKey` |

### 5.8 `KeySlugTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `fixedSlugs` | key_slug の固定値（4.9 と同じ doc コメント） | partkey の固定値 → `"a5d046dce76cfedc"`、`"DJIMIC3:20260829"` → `"43a71bce144be7a7"` |
| `slugIsSixteenLowerHex` | 16 文字の小文字 16 進 | 任意の 3 つの鍵で `^[0-9a-f]{16}$` |

### 5.9 `RequestIDTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `makesUTCRequestID` | UTC・Z 付きの ID | `make(partkey: <固定値>, utcEpochSeconds: 1789203600, randomHex6: "a1b2c3")` = `"20260912T090000Z-a5d046dce76cfedc-a1b2c3"` |
| `validatesPattern` | 形式の検査 | 上の値 → 真。`"20260912T090000-a5d046dce76cfedc-a1b2c3"`（Z 無し。voicedock の形）・`"20260912T090000Z-A5D046DCE76CFEDC-a1b2c3"`・`"20260912T090000Z-a5d0/6dce76cfedc-a1b2c3"`・`"../x"`・末尾改行付き → 偽 |
| `randomHexIsSixLowerHex` | 乱数は 6 桁の小文字 16 進 | 100 回呼んで全部 `^[0-9a-f]{6}$`、かつ 2 種類以上の値が出る |

### 5.10 `ContractJSONTests.swift`

固定の要求 `fixture` = PLAN §4.4 の例（request_id `20260912T090000Z-a5d046dce76cfedc-a1b2c3`、created_at `2026-09-12T18:00:00+09:00`、size 345600000、mtime 1787000000.0）。

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `encodesRequestExactly` | 要求の符号化がバイト単位で決まる | `encode(fixture)` が 4.14 の出力の例（末尾改行 1 つ）と一致 |
| `encodesFractionalMtime` | 小数の mtime | mtime 1787000000.25 → `"mtime" : 1787000000.25` を含む |
| `rejectsNonFiniteMtime` | 非有限の mtime は符号化しない | mtime `.nan` → `ContractEncodeError.nonFiniteNumber` |
| `roundTripsRequest` | 要求が往復する | `decodeRequest(encode(fixture))` = `.success(fixture)` |
| `acceptsIntegerAndFractionalMtime` | mtime は整数・小数の両方を受ける | `"mtime": 1787000000` と `"mtime": 1787000000.5` の手書き JSON が読める |
| `rejectsMalformedRequests` | 形の誤りを拒む（パラメータ化。各行は fixture から 1 か所だけ変えた手書き JSON） | 下表 |
| `roundTripsResult` | 結果が往復する | DELETED（detail = relpath）と SOURCE_IDENTITY_MISMATCH（detail = `size_mismatch`）の 2 通り |
| `rejectsMalformedResults` | 結果の形の誤り | 余計なキー → `.keySetMismatch`、`status: "OK"` → `.wrongType("status")`、`schema: 2` → `.badSchema`、`detail: 1` → `.wrongType("detail")` |

`rejectsMalformedRequests` の表:

| 変更 | 期待 |
|---|---|
| バイト列 `0xFF 0xFE` | `.notJSONObject` |
| `[]`（配列） | `.notJSONObject` |
| キー `extra` を足す | `.keySetMismatch` |
| `session_key` を消す | `.keySetMismatch` |
| `schema: true` | `.wrongType("schema")` |
| `schema: "1"` | `.wrongType("schema")` |
| `schema: 1.0` | `.badSchema` |
| `schema: 2` | `.badSchema` |
| `request_id: 5` | `.wrongType("request_id")` |
| `targets: []` | `.badTargets` |
| targets を 2 要素 | `.badTargets` |
| `targets: {…}`（配列でない） | `.badTargets` |
| target にキー `x` を足す | `.badTargets` |
| `relpath: 1` | `.wrongType("targets.relpath")` |
| `size: -1` | `.wrongType("targets.size")` |
| `size: 1.5` | `.wrongType("targets.size")` |
| `size: true` | `.wrongType("targets.size")` |
| `mtime: true` | `.wrongType("targets.mtime")` |
| `mtime: "1787000000"` | `.wrongType("targets.mtime")` |

### 5.11 `ReaperConfTests.swift`

| 関数名 | 表示名 | 入力 | 期待 |
|---|---|---|---|
| `parsesMinimal` | 必須の 2 行だけ | `"SCHEMA=1\nDELETE_SOURCE_AUDIO=true\n"` | valid、volumesRoot `/Volumes` |
| `parsesWithCommentsAndBlankLines` | コメントと空行を無視 | `"# c\n\nSCHEMA=1\n# x\nDELETE_SOURCE_AUDIO=false\nVOLUMES_ROOT=/tmp/v\n"` | false、`/tmp/v` |
| `renderIsExact` | render の逐語 | `ReaperConf(deleteSourceAudio: true).render()` | `"SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=/Volumes\n"` |
| `renderRoundTrips` | render と parse が往復 | true・false の 2 通り | 元に戻る |
| `failClosed` | 不正はすべて無効側（パラメータ化） | 下表 | 下表 |
| `observeMissing` | ファイルが無い | 無いパス | `.missing` |
| `observeSymlink` | symlink は拒む | 正しい中身のファイルへの symlink | `.invalid(.notRegularFile)` |
| `observeDirectory` | ディレクトリは拒む | ディレクトリ | `.invalid(.notRegularFile)` |
| `observeTooLarge` | 64 KiB 超 | 65,537 バイト（`#` の行で埋める） | `.invalid(.tooLarge)` |
| `observeUnreadable` | 読めない | 権限 000 のファイル | `.invalid(.unreadable)` |
| `observeValid` | 正しいファイル | render の出力を書く | `.valid` |

`failClosed` の表:

| 入力 | 期待 |
|---|---|
| `""` | `.missingKey("SCHEMA")` |
| `"SCHEMA=1\n"` | `.missingKey("DELETE_SOURCE_AUDIO")` |
| `"SCHEMA=2\nDELETE_SOURCE_AUDIO=true\n"` | `.badValue("SCHEMA")` |
| `"SCHEMA=1\nDELETE_SOURCE_AUDIO=yes\n"` | `.badValue("DELETE_SOURCE_AUDIO")` |
| `"SCHEMA=1\nDELETE_SOURCE_AUDIO=TRUE\n"` | `.badValue("DELETE_SOURCE_AUDIO")` |
| `"SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=Volumes\n"` | `.badValue("VOLUMES_ROOT")` |
| `"SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nVOLUMES_ROOT=\n"` | `.badValue("VOLUMES_ROOT")` |
| `"SCHEMA=1\nDELETE_SOURCE_AUDIO=true\nMOUNT_MODE=rw\n"` | `.unknownKey("MOUNT_MODE")` |
| `"SCHEMA=1\nSCHEMA=1\nDELETE_SOURCE_AUDIO=true\n"` | `.duplicateKey("SCHEMA")` |
| `"SCHEMA=1\nDELETE_SOURCE_AUDIO=true \n"` | `.badLine(2)` |
| `"SCHEMA=1\r\nDELETE_SOURCE_AUDIO=true\r\n"` | `.badLine(1)` |
| `"schema=1\n"` | `.badLine(1)` |
| `"SCHEMA = 1\n"` | `.badLine(1)` |
| `"export SCHEMA=1\n"` | `.badLine(1)` |
| `"SCHEMA=1\nDELETE_SOURCE_AUDIO=$(rm -rf ~)\n"` | `.badLine(2)`（bash の `source` で任意コードが走った voicedock の穴を塞ぐ） |
| バイト列 `0xFF` | `.unreadable` |

### 5.12 `HomeLayoutTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `propertiesMatchLayout` | 全プロパティの相対パス（パラメータ化） | 4.16 の表の各行で `relativePath(of: layout.<プロパティ>)` が表の相対パスと等しい |
| `functionsMatchLayout` | 関数の相対パス | slug `a5d046dce76cfedc`、session slug `43a71bce144be7a7`、deviceID `DJIMIC3`、relpath `TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav`、kind `llm`、file `x.gguf` で 4.16 の関数表と一致。`inboxPartial` は `inbox/DJIMIC3/TX_MIC001_20260829_071201/.TX01_MIC002_20260829_071204_orig.wav.partial`、直下の `a_orig.wav` は `inbox/DJIMIC3/.a_orig.wav.partial` |
| `createDirectoriesDoesNotCreateBin` | bin を作らない（ロック 2-A） | 一時ディレクトリで `createDirectories()` → 表の ○ と `models/whisper`・`models/vad`・`models/llm` が在り、`bin` が**無い** |
| `createDirectoriesIsIdempotent` | 2 回呼んでもよい | 2 回目も throw しない |
| `relativePathOutsideIsNil` | 配下でなければ nil | root 自身・兄弟の `<root>-old/x`・`/etc/passwd` → nil |
| `productionPath` | 本番の場所 | `production().root.path(percentEncoded: false)` が `NSHomeDirectory() + "/Library/Application Support/VoiceDock/"`（ディレクトリの URL なので末尾に `/`） |

### 5.13 `AtomicFileTests.swift`

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `writesNewFile` | 新しく書く | 無いファイル | 中身が一致、権限 0644、`.x.tmp` が残らない |
| `replacesExistingFile` | 既存を置き換える | 既存の中身 `old` | 中身が新しい値、tmp が残らない |
| `honorsPermissions` | 権限を指定どおりにする | `permissions: 0o600`、既存の tmp が 0o666 で在る | 最終ファイルが 0o600 |
| `tmpNameIsDotNameDotTmp` | tmp の名前 | `tmpURL(for: <dir>/a.json)` | `<dir>/.a.json.tmp`。`<dir>/2026-08-29 raw.md` → `.2026-08-29 raw.md.tmp` |
| `openFailsInReadOnlyDirectory` | 書けないディレクトリ | 親を `chmod 0o555` | `.open(errno: EACCES)`、最終ファイルは作られない |
| `missingParentIsOpenError` | 親が無い | 無いディレクトリの下 | `.open(errno: ENOENT)`、何も作られない |
| `renameFailureKeepsOriginalAndRemovesTmp` | rename の失敗で元を差し替えない | 宛先が中身のあるディレクトリ | `.rename(errno:)`（EISDIR か ENOTEMPTY）、ディレクトリはそのまま、tmp が残らない |
| `replacesSymlinkItself` | symlink の宛先ではなくリンク自体を置き換える | 宛先 `a` が別ファイル `b` への symlink | `a` が通常ファイルになり、`b` の中身は変わらない |
| `verifyReadBackPasses` | 読み直しの照合が通る | `verifyReadBack: true` | 成功 |

（`readBackMismatch` の経路は注入の手段を持たないので、コードレビューで確認する。PR 本文にその旨を書く）

### 5.14 `FileLockTests.swift`（`.serialized`）

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `secondAcquireFails` | 2 つ目は取れない | 1 つ目を持ったまま、2 つ目の `tryAcquire` を `Thread` で実行し `DispatchSemaphore` で最大 5 秒待つ → 5 秒以内に返り、値が nil（同じプロセスでも flock は開き直した fd ごとに排他。確認済み。返らなければテストを失敗にする） |
| `releaseAllowsReacquire` | release の後は取れる | `release()` → `tryAcquire` が non-nil。`release()` を 2 回呼んでもよい |
| `deinitReleases` | 参照を捨てれば外れる | スコープを抜けた後 `tryAcquire` が non-nil |
| `createsLockFileWith0644` | ロックファイルを 0644 で作る | 無いファイルで取得 → ファイルが在り、権限 0644、サイズ 0 |
| `missingDirectoryIsNil` | 親ディレクトリが無ければ nil | 無いディレクトリの下のパスで `tryAcquire` → nil |

## 6. 破壊による証明

| # | 壊し方 | 落ちるべきテスト |
|---|---|---|
| 1 | `RecordingName.filePattern` の `[0-9]` を 1 か所 `\d` にする | `rejectsMalformedNames`（全角数字）、`patternsAreVerbatim` |
| 2 | `PatternMatch.wholeMatch` の「一致範囲 == 全体」の確認を消す | `rejectsMalformedNames`（末尾改行）、`folderRule`、`validatesPattern` |
| 3 | `LocalDateTime.init?` の閏年の `% 400` を消す | `acceptsValidDates`（2000/2/29） |
| 4 | `DeviceID.isValid` の `":"` の検査を消す | `rejectsUnsafeNames`、`PartKeyTests.rejectsInvalidInputs`、`SessionKeyTests.rejectsInvalid` |
| 5 | `RelPath.isSafe` の空要素の検査を消す | `rejectsUnsafeRelpaths`（`a//b.wav`・`a/`）、`stricterThanVoicedock` |
| 6 | `PartKey.make` の区切りを `"/"` から `"\|"` にする | `fixedPartkey`、`roundTrip` |
| 7 | `KeySlug.of` の先頭 16 文字を 15 文字にする | `fixedSlugs` |
| 8 | `RequestID.make` を `gmtime_r` から `localtime_r` に変える（TZ が UTC でない手元で） | `makesUTCRequestID` |
| 9 | `ContractJSON` の `CFBooleanGetTypeID` の確認を消す | `rejectsMalformedRequests`（`schema: true`・`size: true`・`mtime: true`） |
| 10 | `ContractJSON` のキー集合の完全一致を「部分集合」にする | `rejectsMalformedRequests`（`extra`）、`rejectsMalformedResults` |
| 11 | `ReaperConf.parse` の未知キーを無視する | `failClosed`（`MOUNT_MODE`） |
| 12 | `ReaperConf.observe` の `O_NOFOLLOW` を消す | `observeSymlink` |
| 13 | `HomeLayout.createDirectories` に `binDirectory` を足す | `createDirectoriesDoesNotCreateBin` |
| 14 | `AtomicFile.write` の失敗時の tmp の後始末を消す | `renameFailureKeepsOriginalAndRemovesTmp` |
| 15 | `AtomicFile.write` の `fchmod` を消す | `honorsPermissions` |
| 16 | `FileLock.tryAcquire` の `LOCK_NB` を消す | `secondAcquireFails`（2 つ目の取得が 5 秒以内に返らず失敗） |
| 17 | `RecordingName.matchesFilePattern` を `parseFile(name) != nil` にする | `matchesFilePatternIgnoresDate`（2026-02-30 の名前） |

## 7. 受け入れ条件

- [ ] 3 章のファイルがすべて在り、VDContract の import が Foundation・Darwin・CryptoKit だけ
- [ ] 5 章のテストがすべて在り `make test` が通る
- [ ] 鍵の固定値テスト 3 本に DEL-01 / RK-27 の doc コメントがある
- [ ] `try!`・`as!`・`!`（強制アンラップ）・`Date()`・`print` を使っていない（テストを除く）
- [ ] `"\(…)/\(…)"` の文字列リテラルは `PartKey.swift` と `RelPath.swift` にしか無い
- [ ] `O_CREAT` は `AtomicFile.swift` と `FileLock.swift` にしか無い、`unlink(` は `AtomicFile.swift` にしか無い
- [ ] 破壊による証明 17 項目の結果が PR 本文にある

## 8. API 地図への変更提案

1. `RequestID.randomHex6() -> String` を足す（PLAN §4.4 の「SystemRandomNumberGenerator から 3 バイト」を 1 か所に置くため。呼び手は VDPipeline の要求の書き込み） → 00-api-map に反映済み（2026-09-18）
2. `ContractJSON.encode` を `throws(ContractEncodeError) -> Data` にし、`ContractEncodeError { case nonFiniteNumber }` を足す（`JSONEncoder` は非有限の Double で throw する。黙って空の Data を返すと reaper が malformed として消費してしまう） → 00-api-map に反映済み（2026-09-18）
3. `ContractJSON.requestKeys` / `targetKeys` / `resultKeys`（`Set<String>`）を公開する（reaper の RV-03 が同じ集合を使う） → 00-api-map に反映済み（2026-09-18）
4. `ReaperConf.init(deleteSourceAudio:volumesRoot:)` と、キー名の定数 `keySchema` / `keyDeleteSourceAudio` / `keyVolumesRoot`、`linePattern` を公開する → 00-api-map に反映済み（2026-09-18）
5. `LocalDateTime.daysInMonth(year:month:)` を公開する（VDCore の `LocalDate` が同じ規則を使う。同じ規則を 2 か所に書かない） → 00-api-map に反映済み（2026-09-18）
6. `DeleteRequest` / `DeleteResult` / `DeleteTarget` の公開の初期化子（4.13 のシグネチャ） → 00-api-map に反映済み（2026-09-18）
7. `FileLock.release()` の意味を「`flock(LOCK_UN)`。何度呼んでもよい。fd を閉じるのは deinit」と明記する（`final class` に可変の状態を持たせずに冪等にするため） → 00-api-map に反映済み（2026-09-18）
8. （整合修正で追記）`RecordingName.matchesFilePattern(_:)`（T-13〜T-15 の提案で地図 §1 に載った。形だけの判定）を 4.5 に足した → 00-api-map に反映済み（2026-09-18）
9. （整合修正で追記）00-api-map §15 は `TempDirectory`・`PackageRoot`・`TestEnvironment` の作り手を T-06 と書くが、T-01 が作る（4.20）。地図を T-01 に直すことを提案する
10. （実装時に発見・決定）00-api-map §0 は「`URL` からパス文字列を取るときは `url.path(percentEncoded: false)` だけを使う」とするが、このチケットの 4.15・4.16・4.18 と 5.12 の `productionPath` は `.path` を使っていた。
    上位の地図に合わせて `path(percentEncoded: false)` にした。ディレクトリの URL では末尾に `/` が付くので、`relativePath(of:)` は比べる前に末尾の `/` を落とす（`withoutTrailingSlash`）。地図の変更は不要

## 9. SPEC の変更

`docs/SPEC.md`（T-05 が作る）に、§4.1 の 2 つの正規表現と §4.4 の request_id の正規表現を、このチケットの定数と逐語で同じ形で載せる（SPEC 同期テストが `RecordingName.filePattern` / `folderPattern` / `RequestID.pattern` と照合する）。T-05 が先にマージされていればこの PR で足し、後なら T-05 が足す。
→ （T-05 の実装で判明）SPEC.md は PLAN の 9 節の機械的な写しで §4.1・§4.4 を写さないので、T-05 には収まらなかった。GitHub issue #18 に切り出した（当面は `patternsAreVerbatim` が逐語を守る）
→ **SPEC 同期は #18 で足した**（PLAN F-68）: PLAN §4.1・§4.4 に `| 定数 | 正規表現 |` の表を置き、`make-spec.py` が SPEC の `S10. 名前の正規表現` に写す。`Tests/VDContractTests/SpecSyncContractTests.swift` の `patternsMatchSpec`（「名前の正規表現が SPEC S10 の表と逐語で同じ」）が `RecordingName.filePattern` / `folderPattern` / `RequestID.pattern` と照合する。表の中の `|` は `\|` と書き、`SpecDocument.namePatterns()` が戻す。`patternsAreVerbatim` は二重の守りとして残す

## 10. マージ後にやること

なし
