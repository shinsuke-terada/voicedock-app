// ProcessRunning の差し替え（T-13。00-api-map §15）。本物のプロセスを起動しない。
import Darwin
import Foundation
import VDProcess

/// ProcessRunning の差し替え。受け取った ProcessSpec を記録し、台本の結果を順に返す。
public actor ScriptedProcessRunner: ProcessRunning {
    private let results: [ProcessResult]
    private var nextIndex = 0
    public private(set) var recorded: [ProcessSpec] = []
    public private(set) var recordedTimeouts: [Duration] = []

    /// 足りなくなったら最後の要素を返し続ける。空なら .exited(0)
    public init(results: [ProcessResult]) {
        self.results = results
    }

    public func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult {
        recorded.append(spec)
        recordedTimeouts.append(timeout)
        guard let last = results.last else { return Self.exited(0) }
        let result = nextIndex < results.count ? results[nextIndex] : last
        nextIndex += 1
        return result
    }

    /// 記録してから SpawnError.spawnFailed(errno: ENOSYS) を投げる
    public func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess {
        recorded.append(spec)
        throw SpawnError.spawnFailed(errno: ENOSYS)
    }

    /// stdout / stderr は空
    public static func exited(_ code: Int32) -> ProcessResult {
        ProcessResult(termination: .exited(code), stdoutTail: Data(), stderrTail: Data())
    }
}
