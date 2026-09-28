import UIKit

/// Turns moves into pulse counts using the Taptic Engine.
///
/// A move is played as:
///   [from column pulses] pause [from row pulses] pause  (success buzz)  pause
///   [to column pulses]   pause [to row pulses]
///   optionally: pause [promotion pulses: 1=Q 2=R 3=B 4=N]
///   optionally: pause [check = two warning buzzes | game over = three heavy thumps]
/// Columns are 1...8 for a...h and rows are 1...8, the same numbers you type in.
///
/// Only one playback runs at a time: starting a new one (or calling `cancel()`)
/// stops the previous one, so repeats/shakes can never pile up on top of each other.
@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    enum Suffix {
        case none
        case check
        case gameOver
    }

    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notify = UINotificationFeedbackGenerator()
    private var playback: Task<Void, Never>?

    // MARK: - Single haptics (immediate feedback for button presses)

    /// One short tick per volume-up press.
    func tick() {
        impact.impactOccurred()
    }

    /// An input step was accepted.
    func confirm() {
        notify.notificationOccurred(.success)
    }

    /// Bad input / illegal move / engine problem.
    func error() {
        notify.notificationOccurred(.error)
    }

    // MARK: - Sequences

    func playMove(fromFile: Int, fromRank: Int, toFile: Int, toRank: Int,
                  promotion: Int = 0, suffix: Suffix = .none) {
        cancel()
        playback = Task { [weak self] in
            guard let self = self else { return }
            await self.pulses(fromFile)
            await self.pause(0.45)
            await self.pulses(fromRank)
            await self.pause(0.6)
            if Task.isCancelled { return }
            self.notify.notificationOccurred(.success)
            await self.pause(0.6)
            await self.pulses(toFile)
            await self.pause(0.45)
            await self.pulses(toRank)

            if promotion > 0 {
                await self.pause(0.8)
                await self.pulses(promotion, generator: self.heavy)
            }

            switch suffix {
            case .none:
                break
            case .check:
                await self.pause(0.8)
                if Task.isCancelled { return }
                self.notify.notificationOccurred(.warning)
                await self.pause(0.35)
                if Task.isCancelled { return }
                self.notify.notificationOccurred(.warning)
            case .gameOver:
                await self.pause(0.8)
                await self.pulses(3, generator: self.heavy, gap: 0.5)
            }
        }
    }

    /// Long triple thump for "the game just ended" when no move needs replaying.
    func playGameOver() {
        cancel()
        playback = Task { [weak self] in
            guard let self = self else { return }
            await self.pulses(3, generator: self.heavy, gap: 0.5)
        }
    }

    func cancel() {
        playback?.cancel()
        playback = nil
    }

    // MARK: - Helpers

    private func pulses(_ count: Int, generator: UIImpactFeedbackGenerator? = nil, gap: Double = 0.18) async {
        let gen = generator ?? impact
        guard count > 0 else { return }
        for _ in 0..<count {
            if Task.isCancelled { return }
            gen.impactOccurred()
            await pause(gap)
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
