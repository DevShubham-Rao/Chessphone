import UIKit

/// Translates a move's four coordinates into distinct pulse counts,
/// using iPhone's Taptic Engine (UIImpactFeedbackGenerator for counted
/// pulses, UINotificationFeedbackGenerator for the source/target divider).
class HapticEngine {
    static let shared = HapticEngine()
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notify = UINotificationFeedbackGenerator()

    func playMove(fromCol: Int, fromRow: Int, toCol: Int, toRow: Int) {
        Task {
            await playPulses(count: fromCol)
            try? await Task.sleep(nanoseconds: 400_000_000)

            await playPulses(count: fromRow)
            try? await Task.sleep(nanoseconds: 600_000_000)

            notify.notificationOccurred(.success)
            try? await Task.sleep(nanoseconds: 600_000_000)

            await playPulses(count: toCol)
            try? await Task.sleep(nanoseconds: 400_000_000)

            await playPulses(count: toRow)
        }
    }

    private func playPulses(count: Int) async {
        for _ in 0..<count {
            await MainActor.run { impact.impactOccurred() }
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
    }
}
