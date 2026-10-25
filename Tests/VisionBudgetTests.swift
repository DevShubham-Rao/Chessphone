import XCTest
@testable import ChessPhone

final class VisionBudgetTests: XCTestCase {
    func testAllowancePermitsBoundaryButRefusesNextAttempt() throws {
        var budget = VisionBudget(limitUSD: 0.02)
        try budget.reserve(estimatedRequestCostUSD: 0.01)
        try budget.reserve(estimatedRequestCostUSD: 0.01)
        XCTAssertEqual(budget.estimatedCostUSD, 0.02, accuracy: 0.000001)
        XCTAssertEqual(budget.requestCount, 2)
        XCTAssertThrowsError(try budget.reserve(estimatedRequestCostUSD: 0.01))
        XCTAssertTrue(budget.isPaused)
        XCTAssertEqual(budget.requestCount, 2, "A rejected request must never be counted as sent.")
    }

    func testResumeAddsAnAllowanceBlockAndPreservesHistory() throws {
        var budget = VisionBudget(limitUSD: 0.01)
        try budget.reserve(estimatedRequestCostUSD: 0.01)
        XCTAssertThrowsError(try budget.reserve(estimatedRequestCostUSD: 0.01))
        budget.resume(additionalLimitUSD: 0.02)
        XCTAssertFalse(budget.isPaused)
        XCTAssertEqual(budget.authorizedCostLimitUSD, 0.03, accuracy: 0.000001)
        XCTAssertEqual(budget.estimatedCostUSD, 0.01, accuracy: 0.000001)
        try budget.reserve(estimatedRequestCostUSD: 0.01)
        XCTAssertEqual(budget.requestCount, 2)
    }

    func testSecondAttemptCannotBypassRemainingAllowance() throws {
        var budget = VisionBudget(limitUSD: 0.015)
        try budget.reserve(estimatedRequestCostUSD: 0.01)
        XCTAssertThrowsError(try budget.reserve(estimatedRequestCostUSD: 0.01))
        XCTAssertEqual(budget.estimatedCostUSD, 0.01, accuracy: 0.000001)
        XCTAssertEqual(budget.requestCount, 1)
    }

    func testSettingsDoNotEraseAnExistingGameTally() throws {
        var budget = VisionBudget(limitUSD: 1)
        try budget.reserve(estimatedRequestCostUSD: 0.01)
        budget.updateLimitBeforeFirstRequest(100)
        XCTAssertEqual(budget.authorizedCostLimitUSD, 1)
        XCTAssertEqual(budget.requestCount, 1)
        budget.reset(limitUSD: 3)
        XCTAssertEqual(budget.authorizedCostLimitUSD, 3)
        XCTAssertEqual(budget.estimatedCostUSD, 0)
        XCTAssertEqual(budget.requestCount, 0)
        XCTAssertFalse(budget.isPaused)
    }

    func testNonFiniteAndNegativeSettingsRemainBounded() {
        XCTAssertEqual(VisionBudget.validLimit(.nan), 10)
        XCTAssertEqual(VisionBudget.validLimit(.infinity), 10)
        XCTAssertEqual(VisionBudget.validLimit(-1), 0.01)
        XCTAssertEqual(VisionBudget.validEstimate(.nan), 0.01)
        XCTAssertEqual(VisionBudget.validEstimate(-1), 0.001)
        XCTAssertEqual(VisionBudget.validEstimate(100), 10)
    }
}
