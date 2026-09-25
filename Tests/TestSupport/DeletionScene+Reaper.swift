// DeletionScene に本物の reaper を置く（T-38。削除の往復の結合テスト用）。
// 置き場所は舞台の <tmp>/home/bin だけ（/Volumes の下には触れない）。
import Foundation

extension DeletionScene {
    /// ビルドした本物の reaper（T-37 の ReaperBinary.url()）を bin/voicedock-reaper に複製し 0o755 にする（スタブは消す）
    public func installRealReaper() throws {
        let source = try ReaperBinary.url()
        try removeReaper()
        try FileManager.default.copyItem(at: source, to: layout.reaperExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: layout.reaperExecutable.path(percentEncoded: false))
    }
}
