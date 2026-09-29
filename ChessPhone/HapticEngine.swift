import UIKit

/// Clear, countable chess haptics.
/// Move format:
/// LONG START -> count FROM file -> pause -> count FROM rank
/// -> LONG SWITCH -> count TO file -> pause -> count TO rank -> LONG LONG DONE.
///
/// Every counted pulse also reports visual progress so the board can mirror
/// exactly what the haptics are doing.
@MainActor
final class HapticEngine {
    static let shared = HapticEngine()

    enum Suffix {
        case none
        case check
        case gameOver
    }

    enum VisualStage: Equatable {
        case idle
        case fromFile(Int)   // 1...8
        case fromRank(Int)   // 1...8
        case switchMarker
        case toFile(Int)     // 1...8
        case toRank(Int)     // 1...8
        case done
    }

    enum Clarity: String, CaseIterable, Identifiable {
        case easy = "Easy"
        case fast = "Fast"
        var id: String { rawValue }

        var coordinatePause: Double {
            switch self {
            case .easy: return 0.90
            case .fast: return 0.42
            }
        }

        var markerPause: Double {
            switch self {
            case .easy: return 1.10
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

    /// Seconds between counted pulses. Persisted and adjustable from 0.10 to 5.00.
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
        get { Clarity(rawValue: UserDefaults.standard.string(forKey: clarityKey) ?? "") ?? .easy }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: clarityKey) }
    }

    /// Called on the main actor whenever the haptic sequence changes stage.
    var onVisualStage: ((VisualStage) -> Void)?

    func setClarity(_ value: Clarity) { clarity = value }

    func tick() { impact.impactOccurred() }
    func confirm() { notify.notificationOccurred(.success) }
    func error() { notify.notificationOccurred(.error) }

    func testPattern() {
        cancel()
        playback = Task { [weak self] in
            guard let self else { return }
            self.emit(.fromFile(1))
            self.heavy.impactOccurred()
            await self.pause(self.clarity.markerPause)
            self.emit(.fromFile(2))
            self.impact.impactOccurred()
            await self.pause(self.customPulseGap)
            self.emit(.fromFile(3))
            self.impact.impactOccurred()
            await self.pause(self.clarity.coordinatePause)
            self.emit(.switchMarker)
            self.heavy.impactOccurred()
            await self.pause(self.clarity.markerPause)
            self.emit(.toFile(1))
            self.impact.impactOccurred()
            await self.pause(self.customPulseGap)
            self.emit(.toFile(2))
            self.impact.impactOccurred()
            await self.pause(self.clarity.coordinatePause)
            self.emit(.done)
            self.heavy.impactOccurred()
            await self.pause(0.18)
            self.heavy.impactOccurred()
            await self.pause(self.clarity.markerPause)
            self.emit(.idle)
        }
    }

    func playMove(fromFile: Int, fromRank: Int, toFile: Int, toRank: Int,
                  promotion: Int = 0, suffix: Suffix = .none) {
        cancel()
        let clarity = self.clarity
        let gap = self.customPulseGap

        playback = Task { [weak self] in
            guard let self else { return }

            // 1. LONG = START
            self.emit(.fromFile(0))
            self.heavy.impactOccurred()
            await self.pause(clarity.markerPause)

            // 2. Short/count pulses for FROM file.
            await self.coordinate(count: fromFile, stage: { .fromFile($0) }, gap: gap)
            await self.pause(clarity.coordinatePause)

            // Short/count pulses for FROM rank.
            await self.coordinate(count: fromRank, stage: { .fromRank($0) }, gap: gap)
            await self.pause(clarity.markerPause)

            // 3. LONG = SWITCH
            self.emit(.switchMarker)
            self.heavy.impactOccurred()
            await self.pause(clarity.markerPause)

            // Destination file.
            await self.coordinate(count: toFile, stage: { .toFile($0) }, gap: gap)
            await self.pause(clarity.coordinatePause)

            // Destination rank.
            await self.coordinate(count: toRank, stage: { .toRank($0) }, gap: gap)

            if promotion > 0 {
                await self.pause(clarity.markerPause)
                await self.pulses(promotion, generator: self.heavy, gap: gap)
            }

            await self.pause(clarity.markerPause)

            // 5. TWO LONG = DONE
            self.emit(.done)
            self.heavy.impactOccurred()
            await self.pause(0.22)
            self.heavy.impactOccurred()

            switch suffix {
            case .none: break
            case .check:
                await self.pause(0.45)
                self.notify.notificationOccurred(.warning)
                await self.pause(0.35)
                self.notify.notificationOccurred(.warning)
            case .gameOver:
                await self.pause(0.45)
                await self.pulses(3, generator: self.heavy, gap: 0.5)
            }

            await self.pause(0.35)
            self.emit(.idle)
        }
    }

    private func coordinate(count: Int, stage: (Int) -> VisualStage, gap: Double) async {
        guard count > 0 else { return }
        for number in 1...count {
            if Task.isCancelled { return }
            emit(stage(number))
            impact.impactOccurred()
            await pause(gap)
        }
    }

    func playGameOver() {
        cancel()
        playback = Task { [weak self] in
            guard let self else { return }
            await self.pulses(3, generator: self.heavy, gap: 0.5)
        }
    }

    func cancel() {
        playback?.cancel()
        playback = nil
        emit(.idle)
    }

    private func emit(_ stage: VisualStage) {
        onVisualStage?(stage)
    }

    private func pulses(_ count: Int, generator: UIImpactFeedbackGenerator? = nil,
                        gap: Double? = nil) async {
        let gen = generator ?? impact
        let actualGap = gap ?? customPulseGap
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
