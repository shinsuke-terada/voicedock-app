// 1 tick の間に変わらないもの。工程（PartSteps / SessionSteps）はこれを受けて作る（voicedock の「Pipeline は 1 周に 1 個」）。
import VDCore
import VDDevice

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
    // T-29 が var vaultIndex: VaultIndex? を足す

    /// DB などの予期しない例外を常駐を止めずに記録する（1 件の失敗で残りを止めない。DEL-14）。
    func warnStore(_ error: any Error, rule: String = "store") {
        deps.log.warning(.configWarning, [(.rule, .string(rule)), (.message, .string(ErrorText.describe(error)))])
    }
}
