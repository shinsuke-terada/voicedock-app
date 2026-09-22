// 復旧時の Vault の一時ファイルの削除（PLAN §5.3。本体は T-29）。
import VDStore

extension Recovery {
    // T-29 が中身を書く（PLAN §5.3）。
    func discardVaultTmp(part row: RecordingRow) {}

    // T-29 が中身を書く（PLAN §5.3）。
    func discardVaultTmp(session row: SessionRow) {}
}
