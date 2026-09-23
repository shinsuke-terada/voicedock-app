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

    public init(
        input: URL, partkey: String, durationSeconds: Double?, sha256Helper: String?,
        claimedBy: String?, duplicateOf: @escaping @Sendable (String) -> String?
    ) {
        self.input = input
        self.partkey = partkey
        self.durationSeconds = durationSeconds
        self.sha256Helper = sha256Helper
        self.claimedBy = claimedBy
        self.duplicateOf = duplicateOf
    }
}

public enum NormalizeOutcome: Equatable, Sendable {
    case success(sha256: String, output: URL, inBytes: Int64, outBytes: Int64, reused: Bool)
    case duplicate(of: String, sha256: String)
    case failure(StageFailure)
}

public struct Normalizer: Sendable {
    private let config: AudioConfig
    private let layout: HomeLayout
    private let clock: any AppClock

    public init(config: AudioConfig, layout: HomeLayout, clock: any AppClock) {
        self.config = config
        self.layout = layout
        self.clock = clock
    }

    /// 本体を `BlockingIO.run` の中で同期に実行する（PLAN §2.1。actor を止めない）。
    public func normalize(_ req: NormalizeRequest) async -> NormalizeOutcome {
        do {
            return try await BlockingIO.run { normalizeSync(req) }
        } catch {
            return .failure(StageFailure(.importFailed, ErrorText.describe(error)))
        }
    }

    /// 変換の時間上限（秒）。`Int(max(Double(minTimeoutSeconds), duration × timeoutFactor))`、duration 不明なら minTimeoutSeconds。
    /// Int に収まらない値は `Int.max`（トラップしない。CR-16）。
    static func timeoutSeconds(duration: Double?, config: AudioConfig) -> Int {
        guard let d = duration else { return config.minTimeoutSeconds }
        let seconds = max(Double(config.minTimeoutSeconds), d * config.timeoutFactor)
        guard seconds < Double(Int.max) else { return Int.max }
        return Int(seconds)
    }

    /// 同期の本体（PLAN §8.3 の手順 1〜8。この順）。入力（inbox の原本）には書き込まない・消さない（CONC-08）。
    func normalizeSync(_ req: NormalizeRequest) -> NormalizeOutcome {
        let slug = KeySlug.of(req.partkey)
        let output = layout.normalizedAudio(slug: slug)
        let tmp = layout.normalizedAudioTmp(slug: slug)

        // 1. slug の衝突（CONC-13）
        if let claimedBy = req.claimedBy, claimedBy != req.partkey {
            return .failure(StageFailure(.importFailed, "staging の slug が衝突しています（\(slug) は \(claimedBy) が使用中）"))
        }

        // 2. 再利用（冪等。DEV-18: 再利用でも入力の SHA-256 を計算し直して照合する）。
        //    F-77: 入力のヘッダの照合も通るときだけ。通らなければ変換し直し、手順 6 で落とす
        let tolerance = config.durationToleranceSeconds
        if OutputVerifier.verify(output: output, inputDuration: req.durationSeconds, tolerance: tolerance) == nil,
            InputExtentCheck.check(input: req.input) == nil
        {
            let hashed: (sha256: String, bytes: Int64)
            do {
                hashed = try InputHasher.hash(req.input, chunkBytes: config.hashChunkBytes, deadline: nil)
            } catch {
                return .failure(StageFailure(.importFailed, ErrorText.describe(error)))
            }
            if let mismatch = hashMismatch(sha: hashed.sha256, helper: req.sha256Helper) {
                discard(output)
                return .failure(mismatch)
            }
            if let other = req.duplicateOf(hashed.sha256), other != req.partkey {
                discard(output)
                return .duplicate(of: other, sha256: hashed.sha256)
            }
            return .success(
                sha256: hashed.sha256, output: output, inBytes: hashed.bytes, outBytes: size(of: output), reused: true)
        }

        // 3. 空き容量の再確認
        if case .insufficient(let message) = SpaceCheck(config: config, layout: layout).check(
            durationSeconds: req.durationSeconds)
        {
            return .failure(StageFailure(.diskSpaceLow, message))
        }

        // 4. 変換
        do {
            try FileManager.default.createDirectory(
                at: layout.stagingDirectory(slug: slug), withIntermediateDirectories: true)
        } catch {
            return .failure(StageFailure(.importFailed, ErrorText.describe(error)))
        }
        discard(output)
        discard(tmp)
        let limit = Normalizer.timeoutSeconds(duration: req.durationSeconds, config: config)
        let deadline = Deadline(clock: clock, start: clock.uptime(), limitSeconds: limit)
        let sha: String
        let inBytes: Int64
        do {
            (sha, inBytes) = try InputHasher.hash(req.input, chunkBytes: config.hashChunkBytes, deadline: deadline)
            try AudioConversion.convert(input: req.input, tmpOutput: tmp, deadline: deadline)
            guard Darwin.rename(tmp.path(percentEncoded: false), output.path(percentEncoded: false)) == 0 else {
                throw StageFailure(.importFailed, "rename: errno \(errno)")
            }
        } catch {
            discard(tmp)
            discard(output)
            if let failure = error as? StageFailure { return .failure(failure) }
            if error as? InputHasherError == .deadlineExceeded
                || error as? AudioConversionError == .deadlineExceeded
            {
                return .failure(StageFailure(.importFailed, "\(limit) 秒を超えました"))
            }
            return .failure(StageFailure(.importFailed, ErrorText.describe(error)))
        }

        // 5. コピー時の SHA との照合（DEV-17: helper が無ければ照合不能 = 失敗）
        if let mismatch = hashMismatch(sha: sha, helper: req.sha256Helper) {
            discard(output)
            return .failure(mismatch)
        }

        // 6. 出力の検証（ASR-01）→ 入力のヘッダの長さと実データの量の照合（F-77。後半を欠いた出力を合格にしない）
        if let message = OutputVerifier.verify(output: output, inputDuration: req.durationSeconds, tolerance: tolerance)
            ?? InputExtentCheck.check(input: req.input)
        {
            discard(output)
            return .failure(StageFailure(.normalizeVerifyFailed, message))
        }

        // 7. 重複
        if let other = req.duplicateOf(sha), other != req.partkey {
            discard(output)
            return .duplicate(of: other, sha256: sha)
        }

        // 8. 成功
        return .success(sha256: sha, output: output, inBytes: inBytes, outBytes: size(of: output), reused: false)
    }

    /// 手順 5 の照合。一致なら nil、不一致（helper が nil を含む）なら SOURCE_HASH_MISMATCH。
    private func hashMismatch(sha: String, helper: String?) -> StageFailure? {
        guard let helper, sha == helper else {
            let expected = helper.map { "\($0.prefix(16))…" } ?? "記録なし"
            return StageFailure(
                .sourceHashMismatch, "再計算した SHA-256 がコピー時の値と一致しません（\(sha.prefix(16))… ≠ \(expected)）")
        }
        return nil
    }

    /// 後片付けの削除。失敗は握りつぶし、元の結果を返す（CR-21）。
    private func discard(_ url: URL) {
        try? SafeUnlink.remove(url, under: .staging, layout: layout)
    }

    /// ファイルの size。取れなければ 0。
    private func size(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
            let number = attributes[.size] as? NSNumber
        else { return 0 }
        return number.int64Value
    }
}
