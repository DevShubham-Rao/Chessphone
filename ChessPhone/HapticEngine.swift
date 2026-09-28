import UIKit

/// Output pattern, designed to be countable by feel:
/// - "vir vir vir": one distinct pulse per count, with a real gap
///   between each pulse so they don't blur together.
/// - short "virrrrr" (rapid burst): marks switching from column to
///   row within the same square.
/// - long "VIRRRRR" (longer rapid burst + a closing tick): marks
///   switching from the source square to the target square.
class HapticEngine {
    static let shared = HapticEngine()
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let notify = UINotificationFeedbackGenerator()

    private let pulseGap: UInt64 = 450_000_000        // gap between counted pulses ("vir" ... "vir")
    private let burstPulseGap: UInt64 = 90_000_000     // gap inside a buzz burst
    private let afterSignalPause: UInt64 = 500_000_000 // breathing room after each phase

    func playMove(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int) {
        Task {
            await playPulses(count: fromCol)
            await playColRowBuzz()

            await playPulses(count: fromRow)
            await playSquareDividerBuzz()

            await playPulses(count: toCol)
            await playColRowBuzz()

            await playPulses(count: toRow)
        }
    }

    /// Single lightweight pulse for raw button-tap confirmation while
    /// counting input - separate from the move-relay pattern above.
    func tapTick() {
        lightImpact.impactOccurred()
    }

    private func playPulses(count: Int) async {
        for _ in 0..<count {
            await MainActor.run { impact.impactOccurred() }
            try? await Task.sleep(nanoseconds: pulseGap)
        }
        try? await Task.sleep(nanoseconds: afterSignalPause)
    }

    /// Short rapid burst ("virrrrr") - column -> row within a square.
    private func playColRowBuzz() async {
        for _ in 0..<5 {
            await MainActor.run { heavyImpact.impactOccurred() }
            try? await Task.sleep(nanoseconds: burstPulseGap)
        }
        try? await Task.sleep(nanoseconds: afterSignalPause)
    }

    /// Longer rapid burst + closing tick ("VIRRRRR") - source square ->
    /// target square. Noticeably longer than the column/row buzz above.
    private func playSquareDividerBuzz() async {
        for _ in 0..<10 {
            await MainActor.run { heavyImpact.impactOccurred() }
            try? await Task.sleep(nanoseconds: burstPulseGap)
        }
        await notify.notificationOccurred(.success)
        try? await Task.sleep(nanoseconds: afterSignalPause + 100_000_000)
    }
}
