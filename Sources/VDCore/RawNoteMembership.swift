// Raw ノートに載る Part の判定（PLAN §8.6・§8.7・§8.9.1。00-api-map §2.1）。
/// Raw ノートに載る Part かどうか（PLAN §8.6・§8.7・§8.9.1）。**書き手（Raw の描画）と検証側（保存検証・削除条件の再検証）がこの関数だけを使う**（§9.1 原則 2）。
public enum RawNoteMembership {
    public static func isMember(status: PartStatus, transcriptReadable: Bool) -> Bool {
        PartStates.rawNoteMembers.contains(status) && transcriptReadable
    }
}
