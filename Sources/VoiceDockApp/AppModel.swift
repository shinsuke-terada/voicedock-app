// UI が見る唯一の値（PLAN §8.12）。IngestService / Worker / ConfigStore から来る値の写しで、DB を直接触らない。
import AppKit
import Foundation
import SwiftUI
import VDContract
import VDCore
import VDDevice
import VDModels
import VDPipeline

/// Finder で項目を表示する口（テストで差し替える）。
protocol FinderOpening: Sendable { func reveal(_ url: URL) }

/// 本番の FinderOpening。
struct NSWorkspaceFinder: FinderOpening {
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

/// UI が見る唯一の値（PLAN §8.12）。導出値はすべて計算プロパティ（状態を 2 か所に持たない。CR-06）。
@MainActor
@Observable
final class AppModel {
    /// 観測の写し（refresh で入れ替える。等しければ入れ替えない）
    private(set) var snapshot: AppSnapshot
    /// 要対応があるか（refresh の中で snapshot.attention から立てる。T-32）
    private(set) var hasAttention = false
    /// パネルが開いているか（速い更新に切り替える）
    private(set) var isPanelOpen = false
    /// 「設定を読み直す」の結果（nil = まだ押していない）
    private(set) var reloadResult: ReloadResult?
    // T-31（別ファイルの拡張が書くので private(set) にできない。書くのは AppModel+Vault / +Models / +LoginItem だけ）
    /// 進行中のダウンロード・取り込み（画面にだけ在る値）
    var downloads: [ModelSlot: DownloadState] = [:]
    /// 枠ごとの世代（入手を始める・やめるたびに 1 増やす）。開始時と世代が違う結果・進捗は捨てる
    @ObservationIgnored var downloadGenerations: [ModelSlot: Int] = [:]
    /// 枠ごとの、まだ返っていない download（やめた後の入手し直しは、これが ModelManager から抜けるのを待ってから始める）
    @ObservationIgnored var downloadTasks: [ModelSlot: Task<Result<URL, ModelError>, Never>] = [:]
    /// Vault の選択の失敗（panelDidClose で消す）
    var vaultError: String?
    /// モデルの入手・選択・取り込みの失敗
    var modelError: String?
    /// 取り込んだモデルの注意（警告だけ。PLAN §8.10）
    var modelNotice: String?
    /// ログイン項目の操作の失敗（SMAppService の文言そのまま）
    var loginItemError: String?
    /// ui-state.json に書けなかった
    var uiStateSaveFailed = false
    // T-32（書くのは AppModel+Diagnostics だけ）
    /// 診断の実行と結果（画面にだけ在る値）
    var diagnostics: DiagnosticsPanelState = .idle
    /// DR-09 の実行と結果（結果は 1 件）
    var probe: DiagnosticsPanelState = .idle
    /// DR-09 の世代（押すたび・閉じるたびに 1 増やす）。開始時と世代が違う返事は捨てる
    @ObservationIgnored var probeGeneration = 0
    /// 「詳細」を開いているか（開いている間だけ状態の詳細を読む）
    var detailsExpanded = false
    /// パネルの中の今の画面（F-65。書くのは AppModel+Navigation の show と panelDidClose だけ）
    var screen: PanelScreen = .main
    /// 要対応の「モデルの節を開く」（主画面に戻してモデルのカードを目立たせる。F-65）
    var modelsHighlighted = false
    /// 要対応の「有効化フローを開く」（「元音声の削除」の画面へ移す。F-65）
    var deletionHighlighted = false
    // T-40（書くのは下の extension だけ）
    /// 有効化が成功した後に出す案内（PLAN §8.9.8 の 5）
    private(set) var deletionNotice: String?
    /// 無効化で失敗した段の名前（英語のまま。ログと突き合わせるため）
    private(set) var disableFailedStages: [String] = []
    /// 有効化・根拠 B の直近の失敗（nil = 無い。Strings.enableFailed で出す）
    private(set) var enableError: EnableError?
    /// 削除の操作の実行中（ボタンを押せなくする。二度押し対策）
    private(set) var deletionBusy = false
    // T-41（書くのは下の extension だけ）
    /// 後追いの 2 つのボタンの状態（PLAN §8.9.9。画面にだけ在る値）
    private(set) var backlogState: BacklogPanelState = .idle
    /// working が実行の返事を待っているか（preview から入ったら真。「実行しています…」を出す）
    private(set) var backlogExecuting = false

