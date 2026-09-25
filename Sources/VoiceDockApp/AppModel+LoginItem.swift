// ログイン項目（PLAN §8.12 の 6）と「はじめに」の ④ の記録（PLAN §8.12 の 3-④）。
extension AppModel {
    /// オンで register、オフで unregister。成功したら「はじめに」の ④ も完了にする。
    /// register が成功しても .requiresApproval になることがある（承認待ち）。エラーにしない。
    func setLoginItem(_ on: Bool) async {
        let r = on ? services.registerLoginItem() : services.unregisterLoginItem()
        if case .failure(let m) = r {
            loginItemError = m
            await refresh()
            return
        }
        loginItemError = nil
        await markLoginItemDecided()
        await refresh()
    }

    /// SMAppService.openSystemSettingsLoginItems()（.requiresApproval のときだけボタンを出す）
    func openLoginItemSettings() { services.openSystemSettingsLoginItems() }

    /// 「今はしない」
    func dismissLoginItem() async {
        await markLoginItemDecided()
        await refresh()
    }

    /// <HOME>/ui-state.json に loginItemDecided を記録する（書けなければ uiStateSaveFailed）。
    /// 最終接続はこの起動で最後に書こうとした値を使う（refresh が重なって snapshot が古くても戻さない。F-70）。
    private func markLoginItemDecided() async {
        var st = snapshot.uiState
        st.loginItemDecided = true
        st.lastConnectedAt = lastConnectedWritten ?? st.lastConnectedAt
        let saved = services.saveUIState(st)
        uiStateSaveFailed = !saved
        if saved { loginItemDecidedWritten = true }
    }
}
