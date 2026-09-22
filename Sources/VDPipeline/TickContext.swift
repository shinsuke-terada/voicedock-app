// 1 tick の間に変わらないもの。工程（PartSteps / SessionSteps）はこれを受けて作る（voicedock の「Pipeline は 1 周に 1 個」）。
import VDCore
import VDDevice
import VDNotes

/// 1 tick の間に変わらないもの。
struct TickContext: Sendable {
    let deps: WorkerDependencies
    let config: AppConfig
    let zone: ZonedTime
    /// tick の先頭で取ったもの（起動直後は nil）
    let snapshot: DeviceSnapshot?
    let pauses: PauseBook
    let activity: ActivityBoard
    let stop: StopFlag
    /// Worker が tick をまたいで持つ Vault 索引（linkTags が偽・未作成なら nil。PLAN §8.6 WikiLink）
    var vaultIndex: VaultIndex? = nil
    /// この tick で PENDING に落とした Part（DEL-11。tick ごとに新しい。複製した ctx は同じ集合を共有する）
    let pendedPartkeys = PendedPartkeys()

    /// DB などの予期しない例外を常駐を止めずに記録する（1 件の失敗で残りを止めない。DEL-14）。
    func warnStore(_ error: any Error, rule: String = "store") {
        deps.log.warning(.configWarning, [(.rule, .string(rule)), (.message, .string(ErrorText.describe(error)))])
    }
}
