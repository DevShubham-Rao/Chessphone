import XCTest
import ChessKitEngine
@testable import ChessPhone

final class EngineEvaluationTests: XCTestCase {
    func testSDKResponseKeepsScoreDepthAndVariation() throws {
        let response = try XCTUnwrap(EngineResponse(rawValue: "info depth 22 score cp 125 nodes 80000 pv e2e4 e7e5 g1f3"))
        // The SDK serializes this as <info> <depth> ... <score> <cp> 125.0.
        let evaluation = try XCTUnwrap(EngineEvaluation.parse(uci: response.rawValue))
        XCTAssertEqual(evaluation.centipawns, 125)
        XCTAssertNil(evaluation.mate)
        XCTAssertEqual(evaluation.depth, 22)
        XCTAssertEqual(evaluation.principalVariation, ["e2e4", "e7e5", "g1f3"])
        XCTAssertEqual(evaluation.displayText, "+1.25")
        XCTAssertGreaterThan(evaluation.confidence, 0.5)
        XCTAssertLessThan(evaluation.confidence, 1)
    }

    func testNegativeScoreIsFromTheAskingSidePointOfView() throws {
        // Stockfish's UCI score already describes the side to move. A Black
        // request must therefore retain the sign, rather than flipping it.
        let response = try XCTUnwrap(EngineResponse(rawValue: "info depth 12 score cp -150 pv e7e5"))
        let evaluation = try XCTUnwrap(EngineEvaluation.parse(uci: response.rawValue))
        XCTAssertEqual(evaluation.centipawns, -150)
        XCTAssertEqual(evaluation.displayText, "-1.50")
        XCTAssertLessThan(evaluation.confidence, 0.5)
    }

    func testMateForTheAskingSide() throws {
        let response = try XCTUnwrap(EngineResponse(rawValue: "info depth 15 score mate 3 pv h5f7"))
        let evaluation = try XCTUnwrap(EngineEvaluation.parse(uci: response.rawValue))
        XCTAssertEqual(evaluation.mate, 3)
        XCTAssertNil(evaluation.centipawns)
        XCTAssertEqual(evaluation.displayText, "Mate in 3")
        XCTAssertEqual(evaluation.confidence, 1)
    }

    func testMateAgainstTheAskingSide() throws {
        let evaluation = try XCTUnwrap(EngineEvaluation.parse(uci: "info depth 15 score mate -2 pv a7a6"))
        XCTAssertEqual(evaluation.displayText, "Facing mate in 2")
        XCTAssertEqual(evaluation.confidence, 0)
    }

    func testBoundsAndSecondaryLinesDoNotOverwriteExactMainLine() {
        XCTAssertNil(EngineEvaluation.parse(uci: "info depth 14 score cp 300 lowerbound pv e2e4"))
        XCTAssertNil(EngineEvaluation.parse(uci: "info depth 14 score cp 300 upperbound pv e2e4"))
        XCTAssertNil(EngineEvaluation.parse(uci: "info depth 14 multipv 2 score cp 300 pv d2d4"))
    }

    func testAbsentAndMalformedScoresAreIgnored() {
        XCTAssertNil(EngineEvaluation.parse(uci: "info depth 2 nodes 1000"))
        XCTAssertNil(EngineEvaluation.parse(uci: "info score cp nan"))
        XCTAssertNil(EngineEvaluation.parse(uci: "info score cp 9223372036854775807"))
        XCTAssertNil(EngineEvaluation.parse(uci: "bestmove e2e4"))
    }

    func testNeutralAndExtremeBarsStayInRange() throws {
        let neutral = try XCTUnwrap(EngineEvaluation.parse(uci: "info score cp 0"))
        XCTAssertEqual(neutral.confidence, 0.5)
        for score in [-99999, 99999] {
            let result = try XCTUnwrap(EngineEvaluation.parse(uci: "info score cp \(score)"))
            XCTAssertGreaterThanOrEqual(result.confidence, 0)
            XCTAssertLessThanOrEqual(result.confidence, 1)
            XCTAssertTrue(result.confidence.isFinite)
        }
    }
}
