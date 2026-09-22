// 長押しで確かめる赤いボタン（PLAN §8.9.8 の 2。F-65）。3 秒押し続けたときだけ 1 回完了を知らせる。
import SwiftUI
import VDCore

/// 長押しで確かめる赤いボタン。押している間はリングが満ち、`holdDuration` 秒に達したら `onConfirm` を 1 回だけ呼ぶ。
/// 途中で離すと何もしない（取り消し）。クリック 1 回では通らない。時間の計算は `Tracker`（純粋な値）に切り出してある。
struct HoldToConfirmButton: View {
    /// 押し続ける秒数（PLAN §8.9.8 の 2）
    nonisolated static let holdDuration: Double = 3.0
    /// 押している間の進捗の更新の間隔
    static let tickMilliseconds = 16

    let title: String
    let disabled: Bool
    let onConfirm: @MainActor () -> Void

    @State private var tracker = Tracker()
    @State private var fraction: Double = 0
    @State private var ticker: Task<Void, Never>?
    /// この押下は使い終えた（離すまで押し直しと見なさない。完了の後や押せなくなった後に、押したまま再び数え始めない）
    @State private var awaitingRelease = false
    /// 単調な時計（uptime の起点をビューの寿命の間は動かさない）
    @State private var clock = SystemClock()

    var body: some View {
        HStack(spacing: 8) {
            ProgressRing(fraction: fraction)
            Text(tracker.isHolding && !tracker.fired ? Strings.holdKeepPressing : title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(disabled ? Color.gray : Color.red))
        .opacity(disabled ? 0.6 : 1)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in begin() }
                .onEnded { _ in
                    awaitingRelease = false
                    end()
                }
        )
        .onChange(of: disabled) { _, now in
            if now { end() }
        }
        .onDisappear { end() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Strings.holdToEnableHint)
    }

    /// 押し始め（同じ押下の 2 回目以降の onChanged は無視する）
    private func begin() {
        guard !disabled, !awaitingRelease, !tracker.isHolding else { return }
        awaitingRelease = true
        tracker.press(at: seconds())
        ticker?.cancel()
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                if step() { return }
                try? await Task.sleep(for: .milliseconds(Self.tickMilliseconds))
            }
        }
    }

    /// 進捗を描き直し、完了した最初の 1 回だけ onConfirm を呼ぶ。完了したら true（ループを止める）
    private func step() -> Bool {
        let t = seconds()
        fraction = tracker.progress(at: t).fraction
        guard tracker.tick(at: t) else { return false }
        onConfirm()
        return true
    }

    /// 離した（または押せなくなった・画面から消えた）。途中なら何もせずに戻す
    private func end() {
        ticker?.cancel()
        ticker = nil
        tracker.release()
        withAnimation(.easeOut(duration: 0.2)) { fraction = 0 }
    }

    private func seconds() -> Double { clock.uptime() / .seconds(1) }

    /// 経過時間 → 進捗（0〜1）と完了か。
    struct Progress: Equatable {
        let fraction: Double
        let complete: Bool
    }

    /// 経過時間 → 進捗。純関数（テストが直接呼ぶ）。duration が 0 以下なら完了扱い（割り算をしない）
    nonisolated static func progress(elapsed: Double, duration: Double = holdDuration) -> Progress {
        guard duration > 0 else { return Progress(fraction: 1, complete: true) }
        let f = min(max(elapsed / duration, 0), 1)
        return Progress(fraction: f, complete: elapsed >= duration)
    }

    /// 押し始めの時刻と、完了を知らせたかを持つ値。完了の知らせは 1 回の押下につき 1 回だけ。
    struct Tracker: Equatable {
        let duration: Double
        private(set) var startedAt: Double?
        private(set) var fired = false

        init(duration: Double = HoldToConfirmButton.holdDuration) {
            self.duration = duration
        }

        var isHolding: Bool { startedAt != nil }

        /// 押し始め。押している間の 2 回目は無視する（押し始めの時刻を動かさない）
        mutating func press(at t: Double) {
            guard startedAt == nil else { return }
            startedAt = t
            fired = false
        }

        /// 離した。途中でも完了後でも最初に戻す
        mutating func release() {
            startedAt = nil
            fired = false
        }

        /// 今の進捗（押していなければ 0）
        func progress(at t: Double) -> Progress {
            guard let startedAt else { return Progress(fraction: 0, complete: false) }
            return HoldToConfirmButton.progress(elapsed: t - startedAt, duration: duration)
        }

        /// 完了に達した最初の 1 回だけ true。押していない・知らせ済み・未達なら false
        mutating func tick(at t: Double) -> Bool {
            guard isHolding, !fired, progress(at: t).complete else { return false }
            fired = true
            return true
        }
    }
}

/// 進捗のリング（押している間だけ満ちる）。
private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
    }
}
