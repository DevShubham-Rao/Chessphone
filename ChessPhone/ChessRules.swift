import Foundation

// MARK: - Basic types

enum PieceColor: Int {
    case white = 0
    case black = 1

    var opposite: PieceColor { self == .white ? .black : .white }
    var name: String { self == .white ? "White" : "Black" }
}

enum PieceType: Int {
    case pawn, knight, bishop, rook, queen, king

    /// Lowercase FEN letter.
    var fenLetter: Character {
        switch self {
        case .pawn: return "p"
        case .knight: return "n"
        case .bishop: return "b"
        case .rook: return "r"
        case .queen: return "q"
        case .king: return "k"
        }
    }

    /// Letter used for promotion in UCI moves (e.g. e7e8q).
    var uciLetter: String {
        switch self {
        case .knight: return "n"
        case .bishop: return "b"
        case .rook: return "r"
        case .queen: return "q"
        default: return ""
        }
    }

    static func fromUCILetter(_ c: Character) -> PieceType? {
        switch c {
        case "n": return .knight
        case "b": return .bishop
        case "r": return .rook
        case "q": return .queen
        default: return nil
        }
    }

    /// 1...4 code used by the haptic promotion signal / promotion input.
    var promotionCode: Int {
        switch self {
        case .queen: return 1
        case .rook: return 2
        case .bishop: return 3
        case .knight: return 4
        default: return 0
        }
    }

    static func fromPromotionCode(_ code: Int) -> PieceType? {
        switch code {
        case 1: return .queen
        case 2: return .rook
        case 3: return .bishop
        case 4: return .knight
        default: return nil
        }
    }
}

struct Piece: Equatable {
    let type: PieceType
    let color: PieceColor

    var fenChar: Character {
        let l = type.fenLetter
        return color == .white ? Character(String(l).uppercased()) : l
    }
}

/// Squares are indexed 0...63 with a1 = 0, b1 = 1, ... h1 = 7, a2 = 8, ... h8 = 63.
enum Square {
    static let fileLetters = ["a", "b", "c", "d", "e", "f", "g", "h"]

    static func index(file: Int, rank: Int) -> Int { rank * 8 + file }
    static func file(_ index: Int) -> Int { index % 8 }
    static func rank(_ index: Int) -> Int { index / 8 }

    static func name(_ index: Int) -> String {
        fileLetters[file(index)] + String(rank(index) + 1)
    }

    static func index(named name: String) -> Int? {
        let chars = Array(name.lowercased())
        guard chars.count == 2,
              let f = fileLetters.firstIndex(of: String(chars[0])),
              let r = Int(String(chars[1])),
              r >= 1, r <= 8 else { return nil }
        return index(file: f, rank: r - 1)
    }
}

struct Move: Equatable, Hashable {
    let from: Int
    let to: Int
    let promotion: PieceType?

    var uci: String {
        Square.name(from) + Square.name(to) + (promotion?.uciLetter ?? "")
    }
}

extension Move {
    /// Parses "e2e4" or "e7e8q". Returns nil if the text isn't well-formed.
    /// (Does NOT check legality - use ChessGame.legalMove(uci:) for that.)
    init?(uci: String) {
        let chars = Array(uci.lowercased())
        guard chars.count == 4 || chars.count == 5,
              let f = Square.index(named: String(chars[0...1])),
              let t = Square.index(named: String(chars[2...3])) else { return nil }
        var promo: PieceType? = nil
        if chars.count == 5 {
            guard let p = PieceType.fromUCILetter(chars[4]) else { return nil }
            promo = p
        }
        self.init(from: f, to: t, promotion: promo)
    }
}

enum GameOutcome: Equatable {
    case checkmate(winner: PieceColor)
    case stalemate
    case insufficientMaterial
    case fiftyMoveRule
    case threefoldRepetition

