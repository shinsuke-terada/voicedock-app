# T-16 VDAudio: 16 kHz 変換・出力の検証・空き容量

| 項目 | 値 |
|---|---|
| ID | T-16 |
| Phase | 4（変換と文字起こし） |
| 前提 | T-14（`AudioProbe` と VDAudio ターゲット・TestSupport の `BWFWriter`）。T-09（`AudioConfig`）、T-10（`AppClock`・`BlockingIO`・`SafeUnlink`・`SteppingClock`）、T-08（`StageFailure`）、T-06（`HomeLayout`・`KeySlug`・`TempDirectory`）はその前提に含まれる |
| 見積もり | Sources 約 450 行、Tests 約 500 行（TestSupport の BWFWriter は T-14 が作る） |

## 1. 目的

inbox の DJI 原本（Broadcast Wave、48 kHz / 24 bit か 32 bit float）を、AVFoundation で 16 kHz / 1 ch / 16 bit の WAV に変換する。
変換と同時に入力の SHA-256 を計算してコピー時の値と照合し、出力を検証し、重複を検出する。ffmpeg を使わない（X-01）。
**状態遷移と DB 更新はしない**（呼び手 = T-18 の `ensureNormalized` が行う）。

## 2. 参照

- PLAN §8.3（全体）、§2.1（`BlockingIO`・actor の中で長い同期処理をしない）、§5.7、§6.2（`audio.*`）、§10.2（BWFWriter）、付録 A.3（IMPORT_FAILED / SOURCE_HASH_MISMATCH / NORMALIZE_VERIFY_FAILED / DUPLICATE_CONTENT / DISK_SPACE_LOW）
- voicedock@d3d595e: `src/voicedock/audio.py:210-500`（`expected_bytes` / `check_space` / `normalize` / `_reuse` / `_digest_file` / `_stream`）、`audio.py:672-739`（`verify_output` / `_discard_output` / `release_inbox`）、
  `tests/fixtures/make_wav.py`（全体）、`tests/unit/test_normalize.py`
- 移植メモ V4 §1

## 3. 作るもの

| パス | 種別 |
|---|---|
| `Sources/VDAudio/SpaceCheck.swift` | `SpaceCheck` / `SpaceCheckResult` / `SpaceMath` |
| `Sources/VDAudio/Normalizer.swift` | `Normalizer` / `NormalizeRequest` / `NormalizeOutcome`（`rename(` を使ってよい唯一のファイル。PT-12） |
| `Sources/VDAudio/AudioConversion.swift` | internal: AVFoundation による変換ループ |
| `Sources/VDAudio/InputHasher.swift` | internal: 期限付きの SHA-256 |
| `Sources/VDAudio/OutputVerifier.swift` | `OutputVerifier` |
| `Sources/VDAudio/ErrorText.swift` | internal: エラーの文字列化 |
| `Tests/VDAudioTests/SpaceCheckTests.swift` | |
| `Tests/VDAudioTests/NormalizerTests.swift` | |
| `Tests/VDAudioTests/OutputVerifierTests.swift` | |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 6 キーを消す（§6.5） |

`AudioProbe.swift` と TestSupport の `BWFWriter.swift`（とそのテスト `Tests/VDAudioTests/BWFWriterTests.swift`）は T-14 が作る（00-api-map §15）。このチケットでは触らない。

## 4. 仕様

パスの文字列化は `url.path(percentEncoded: false)` を使う。

### 4.1 `ErrorText.swift`（internal）

```swift
// エラーを error_message 用の 1 行にする（PLAN §8.3「<型名>: <説明>」）。
enum ErrorText {
    /// `"<型名>: <説明>"`。型名は `String(describing: type(of: error))`、説明は `String(describing: error)`。
    static func describe(_ error: any Error) -> String {
        "\(String(describing: type(of: error))): \(String(describing: error))"
    }
}
```

### 4.2 `SpaceCheck.swift`

