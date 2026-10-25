import Foundation

enum PositionImportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let reason) = self { return "Invalid FEN: \(reason)" }
        return nil
    }
}

extension Position {
    /// Imports all six FEN fields; never guesses castling rights or whose turn it is.
    init(fen: String) throws {
        let fields = fen.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard fields.count == 6 else { throw PositionImportError.invalid("enter all six fields.") }
        let ranks = fields[0].split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8 else { throw PositionImportError.invalid("expected eight ranks.") }
        self.init()
        board = Array(repeating: nil, count: 64)
        for (row, rank) in ranks.enumerated() {
            var file = 0
            for character in rank {
                if let empty = Int(String(character)), (1...8).contains(empty) {
                    file += empty
                } else {
                    guard "pnbrqkPNBRQK".contains(character), file < 8 else {
                        throw PositionImportError.invalid("unknown piece or oversized rank.")
                    }
                    let type: PieceType
                    switch character.lowercased() {
                    case "p": type = .pawn
                    case "n": type = .knight
                    case "b": type = .bishop
                    case "r": type = .rook
                    case "q": type = .queen
                    default: type = .king
                    }
                    board[Square.index(file: file, rank: 7 - row)] = Piece(
                        type: type, color: character.isUppercase ? .white : .black)
                    file += 1
                }
                guard file <= 8 else { throw PositionImportError.invalid("a rank exceeds eight squares.") }
            }
            guard file == 8 else { throw PositionImportError.invalid("each rank must cover eight squares.") }
        }
        guard fields[1] == "w" || fields[1] == "b" else {
            throw PositionImportError.invalid("side to move must be w or b.")
        }
        sideToMove = fields[1] == "w" ? .white : .black
        let rights = fields[2]
        guard rights == "-" || (!rights.isEmpty && rights.allSatisfy({ "KQkq".contains($0) })
            && Set(rights).count == rights.count) else {
            throw PositionImportError.invalid("castling rights must be KQkq or -.")
        }
        whiteKingside = rights.contains("K"); whiteQueenside = rights.contains("Q")
        blackKingside = rights.contains("k"); blackQueenside = rights.contains("q")
        for (allowed, king, rook, color) in [
            (whiteKingside, "e1", "h1", PieceColor.white), (whiteQueenside, "e1", "a1", .white),
            (blackKingside, "e8", "h8", .black), (blackQueenside, "e8", "a8", .black)
        ] where allowed {
            guard board[Square.index(named: king)!] == Piece(type: .king, color: color),
                  board[Square.index(named: rook)!] == Piece(type: .rook, color: color) else {
                throw PositionImportError.invalid("castling rights require the king and rook on their home squares.")
            }
        }
        guard let half = Int(fields[4]), (0...1_000_000).contains(half),
              let full = Int(fields[5]), (1...1_000_000).contains(full) else {
            throw PositionImportError.invalid("invalid halfmove or fullmove counter.")
        }
        halfmoveClock = half; fullmoveNumber = full
        enPassant = nil
        if fields[3] != "-" {
            guard let square = Square.index(named: fields[3]),
                  Square.rank(square) == (sideToMove == .white ? 5 : 2), board[square] == nil else {
                throw PositionImportError.invalid("invalid en passant target.")
            }
            let pawn = square + (sideToMove == .white ? -8 : 8)
            let origin = square + (sideToMove == .white ? 8 : -8)
            guard board[pawn] == Piece(type: .pawn, color: sideToMove.opposite),
                  board[origin] == nil, halfmoveClock == 0 else {
                throw PositionImportError.invalid("en passant requires a pawn that just moved two squares.")
            }
            enPassant = square
        }
        for color in [PieceColor.white, .black] {
            let pieces = board.compactMap { $0 }.filter { $0.color == color }
            guard pieces.filter({ $0.type == .king }).count == 1,
                  pieces.count <= 16, pieces.filter({ $0.type == .pawn }).count <= 8 else {
                throw PositionImportError.invalid("each side needs one king and a valid number of pieces.")
            }
        }
        guard !(0..<64).contains(where: {
            board[$0]?.type == .pawn && (Square.rank($0) == 0 || Square.rank($0) == 7)
        }) else { throw PositionImportError.invalid("pawns cannot be on the first or last rank.") }
        guard !isInCheck(sideToMove.opposite) else {
            throw PositionImportError.invalid("the side that just moved cannot be in check.")
        }
    }

