// 「はじめに」の 5 項目（PLAN §8.12 の 3）。純関数。未完了が 1 つでもあれば節を出す。
import VDDevice

/// 「はじめに」の項目（PLAN §8.12 の 3 の ①〜⑤ の順）。
enum OnboardingStep: String, CaseIterable, Sendable, Equatable {
    case vault, whisperModel, llmModel, loginItem, deviceName
}

/// 「はじめに」の 1 行。
struct OnboardingItem: Equatable, Sendable, Identifiable {
    let step: OnboardingStep
    let title: String
    let detail: String?
    let done: Bool
    /// 偽ならこの項目は出さない（deviceName は改名が要るデバイスが在るときだけ）
    let visible: Bool
    var id: OnboardingStep { step }
}

/// 「はじめに」の判定（純関数）。
enum OnboardingEvaluator {
    /// PLAN §8.12 の 3 の ①〜⑤ の順。
    static func items(_ s: AppSnapshot) -> [OnboardingItem] {
        [
            OnboardingItem(
                step: .vault, title: Strings.onboardingVault, detail: nil, done: s.vault == .available, visible: true),
            OnboardingItem(
                step: .whisperModel, title: Strings.onboardingWhisper, detail: nil,
                done: s.whisperPresent && (!s.vadEnabled || s.vadPresent), visible: true),
            OnboardingItem(
                step: .llmModel, title: Strings.onboardingLLM, detail: nil,
                done: s.llmModelID != nil && s.llmPresent, visible: true),
            OnboardingItem(
                step: .loginItem, title: Strings.onboardingLoginItem, detail: nil,
                done: s.loginItem == .enabled || s.uiState.loginItemDecided, visible: true),
            // ⑤ は完了にできない（アプリは改名を検知するしかない。DEV-10）
            OnboardingItem(
                step: .deviceName, title: Strings.onboardingDeviceName,
                detail: Strings.renameInstructions(s.renameCandidates), done: false,
                visible: !s.renameCandidates.isEmpty),
        ]
    }

    /// items に未完了かつ visible が 1 つも無いこと
    static var isComplete: (AppSnapshot) -> Bool {
        { s in !items(s).contains { $0.visible && !$0.done } }
    }

    /// 改名の案内が要る名前（バイト順・重複なし）。次の 2 つを合わせる。
    /// - unavailable の not_included: 名前が include（既定は ["VOICEDOCK"]）に合わないが、録音のフォルダがあるボリューム
    ///   （出荷時名 `NO NAME` の新品・名前を変えた機器・古いマウント点が残って `VOICEDOCK 1` にマウントされた実機・写しを入れたメモリ。
    ///   取り込まず削除もしない。F-81。PLAN §8.1 の規則 1）
    /// - devices と unavailable の鍵のうち `NO NAME`（include が空の設定で検出された出荷時名。DEV-10。
    ///   unavailable も見るのは、invalid_device_id や mount_name_mismatch で devices に載らない場合があるため。規則 8・9）
    static func renameCandidates(_ snapshot: DeviceSnapshot?) -> [String] {
        guard let snapshot else { return [] }
        let notIncluded = snapshot.unavailable.filter { $0.value == DetectionReason.notIncluded.rawValue }.keys
        let factoryNamed = Set(snapshot.devices.keys).union(snapshot.unavailable.keys).filter { $0 == renameName }
        return Set(notIncluded).union(factoryNamed)
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// DJI Mic 3 の工場出荷時の名前（PLAN §8.12 の 3-⑤）
    static let renameName = "NO NAME"
}