```swift
// 空き容量の 2 条件（PLAN §8.3「空き容量」。voicedock audio.py:292-349）。
import Foundation
import VDContract
import VDCore

public enum SpaceMath {
    /// 16 kHz / 1 ch / s16 のバイトレート。
    static let bytesPerSecond: Int64 = 32_000
    /// duration が不明なときの仮定値（30 分）。
    static let defaultDurationSeconds: Double = 1800

    /// `Int64(max(0, duration ?? 1800) × 32000)`（0 方向への切り捨て）。Int64 に収まらない積は `Int64.max`（トラップしない。CR-16）。
    public static func expectedBytes(_ durationSeconds: Double?) -> Int64 {
        let seconds = durationSeconds ?? defaultDurationSeconds
        return saturatingInt64(max(0, seconds) * Double(bytesPerSecond))
    }

    /// `Int64(Double(expected) × freeSpaceMultiplier) + freeSpaceMarginBytes`。桁あふれは `Int64.max`（トラップしない。CR-16）。
    public static func requiredBytes(expected: Int64, config: AudioConfig) -> Int64 {
        saturatingAdd(
            saturatingInt64(Double(expected) * config.freeSpaceMultiplier), Int64(config.freeSpaceMarginBytes))
    }

    /// 0 方向へ切り捨てて Int64 にする。`Int64.max` 以上と NaN は `Int64.max`、`Int64.min` 以下は `Int64.min`。
    static func saturatingInt64(_ value: Double) -> Int64 {
        if value.isNaN || value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value)
    }

    /// 桁あふれを `Int64.max` / `Int64.min` に留める足し算。
    static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return sum }
        return rhs > 0 ? Int64.max : Int64.min
    }
}

public enum SpaceCheckResult: Equatable, Sendable {
    case ok
    case insufficient(String)   // error_message にそのまま使う文言
}

public struct SpaceCheck: Sendable {
    public init(config: AudioConfig, layout: HomeLayout)
    public func check(durationSeconds: Double?) -> SpaceCheckResult
}
```

`check(durationSeconds:)` の手順（この順。voicedock と同じ）:
1. `expected = SpaceMath.expectedBytes(durationSeconds)`、`required = SpaceMath.requiredBytes(expected: expected, config: config)`
2. `statfs` の対象は `layout.staging` がディレクトリならそれ、でなければ `layout.root`。`statfs` が失敗したら
   `.insufficient("空き容量を取得できません: errno \(errno)")`
3. `free = Int64(clamping: st.f_bavail) × Int64(clamping: st.f_bsize)`（`multipliedReportingOverflow` で桁あふれは `Int64.max`。CR-16）
4. `used = stagingBytes()`: `layout.staging` 配下を再帰的に列挙し（`FileManager.default.enumerator(at:includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [])`）、
   `isRegularFile == true` のものの `fileSize` を合計する（`SpaceMath.saturatingAdd`）。読めないものは飛ばす（例外を投げない）。staging が無ければ 0
5. `free < required` → `.insufficient("空き \(free) バイトが必要量 \(required) バイトを下回る")`
6. `SpaceMath.saturatingAdd(used, expected) > Int64(config.stagingMaxBytes)` → `.insufficient("staging 使用量 \(used) + 想定 \(expected) が上限 \(config.stagingMaxBytes) を超える")`
7. それ以外 `.ok`

数値は `Int64` の 10 進（区切り記号なし）で埋め込む。

VDAudio の import は Foundation / AVFoundation / CryptoKit / VDContract / VDCore だけ（PLAN §3.4。PT-07）。`statfs`・`errno`・`rename`・`open`・`fsync`・`lrint` は Foundation が再輸出する Darwin から使い、`import Darwin` は書かない（T-16 の実装で直した。旧版は `import Darwin` を書いていた）。

### 4.3 `InputHasher.swift`（internal）

```swift
// 入力の SHA-256。変換の経路と再利用の経路で同じ関数を使う（DEV-18）。
import CryptoKit
import Foundation
import VDCore

struct Deadline: Sendable {
    let clock: any AppClock
    let start: Duration        // clock.uptime() の値
    let limitSeconds: Int
    /// `clock.uptime() - start > .seconds(limitSeconds)`（等しいときは超えていない）
    func isExceeded() -> Bool
}

enum InputHasherError: Error, Equatable { case deadlineExceeded }

enum InputHasher {
    /// ファイル全体を `chunkBytes` ずつ読み、SHA-256 の小文字 16 進と読んだバイト数を返す。
    /// `deadline` が与えられていれば、チャンクを 1 つ読むたびに `isExceeded()` を確かめ、超えたら `deadlineExceeded` を投げる。
    static func hash(_ url: URL, chunkBytes: Int, deadline: Deadline?) throws -> (sha256: String, bytes: Int64)
}
```

- 読み取りは `FileHandle(forReadingFrom: url)` と `read(upToCount: chunkBytes)`（`nil` か空で終わり）。`close()` は `defer` で
- ハッシュは `CryptoKit.SHA256`、出力は `digest.map { String(format: "%02x", $0) }.joined()`
- 開けない・読めないときは Foundation のエラーをそのまま投げる（呼び手が `ErrorText.describe` で文字列にする）

### 4.4 `AudioConversion.swift`（internal）

```swift
// AVFoundation で 16 kHz / 1 ch / Int16 の WAV を書く（PLAN §8.3 手順 4）。
import AVFoundation
import Foundation
import VDCore

enum AudioConversionError: Error, Equatable {
    case cannotCreateConverter
    case cannotAllocateBuffer
    case converterFailed(String)
    case deadlineExceeded
}

enum AudioConversion {
    static let outputSampleRate: Double = 16_000
    static let inputFramesPerBuffer: AVAudioFrameCount = 65_536

    /// 出力ファイルの settings（逐語。キーの意味は PLAN §8.3）。
    /// `[String: Any]` は Sendable でないため、static let ではなく計算プロパティで持つ（Swift 6。static let はコンパイルエラー）。
    static var outputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVAudioFileTypeKey: kAudioFileWAVEType,
        ]
    }

    /// `input` を読み、`tmpOutput` に 16 kHz / 1 ch / Int16 の WAV を書いて閉じる。rename はしない。
    static func convert(input: URL, tmpOutput: URL, deadline: Deadline) throws
}
```