    var summary: String {
        switch self {
        case .checkmate(let winner): return "Checkmate. \(winner.name) wins."
        case .stalemate: return "Stalemate. Draw."
        case .insufficientMaterial: return "Draw by insufficient material."
        case .fiftyMoveRule: return "Draw by the fifty-move rule."
        case .threefoldRepetition: return "Draw by threefold repetition."
        }
    }
}

// MARK: - Position

struct Position {
    var board: [Piece?] = Array(repeating: nil, count: 64)
    var sideToMove: PieceColor = .white
    var whiteKingside = true
    var whiteQueenside = true
    var blackKingside = true
    var blackQueenside = true
    /// En passant target square (the square "behind" a pawn that just double-pushed).
    var enPassant: Int? = nil
    var halfmoveClock = 0
    var fullmoveNumber = 1

    private static let knightOffsets: [(Int, Int)] = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    private static let kingOffsets: [(Int, Int)] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    private static let bishopDirs: [(Int, Int)] = [(1, 1), (1, -1), (-1, 1), (-1, -1)]
    private static let rookDirs: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]

    static var start: Position {
        var p = Position()
        let back: [PieceType] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for f in 0..<8 {
            p.board[f] = Piece(type: back[f], color: .white)
            p.board[8 + f] = Piece(type: .pawn, color: .white)
            p.board[48 + f] = Piece(type: .pawn, color: .black)
            p.board[56 + f] = Piece(type: back[f], color: .black)
        }
        return p
    }

    // MARK: Attacks / check

    func isAttacked(_ sq: Int, by attacker: PieceColor) -> Bool {
        let f = sq % 8
        let r = sq / 8

        // Pawns: a white pawn attacks the two squares diagonally ahead of it (rank + 1),
        // so the attacker of `sq` sits one rank BELOW it (rank - 1). Black is mirrored.
        let pawnRank = attacker == .white ? r - 1 : r + 1
        if pawnRank >= 0 && pawnRank < 8 {
            for df in [-1, 1] {
                let pf = f + df
                if pf >= 0 && pf < 8 && board[pawnRank * 8 + pf] == Piece(type: .pawn, color: attacker) {
                    return true
                }
            }
        }

        for (df, dr) in Position.knightOffsets {
            let nf = f + df
            let nr = r + dr
            if nf >= 0 && nf < 8 && nr >= 0 && nr < 8 && board[nr * 8 + nf] == Piece(type: .knight, color: attacker) {
                return true
            }
        }

        for (df, dr) in Position.kingOffsets {
            let nf = f + df
            let nr = r + dr
            if nf >= 0 && nf < 8 && nr >= 0 && nr < 8 && board[nr * 8 + nf] == Piece(type: .king, color: attacker) {
                return true
            }
        }

        if slideAttacked(f, r, dirs: Position.bishopDirs, types: [.bishop, .queen], by: attacker) { return true }
        if slideAttacked(f, r, dirs: Position.rookDirs, types: [.rook, .queen], by: attacker) { return true }
        return false
    }

    private func slideAttacked(_ f: Int, _ r: Int, dirs: [(Int, Int)], types: [PieceType], by attacker: PieceColor) -> Bool {
        for (df, dr) in dirs {
            var nf = f + df
            var nr = r + dr
            while nf >= 0 && nf < 8 && nr >= 0 && nr < 8 {
                if let p = board[nr * 8 + nf] {
                    if p.color == attacker && types.contains(p.type) { return true }
                    break
                }
                nf += df
                nr += dr
            }
        }
        return false
    }

    func kingSquare(of color: PieceColor) -> Int? {
        for i in 0..<64 {
            if board[i] == Piece(type: .king, color: color) { return i }
        }
        return nil
    }

    func isInCheck(_ color: PieceColor) -> Bool {
        guard let k = kingSquare(of: color) else { return false }
        return isAttacked(k, by: color.opposite)
    }

    // MARK: Move generation

    /// Moves that follow piece movement rules but may leave the mover's own king in check.
    private func pseudoLegalMoves() -> [Move] {
        var out: [Move] = []
        let us = sideToMove
        let them = us.opposite

        for sq in 0..<64 {
            guard let piece = board[sq], piece.color == us else { continue }
            let f = sq % 8
            let r = sq / 8

            switch piece.type {
            case .pawn:
                let dir = us == .white ? 1 : -1
                let startRank = us == .white ? 1 : 6
                let promoRank = us == .white ? 7 : 0
                let nr = r + dir
                guard nr >= 0 && nr < 8 else { continue }

                // Forward pushes
                let oneStep = nr * 8 + f
                if board[oneStep] == nil {
                    if nr == promoRank {
                        for t in [PieceType.queen, .rook, .bishop, .knight] {
                            out.append(Move(from: sq, to: oneStep, promotion: t))
                        }
                    } else {
                        out.append(Move(from: sq, to: oneStep, promotion: nil))
                        let twoStep = (r + 2 * dir) * 8 + f
                        if r == startRank && board[twoStep] == nil {
                            out.append(Move(from: sq, to: twoStep, promotion: nil))
                        }
                    }
                }

                // Captures (including en passant)
                for df in [-1, 1] {
                    let nf = f + df
                    guard nf >= 0 && nf < 8 else { continue }
                    let to = nr * 8 + nf
                    if let target = board[to] {
                        if target.color == them {
                            if nr == promoRank {
                                for t in [PieceType.queen, .rook, .bishop, .knight] {
                                    out.append(Move(from: sq, to: to, promotion: t))
                                }
                            } else {
                                out.append(Move(from: sq, to: to, promotion: nil))
                            }
                        }
                    } else if enPassant == to {
                        out.append(Move(from: sq, to: to, promotion: nil))
                    }
                }

            case .knight, .king:
                let offsets = piece.type == .knight ? Position.knightOffsets : Position.kingOffsets
                for (df, dr) in offsets {
                    let nf = f + df
                    let nr = r + dr
                    guard nf >= 0 && nf < 8 && nr >= 0 && nr < 8 else { continue }
                    let to = nr * 8 + nf
                    if let target = board[to] {
                        if target.color == them { out.append(Move(from: sq, to: to, promotion: nil)) }
                    } else {
                        out.append(Move(from: sq, to: to, promotion: nil))
                    }
                }
                if piece.type == .king {
                    appendCastling(&out, us: us, them: them, kingSq: sq)
                }

            case .bishop, .rook, .queen:
                var dirs: [(Int, Int)] = []
                if piece.type != .rook { dirs += Position.bishopDirs }
                if piece.type != .bishop { dirs += Position.rookDirs }
                for (df, dr) in dirs {
                    var nf = f + df
                    var nr = r + dr
                    while nf >= 0 && nf < 8 && nr >= 0 && nr < 8 {
                        let to = nr * 8 + nf
                        if let target = board[to] {
                            if target.color == them { out.append(Move(from: sq, to: to, promotion: nil)) }
                            break
                        }
                        out.append(Move(from: sq, to: to, promotion: nil))
                        nf += df
                        nr += dr
                    }
                }
            }
        }
        return out
    }

    private func appendCastling(_ out: inout [Move], us: PieceColor, them: PieceColor, kingSq: Int) {
        if us == .white && kingSq == 4 {
            if whiteKingside && board[7] == Piece(type: .rook, color: .white)
                && board[5] == nil && board[6] == nil
                && !isAttacked(4, by: them) && !isAttacked(5, by: them) && !isAttacked(6, by: them) {
                out.append(Move(from: 4, to: 6, promotion: nil))
            }
            if whiteQueenside && board[0] == Piece(type: .rook, color: .white)
                && board[1] == nil && board[2] == nil && board[3] == nil
                && !isAttacked(4, by: them) && !isAttacked(3, by: them) && !isAttacked(2, by: them) {
                out.append(Move(from: 4, to: 2, promotion: nil))
            }
        }
        if us == .black && kingSq == 60 {
            if blackKingside && board[63] == Piece(type: .rook, color: .black)
                && board[61] == nil && board[62] == nil
                && !isAttacked(60, by: them) && !isAttacked(61, by: them) && !isAttacked(62, by: them) {
                out.append(Move(from: 60, to: 62, promotion: nil))
            }
            if blackQueenside && board[56] == Piece(type: .rook, color: .black)
                && board[57] == nil && board[58] == nil && board[59] == nil
                && !isAttacked(60, by: them) && !isAttacked(59, by: them) && !isAttacked(58, by: them) {
                out.append(Move(from: 60, to: 58, promotion: nil))
            }
        }
    }

    /// Fully legal moves for the side to move.
    func legalMoves() -> [Move] {
        let mover = sideToMove
        return pseudoLegalMoves().filter { !applying($0).isInCheck(mover) }
    }

    /// Returns the position after `m`. Assumes `m` is at least pseudo-legal.
    func applying(_ m: Move) -> Position {
        var n = self
        guard let piece = n.board[m.from] else { return n }
        let captured = n.board[m.to]
        n.board[m.from] = nil

        var enPassantCapture = false
        if piece.type == .pawn && captured == nil && (m.from % 8) != (m.to % 8) {
            // Diagonal pawn move onto an empty square = en passant; remove the passed pawn.
            n.board[(m.from / 8) * 8 + (m.to % 8)] = nil
            enPassantCapture = true
        }

        if let promo = m.promotion {
            n.board[m.to] = Piece(type: promo, color: piece.color)
        } else {
            n.board[m.to] = piece
        }

        // Castling: king moved two files, so bring the rook across.
        if piece.type == .king && abs((m.to % 8) - (m.from % 8)) == 2 {
            if m.to % 8 == 6 {
                n.board[m.to - 1] = n.board[m.to + 1]
                n.board[m.to + 1] = nil
            } else {
                n.board[m.to + 1] = n.board[m.to - 2]
                n.board[m.to - 2] = nil
            }
        }

        if piece.type == .king {
            if piece.color == .white {
                n.whiteKingside = false
                n.whiteQueenside = false
            } else {
                n.blackKingside = false
                n.blackQueenside = false
            }
        }
        // Rook moved from, or was captured on, a corner.
        for s in [m.from, m.to] {
            if s == 0 { n.whiteQueenside = false }
            if s == 7 { n.whiteKingside = false }
            if s == 56 { n.blackQueenside = false }
            if s == 63 { n.blackKingside = false }
        }

        n.enPassant = nil
        if piece.type == .pawn && abs((m.to / 8) - (m.from / 8)) == 2 {
            n.enPassant = (m.from + m.to) / 2
        }

        if piece.type == .pawn || captured != nil || enPassantCapture {
            n.halfmoveClock = 0
        } else {
            n.halfmoveClock += 1
        }
        if piece.color == .black { n.fullmoveNumber += 1 }
        n.sideToMove = sideToMove.opposite
        return n
    }

    // MARK: FEN / repetition key

    var fen: String {
        var s = ""
        for r in stride(from: 7, through: 0, by: -1) {
            var empty = 0
            for f in 0..<8 {
                if let p = board[r * 8 + f] {
                    if empty > 0 { s += String(empty); empty = 0 }
                    s.append(p.fenChar)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { s += String(empty) }
            if r > 0 { s += "/" }
        }
        s += sideToMove == .white ? " w " : " b "
        var castling = ""
        if whiteKingside { castling += "K" }
        if whiteQueenside { castling += "Q" }
        if blackKingside { castling += "k" }
        if blackQueenside { castling += "q" }
        s += castling.isEmpty ? "-" : castling
        s += " " + (enPassant.map { Square.name($0) } ?? "-")
        s += " \(halfmoveClock) \(fullmoveNumber)"
        return s
    }

    /// En passant square only if a pawn of the side to move could actually capture there.
    private var capturableEnPassant: Int? {
        guard let ep = enPassant else { return nil }
        let r = ep / 8
        let f = ep % 8
        let pawnRank = sideToMove == .white ? r - 1 : r + 1
        guard pawnRank >= 0 && pawnRank < 8 else { return nil }
        for df in [-1, 1] {
            let pf = f + df
            if pf >= 0 && pf < 8 && board[pawnRank * 8 + pf] == Piece(type: .pawn, color: sideToMove) {
                return ep
            }
        }
        return nil
    }

    /// Identifies a position for threefold-repetition purposes (ignores move counters).
    var repetitionKey: String {
        let parts = fen.split(separator: " ")
        let placement = parts[0]
        let side = parts[1]
        let castling = parts[2]
        let ep = capturableEnPassant.map { Square.name($0) } ?? "-"
        return "\(placement) \(side) \(castling) \(ep)"
    }

    var hasInsufficientMaterial: Bool {
        var minors: [(PieceType, Int)] = []
        for sq in 0..<64 {
            guard let p = board[sq] else { continue }
            switch p.type {
            case .king:
                continue
            case .knight, .bishop:
                minors.append((p.type, ((sq % 8) + (sq / 8)) % 2))
            default:
                return false // pawn, rook or queen on the board: mate is still possible
            }
        }
        if minors.count <= 1 { return true } // K v K, K+minor v K
        // Only bishops, all on the same square colour.
        let first = minors[0]
        return minors.allSatisfy { $0.0 == .bishop && $0.1 == first.1 } && first.0 == .bishop
    }
}

// MARK: - Game

/// A whole game: current position, move list, repetition tracking and result.
/// `play(_:)` re-validates every move against freshly generated legal moves,
/// so nothing illegal can ever reach the board.
struct ChessGame {
    private(set) var position = Position.start
    private(set) var moveHistory: [Move] = []
    private(set) var outcome: GameOutcome? = nil
    private var repetitionCounts: [String: Int] = [:]

    init() {
        repetitionCounts[position.repetitionKey] = 1
    }

    var sideToMove: PieceColor { position.sideToMove }
    var fen: String { position.fen }
    var board: [Piece?] { position.board }

    var isInCheck: Bool { position.isInCheck(position.sideToMove) }

    /// Square of the king that is currently in check, if any (for highlighting).
    var checkedKingSquare: Int? {
        isInCheck ? position.kingSquare(of: position.sideToMove) : nil
    }

    func legalMoves() -> [Move] {
        outcome == nil ? position.legalMoves() : []
    }

    func legalMoves(from square: Int) -> [Move] {
        legalMoves().filter { $0.from == square }
    }

    func isLegal(_ move: Move) -> Bool {
        legalMoves().contains(move)
    }

    /// Parses a UCI string and returns the matching legal move, or nil if it is
    /// malformed or not legal in the current position.
    func legalMove(uci: String) -> Move? {
        guard let parsed = Move(uci: uci) else { return nil }
        return legalMoves().first { $0 == parsed }
    }

    /// Plays `move` if (and only if) it is legal. Returns true on success.
    @discardableResult
    mutating func play(_ move: Move) -> Bool {
        guard outcome == nil else { return false }
        // Check 1: the move must be in the freshly generated legal move list.
        guard position.legalMoves().contains(move) else { return false }
        let mover = position.sideToMove
        let next = position.applying(move)
        // Check 2: after the move, the mover's own king must not be attacked.
        guard !next.isInCheck(mover) else { return false }

        position = next
        moveHistory.append(move)
        repetitionCounts[position.repetitionKey, default: 0] += 1
        outcome = computeOutcome()
        return true
    }

    private func computeOutcome() -> GameOutcome? {
        if position.legalMoves().isEmpty {
            if position.isInCheck(position.sideToMove) {
                return .checkmate(winner: position.sideToMove.opposite)
            }
            return .stalemate
        }
        if position.hasInsufficientMaterial { return .insufficientMaterial }
        if position.halfmoveClock >= 100 { return .fiftyMoveRule }
        if (repetitionCounts[position.repetitionKey] ?? 0) >= 3 { return .threefoldRepetition }
        return nil
    }
}
