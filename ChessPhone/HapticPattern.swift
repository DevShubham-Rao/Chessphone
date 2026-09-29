import Foundation

/// One step in the vibration sequence that plays a move.
/// The whole sequence is a list of these, played top to bottom, and every value is editable in the app.
struct PatternStep: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case wait          // silence
        case startBuzz     // long buzz that marks the start
        case fromFile      // pulses = FROM column (1-8)
        case fromRank      // pulses = FROM row (1-8)
        case switchBuzz    // long buzz that marks "now the destination"
        case toFile        // pulses = TO column (1-8)
        case toRank        // pulses = TO row (1-8)
        case promotion     // pulses = promotion piece (1=Q 2=R 3=B 4=N); skipped if no promotion
        case doneBuzz      // buzz that marks the end
        case buzz          // free extra buzz, no meaning

        var title: String {
            switch self {
            case .wait: return "Pause"
            case .startBuzz: return "Start buzz"
            case .fromFile: return "FROM column pulses"
            case .fromRank: return "FROM row pulses"
            case .switchBuzz: return "Switch buzz"
            case .toFile: return "TO column pulses"
            case .toRank: return "TO row pulses"
            case .promotion: return "Promotion pulses"
            case .doneBuzz: return "Done buzz"
            case .buzz: return "Extra buzz"
            }
        }

        /// Steps that pulse a number of times taken from the move.
        var isCounted: Bool {
            switch self {
            case .fromFile, .fromRank, .toFile, .toRank, .promotion: return true
            default: return false
            }
        }

        /// Steps that make one continuous vibration.
        var isBuzz: Bool {
            switch self {
            case .startBuzz, .switchBuzz, .doneBuzz, .buzz: return true
            default: return false
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// wait: length of the pause. buzz: length of the vibration.
    /// counted: silence BETWEEN two pulses.
    var seconds: Double
    /// Counted steps only: how long each pulse vibrates. 0 = a short tap.
    var pulseLength: Double = 0
    /// 0.1 (soft) ... 1.0 (full)
    var intensity: Double = 1.0

    /// A sensible new step when the user adds one.
    static func fresh(_ kind: Kind) -> PatternStep {
        switch kind {
        case .wait: return PatternStep(kind: kind, seconds: 0.5)
        case .startBuzz, .switchBuzz, .buzz: return PatternStep(kind: kind, seconds: 0.5)
        case .doneBuzz: return PatternStep(kind: kind, seconds: 0.4)
        default: return PatternStep(kind: kind, seconds: 0.6)
        }
    }
}

struct HapticPattern: Codable, Equatable {
    var steps: [PatternStep]

    /// Slow, easy to count. This is the default.
    static var easy: HapticPattern {
        make(lead: 0.3, gap: 0.6, betweenNumbers: 0.9, betweenParts: 0.8, marker: 0.5)
    }

    /// Quicker, for when you are used to it.
    static var fast: HapticPattern {
        make(lead: 0.15, gap: 0.3, betweenNumbers: 0.45, betweenParts: 0.5, marker: 0.3)
    }

    private static func make(lead: Double, gap: Double, betweenNumbers: Double,
                             betweenParts: Double, marker: Double) -> HapticPattern {
        func wait(_ s: Double) -> PatternStep { PatternStep(kind: .wait, seconds: s) }
        func buzz(_ k: PatternStep.Kind, _ s: Double) -> PatternStep { PatternStep(kind: k, seconds: s) }
        func count(_ k: PatternStep.Kind) -> PatternStep { PatternStep(kind: k, seconds: gap) }

        return HapticPattern(steps: [
            wait(lead),
            buzz(.startBuzz, marker),
            wait(betweenParts),
            count(.fromFile),
            wait(betweenNumbers),
            count(.fromRank),
            wait(betweenParts),
            buzz(.switchBuzz, marker),
            wait(betweenParts),
            count(.toFile),
            wait(betweenNumbers),
            count(.toRank),
            wait(betweenParts),
            count(.promotion),
            wait(betweenParts),
            buzz(.doneBuzz, marker * 0.8),
            wait(0.2),
            buzz(.doneBuzz, marker * 0.8)
        ])
    }

    // MARK: - Persistence

    private static let key = "hapticPatternV1"

    static func load() -> HapticPattern {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(HapticPattern.self, from: data),
              !decoded.steps.isEmpty else { return .easy }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: HapticPattern.key)
        }
    }
}