`convert` の手順（Swift のコードで書く。変数名もこのとおり）:

```swift
let inFile = try AVAudioFile(forReading: input)            // processingFormat は Float32・非インターリーブ
let inFormat = inFile.processingFormat
guard let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate,
                                      channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: inFormat, to: floatFormat) else {
    throw AudioConversionError.cannotCreateConverter
}
converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
converter.downmix = inFormat.channelCount >= 2
// 入力の sampleRate が 1 Hz 未満だと容量が UInt32 に収まらない（トラップしない。CR-16）。
guard inFormat.sampleRate >= 1 else { throw AudioConversionError.cannotAllocateBuffer }
let outFile = try AVAudioFile(forWriting: tmpOutput, settings: outputSettings,
                              commonFormat: .pcmFormatInt16, interleaved: true)
let outCapacity = AVAudioFrameCount((Double(inputFramesPerBuffer) * outputSampleRate / inFormat.sampleRate).rounded(.up)) + 1024
var readError: (any Error)?
var finished = false
while !finished {
    if deadline.isExceeded() { throw AudioConversionError.deadlineExceeded }
    guard let floatBuffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: outCapacity) else {
        throw AudioConversionError.cannotAllocateBuffer
    }
    var conversionError: NSError?
    let status = converter.convert(to: floatBuffer, error: &conversionError) { _, inputStatus in
        // 末尾で read(into:) を呼ぶと nilError を投げる（T-16 で実測）。読む前に終わりを確かめる。
        if inFile.framePosition >= inFile.length {
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inputFramesPerBuffer) else {
            inputStatus.pointee = .endOfStream
            return nil
        }
        do {
            try inFile.read(into: inBuffer, frameCount: inputFramesPerBuffer)
        } catch {
            readError = error
            inputStatus.pointee = .endOfStream
            return nil
        }
        if inBuffer.frameLength == 0 {
            inputStatus.pointee = .endOfStream
            return nil
        }
        inputStatus.pointee = .haveData
        return inBuffer
    }
    if let readError { throw readError }
    switch status {
    case .error:
        throw AudioConversionError.converterFailed(conversionError.map { ErrorText.describe($0) } ?? "unknown")
    case .endOfStream:
        finished = true
    case .haveData, .inputRanDry:
        break
    @unknown default:
        throw AudioConversionError.converterFailed("unknown status \(status.rawValue)")
    }
    if floatBuffer.frameLength > 0 {
        try writeInt16(floatBuffer, to: outFile)
    }
}
outFile.close()                                            // macOS 15 以上
```

`writeInt16(_:to:)`:

```swift
static func writeInt16(_ floatBuffer: AVAudioPCMBuffer, to outFile: AVAudioFile) throws {
    let frames = floatBuffer.frameLength
    guard let source = floatBuffer.floatChannelData?[0],
          let intBuffer = AVAudioPCMBuffer(pcmFormat: outFile.processingFormat, frameCapacity: frames),
          let destination = intBuffer.int16ChannelData?[0] else {
        throw AudioConversionError.cannotAllocateBuffer
    }
    intBuffer.frameLength = frames
    for index in 0..<Int(frames) {
        // PLAN §8.3: clamp(lrint(x × 32768), −32768, 32767)
        destination[index] = Int16(clamping: lrint(Double(source[index]) * 32_768.0))
    }
    try outFile.write(from: intBuffer)
}
```

- `lrint` は既定の丸め（最近接偶数）。`Int16(clamping:)` が −32768〜32767 に収める
- 入力が既に 16 kHz でも同じ経路を通す（特別扱いしない）
- `AVAudioFile.read(into:frameCount:)` はファイルの末尾で呼ぶと 0 フレームを返さず `_GenericObjCError.nilError` を投げる（macOS 26.6・SDK 27.0 で実測）。だから入力ブロックの先頭で `framePosition >= length` を確かめて `.endOfStream` を返す（旧版はこれが無く、変換がすべて IMPORT_FAILED になった）
- `outFile.close()` の後、`open(tmpOutput.path(percentEncoded: false), O_RDONLY)` → `fsync` → `close` で内容をディスクへ（失敗は無視）

### 4.5 `OutputVerifier.swift`

