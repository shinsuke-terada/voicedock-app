// ガード（遷移せずに待つ。失敗ではない。PLAN §5.4）の理由。rawValue はログの reason 語（付録 A.4）。

/// ガードの理由。宣言順 = PLAN 付録 A.4 の並び（status の paused もこの順）。
public enum PauseReason: String, Sendable, CaseIterable, Equatable {
    case diskSpaceLow = "disk_space_low"
    case whisperMissing = "whisper_missing"
    case modelMissing = "model_missing"
    case vadModelMissing = "vad_model_missing"
    case vaultNotConfigured = "vault_not_configured"
    case vaultUnavailable = "vault_unavailable"
    case llmNotSelected = "llm_not_selected"
    case llmModelMissing = "llm_model_missing"
    case llmInsufficientMemory = "llm_insufficient_memory"
    case llamaServerMissing = "llama_server_missing"
    case license
}
