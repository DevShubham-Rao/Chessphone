import Foundation

/// A conservative local allowance, not a copy of the provider's invoice. Each
/// HTTP attempt is counted, including requests whose answer never reaches us.
struct VisionBudget {
    private(set) var estimatedCostUSD: Double = 0
    private(set) var authorizedCostLimitUSD: Double
    private(set) var requestCount = 0
    private(set) var isPaused = false

    init(limitUSD: Double) {
        authorizedCostLimitUSD = Self.validLimit(limitUSD)
    }

    mutating func reserve(estimatedRequestCostUSD: Double) throws {
        let amount = Self.validEstimate(estimatedRequestCostUSD)
        guard !isPaused, estimatedCostUSD + amount <= authorizedCostLimitUSD + 0.0000001 else {
            isPaused = true
            throw VisionError.budgetReached
        }
        estimatedCostUSD += amount
        requestCount += 1
    }

    /// Explicit Resume authorizes one additional block; it never clears history.
    mutating func resume(additionalLimitUSD: Double) {
        authorizedCostLimitUSD += Self.validLimit(additionalLimitUSD)
        isPaused = false
    }

    mutating func reset(limitUSD: Double) {
        self = VisionBudget(limitUSD: limitUSD)
    }

    mutating func updateLimitBeforeFirstRequest(_ value: Double) {
        guard requestCount == 0 else { return }
        authorizedCostLimitUSD = Self.validLimit(value)
        isPaused = false
    }

    static func validLimit(_ value: Double) -> Double {
        value.isFinite ? min(1000, max(0.01, value)) : 10
    }

    static func validEstimate(_ value: Double) -> Double {
        value.isFinite ? min(10, max(0.001, value)) : 0.01
    }
}

struct VisionFrameDiagnostics {
    var timestamp = Date()
    var boardVisible: Bool?
    var handOverBoard: Bool?
    var confidence: String?
    var latencySeconds: Double?
    var precheckNote = "No frame checked yet"
    var notes: String?
}