```swift
// 16 kHz 出力の検証（PLAN §8.3 手順 6、ASR-01。voicedock audio.py:672-712）。
import AVFoundation
import Foundation

public enum OutputVerifier {
    static let expectedSampleRate: Double = 16_000
    static let expectedChannels: AVAudioChannelCount = 1

    /// 合格なら nil、不合格なら error_message の文言。例外を投げない。
    public static func verify(output: URL, inputDuration: Double?, tolerance: Double) -> String?

    /// AVAudioCommonFormat を ffmpeg 風の名前へ（文言用）。
    static func sampleFormatName(_ f: AVAudioCommonFormat) -> String

    /// `Int(sampleRate)` の文言。Int に収まらない値（NaN・無限大・巨大）は `Double.description`（トラップしない。CR-16）。
    static func integerText(_ value: Double) -> String {
        guard let integer = Int(exactly: value.rounded(.towardZero)) else { return value.description }
        return String(integer)
    }
}
```

検査の順（最初に落ちたものの文言を返す。`<path>` は `output.path(percentEncoded: false)`）:

| # | 条件 | 文言（逐語） |
|---|---|---|
| 1 | `stat` で通常ファイルでない（symlink は辿る。無い・ディレクトリ） | `<path> がありません` |
| 2 | size == 0 | `<path> が 0 バイトです` |
| 3 | `AVAudioFile(forReading:)` が投げる | `出力を読めません: <ErrorText.describe(error)>` |
| 4 | `fileFormat.sampleRate != 16000` | `sample_rate が <integerText(sampleRate)>（期待 16000）` |
| 5 | `fileFormat.channelCount != 1` | `channels が <n>（期待 1）` |
| 6 | `fileFormat.commonFormat != .pcmFormatInt16` | `sample_fmt が <sampleFormatName>（期待 s16）` |
| 7 | `inputDuration` が nil → 合格（長さを照合しない） | — |
| 8 | `outDuration = Double(file.length) / fileFormat.sampleRate`、`gap = abs(outDuration − inputDuration)`、`gap > tolerance` | `長さが入力と <String(format: "%.2f", gap)> 秒ずれています（許容 <tolerance.description> 秒）` |

- `sampleFormatName`: `.pcmFormatInt16`→`s16`、`.pcmFormatInt32`→`s32`、`.pcmFormatFloat32`→`flt`、`.pcmFormatFloat64`→`dbl`、それ以外→`other`
- `tolerance.description` は Swift の `Double.description`（`1.0` → `"1.0"`。voicedock の `{1.0}` と同じ）
- **1.0 ちょうどは合格**（`>` で比べる）
- 出力の長さが求まらない（`fileFormat.sampleRate == 0`）ときも合格（長さの照合を飛ばす）

### 4.6 `Normalizer.swift`

```swift
// inbox の原本 → 16 kHz WAV（PLAN §8.3。voicedock audio.py:379-500）。状態遷移と DB 更新はしない。
import Foundation
import VDContract
import VDCore

public struct NormalizeRequest: Sendable {
    public let input: URL
    public let partkey: String
    public let durationSeconds: Double?
    public let sha256Helper: String?
    public let claimedBy: String?
    public let duplicateOf: @Sendable (String) -> String?
    public init(input: URL, partkey: String, durationSeconds: Double?, sha256Helper: String?,
                claimedBy: String?, duplicateOf: @escaping @Sendable (String) -> String?)
}

public enum NormalizeOutcome: Equatable, Sendable {
    case success(sha256: String, output: URL, inBytes: Int64, outBytes: Int64, reused: Bool)
    case duplicate(of: String, sha256: String)
    case failure(StageFailure)
}

public struct Normalizer: Sendable {
    public init(config: AudioConfig, layout: HomeLayout, clock: any AppClock)
    public func normalize(_ req: NormalizeRequest) async -> NormalizeOutcome

    /// 変換の時間上限（秒）。`Int(max(Double(minTimeoutSeconds), duration × timeoutFactor))`、duration 不明なら minTimeoutSeconds。
    static func timeoutSeconds(duration: Double?, config: AudioConfig) -> Int
}
```

`normalize` は本体を `BlockingIO.run { … }` の中で同期に実行する（PLAN §2.1）。`BlockingIO.run` が投げたら `.failure(StageFailure(.importFailed, ErrorText.describe(error)))`。

同期の本体の手順（この順。voicedock と同じ。`slug = KeySlug.of(req.partkey)`、`output = layout.normalizedAudio(slug:)`、`tmp = layout.normalizedAudioTmp(slug:)`）:

1. **slug の衝突**（CONC-13）: `req.claimedBy != nil && req.claimedBy != req.partkey` →
   `.failure(StageFailure(.importFailed, "staging の slug が衝突しています（\(slug) は \(claimedBy) が使用中）"))`
2. **再利用**（冪等。DEV-18）: `OutputVerifier.verify(output: output, inputDuration: req.durationSeconds, tolerance: config.durationToleranceSeconds) == nil` なら:
   1. `InputHasher.hash(req.input, chunkBytes: config.hashChunkBytes, deadline: nil)`。投げたら `.failure(.importFailed, ErrorText.describe(error))`
   2. 手順 5 と同じ照合（不一致なら `discard(output)` して `SOURCE_HASH_MISMATCH`）
   3. 手順 7 と同じ重複の判定（相手がいれば `discard(output)` して `.duplicate`）
   4. `.success(sha256:, output:, inBytes: 読んだバイト数, outBytes: output の size, reused: true)`
