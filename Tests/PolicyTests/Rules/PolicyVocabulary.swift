// PT-06 が探す状態名とエラーコード名（docs/SPEC.md の S1・S3 から読む。T-04 で作り、T-05 で読み先を SPEC に替えた）。
import TestSupport

struct PolicyVocabulary: Sendable {
    let stateNames: [String]
    let errorCodeNames: [String]

    /// `docs/SPEC.md` の状態（Part と Session）とエラーコードから読む。
    static func load() throws -> PolicyVocabulary {
        let spec = try SpecDocument.load()
        let states = try SpecEntity.allCases.flatMap { try spec.stateNames($0) }
        let codes = try spec.errorCodes().map(\.code)
        return PolicyVocabulary(stateNames: Array(Set(states)).sorted(), errorCodeNames: codes)
    }
}