    // F-66（書くのは AppModel+SummarizeNow と panelDidClose だけ）
    /// 「今すぐ要約」の実行と結果（画面にだけ在る値）
    var summarizeNow: SummarizeNowState = .idle
    /// 今すぐ要約の世代（押すたび・閉じるたびに 1 増やす）。開始時と世代が違う返事は捨てる（DR-09 と同じ形）
    @ObservationIgnored var summarizeNowGeneration = 0
    /// この起動で最後に ui-state.json に書こうとした最終接続（F-70。失敗しても同じ値を書き直さない。
    /// 「今はしない」の記録もこの値を使い、読み直す前の古い値で戻さない）
    @ObservationIgnored var lastConnectedWritten: Instant?
    /// この起動で loginItemDecided = true を書いたか（F-70。重なった refresh の古い ui-state で「今はしない」を消さない。
    /// 書くのは AppModel+LoginItem の markLoginItemDecided だけ）
    @ObservationIgnored var loginItemDecidedWritten = false

    @ObservationIgnored let services: any AppServices
    /// ModelSlot.llm(id) の項目を引く（T-31）
    @ObservationIgnored let catalog: ModelCatalog
    @ObservationIgnored let chooser: any FolderChooser
    @ObservationIgnored let fileChooser: any FileChooser
    /// StatusItemController.runModal を差す（popover を閉じてから modal を出し、終わったら開き直す。PLAN §8.12）
    @ObservationIgnored let presentModal: @MainActor (@MainActor () -> URL?) -> URL?
    @ObservationIgnored private let openFinder: any FinderOpening
    @ObservationIgnored private let layout: HomeLayout
    @ObservationIgnored private let quitHandler: @MainActor () -> Void
    @ObservationIgnored private let sleeper: any Sleeper
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var updatesLoop: Task<Void, Never>?
    /// 周期の眠りを途中で起こす（パネルを開いたら 30 秒の眠りを待たずに 1 秒周期へ。Worker.run と同じ形）
    @ObservationIgnored private var wakeContinuation: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var iconContinuation: AsyncStream<Void>.Continuation?

    init(
        services: any AppServices, openFinder: any FinderOpening, layout: HomeLayout, catalog: ModelCatalog,
        chooser: any FolderChooser, fileChooser: any FileChooser,
        presentModal: @escaping @MainActor (@MainActor () -> URL?) -> URL?,
        sleeper: any Sleeper = TaskSleeper(), now: Instant,
        quit: @escaping @MainActor () -> Void
    ) {
        self.services = services
        self.catalog = catalog
        self.chooser = chooser
        self.fileChooser = fileChooser
        self.presentModal = presentModal
        self.openFinder = openFinder
        self.layout = layout
        self.sleeper = sleeper
        self.quitHandler = quit
        self.snapshot = AppSnapshot(now: now)
    }

    // 導出（すべて計算プロパティ。状態を 2 か所に持たない）
    var iconState: IconState {
        IconState.compute(
            hasAttention: hasAttention, ingesting: snapshot.ingestActivity.scanning,
            processing: snapshot.worker.activity != .idle)
    }
    var showsTrash: Bool { IconState.showsTrash(deletion, residual: snapshot.deletionResidual) }
    var statusLine: String { StatusLine.make(snapshot) }
    var lastConnectedLine: String { StatusLine.lastConnected(snapshot, zone: zone) }
    var deviceFreeLine: String? { StatusLine.deviceFree(snapshot) }
    var backlogLine: String { StatusLine.backlog(snapshot) }
    var versionLine: String { Strings.versionLine(snapshot.version) }
    var zone: ZonedTime { ZonedTime(timeZone: TimeZone(identifier: snapshot.timeZone) ?? .current) }
    /// アイコンの張り替えの通知（StatusItemController が待つ）。受け手は 1 つ（取り直すと前のストリームは終わる）
    var iconChanges: AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        iconContinuation?.finish()
        iconContinuation = continuation
        return stream
    }

