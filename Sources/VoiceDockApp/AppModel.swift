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
    /// 要対応の「モデルの節を開く」（節を目立たせるだけ。新しい画面を作らない。D-7）
    var modelsHighlighted = false
    /// 要対応の「有効化フローを開く」（T-40 が使う）
    var deletionHighlighted = false
    // T-40（書くのは下の extension だけ）
    /// 有効化が成功した後に出す案内（PLAN §8.9.8 の 5）
    private(set) var deletionNotice: String?
    /// 無効化で失敗した段の名前（英語のまま。ログと突き合わせるため）
    private(set) var disableFailedStages: [String] = []

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
    var showsTrash: Bool { IconState.showsTrash(deletion) }
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

    /// 「元音声の削除を有効にする」。confirmation はテキストフィールドの入力そのまま
    func enableDeletion(confirmation: String) async -> Result<Void, EnableError> {
        let r = await services.enableDeletion(confirmation: confirmation)
        if case .success = r { deletionNotice = DeletionStrings.reinsertNotice }
        await refresh()
        return r
    }

    /// 「無音・重複も消す」
    func enableSkippedDeletion(confirmation: String) async -> Result<Void, EnableError> {
        let r = await services.enableSkippedDeletion(confirmation: confirmation)
        await refresh()
        return r
    }

    /// 「削除を無効にする」（確認なし）。失敗した段の名前をパネルに出す
    func disableDeletion() async -> [String] {
        let failed = await services.disableDeletion()
        disableFailedStages = failed
        deletionNotice = nil
        await refresh()
        return failed
    }
}
