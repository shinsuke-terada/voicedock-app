// Remounter の差し替え（T-15。00-api-map §15）。本物の diskutil を動かさない。
import Foundation
import VDDevice

/// Remounter の差し替え。呼ばれた (path, node) を記録し、台本の結果を返す。onRemount で呼ばれた瞬間の動き（通知を起こす等）を差し込める
public actor FakeRemounter: Remounter {
    private let outcomes: [RemountOutcome]
    private let onRemount: (@Sendable () async -> Void)?
    private var nextIndex = 0
    public private(set) var calls: [(path: String, node: String)] = []

    /// 足りなければ最後の要素を返し続ける（空なら .alreadyReadOnly）
    public init(outcomes: [RemountOutcome], onRemount: (@Sendable () async -> Void)? = nil) {
        self.outcomes = outcomes
        self.onRemount = onRemount
    }

    /// 記録 → onRemount → 台本の結果
    public func remountReadOnly(path: String, node: String) async -> RemountOutcome {
        calls.append((path, node))
        if let onRemount { await onRemount() }
        guard let last = outcomes.last else { return .alreadyReadOnly }
        let outcome = nextIndex < outcomes.count ? outcomes[nextIndex] : last
        nextIndex += 1
        return outcome
    }
}