3. **空き容量の再確認**: `SpaceCheck(config:layout:).check(durationSeconds: req.durationSeconds)` が `.insufficient(msg)` → `.failure(StageFailure(.diskSpaceLow, msg))`
4. **変換**:
   1. `FileManager.default.createDirectory(at: layout.stagingDirectory(slug: slug), withIntermediateDirectories: true)`（失敗は `.importFailed` + describe）
   2. 検証を通らなかった古い出力と tmp を消す: `discard(output)`、`discard(tmp)`
   3. `deadline = Deadline(clock: clock, start: clock.uptime(), limitSeconds: Normalizer.timeoutSeconds(duration: req.durationSeconds, config: config))`
   4. `(sha, inBytes) = InputHasher.hash(req.input, chunkBytes: config.hashChunkBytes, deadline: deadline)`
   5. `AudioConversion.convert(input: req.input, tmpOutput: tmp, deadline: deadline)`
   6. `Darwin.rename(tmp.path(percentEncoded: false), output.path(percentEncoded: false))`。0 以外なら `IMPORT_FAILED`「rename: errno <errno>」
   - 4-4〜4-6 のどこかで失敗したら `discard(tmp)` と `discard(output)` をして:
     - `InputHasherError.deadlineExceeded` / `AudioConversionError.deadlineExceeded` → `.failure(StageFailure(.importFailed, "\(limit) 秒を超えました"))`
     - それ以外 → `.failure(StageFailure(.importFailed, ErrorText.describe(error)))`
5. **コピー時の SHA との照合**（DEV-17）: `req.sha256Helper == nil || sha != req.sha256Helper` →
   `discard(output)`、`.failure(StageFailure(.sourceHashMismatch, message))`。
   message は helper があれば `再計算した SHA-256 がコピー時の値と一致しません（<sha の先頭 16>… ≠ <helper の先頭 16>…）`、
   nil なら `再計算した SHA-256 がコピー時の値と一致しません（<sha の先頭 16>… ≠ 記録なし）`（`…` は U+2026）
6. **出力の検証**: `OutputVerifier.verify(output:inputDuration: req.durationSeconds, tolerance: config.durationToleranceSeconds)` が文言を返したら
   `discard(output)`、`.failure(StageFailure(.normalizeVerifyFailed, 文言))`
7. **重複**: `if let other = req.duplicateOf(sha), other != req.partkey` → `discard(output)`、`.duplicate(of: other, sha256: sha)`
8. **成功**: `.success(sha256: sha, output: output, inBytes: inBytes, outBytes: output の size, reused: false)`

- `discard(url)` = `try? SafeUnlink.remove(url, under: .staging, layout: layout)`（後片付けの失敗は握りつぶし、元の結果を返す。CR-21）
- `output の size` は `FileManager.default.attributesOfItem(atPath:)[.size]` を `Int64` に（取れなければ 0）
- **入力（inbox の原本）には一切書き込まない・消さない**。inbox の解放は呼び手（T-18）が DB 更新の後に行う（CONC-08）
- `timeoutSeconds`: `guard let d = duration else { return config.minTimeoutSeconds }`、`let seconds = max(Double(config.minTimeoutSeconds), d * config.timeoutFactor)`、`guard seconds < Double(Int.max) else { return Int.max }`、`return Int(seconds)`（`Int(Double)` は 0 方向への切り捨て。Int に収まらない値でトラップしない。CR-16）

## 5. TestSupport: `BWFWriter.swift`（T-14 が作る）

**`BWFWriter` は T-14 が作る**（00-api-map §15。宣言・手順・テストは T-14 §4.7・§5.6）。本チケットで書いた版（voicedock `tests/fixtures/make_wav.py` とのバイト一致を確かめたもの）をそのまま T-14 へ移した。
本チケットのテストは `BWFWriter.build(seconds:format:content:minimalHeader:toneHz:sampleRate:)` / `BWFWriter.write(to:seconds:…)` を使うだけで、`BWFWriter` を作り直さない・変えない。

## 6. テスト

共通の準備: `TempDirectory()` の下に `HomeLayout(root:)` を作り `createDirectories()`。`AudioConfig` は `AppConfig.defaults(timeZone: "Asia/Tokyo").audio` を写して必要な値だけ変える。
`PARTKEY = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"`。入力は `inbox/…` に `BWFWriter.write` で作る。時計は `SystemClock()`（時間超過のテストだけ `SteppingClock`）。

### 6.1 `BWFWriterTests.swift`

T-14 が作る（T-14 §5.6。make_wav とのバイト一致を確かめる 9 本）。本チケットには置かない。

