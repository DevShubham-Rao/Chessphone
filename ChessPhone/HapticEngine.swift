import UIKit

/// Converts chess coordinates into a deliberately slow, easy-to-count haptic language.
///
/// EASY mode:
///   - A strong "start" buzz
///   - FROM file: 1...8 medium pulses
///   - long separator
///   - FROM rank: 1...8 medium pulses
///   - two strong marker buzzes
///   - TO file: 1...8 medium pulses
///   - long separator
///   - TO rank: 1...8 medium pulses
///
/// The extra separators/markers make it much harder to lose your place.
@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    enum Suffix {
        case none
        case check
        case gameOver
    }

    enum Clarity: String, CaseIterable, Identifiable {
        case easy = "Easy"
        case fast = "Fast"

        var id: String { rawValue }

        var pulseGap: Double {
            switch self {
            case .easy: return 0.30
            case .fast: return 0.14
            }
        }

        var coordinatePause: Double {
            switch self {
            case .easy: return 0.85
            case .fast: return 0.42
            }
        }

        var movePause: Double {
            switch self {
            case .easy: return 1.05
            case .fast: return 0.55
            }
        }
    }

    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notify = UINotificationFeedbackGenerator()
    private var playback: Task<Void, Never>?

    private let clarityKey = "hapticClarity"
    private let customGapKey = "hapticCustomGap"

    /// Time between counted pulses, in seconds. This is user-adjustable and persisted.
    var customPulseGap: Double {
        get {
            let value = UserDefaults.standard.double(forKey: customGapKey)
            return value > 0 ? min(max(value, 0.10), 5.00) : 0.80
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0.10), 5.00), forKey: customGapKey)
        }
    }

    var clarity: Clarity {
        get {
            Clarity(rawValue: UserDefaults.standard.string(forKey: clarityKey) ?? "") ?? .easy
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: clarityKey)
        }
    }

    func setClarity(_ value: Clarity) {
        clarity = value
    }

    // MARK: - Immediate feedback

    func tick() {
        impact.impactOccurred()
    }

    func confirm() {
        notify.notificationOccurred(.success)
    }

    func error() {
        notify.notificationOccurred(.error)
    }

    /// A short, very distinct preview of the selected haptic mode.
    func testPattern() {
        cancel()
        playback = Task { [weak self] in
            guard let self = self else { return }
            self.heavy.impactOccurred()
            await self.pause(self.clarity.coordinatePause)
            await self.pulses(3)
            await self.pause(self.clarity.coordinatePause)
            self.heavy.impactOccurred()
        }
    }

    // MARK: - Chess move output

    func playMove(fromFile: Int, fromRank: Int, toFile: Int, toRank: Int,
                  promotion: Int = 0, suffix: Suffix = .none) {
        cancel()
        let clarity = self.clarity
        let pulseGap = self.customPulseGap

        playback = Task { [weak self] in
            guard let self = self else { return }

            // Start marker: one heavy buzz means "new move".
            self.heavy.impactOccurred()
            await self.pause(clarity.movePause)

            // FROM coordinate
            await self.coordinate(fromFile, clarity: clarity, pulseGap: pulseGap)
            await self.pause(max(clarity.coordinatePause, pulseGap * 1.5))
            await self.coordinate(fromRank, clarity: clarity, pulseGap: pulseGap)

            // Two heavy buzzes = FROM is complete.
            await self.pause(clarity.movePause)
            self.heavy.impactOccurred()
            await self.pause(0.22)
            self.heavy.impactOccurred()

            await self.pause(clarity.movePause)

            // TO coordinate
            await self.coordinate(toFile, clarity: clarity, pulseGap: pulseGap)
            await self.pause(max(clarity.coordinatePause, pulseGap * 1.5))
            await self.coordinate(toRank, clarity: clarity, pulseGap: pulseGap)

            if promotion > 0 {
                await self.pause(clarity.movePause)
                await self.pulses(promotion, generator: self.heavy, gap: clarity.pulseGap)
            }

            switch suffix {
            case .none:
                break
            case .check:
                await self.pause(clarity.movePause)
                self.notify.notificationOccurred(.warning)
                await self.pause(0.4)
                self.notify.notificationOccurred(.warning)
            case .gameOver:
                await self.pause(clarity.movePause)
                await self.pulses(3, generator: self.heavy, gap: 0.5)
            }
        }
    }

    private func coordinate(_ count: Int, clarity: Clarity, pulseGap: Double) async {
        // A heavy marker before every coordinate tells the user where counting starts.
        if Task.isCancelled { return }
        heavy.impactOccurred()
        await pause(min(max(pulseGap * 0.45, 0.20), 1.25))
        await pulses(count, gap: pulseGap)
    }

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

    private func pulses(_ count: Int, generator: UIImpactFeedbackGenerator? = nil,
                        gap: Double? = nil) async {
        let gen = generator ?? impact
        let actualGap = gap ?? clarity.pulseGap
        guard count > 0 else { return }

        for _ in 0..<count {
            if Task.isCancelled { return }
            gen.impactOccurred()
            await pause(actualGap)
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
