import Foundation

// Turns Gemini's "what I see" into a validated chess position, and compares it with the game
// the app is already tracking. Uses only types that already exist in ChessRules.swift.

/// A board read from a photo, already rotated into real board coordinates (a1 = index 0 ... h8 = 63).
struct ScannedBoard {
    let squares: [Piece?]
    let confidence: String
    let notes: String?
}

enum BoardOrienter {
    /// The photo is taken from the player's side of the board, so the row nearest the camera is the
    /// player's home rank. Rotating here (not in the prompt) keeps the model's job purely visual.
    static func orient(_ reading: GeminiBoardReading, playerColor: PieceColor) throws -> ScannedBoard {
        guard reading.boardVisible else { throw VisionError.boardNotVisible }
        guard reading.rows.count == 8, reading.rows.allSatisfy({ $0.count == 8 }) else {
            throw VisionError.malformedReading("expected 8 rows of 8 squares")
        }
        if reading.confidence.lowercased() == "low" { throw VisionError.lowConfidence }

        var squares = [Piece?](repeating: nil, count: 64)
        for (row, text) in reading.rows.enumerated() {
            for (col, ch) in text.enumerated() {
                guard let decoded = decodePiece(ch) else {
                    if ch == "." { continue }
                    throw VisionError.malformedReading("unknown symbol '\(ch)'")
                }
                // row 0 = farthest from camera, col 0 = left of the image.
                let rank = playerColor == .white ? 7 - row : row
                let file = playerColor == .white ? col : 7 - col
                squares[Square.index(file: file, rank: rank)] = decoded
            }
        }
        return ScannedBoard(squares: squares, confidence: reading.confidence, notes: reading.notes)
    }

    private static func decodePiece(_ ch: Character) -> Piece? {
        let color: PieceColor = ch.isUppercase ? .white : .black
        switch Character(ch.lowercased()) {
        case "p": return Piece(type: .pawn, color: color)
        case "n": return Piece(type: .knight, color: color)
        case "b": return Piece(type: .bishop, color: color)
        case "r": return Piece(type: .rook, color: color)
        case "q": return Piece(type: .queen, color: color)
        case "k": return Piece(type: .king, color: color)
        default: return nil
        }
    }
}

extension ScannedBoard {
    /// Builds a full Position (FEN-ready). A photo cannot show castling rights or en passant, so:
    ///  - castling is allowed only if king+rook are on their home squares, AND (when a tracked game
    ///    exists) the tracked game still allows it - this prevents suggesting an illegal castle;
    ///  - en passant is left off (the only cost is missing a one-move en-passant tip).
    func makePosition(sideToMove: PieceColor, rightsFrom tracked: Position?) throws -> Position {
        var p = Position()
        p.board = squares
        p.sideToMove = sideToMove

        func has(_ name: String, _ type: PieceType, _ color: PieceColor) -> Bool {
            guard let i = Square.index(named: name) else { return false }
            return squares[i] == Piece(type: type, color: color)
        }
        p.whiteKingside  = has("e1", .king, .white) && has("h1", .rook, .white)
        p.whiteQueenside = has("e1", .king, .white) && has("a1", .rook, .white)
        p.blackKingside  = has("e8", .king, .black) && has("h8", .rook, .black)
        p.blackQueenside = has("e8", .king, .black) && has("a8", .rook, .black)
        if let t = tracked {
            p.whiteKingside = p.whiteKingside && t.whiteKingside
            p.whiteQueenside = p.whiteQueenside && t.whiteQueenside
            p.blackKingside = p.blackKingside && t.blackKingside
            p.blackQueenside = p.blackQueenside && t.blackQueenside
        }

        try validate(p)
        return p
    }

    /// Cheap sanity checks that catch most vision mistakes before Stockfish ever sees them.
    private func validate(_ p: Position) throws {
        for color in [PieceColor.white, .black] {
            let mine = p.board.compactMap { $0 }.filter { $0.color == color }
            if mine.filter({ $0.type == .king }).count != 1 {
                throw VisionError.invalidPosition("\(color.name) must have exactly one king")
            }
            if mine.count > 16 { throw VisionError.invalidPosition("\(color.name) has more than 16 pieces") }
            if mine.filter({ $0.type == .pawn }).count > 8 {
                throw VisionError.invalidPosition("\(color.name) has more than 8 pawns")
            }
        }
        for sq in 0..<64 where p.board[sq]?.type == .pawn && (Square.rank(sq) == 0 || Square.rank(sq) == 7) {
            throw VisionError.invalidPosition("a pawn on the first or last rank")
        }
        // The side that just moved can't be in check.
        if p.isInCheck(p.sideToMove.opposite) {
            throw VisionError.invalidPosition("the side not to move is in check")
        }
        if p.legalMoves().isEmpty {
            throw VisionError.invalidPosition("no legal moves (game already over?)")
        }
    }
}

enum ScanMatch {
    case move(Move)      // the board is exactly one legal opponent move away from the tracked game
    case unchanged       // the photo shows the tracked position as-is
    case noMatch         // photo and tracked game disagree (misread, or board got out of sync)
}

enum ScanMatcher {
    /// `tracked` is the position the app is waiting on: opponent to move.
    static func match(_ scan: ScannedBoard, against tracked: Position) -> ScanMatch {
        if scan.squares == tracked.board { return .unchanged }
        for move in tracked.legalMoves() where tracked.applying(move).board == scan.squares {
            return .move(move)          // includes promotions: each promotion piece gives a different board
        }
        return .noMatch
    }
}