    func san(for move: Move) -> String {
        guard let piece = board[move.from], legalMoves().contains(move) else { return move.uci }
        var text = ""
        if piece.type == .king && abs(Square.file(move.to) - Square.file(move.from)) == 2 {
            text = move.to > move.from ? "O-O" : "O-O-O"
        } else {
            let capture = board[move.to] != nil || (piece.type == .pawn && Square.file(move.from) != Square.file(move.to))
            if piece.type != .pawn {
                text = String(piece.type.fenLetter).uppercased()
                let rivals = legalMoves().filter {
                    $0.from != move.from && $0.to == move.to && board[$0.from] == piece
                }
                if !rivals.isEmpty {
                    if !rivals.contains(where: { Square.file($0.from) == Square.file(move.from) }) {
                        text += Square.fileLetters[Square.file(move.from)]
                    } else if !rivals.contains(where: { Square.rank($0.from) == Square.rank(move.from) }) {
                        text += String(Square.rank(move.from) + 1)
                    } else { text += Square.name(move.from) }
                }
            } else if capture { text += Square.fileLetters[Square.file(move.from)] }
            if capture { text += "x" }
            text += Square.name(move.to)
            if let promotion = move.promotion { text += "=" + String(promotion.fenLetter).uppercased() }
        }
        let next = applying(move)
        if next.isInCheck(next.sideToMove) { text += next.legalMoves().isEmpty ? "#" : "+" }
        return text
    }

    func legalMove(notation: String) -> Move? {
        let trimmed = notation.trimmingCharacters(in: .whitespacesAndNewlines)
        if let move = Move(uci: trimmed), legalMoves().contains(move) { return move }
        func normalize(_ value: String) -> String {
            value.replacingOccurrences(of: "0", with: "O")
                .filter { !"+#!?".contains($0) }
        }
        let matches = legalMoves().filter { normalize(san(for: $0)) == normalize(trimmed) }
        return matches.count == 1 ? matches[0] : nil
    }
}

extension ChessGame {
    var numberedMoves: [String] {
        var position = startingPosition
        return moveHistory.map { move in
            let label = "\(position.fullmoveNumber)\(position.sideToMove == .white ? "." : "...") \(position.san(for: move))"
            position = position.applying(move)
            return label
        }
    }

    func pgn(playerColor: PieceColor) -> String {
        let result: String
        switch outcome {
        case .checkmate(let winner): result = winner == .white ? "1-0" : "0-1"
        case .none: result = "*"
        default: result = "1/2-1/2"
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy.MM.dd"
        var tags = ["[Event \"ChessPhone session\"]", "[Site \"iPhone\"]", "[Date \"\(date.string(from: Date()))\"]",
                    "[Round \"-\"]", "[White \"\(playerColor == .white ? "You" : "Opponent")\"]",
                    "[Black \"\(playerColor == .black ? "You" : "Opponent")\"]", "[Result \"\(result)\"]"]
        if startingPosition.fen != Position.start.fen {
            tags += ["[SetUp \"1\"]", "[FEN \"\(startingPosition.fen)\"]"]
        }
        var position = startingPosition
        var tokens: [String] = []
        for (index, move) in moveHistory.enumerated() {
            if position.sideToMove == .white { tokens.append("\(position.fullmoveNumber).") }
            else if index == 0 { tokens.append("\(position.fullmoveNumber)...") }
            tokens.append(position.san(for: move))
            position = position.applying(move)
        }
        tokens.append(result)
        return tags.joined(separator: "\n") + "\n\n" + tokens.joined(separator: " ") + "\n"
    }
}
