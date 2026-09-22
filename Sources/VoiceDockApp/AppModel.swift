// UI が見る唯一の値（PLAN §8.12）。IngestService / Worker / ConfigStore から来る値の写しで、DB を直接触らない。
import AppKit
import Foundation
import SwiftUI
import VDContract
import VDCore
import VDDevice
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
    /// 要対応があるか（T-32 が refresh の中で立てる。T-30 では常に false）
    private(set) var hasAttention = false
    /// パネルが開いているか（速い更新に切り替える）
    private(set) var isPanelOpen = false
    /// 「設定を読み直す」の結果（nil = まだ押していない）
    private(set) var reloadResult: ReloadResult?

    @ObservationIgnored private let services: any AppServices
    @ObservationIgnored private let openFinder: any FinderOpening
    @ObservationIgnored private let layout: HomeLayout
    @ObservationIgnored private let quitHandler: @MainActor () -> Void
    @ObservationIgnored private let sleeper: any Sleeper
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var updatesLoop: Task<Void, Never>?
    @ObservationIgnored private var iconContinuation: AsyncStream<Void>.Continuation?

    init(
        services: any AppServices, openFinder: any FinderOpening, layout: HomeLayout,
        sleeper: any Sleeper = TaskSleeper(), now: Instant,
        quit: @escaping @MainActor () -> Void
    ) {
        self.services = services
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
    var showsTrash: Bool { snapshot.deletionEnabled }
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
    func start() {
        guard loop == nil else { return }
        let sleeper = self.sleeper
        loop = Task { @MainActor [weak self] in
            await self?.refresh()
            let updates = await self?.services.updates()
            if let updates {
                // 走査の終わりで 1 回
                self?.updatesLoop = Task { @MainActor [weak self] in
                    for await _ in updates { await self?.refresh() }
                }
            }
            while !Task.isCancelled {
                try? await sleeper.sleep(
                    seconds: self?.isPanelOpen == true ? Self.fastIntervalSeconds : Self.slowIntervalSeconds)
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        updatesLoop?.cancel()
        updatesLoop = nil
        iconContinuation?.finish()
    }

    func refresh() async {
        let next = await services.read(lastConnectedAt: snapshot.lastConnectedAt)
        let before = (iconState, showsTrash)
        if next != snapshot { snapshot = next }
        // T-32 がここに hasAttention = !attention.isEmpty を足す
        if (iconState, showsTrash) != before { iconContinuation?.yield(()) }
    }

    func panelDidOpen() {
        isPanelOpen = true
        // 開いた瞬間に最新にする
        Task { await refresh() }
    }

    func panelDidClose() {
        isPanelOpen = false
        // 次に開いたときに古い結果を出さない
        reloadResult = nil
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

    /// テスト用（@testable）。T-32 が要対応から立てるまで、アイコンの優先順位を試す口。
    func setAttentionForTesting(_ value: Bool) { hasAttention = value }

    enum ReloadResult: Equatable {
        case ok
        case invalid([ConfigViolation])
    }

    /// パネルが開いている間
    static let fastIntervalSeconds = 1
    /// 閉じている間（Worker の周期と同じ。PLAN §8.15「常時ポーリングしない」）
    static let slowIntervalSeconds = 30
}
