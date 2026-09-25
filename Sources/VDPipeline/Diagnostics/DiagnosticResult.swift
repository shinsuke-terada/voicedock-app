// 診断の 1 件の結果（PLAN §8.11。voicedock doctor.py:45-57）。

/// 診断の 1 件の結果の 4 値（PLAN §8.11。voicedock doctor.py:45-57）。
public enum DiagnosticStatus: String, Sendable, Equatable, CaseIterable {
    case ok, notice, fail, skip

    /// voicedock doctor.py:52-57 と同じ記号
    public var mark: String {
        switch self {
        case .ok: "✓"
        case .notice: "!"
        case .fail: "✗"
        case .skip: "-"
        }
    }
}

/// 診断の 1 件の結果。
public struct DiagnosticResult: Sendable, Equatable {
    /// "DR-01" … "DR-17"（2 桁。ゼロ詰め）
    public let id: String
    public let status: DiagnosticStatus
    /// DiagnosticTexts の日本語のラベル
    public let label: String
    /// 続きの行。0 件でもよい
    public let details: [String]

    public init(id: String, status: DiagnosticStatus, label: String, details: [String] = []) {
        self.id = id
        self.status = status
        self.label = label
        self.details = details
    }
}
