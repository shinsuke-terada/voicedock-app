// エラーコードの宣言順・RetryPolicy・reason 語（PLAN 付録 A.3。T-08）。
import Testing

@testable import VDCore

@Suite("ErrorCode")
struct ErrorCodeTests {
    /// 付録 A.3 の表の「コード」と「再試行」の列の写し（手で書く。TEST-01）。
    static let appendixA3: [(code: String, retry: String)] = [
        ("CONFIG_UNKNOWN_KEY", "none"),
        ("CONFIG_INVALID_VALUE", "none"),
        ("CONFIG_LOCK_MISMATCH", "none"),
        ("DEVICE_NOT_READABLE", "next_poll"),
        ("DEVICE_UNSUPPORTED", "none"),
        ("FILE_NOT_STABLE", "next_poll"),
        ("DUPLICATE_CONTENT", "none"),
        ("SOURCE_MISSING", "none"),
        ("SOURCE_HASH_MISMATCH", "attempts"),
        ("DELETE_QUEUE_FAILED", "next_connect"),
        ("DELETE_TIMEOUT", "next_connect"),
        ("DISK_SPACE_LOW", "next_poll"),
        ("AUDIO_PROBE_FAILED", "attempts"),
        ("IMPORT_FAILED", "attempts"),
        ("NORMALIZE_VERIFY_FAILED", "attempts"),
        ("NORMALIZED_MISSING", "next_connect"),
        ("WHISPER_EXEC_MISSING", "none"),
        ("WHISPER_MODEL_MISSING", "none"),
        ("WHISPER_FAILED", "attempts"),
        ("WHISPER_TIMEOUT", "attempts"),
        ("NO_SPEECH_DETECTED", "none"),
        ("OBSIDIAN_RAW_WRITE_FAILED", "attempts"),
        ("OBSIDIAN_RAW_VERIFY_FAILED", "attempts"),
        ("SESSION_MERGE_FAILED", "attempts"),
        ("LLM_UNAVAILABLE", "attempts"),
        ("LLM_FAILED", "attempts"),
        ("LLM_INVALID_JSON", "none"),
        ("OBSIDIAN_NOT_FOUND", "attempts"),
        ("OBSIDIAN_WRITE_FAILED", "attempts"),
        ("OBSIDIAN_VERIFY_FAILED", "attempts"),
        ("SOURCE_IDENTITY_MISMATCH", "next_connect"),
        ("SOURCE_DELETE_FAILED", "next_connect"),
    ]

    @Test("宣言順は付録 A.3 の順（voicedock errors.py から 3 つを除いた順）")
    func declarationOrderMatchesAppendixA3() {
        #expect(
            ErrorCode.allCases.map(\.rawValue) == [
                "CONFIG_UNKNOWN_KEY", "CONFIG_INVALID_VALUE", "CONFIG_LOCK_MISMATCH", "DEVICE_NOT_READABLE",
                "DEVICE_UNSUPPORTED", "FILE_NOT_STABLE", "DUPLICATE_CONTENT", "SOURCE_MISSING", "SOURCE_HASH_MISMATCH",
                "DELETE_QUEUE_FAILED", "DELETE_TIMEOUT", "DISK_SPACE_LOW", "AUDIO_PROBE_FAILED", "IMPORT_FAILED",
                "NORMALIZE_VERIFY_FAILED", "NORMALIZED_MISSING", "WHISPER_EXEC_MISSING", "WHISPER_MODEL_MISSING",
                "WHISPER_FAILED", "WHISPER_TIMEOUT", "NO_SPEECH_DETECTED", "OBSIDIAN_RAW_WRITE_FAILED",
                "OBSIDIAN_RAW_VERIFY_FAILED", "SESSION_MERGE_FAILED", "LLM_UNAVAILABLE", "LLM_FAILED",
                "LLM_INVALID_JSON", "OBSIDIAN_NOT_FOUND", "OBSIDIAN_WRITE_FAILED", "OBSIDIAN_VERIFY_FAILED",
                "SOURCE_IDENTITY_MISMATCH", "SOURCE_DELETE_FAILED",
            ])
    }

    @Test("廃止した 3 コードは無い")
    func abolishedCodesAreAbsent() {
        #expect(ErrorCode(rawValue: "HELPER_UNAVAILABLE") == nil)
        #expect(ErrorCode(rawValue: "LOCAL_DELETE_FAILED") == nil)
        #expect(ErrorCode(rawValue: "DB_ERROR") == nil)
    }

    @Test("再試行の区分は付録 A.3 の表どおり", arguments: ErrorCodeTests.appendixA3)
    func retryPolicyTable(row: (code: String, retry: String)) throws {
        let code = try #require(ErrorCode(rawValue: row.code))
        #expect(code.retryPolicy.rawValue == row.retry)
    }

    @Test("全コードに RetryPolicy がある（TEST-08）")
    func everyCodeHasRetryPolicy() {
        #expect(ErrorCodeTests.appendixA3.count == 32)
        let policies = ErrorCode.allCases.map(\.retryPolicy)
        #expect(policies.count == 32)
    }

    @Test("工程内リトライの対象は attempts だけ")
    func countsAgainstMaxAttemptsOnlyAttempts() {
        let expected: Set<ErrorCode> = [
            .sourceHashMismatch, .audioProbeFailed, .importFailed, .normalizeVerifyFailed, .whisperFailed,
            .whisperTimeout, .obsidianRawWriteFailed, .obsidianRawVerifyFailed, .sessionMergeFailed, .llmUnavailable,
            .llmFailed, .obsidianNotFound, .obsidianWriteFailed, .obsidianVerifyFailed,
        ]
        #expect(expected.count == 14)
        #expect(Set(ErrorCode.allCases.filter(\.countsAgainstMaxAttempts)) == expected)
    }

    @Test("part_skipped の reason 語")
    func skipReasonWords() {
        #expect(ErrorCode.sourceMissing.skipReasonWord == "source_missing")
        #expect(ErrorCode.duplicateContent.skipReasonWord == "duplicate_content")
        #expect(ErrorCode.noSpeechDetected.skipReasonWord == "no_speech")
        let others = ErrorCode.allCases.filter { ![.sourceMissing, .duplicateContent, .noSpeechDetected].contains($0) }
        #expect(others.count == 29)
        for code in others {
            #expect(code.skipReasonWord == nil, "\(code)")
        }
    }

    @Test("declarationIndex は宣言順の位置")
    func declarationIndexIsPosition() {
        #expect(ErrorCode.configUnknownKey.declarationIndex == 0)
        #expect(ErrorCode.duplicateContent.declarationIndex == 6)
        #expect(ErrorCode.noSpeechDetected.declarationIndex == 20)
        #expect(ErrorCode.sourceDeleteFailed.declarationIndex == 31)
    }

    @Test("StageFailure は code と message で等しい")
    func stageFailureEquality() {
        #expect(StageFailure(.whisperFailed, "exit 1") == StageFailure(.whisperFailed, "exit 1"))
        #expect(StageFailure(.whisperFailed, "exit 1") != StageFailure(.whisperTimeout, "exit 1"))
        #expect(StageFailure(.whisperFailed, "exit 1") != StageFailure(.whisperFailed, "exit 2"))
        #expect(StageFailure(.llmFailed, "") == StageFailure(.llmFailed, ""))
    }
}