    // 操作

    /// 購読と最初の refresh を始める。アイドル時の CPU を 0 に近く保つ（PLAN §8.15）:
    /// 閉じている間は 30 秒周期＋走査の通知だけ、開いている間だけ 1 秒周期。
    /// 周期の眠りは wake と競わせる（眠りの途中でパネルを開いたら、すぐ読み直して 1 秒周期に切り替える）。
    func start() {
        guard loop == nil else { return }
        let sleeper = self.sleeper
        let (wake, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wakeContinuation = continuation
        loop = Task { @MainActor [weak self] in
            await self?.refresh()
            guard let updates = await self?.services.updates() else { return }
            // stop() が先に来ていたら購読を作らない（stop の後に updatesLoop を代入しない）
            guard !Task.isCancelled, self != nil else { return }
            // 走査の終わりで 1 回
            self?.updatesLoop = Task { @MainActor [weak self] in
                for await _ in updates { await self?.refresh() }
            }
            var waiting = wake.makeAsyncIterator()
            while !Task.isCancelled {
                guard let open = self?.isPanelOpen else { break }
                let seconds = open ? Self.fastIntervalSeconds : Self.slowIntervalSeconds
                let timer = Task {
                    do { try await sleeper.sleep(seconds: seconds) } catch { return }
                    continuation.yield(())
                }
                let woke = await waiting.next() != nil
                timer.cancel()
                if !woke || Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        updatesLoop?.cancel()
        updatesLoop = nil
        wakeContinuation?.finish()
        wakeContinuation = nil
        iconContinuation?.finish()
    }

    func refresh() async {
        var next = await services.read(lastConnectedAt: snapshot.lastConnectedAt)
        // 状態の詳細は「詳細」を開いたときだけ作る（read は作らない。開いている間は持ち越す。T-32）
        next.statusReport = detailsExpanded ? snapshot.statusReport : nil
        let before = (iconState, showsTrash)
        if next != snapshot { snapshot = next }
        let attention = !snapshot.attention.isEmpty
        if attention != hasAttention { hasAttention = attention }
        if (iconState, showsTrash) != before { iconContinuation?.yield(()) }
        // 挿し直しの案内は、読み書きできるデバイスを観測したら消す（PLAN §8.9.8 の 5）
        if deletionNotice != nil, Self.observesWritableDevice(snapshot.device) { deletionNotice = nil }
        persistLastConnected()
    }

    /// 最終接続を ui-state.json に残す（F-70。再起動で「まだありません」に戻さない）。
    /// この起動で最後に書こうとした値（無ければファイルの値）と違うときだけ書く。
    /// 接続中は観測時刻が 60 秒以上動いたら、切れたら最後の値を 1 回だけ書く（LastConnected.valueToSave）。
    /// 書けなくても表示は変えない（「今はしない」の uiStateSaveFailed とは別。次の値で書き直す）。
    private func persistLastConnected() {
        let written = lastConnectedWritten ?? snapshot.uiState.lastConnectedAt
        let connected = snapshot.device?.devices.isEmpty == false
        guard
            let at = LastConnected.valueToSave(
                current: snapshot.lastConnectedAt, connected: connected, written: written)
        else { return }
        lastConnectedWritten = at
        var state = snapshot.uiState
        state.lastConnectedAt = at
        // refresh が重なり、この read が「今はしない」を書く前のファイルを読んでいても、それを消さない
        state.loginItemDecided = state.loginItemDecided || loginItemDecidedWritten
        // 次の read までの間に「今はしない」を書いても、書いた最終接続を古い値で上書きしない
        if services.saveUIState(state) { snapshot.uiState = state }
    }

    /// 状態の詳細を差し込む（AppModel+Diagnostics が使う。snapshot を書くのはこのファイルだけ）
    func setStatusReport(_ report: StatusReport?) {
        var next = snapshot
        next.statusReport = report
        if next != snapshot { snapshot = next }
    }

    func panelDidOpen() {
        isPanelOpen = true
        // 開いた瞬間に最新にする。ループが回っていれば眠りを起こす（読み直して 1 秒周期へ）。回っていなければ 1 回だけ読む
        if let wake = wakeContinuation {
            wake.yield(())
        } else {
            Task { await refresh() }
        }
    }

    func panelDidClose() {
        isPanelOpen = false
        // 次に開いたときに古い結果を出さない
        reloadResult = nil
        vaultError = nil
        modelNotice = nil
        // 閉じた後に届いた DR-09 の返事は捨てる（receiveProbe が .running のときだけ受け取る）
        probe = .idle
        probeGeneration += 1
        // 今すぐ要約も同じ（閉じた後に届いた返事は捨て、次に開いたときに古い通知を出さない。F-66）
        summarizeNow = .idle
        summarizeNowGeneration += 1
        // 次に開いたときは主画面から（F-65）。「詳細・診断」を出たので状態の詳細も捨てる
        screen = .main
        if detailsExpanded {
            detailsExpanded = false
            setStatusReport(nil)
        }
    }

    func requeueManual() async {
        await services.requeueManual()
        await refresh()
    }

    func reloadConfig() async {
        switch await services.reloadConfig() {
        case .valid: reloadResult = .ok
        case .invalid(let v): reloadResult = .invalid(v)
        }
        await refresh()
    }

    func revealConfigInFinder() { openFinder.reveal(layout.configFile) }

    func revealLogsInFinder() { openFinder.reveal(layout.appLog) }

    func quit() { quitHandler() }

    /// テスト用（@testable）。アイコンの優先順位を試す口（次の refresh で snapshot.attention から立て直す）。
    func setAttentionForTesting(_ value: Bool) { hasAttention = value }

    /// 診断・DR-09 の表示の状態
    enum DiagnosticsPanelState: Equatable {
        case idle, running
        case done([DiagnosticResult])
    }

    enum ReloadResult: Equatable {
        case ok
        case invalid([ConfigViolation])
    }

    /// パネルが開いている間
    static let fastIntervalSeconds = 1
    /// 閉じている間（Worker の周期と同じ。PLAN §8.15「常時ポーリングしない」）
    static let slowIntervalSeconds = 30
}

// T-40: 「元音声の削除」への口（PLAN §8.9.8）
extension AppModel {
    /// パネルとメニューバーが読む値。tick / 走査 / 操作のたびに作り直す（設定エラー中は nil）
    var deletion: DeletionPanelState? { snapshot.deletion }

    /// 「無効にする」を出すか: 消える可能性がある間（trash と同じ）と、前回の無効化に失敗した段がある間
    var showsDisableButton: Bool { showsTrash || !disableFailedStages.isEmpty }

    /// 「元音声の削除を有効にする」。赤いボタンの 3 秒の長押しが完了したときだけ呼ぶ（HoldToConfirmButton。F-65）。
    /// 確認語は定数 `DeletionStrings.confirmationWord` を渡し、完全一致の判定は DeletionEnabler が行う（安全の二重化）
    func enableDeletion() async -> Result<Void, EnableError> {
        deletionBusy = true
        defer { deletionBusy = false }
        let r = await services.enableDeletion(confirmation: DeletionStrings.confirmationWord)
        switch r {
        case .success:
            enableError = nil
            disableFailedStages = []
            deletionNotice = DeletionStrings.reinsertNotice
        case .failure(let e):
            enableError = e
        }
        await refresh()
        return r
    }

    /// 「無音・重複も消す」。有効化と同じく長押しの完了で呼び、定数の確認語を渡す（F-65）
    func enableSkippedDeletion() async -> Result<Void, EnableError> {
        deletionBusy = true
        defer { deletionBusy = false }
        let r = await services.enableSkippedDeletion(confirmation: DeletionStrings.confirmationWord)
        switch r {
        case .success: enableError = nil
        case .failure(let e): enableError = e
        }
        await refresh()
        return r
    }

    /// 「削除を無効にする」（確認なし）。失敗した段の名前をパネルに出す
    func disableDeletion() async -> [String] {
        deletionBusy = true
        defer { deletionBusy = false }
        let failed = await services.disableDeletion()
        disableFailedStages = failed
        deletionNotice = nil
        enableError = nil
        await refresh()
        return failed
    }

    /// snapshot に読み書きできる（観測）デバイスが 1 台以上あるか
    static func observesWritableDevice(_ snapshot: DeviceSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.devices.keys.contains {
            DeviceWritability.observe(deviceID: $0, snapshot: snapshot) == .writable
        }
    }
}

/// 後追いの 2 つのボタンの状態（PLAN §8.9.9）。
enum BacklogPanelState: Equatable {
    case idle
    /// 計画・実行の返事を待っている
    case working(BacklogKind)
    case preview(BacklogKind, BacklogPlan)
    case done(BacklogKind, BacklogExecution)
    case failed(BacklogKind, String)
}

// T-41: 後追い（PLAN §8.9.9）。仕事は Worker の直列ループに 1 件として入れる
extension AppModel {
    /// 1 回目の押下。working にして preview の仕事を入れる（working 中は何もしない）
    func previewBacklog(_ kind: BacklogKind) {
        if case .working = backlogState { return }
        backlogExecuting = false
        backlogState = .working(kind)
        // reply は Worker の文脈で呼ばれるので MainActor へ移してから状態を変える
        let action = BacklogAction.preview(reply: { [weak self] result in
            Task { @MainActor in self?.receive(kind, result) }
        })
        enqueueBacklog(kind, action)
    }

    /// 2 回目の押下（preview の状態からだけ）。working にして execute の仕事を入れる
    func executeBacklog(_ kind: BacklogKind) {
        guard case .preview(let current, _) = backlogState, current == kind else { return }
        backlogExecuting = true
        backlogState = .working(kind)
        let action = BacklogAction.execute(reply: { [weak self] result in
            Task { @MainActor in self?.receive(kind, result) }
        })
        enqueueBacklog(kind, action)
    }

    /// やめる・閉じる。idle に戻す（返事が来る前なら、届いた返事は捨てる）
    func dismissBacklog() {
        backlogState = .idle
        backlogExecuting = false
    }

    /// preview の返事（backlogState が .working(kind) のときだけ受け取る）
    func receive(_ kind: BacklogKind, _ result: Result<BacklogPlan, BacklogFailure>) {
        guard backlogState == .working(kind) else { return }
        switch result {
        case .success(let plan): backlogState = .preview(kind, plan)
        case .failure(let f): backlogState = .failed(kind, f.message)
        }
    }

    /// execute の返事（backlogState が .working(kind) のときだけ受け取る）
    func receive(_ kind: BacklogKind, _ result: Result<BacklogExecution, BacklogFailure>) {
        guard backlogState == .working(kind) else { return }
        switch result {
        case .success(let execution): backlogState = .done(kind, execution)
        case .failure(let f): backlogState = .failed(kind, f.message)
        }
    }

    private func enqueueBacklog(_ kind: BacklogKind, _ action: BacklogAction) {
        let services = self.services
        let job: WorkerJob = kind == .backlog ? .backlog(action) : .resolveAbsent(action)
        Task { await services.enqueue(job) }
    }
}
