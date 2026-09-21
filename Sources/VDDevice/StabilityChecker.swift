// 安定性判定（PLAN §8.1。voicedock-ingest:354-431 の check_stability と同じ結果）。待ちはファイル数に比例しない（DEV-14）。
import Foundation
import VDCore

public struct StabilityChecker: Sendable {
    let config: DeviceConfig
    let clock: any AppClock
    let sleeper: any Sleeper

    public init(config: DeviceConfig, clock: any AppClock, sleeper: any Sleeper) {
        self.config = config
        self.clock = clock
        self.sleeper = sleeper
    }

    /// candidates のうち安定と判定したものを、最後に観測した FileStat と一緒に返す
    public func stableCandidates(
        _ candidates: [String], stat: @escaping @Sendable (String) -> FileStat?
    ) async -> [String: FileStat] {
        if candidates.isEmpty { return [:] }  // 待たない
        let checks = config.stabilityChecks
        var samples = await sample(candidates, stat: stat)
        let nowSeconds = Double(clock.now().epochMillis) / 1000
        var ok: [String: Int] = [:]
        for r in candidates {
            // fast path（等号を含む）
            if let s = samples[r] ?? nil, s.mtime <= nowSeconds - Double(config.stabilityFastPathSeconds) {
                ok[r] = checks
            } else {
                ok[r] = 0
            }
        }
        if ok.values.allSatisfy({ $0 == checks }) {
            return Self.observed(candidates, samples) { _ in true }
        }
        for _ in 0..<checks {
            let saved = samples
            do {
                try await sleeper.sleep(seconds: config.stabilityIntervalSeconds)
            } catch {
                return [:]  // 止められたらこの回は見送り
            }
            samples = await sample(candidates, stat: stat)  // 毎回 全候補を取り直す（voicedock と同じ）
            for r in candidates where (ok[r] ?? 0) < checks {
                if let cur = samples[r] ?? nil, let prev = saved[r] ?? nil, cur == prev {
                    ok[r] = (ok[r] ?? 0) + 1
                } else {
                    ok[r] = 0
                }
            }
        }
        return Self.observed(candidates, samples) { (ok[$0] ?? 0) >= checks }
    }

    /// 全候補の FileStat を BlockingIO.run で一括取得する（取れないものは nil）
    private func sample(
        _ candidates: [String], stat: @escaping @Sendable (String) -> FileStat?
    ) async -> [String: FileStat?] {
        await (try? BlockingIO.run { Dictionary(uniqueKeysWithValues: candidates.map { ($0, stat($0)) }) }) ?? [:]
    }

    /// accepted を満たし、最新の観測が nil でないものを最後に観測した値と一緒に返す
    private static func observed(
        _ candidates: [String], _ samples: [String: FileStat?], accepted: (String) -> Bool
    ) -> [String: FileStat] {
        var result: [String: FileStat] = [:]
        for r in candidates where accepted(r) {
            if let s = samples[r] ?? nil { result[r] = s }
        }
        return result
    }
}
