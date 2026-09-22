// 削除の経路のログの reason 語と、後追いの対象外の語（PLAN 付録 A.4・§8.9.9）。逐語。ここ以外に書かない（CR-06）。
public enum DeletionReason {
    // source_delete_skipped session_key=… reason=…（readiness。§8.9.2 の判定順）
    public static let deleteSourceAudioDisabled = "delete_source_audio_disabled"
    public static let lockMismatch = "lock_mismatch"
    public static let mountModeRO = "mount_mode_ro"
    public static let reaperNotInstalled = "reaper_not_installed"
    public static let reaperInvalid = "reaper_invalid"
    // source_delete_skipped（観測・後追い・衝突）
    public static let deviceReadonly = "device_readonly"
    public static let alreadyAbsent = "already_absent"
    public static let statusChanged = "status_changed"
    // source_delete_pending recording_key=… reason=…（RV の理由語は IdentityReason）
    public static let stillInInventory = "still_in_inventory"
    public static let noResult = "no_result"
    public static let queueWriteFailed = "queue_write_failed"
    // disk_space_low session_key=… reason=…
    public static let stagingUnlinkFailed = "staging_unlink_failed"
    // reaper_failed reason=…
    public static let signature = "signature"
    public static let versionMismatch = "version_mismatch"
    public static let timeout = "timeout"
    /// reaper が reaper.lock を取れず終了コード 4 で終わった（§8.9.6「4 は busy」。T-38）
    public static let busy = "busy"
    /// "exit_<n>"（10 進）
    public static func exit(_ code: Int32) -> String { "exit_" + String(code) }
    // 後追いの対象外（BacklogPlan の reason。§8.9.9）。IdentityReason の同じ綴りの語とは別の語彙（意味が違う）
    public static let alreadyDeleted = "already_deleted"
    public static let notDeletable = "not_deletable"
    public static let deviceAbsent = "device_absent"
    public static let stillPresent = "still_present"
    // events.detail（§8.9.9 の手動で消した分）
    public static let resolveAbsentDetail = "resolve_absent"
}
