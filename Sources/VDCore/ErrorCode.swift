// エラーコード（PLAN 付録 A.3）。宣言順は voicedock errors.py と同じ（Daily の警告行の並びがこれに依存する）。コード名の文字列はこのファイルにしか書かない（PT-06）。
import Foundation

public enum ErrorCode: String, CaseIterable, Sendable, Hashable {
    case configUnknownKey = "CONFIG_UNKNOWN_KEY"
    case configInvalidValue = "CONFIG_INVALID_VALUE"
    case configLockMismatch = "CONFIG_LOCK_MISMATCH"
    case deviceNotReadable = "DEVICE_NOT_READABLE"
    case deviceUnsupported = "DEVICE_UNSUPPORTED"
    case fileNotStable = "FILE_NOT_STABLE"
    case duplicateContent = "DUPLICATE_CONTENT"
    case sourceMissing = "SOURCE_MISSING"
    case sourceHashMismatch = "SOURCE_HASH_MISMATCH"
    // HELPER_UNAVAILABLE は廃止（番号を詰めない。PLAN 付録 A.3）
    case deleteQueueFailed = "DELETE_QUEUE_FAILED"
    case deleteTimeout = "DELETE_TIMEOUT"
    case diskSpaceLow = "DISK_SPACE_LOW"
    case audioProbeFailed = "AUDIO_PROBE_FAILED"
    case importFailed = "IMPORT_FAILED"
    case normalizeVerifyFailed = "NORMALIZE_VERIFY_FAILED"
    case normalizedMissing = "NORMALIZED_MISSING"
    case whisperExecMissing = "WHISPER_EXEC_MISSING"
    case whisperModelMissing = "WHISPER_MODEL_MISSING"
    case whisperFailed = "WHISPER_FAILED"
    case whisperTimeout = "WHISPER_TIMEOUT"
    case noSpeechDetected = "NO_SPEECH_DETECTED"
    case obsidianRawWriteFailed = "OBSIDIAN_RAW_WRITE_FAILED"
    case obsidianRawVerifyFailed = "OBSIDIAN_RAW_VERIFY_FAILED"
    case sessionMergeFailed = "SESSION_MERGE_FAILED"
    case llmUnavailable = "LLM_UNAVAILABLE"
    case llmFailed = "LLM_FAILED"
    case llmInvalidJSON = "LLM_INVALID_JSON"
    case obsidianNotFound = "OBSIDIAN_NOT_FOUND"
    case obsidianWriteFailed = "OBSIDIAN_WRITE_FAILED"
    case obsidianVerifyFailed = "OBSIDIAN_VERIFY_FAILED"
    case sourceIdentityMismatch = "SOURCE_IDENTITY_MISMATCH"
    case sourceDeleteFailed = "SOURCE_DELETE_FAILED"
    // LOCAL_DELETE_FAILED / DB_ERROR は廃止
}

/// 再試行の区分（PLAN 付録 A.3・§5.4）。振る舞いを変えるのは `attempts`（工程内リトライの対象）だけ。
/// requeue（4 つの契機）は RetryPolicy を見ずに FAILED をすべて戻す。`none` / `nextPoll` / `nextConnect` は表示と voicedock との対応のために残す。
public enum RetryPolicy: Sendable, Hashable {
    case none
    case nextPoll
    case nextConnect
    case attempts
}

extension ErrorCode {
    /// PLAN 付録 A.3 の「再試行」列。
    public var retryPolicy: RetryPolicy {
        switch self {
        case .configUnknownKey, .configInvalidValue, .configLockMismatch, .deviceUnsupported, .duplicateContent,
            .sourceMissing, .whisperExecMissing, .whisperModelMissing, .noSpeechDetected, .llmInvalidJSON:
            return .none
        case .deviceNotReadable, .fileNotStable, .diskSpaceLow:
            return .nextPoll
        case .deleteQueueFailed, .deleteTimeout, .normalizedMissing, .sourceIdentityMismatch, .sourceDeleteFailed:
            return .nextConnect
        case .sourceHashMismatch, .audioProbeFailed, .importFailed, .normalizeVerifyFailed, .whisperFailed,
            .whisperTimeout, .obsidianRawWriteFailed, .obsidianRawVerifyFailed, .sessionMergeFailed, .llmUnavailable,
            .llmFailed, .obsidianNotFound, .obsidianWriteFailed, .obsidianVerifyFailed:
            return .attempts
        }
    }

    /// 宣言順の 0 始まりの位置（`ErrorCode.allCases.firstIndex(of: self)`）。Daily の警告行の並びに使う。
    public var declarationIndex: Int {
        ErrorCode.allCases.firstIndex(of: self) ?? ErrorCode.allCases.count
    }

    /// `part_skipped` の reason 語。対象外は nil。
    public var skipReasonWord: String? {
        switch self {
        case .sourceMissing:
            return "source_missing"
        case .duplicateContent:
            return "duplicate_content"
        case .noSpeechDetected:
            return "no_speech"
        case .configUnknownKey, .configInvalidValue, .configLockMismatch, .deviceNotReadable, .deviceUnsupported,
            .fileNotStable, .sourceHashMismatch, .deleteQueueFailed, .deleteTimeout, .diskSpaceLow, .audioProbeFailed,
            .importFailed, .normalizeVerifyFailed, .normalizedMissing, .whisperExecMissing, .whisperModelMissing,
            .whisperFailed, .whisperTimeout, .obsidianRawWriteFailed, .obsidianRawVerifyFailed, .sessionMergeFailed,
            .llmUnavailable, .llmFailed, .llmInvalidJSON, .obsidianNotFound, .obsidianWriteFailed,
            .obsidianVerifyFailed, .sourceIdentityMismatch, .sourceDeleteFailed:
            return nil
        }
    }

    /// 工程内リトライの対象か（`retryPolicy == .attempts`。voicedock counts_against_max_attempts）。
    public var countsAgainstMaxAttempts: Bool { retryPolicy == .attempts }
}
