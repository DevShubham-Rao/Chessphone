import UIKit
import CoreHaptics

/// Plays a move as vibration, following the user's editable `HapticPattern`
/// (see Vibration Settings). The pattern is a list of steps - pauses, long buzzes
/// and counted pulses - each with its own timing.
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

    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notify = UINotificationFeedbackGenerator()
    private var playback: Task<Void, Never>?

    // Core Haptics is used for buzzes with a real length (e.g. "vibrate for 0.1 s").
    private let supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var core: CHHapticEngine?
    private var activePlayer: CHHapticPatternPlayer?

    /// The sequence that gets played. Saved automatically whenever it changes.
    var pattern: HapticPattern {
        didSet { pattern.save() }
    }

    /// Called on the main actor whenever the haptic sequence changes stage.
    var onVisualStage: ((VisualStage) -> Void)?

    private init() {
        pattern = HapticPattern.load()
    }

    func tick() { impact.impactOccurred() }
    func confirm() { notify.notificationOccurred(.success) }
    func error() { notify.notificationOccurred(.error) }

    /// Plays e2 -> e4 (5,2 -> 5,4), optionally with a promotion signal.
    func testPattern(withPromotion: Bool = false) {
        playMove(fromFile: 5, fromRank: 2, toFile: 5, toRank: 4,
                 promotion: withPromotion ? 1 : 0, suffix: .none)
    }

    func playMove(fromFile: Int, fromRank: Int, toFile: Int, toRank: Int,
                  promotion: Int = 0, suffix: Suffix = .none,
                  onFinished: (@MainActor () -> Void)? = nil) {
        cancel()
        let steps = pattern.steps

        playback = Task { [weak self] in
            guard let self else { return }

            // A pause that follows a skipped step (e.g. promotion on a normal move)
            // is skipped too, so there is no dead air at the end.
            var skipNextWait = false

            for step in steps {
                if Task.isCancelled { return }

                if step.kind == .wait {
                    if skipNextWait {
                        skipNextWait = false
                    } else {
                        await self.pause(step.seconds)
                    }
                    continue
                }
                skipNextWait = false

                switch step.kind {
                case .wait:
                    break
                case .startBuzz:
                    self.emit(.fromFile(0))
                    await self.vibrate(length: step.seconds, intensity: step.intensity)
                case .switchBuzz:
                    self.emit(.switchMarker)
                    await self.vibrate(length: step.seconds, intensity: step.intensity)
                case .doneBuzz:
                    self.emit(.done)
                    await self.vibrate(length: step.seconds, intensity: step.intensity)
                case .buzz:
                    await self.vibrate(length: step.seconds, intensity: step.intensity)
                case .fromFile:
                    if fromFile > 0 { await self.counted(fromFile, step, { .fromFile($0) }) } else { skipNextWait = true }
                case .fromRank:
                    if fromRank > 0 { await self.counted(fromRank, step, { .fromRank($0) }) } else { skipNextWait = true }
                case .toFile:
                    if toFile > 0 { await self.counted(toFile, step, { .toFile($0) }) } else { skipNextWait = true }
                case .toRank:
                    if toRank > 0 { await self.counted(toRank, step, { .toRank($0) }) } else { skipNextWait = true }
                case .promotion:
                    if promotion > 0 { await self.counted(promotion, step, { _ in .idle }) } else { skipNextWait = true }
                }
            }

            if Task.isCancelled { return }

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
            if Task.isCancelled { return }
            self.emit(.idle)
            onFinished?()
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
        try? activePlayer?.stop(atTime: CHHapticTimeImmediate)
        activePlayer = nil
        emit(.idle)
    }

    // MARK: - Building blocks

    /// `n` pulses of one step. `seconds` on the step is the silence between pulses.
    private func counted(_ n: Int, _ step: PatternStep, _ stage: (Int) -> VisualStage) async {
        guard n > 0 else { return }
        for i in 1...n {
            if Task.isCancelled { return }
            let s = stage(i)
            if s != .idle { emit(s) }
            await vibrate(length: step.pulseLength, intensity: step.intensity)
            if i < n { await pause(step.seconds) }
        }
    }

    /// One vibration. Lengths under ~0.05 s are a tap; longer ones are a continuous buzz.
    /// Returns when the vibration has finished.
    private func vibrate(length: Double, intensity: Double) async {
        let level = Float(min(max(intensity, 0.1), 1.0))

        if length < 0.05 {
            impact.impactOccurred(intensity: CGFloat(level))
            return
        }

        if supportsCoreHaptics { startCoreEngineIfNeeded() }
        if let engine = core {
            do {
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: level),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                    ],
                    relativeTime: 0,
                    duration: length
                )
                let hapticPattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine.makePlayer(with: hapticPattern)
                activePlayer = player
                try player.start(atTime: CHHapticTimeImmediate)
                await pause(length)
                return
            } catch {
                // fall through to the tap-train fallback
            }
        }

        // Fallback (no Core Haptics, e.g. simulator): a fast train of taps for `length` seconds.
        var elapsed = 0.0
        while elapsed < length && !Task.isCancelled {
            heavy.impactOccurred(intensity: CGFloat(level))
            await pause(0.07)
            elapsed += 0.07
        }
    }

    private func startCoreEngineIfNeeded() {
        guard core == nil else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = false
            engine.playsHapticsOnly = true
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.core = nil }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in self?.core = nil }
            }
            try engine.start()
            core = engine
        } catch {
            core = nil
        }
    }

    private func emit(_ stage: VisualStage) {
        onVisualStage?(stage)
    }

    private func pulses(_ count: Int, generator: UIImpactFeedbackGenerator? = nil,
                        gap: Double) async {
        let gen = generator ?? impact
        guard count > 0 else { return }
        for _ in 0..<count {
            if Task.isCancelled { return }
            gen.impactOccurred()
            await pause(gap)
        }
    }

    private func pause(_ seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