### 6.2 `SpaceCheckTests.swift`（`@Suite("SpaceCheck")`）

| 関数名 / 表示名 | 入力 | 期待 |
|---|---|---|
| `expectedBytesTable` / 「想定バイト数の表」（パラメータ化） | `nil`, `0`, `1.5`, `1800`, `-5` | `57600000`, `0`, `48000`, `57600000`, `0` |
| `requiredBytesUsesMultiplierAndMargin` / 「CE audio.freeSpaceMultiplier 必要量 = 想定 × 倍率 + 余裕」 | expected 57600000 を、既定の設定（倍率 2.0）と `freeSpaceMultiplier = 4.0` で | `2262683648` と `2377883648` |
| `enoughSpacePasses` / 「空きが十分なら ok」 | margin 0、stagingMaxBytes 既定、duration 1 | `.ok` |
| `marginIsEnforced` / 「CE audio.freeSpaceMarginBytes 空きが必要量を下回ると不足」 | `freeSpaceMarginBytes = Int(Int64.max / 4)`（既定の 2147483648 では `.ok`） | `.insufficient` で文言が `空き ` で始まり `バイトが必要量 ` と ` バイトを下回る` を含む |
| `stagingCapIsEnforced` / 「CE audio.stagingMaxBytes staging の上限」 | margin 0、`stagingMaxBytes = 100`、staging に 80 バイトの通常ファイル、duration 0.001（既定の 5368709120 では `.ok`） | `.insufficient("staging 使用量 80 + 想定 32 が上限 100 を超える")` |
| `stagingCapExactlyAtLimitPasses` / 「上限ちょうどは ok」 | 同上で 68 バイトのファイル | `.ok`（68 + 32 = 100） |
| `missingStagingCountsAsZero` / 「staging が無ければ使用量 0」 | staging を消す、margin 0、`stagingMaxBytes = 32`、duration 0.001 | `.ok`（0 + 32 = 32） |
| `hugeDurationSaturates` / 「Int64 に収まらない長さでもトラップせず不足になる」 | `expectedBytes(.infinity)`・`expectedBytes(1e300)`・`requiredBytes(expected: Int64.max, 既定)`、既定の設定で `check(durationSeconds: .infinity)` | `Int64.max`・`Int64.max`・`Int64.max`、`.insufficient` で文言が `空き ` で始まる |

### 6.3 `OutputVerifierTests.swift`（`@Suite("OutputVerifier")`）

出力の見本は `BWFWriter.write(seconds: 1, format: .pcm16, content: .speech, minimalHeader: true, sampleRate: 16000)`（16 kHz / s16 / 1 ch / 1.0 秒ちょうど）。

| 関数名 / 表示名 | 入力 | 期待 |
|---|---|---|
| `validOutputPasses` / 「16 kHz / s16 / mono は合格」 | 見本、inputDuration 1.0 | nil |
| `missingOutput` / 「無い出力」 | 存在しないパス | `<path> がありません` |
| `emptyOutput` / 「0 バイト」 | 空ファイル | `<path> が 0 バイトです` |
| `unreadableOutput` / 「音声として読めない」 | 中身が `not a wav` | `出力を読めません: ` で始まる |
| `wrongSampleRate` / 「48 kHz は不合格」 | pcm16・48000 Hz | `sample_rate が 48000（期待 16000）` |
| `wrongSampleFormat` / 「24 bit は不合格」 | pcm24・16000 Hz | `sample_fmt が ` で始まり `（期待 s16）` で終わる |
| `unknownInputDurationSkipsLength` / 「入力の長さが不明なら長さを見ない」 | 見本、inputDuration nil | nil |
| `gapExactlyToleranceIsAccepted` / 「ずれが 1.0 ちょうどは合格」 | 見本、inputDuration 2.0 | nil |
| `gapOverToleranceFails` / 「ずれが 1.0 を超えると不合格」 | 見本、inputDuration 2.001 | `長さが入力と 1.00 秒ずれています（許容 1.0 秒）` |
| `directoryIsMissing` / 「ディレクトリは無い出力として扱う」 | TempDirectory の URL | `<path> がありません` |
| `sampleFormatNames` / 「sample_fmt の名前の表」 | `.pcmFormatInt16`・`.pcmFormatInt32`・`.pcmFormatFloat32`・`.pcmFormatFloat64`・`.otherFormat` | `s16`・`s32`・`flt`・`dbl`・`other` |

