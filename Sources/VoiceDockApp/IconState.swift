// メニューバーのアイコンの状態（PLAN §8.12 の表）。値と記号の対応をここだけに持つ。

/// メニューバーのアイコンの状態（PLAN §8.12）。
enum IconState: String, Equatable, CaseIterable, Sendable {
    case idle, ingesting, processing, attention

    var symbolName: String {
        switch self {
        case .idle: "waveform"
        case .ingesting: "arrow.down.circle"
        case .processing: "text.bubble"
        case .attention: "exclamationmark.triangle"
        }
    }
    static let trashSymbolName = "trash"

    /// PLAN §8.12「要対応あり（上の 3 つより優先）」。
    static func compute(hasAttention: Bool, ingesting: Bool, processing: Bool) -> IconState {
        if hasAttention { return .attention }
        if ingesting { return .ingesting }
        if processing { return .processing }
        return .idle
    }
}
