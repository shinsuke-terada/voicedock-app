// Raw ノートを保存した直後の削除評価（PLAN §5.5。その Part だけでなく Session の全 Part）。本体は T-38。

extension PartSteps {
    /// 書いた要求の数（T-38 が requestDeletions(session) を呼ぶ。snapshot の新鮮さは要求を書く直前に確かめる。DEL-20）。
    func requestDeletionsAfterRawNote(sessionKey: String) async -> Int { 0 }  // T-38 が中身を書く
}