### 6.4 `NormalizerTests.swift`（`@Suite("Normalizer", .serialized)`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `convertsPCM24` / 「24 bit の BWF を 16 kHz に変換する」 | pcm24 発話 2 秒、helper = 入力の SHA、duration 2.0 | `.success`、`reused == false`、sha = 入力の SHA、`inBytes` = 入力の size、`OutputVerifier.verify(… inputDuration: 2.0 …) == nil`、`staging/<slug>/` に `audio16k.wav` だけが在る（tmp が無い） |
| `convertsFloat32` / 「32 bit float の BWF を変換する」 | float32 発話 2 秒 | 同上 |
| `convertsPCM16MinimalHeader` / 「44 バイトヘッダの WAV も変換する」 | pcm16・48 kHz・minimalHeader | `.success` |
| `outputIsRIFFWave` / 「出力は RIFF/WAVE」 | 変換の後 | 先頭 4 バイト `RIFF`、8〜11 バイト `WAVE`（`AVAudioFileTypeKey` の欠落を見張る） |
| `originalIsNeverTouched` / 「入力を書き換えない」 | 変換の前後 | 入力のバイト列が同じ |
| `helperMismatchIsSourceHashMismatch` / 「コピー時の SHA と違えば SOURCE_HASH_MISMATCH」 | helper = `"0" × 64` | `.failure(code: .sourceHashMismatch)`、文言が `再計算した SHA-256 がコピー時の値と一致しません（` で始まり `… ≠ 0000000000000000…）`（0 が 16 個）で終わる、出力が無い、入力が在る |
| `missingHelperIsMismatch` / 「コピー時の SHA が無ければ不一致として扱う」 | helper = nil | `.sourceHashMismatch`、文言が `… ≠ 記録なし）` で終わる |
| `durationMismatchFailsVerification` / 「長さが 1 秒を超えてずれると NORMALIZE_VERIFY_FAILED」 | 2 秒の入力、duration 4.0 | `.normalizeVerifyFailed`、文言が `長さが入力と ` で始まる、出力が無い |
| `unknownDurationSkipsLengthCheck` / 「duration 不明なら長さを見ない」 | duration nil | `.success` |
| `slugCollisionIsImportFailed` / 「slug の衝突は IMPORT_FAILED」 | claimedBy = `"DJIMIC3/other/other_orig.wav"` | `.importFailed`、文言 `staging の slug が衝突しています（<slug> は DJIMIC3/other/other_orig.wav が使用中）` |
| `ownClaimIsNotCollision` / 「自分の claim は衝突ではない」 | claimedBy = PARTKEY | `.success` |
| `duplicateContentIsReported` / 「同じ SHA の別の Part があれば重複」 | duplicateOf が常に `"DJIMIC3/other/other_orig.wav"` | `.duplicate(of: "DJIMIC3/other/other_orig.wav", sha256: 入力の SHA)`、出力が無い、入力が在る |
| `ownSHAIsNotDuplicate` / 「自分の SHA は重複ではない」 | duplicateOf が PARTKEY を返す | `.success` |
| `verifiedOutputIsReused` / 「検証を通る出力は再利用する」 | 1 回目の成功の後にもう一度 | `.success(reused: true)`、sha が 1 回目と同じ |
| `reusePathChecksHash` / 「再利用でもコピー時の SHA と照合する」（DEV-18） | 1 回目の成功の後、helper を別の値にして 2 回目 | `.sourceHashMismatch`、出力が消えている |
| `reusePathChecksDuplicate` / 「再利用でも重複を判定する」 | 1 回目の成功の後、duplicateOf が別の Part を返す | `.duplicate`、出力が消えている |
| `brokenOutputIsRegenerated` / 「壊れた出力は作り直す」 | 出力の位置に `broken` を書いておく | `.success(reused: false)` |
| `missingInputIsImportFailed` / 「入力が無ければ IMPORT_FAILED」 | 存在しない入力 | `.importFailed`、tmp も出力も無い |
| `emptyInputIsImportFailed` / 「0 バイトの入力は IMPORT_FAILED」（TEST-28） | 入力を 0 バイトにする、helper = 空の SHA-256、duration nil | `.importFailed`、tmp も出力も無い、入力が在る |
| `diskSpaceLowIsReported` / 「空きが足りなければ DISK_SPACE_LOW」 | `freeSpaceMarginBytes = Int(Int64.max / 4)` | `.diskSpaceLow`、出力が無い、入力が在る |
| `deadlineExceededIsImportFailed` / 「時間上限を超えたら中断して IMPORT_FAILED」 | `SteppingClock(start: Instant(epochMillis: 0), stepMilliseconds: 1_000_000)`（`uptime()` を呼ぶたびに 1000 秒進む。T-10）、duration nil | `.importFailed("180 秒を超えました")`、tmp も出力も無い |
| `timeoutTable` / 「時間上限の式」（パラメータ化） | duration `nil`, `100`, `360`, `361`, `1800.7` | `180`, `180`, `180`, `180`, `900` |
| `ceAudioTimeoutFactor` / 「CE audio.timeoutFactor を 2.0 にすると時間上限が伸びる」 | duration 1800.7、`timeoutFactor = 2.0` | `3601`（既定の 0.5 なら `900`） |
| `ceAudioMinTimeoutSeconds` / 「CE audio.minTimeoutSeconds が時間上限の下限」 | duration `nil` と `100`、`minTimeoutSeconds = 600` | どちらも `600`（既定の 180 なら `180`） |
| `ceDurationToleranceSeconds` / 「CE audio.durationToleranceSeconds 許容を広げると検証を通る」 | 2 秒の入力、duration 4.0、`durationToleranceSeconds = 3.0` | `.success`（既定の 1.0 では `.normalizeVerifyFailed`。`durationMismatchFailsVerification` と対） |
| `hugeDurationTimeoutSaturates` / 「Int に収まらない長さでも時間上限はトラップしない」 | duration `.infinity` と `1e300` | どちらも `Int.max` |

