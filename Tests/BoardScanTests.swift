import XCTest
@testable import ChessPhone

final class BoardScanTests: XCTestCase {
    private let startingRows = ["rnbqkbnr", "pppppppp", "........", "........", "........", "........", "PPPPPPPP", "RNBQKBNR"]

    func testBoardCoordinatesStayAbsoluteForEitherPlayersSeat() throws {
        let reading = GeminiBoardReading(boardVisible: true, handOverBoard: false,
                                         rows: startingRows, confidence: "high", notes: nil)
        let scan = try BoardOrienter.orient(reading)
        XCTAssertEqual(scan.squares, Position.start.board)
        XCTAssertEqual(scan.squares[Square.index(named: "e1")!], Piece(type: .king, color: .white))
        XCTAssertEqual(scan.squares[Square.index(named: "e8")!], Piece(type: .king, color: .black))
    }

    func testBlockedBoardCannotCommitEvenIfModelClaimsHighConfidence() {
        let reading = GeminiBoardReading(boardVisible: true, handOverBoard: true,
                                         rows: startingRows, confidence: "high", notes: nil)
        XCTAssertThrowsError(try BoardOrienter.orient(reading))
    }

    func testUnreadableAndMalformedResponsesAreRejected() {
        for reading in [
            GeminiBoardReading(boardVisible: false, handOverBoard: nil, rows: startingRows, confidence: "high", notes: nil),
            GeminiBoardReading(boardVisible: true, handOverBoard: nil, rows: startingRows, confidence: "low", notes: nil),
            GeminiBoardReading(boardVisible: true, handOverBoard: nil, rows: startingRows, confidence: "certain", notes: nil),
            GeminiBoardReading(boardVisible: true, handOverBoard: nil, rows: ["too short"], confidence: "high", notes: nil)
        ] {
            XCTAssertThrowsError(try BoardOrienter.orient(reading))
        }
    }

    func testExactlyOneLegalObservedMoveIsRecognized() throws {
        let move = try XCTUnwrap(Move(uci: "e2e4"))
        let scan = ScannedBoard(squares: Position.start.applying(move).board, confidence: "high", notes: nil)
        guard case .move(let actual) = ScanMatcher.match(scan, against: .start) else {
            return XCTFail("An exact legal successor must be recognized.")
        }
        XCTAssertEqual(actual, move)
    }

    func testAnUnchangedBoardDoesNotInventAMove() {
        let scan = ScannedBoard(squares: Position.start.board, confidence: "high", notes: nil)
        guard case .unchanged = ScanMatcher.match(scan, against: .start) else {
            return XCTFail("An unchanged board must not become an opponent move.")
        }
    }
}
