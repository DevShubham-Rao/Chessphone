import XCTest
@testable import ChessPhone

final class ChessNotationTests: XCTestCase {
    func testStartingFENRoundTripAndLegalMoveCount() throws {
        let position = try Position(fen: Position.start.fen)
        XCTAssertEqual(position.fen, Position.start.fen)
        XCTAssertEqual(position.legalMoves().count, 20)
    }

    func testMalformedAndImpossibleFENsAreRejected() {
        let invalid = [
            "8/8/8/8/8/8/8/8 w - - 0 1", // no kings
            "4k3/8/8/8/8/8/8/4K3 x - - 0 1", // bad side
            "4k3/8/8/8/8/8/8/4K3 w K - 0 1", // missing castling rook
            "4k3/8/8/8/8/8/8/4K3 w - e6 0 1", // no double-pushed pawn
            "4k3/8/8/8/8/8/8/P3K3 w - - 0 1", // pawn on first rank
            "4k3/8/8/8/8/8/4K3/8 w - - 0 0", // bad fullmove
            "4k3/8/8/8/8/8/8/4K3 w - - 0", // incomplete fields
            "4k3/8/8/8/8/8/8/4K3 w - - 0 99999999999999999999999999",
            "4k3/8/8/8/8/8/4K3/8 w - - -1 1"
        ]
        for fen in invalid { XCTAssertThrowsError(try Position(fen: fen), fen) }
    }

    func testSANAndUCIManualInputResolveToTheSameMove() throws {
        let position = Position.start
        XCTAssertEqual(position.legalMove(notation: "Nf3"), Move(uci: "g1f3"))
        XCTAssertEqual(position.legalMove(notation: "g1f3"), Move(uci: "g1f3"))
        XCTAssertNil(position.legalMove(notation: "e2e5"))
        XCTAssertNil(position.legalMove(notation: "definitely not a move"))
    }

    func testSANAmbiguityRequiresTheOriginFile() throws {
        let position = try Position(fen: "4k3/8/8/8/8/8/3N1N2/4K3 w - - 0 1")
        XCTAssertNil(position.legalMove(notation: "Ne4"))
        XCTAssertEqual(position.legalMove(notation: "Nde4"), Move(uci: "d2e4"))
        XCTAssertEqual(position.san(for: try XCTUnwrap(Move(uci: "f2e4"))), "Nfe4")
    }

    func testCastlingAndEnPassantArePreservedByFEN() throws {
        let castle = try Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        XCTAssertEqual(castle.legalMove(notation: "0-0"), Move(uci: "e1g1"))
        let ep = try Position(fen: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 2")
        let move = try XCTUnwrap(ep.legalMove(notation: "exd6"))
        XCTAssertEqual(ep.applying(move).board[Square.index(named: "d5")!], nil)
        XCTAssertEqual(ep.fen.split(separator: " ")[3], "d6")
    }

    func testPromotionIncludesCheckAndChoice() throws {
        let position = try Position(fen: "7k/P7/8/8/8/8/8/7K w - - 0 1")
        let move = try XCTUnwrap(position.legalMove(notation: "a8=Q+"))
        XCTAssertEqual(move.promotion, .queen)
        XCTAssertEqual(position.san(for: move), "a8=Q+")
        XCTAssertNil(position.legalMove(notation: "a7a8"))
    }

    func testPGNUsesSANAndMateResult() throws {
        var game = ChessGame()
        for uci in ["f2f3", "e7e5", "g2g4", "d8h4"] {
            XCTAssertTrue(game.play(try XCTUnwrap(Move(uci: uci))))
        }
        XCTAssertEqual(game.outcome, .checkmate(winner: .black))
        let pgn = game.pgn(playerColor: .white)
        XCTAssertTrue(pgn.contains("[White \"You\"]"))
        XCTAssertTrue(pgn.contains("1. f3 e5 2. g4 Qh4# 0-1"))
    }

    func testCustomStartSurvivesRebuildAndPGNStartsWithBlackMoveNumber() throws {
        let initial = try Position(fen: "4k3/7p/8/8/8/8/P7/4K3 b - - 0 42")
        let move = try XCTUnwrap(initial.legalMove(notation: "h6"))
        let game = ChessGame(startingPosition: initial, moves: [move])
        let rebuilt = ChessGame(startingPosition: game.startingPosition, moves: [])
        XCTAssertEqual(rebuilt.fen, initial.fen)
        XCTAssertEqual(game.numberedMoves, ["42... h6"])
        XCTAssertTrue(game.pgn(playerColor: .black).contains("[SetUp \"1\"]"))
        XCTAssertTrue(game.pgn(playerColor: .black).contains("42... h6 *"))
    }

    func testTerminalFENLoadsAsFinishedGame() throws {
        let position = try Position(fen: "7k/6Q1/6K1/8/8/8/8/8 b - - 0 42")
        let game = ChessGame(startingPosition: position)
        XCTAssertEqual(game.outcome, .checkmate(winner: .white))
        XCTAssertTrue(game.legalMoves().isEmpty)
        XCTAssertTrue(game.pgn(playerColor: .white).contains("[Result \"1-0\"]"))
    }

    func testRebuildingFromInitialPositionRetainsThreefoldDraw() throws {
        let line = ["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"]
        let game = ChessGame(startingPosition: .start, moves: try line.map { try XCTUnwrap(Move(uci: $0)) })
        XCTAssertEqual(game.outcome, .threefoldRepetition)
        XCTAssertTrue(game.pgn(playerColor: .white).contains("[Result \"1/2-1/2\"]"))
    }
}