### 6.5 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`audio.timeoutFactor`・`audio.minTimeoutSeconds`・`audio.durationToleranceSeconds`・`audio.freeSpaceMultiplier`・`audio.freeSpaceMarginBytes`・`audio.stagingMaxBytes` の 6 行を消す（CE テストは §6.2・§6.4）。

## 7. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| 手順 5 の照合を消す | `helperMismatchIsSourceHashMismatch`、`missingHelperIsMismatch` |
| 再利用の経路の照合を消す | `reusePathChecksHash` |
| 再利用の経路の重複判定を消す | `reusePathChecksDuplicate` |
| `OutputVerifier` の `gap > tolerance` を `>=` にする | `gapExactlyToleranceIsAccepted` |
| 手順 6 の `discard(output)` を消す | `durationMismatchFailsVerification` |
| `outputSettings` から `AVAudioFileTypeKey` を消す | `outputIsRIFFWave`（か変換のテスト） |
| `commonFormat: .pcmFormatInt16` を外して `forWriting:settings:` にする | `convertsPCM24` ほか（書き込みで失敗する） |
| `Deadline.isExceeded` を常に false にする | `deadlineExceededIsImportFailed` |
| `SpaceCheck` の 2 つ目の条件を消す | `stagingCapIsEnforced` |
| 入力ブロックの `framePosition >= length` の確かめを消す | `convertsPCM24` ほか変換の成功を見るテストすべて（末尾の `read(into:)` が nilError を投げる） |
| `timeoutSeconds` の `Int.max` への留めを消す | `hugeDurationTimeoutSaturates`（`Int(Double)` のトラップでテストの実行が止まる） |

T-16 の実装で上の 11 項目を 1 つずつ行い、どれも表の「落ちるべきテスト」が落ちることを確かめた。
`AVAudioFileTypeKey` を消すと出力は CAF（先頭 `caff`）になり、`AVAudioFile` はそれも読めるので、落ちるのは `outputIsRIFFWave` だけ（変換のテストは通る）。
`commonFormat: .pcmFormatInt16` を外すと、変換の成功を前提にするテスト 17 本がすべて落ちる。

## 8. 受け入れ条件

- [ ] §3 のファイルがすべて在り、公開宣言が 00-api-map.md §6 と一致する
- [ ] `normalize` の同期の本体が `BlockingIO.run` の中で動く（actor を止めない）
- [ ] `rename(` は `Normalizer.swift` にだけ在る（PT-12）。削除は `SafeUnlink` 経由だけ（PT-01）
- [ ] §6 のテストがすべて通る（BWFWriter の SHA-256 の一致は T-14 が確かめる）
- [ ] 入力を書き換えない・消さない
- [ ] `make lint` が通る

## 9. SPEC の変更

なし。

## 10. マージ後にやること

- P0-05 の結果（AVAudioConverter と ffmpeg の長さの差、float BWF の読み込み）が docs/POC.md に在ることを確かめる。無ければ P0-05 を先に済ませる

## API 地図への変更提案

1. `Normalizer.init` の `clock` の型を `any AppClock` と明記する（地図は `clock: AppClock`）。意味は同じ → 地図は `AppClock` のまま（Swift 6 では存在型を `any AppClock` と書く。同じ型）
2. `NormalizeRequest` に公開の `init(input:partkey:durationSeconds:sha256Helper:claimedBy:duplicateOf:)` が要る（地図に init の記載が無い）→ 00-api-map に反映済み（2026-09-18）
3. TestSupport の `SteppingClock` は `uptime()` も呼ばれるたびに進むこと（時間上限のテストで使う）→ 00-api-map §15 に反映済み（2026-09-18）。T-10 の形は `SteppingClock(start: Instant, stepMilliseconds: Int64)`（`now()` と `uptime()` の両方を進める）
4. `BWFWriter` の作り手を T-14 にし、本チケットの版を正とする → 00-api-map §15 に反映済み（2026-09-18）。宣言とテストは T-14 へ移した
5. 旧版は `SpaceMath.bytesPerSecond` / `defaultDurationSeconds` と `OutputVerifier.expectedSampleRate` / `expectedChannels` を `public` にしていたが、地図 §6 に無く、モジュールの外で使う者もいない → 地図に合わせて internal にした（T-16 の実装。地図の変更は不要）
