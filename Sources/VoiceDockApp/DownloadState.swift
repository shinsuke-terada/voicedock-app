// 進行中のダウンロード・取り込みの状態（画面にだけ在る値。AppSnapshot には入れない）。

/// ダウンロード・取り込みの枠。
enum ModelSlot: Hashable, Sendable {
    case whisper, vad
    case llm(String)

    /// ファイルから読み込む間の枠（ID が決まる前なので専用の枠を使う）
    static let customImport = ModelSlot.llm("custom")
}

/// 1 つの枠の状態。
enum DownloadState: Equatable, Sendable {
    case idle
    /// total <= 0 なら不定
    case running(received: Int64, total: Int64)
    /// ファイルから読み込む（SHA を計算中。進捗は出ない）
    case importing
    case failed(String)

    /// total > 0 のときだけ received/total（0…1 に丸める）
    var fraction: Double? {
        guard case .running(let received, let total) = self, total > 0 else { return nil }
        return min(1, max(0, Double(received) / Double(total)))
    }
}
