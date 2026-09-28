import Foundation

/// Extremely simple 8x8 board tracker for on-screen debugging only.
/// It is NOT used for legality or sent to the engine - it just mirrors
/// whatever absolute UCI moves get applied, so you can sanity-check
/// what's actually happening. No special-move correctness (captures
/// overwrite blindly, no castling/en-passant/promotion handling).
struct BoardModel {
    /// squares[rank][file], rank 0 = rank 1, file 0 = file a.
    var squares: [[Character?]] = BoardModel.startingPosition()

    static func startingPosition() -> [[Character?]] {
        var b: [[Character?]] = Array(repeating: Array(repeating: nil, count: 8), count: 8)
        let backRank: [Character] = ["R", "N", "B", "Q", "K", "B", "N", "R"]
        for f in 0..<8 {
            b[0][f] = backRank[f]
            b[1][f] = "P"
            b[6][f] = "p"
            b[7][f] = Character(String(backRank[f]).lowercased())
        }
        return b
    }

    mutating func reset() {
        squares = BoardModel.startingPosition()
    }

    /// move is UCI long algebraic, e.g. "e2e4". Ignores any promotion
    /// suffix beyond the first 4 characters.
    mutating func apply(uciMove move: String) {
        guard move.count >= 4 else { return }
        let chars = Array(move)
        guard
            let fromFile = fileIndex(chars[0]), let fromRank = Int(String(chars[1])),
            let toFile = fileIndex(chars[2]), let toRank = Int(String(chars[3])),
            (1...8).contains(fromRank), (1...8).contains(toRank)
        else { return }

        let piece = squares[fromRank - 1][fromFile]
        squares[fromRank - 1][fromFile] = nil
        squares[toRank - 1][toFile] = piece
    }

    private func fileIndex(_ c: Character) -> Int? {
        let files: [Character] = ["a", "b", "c", "d", "e", "f", "g", "h"]
        return files.firstIndex(of: Character(c.lowercased()))
    }

    /// rankFromTop: 0 = rank 8 (top row when drawn standard orientation).
    func symbol(rankFromTop rankIdx: Int, file: Int) -> String {
        let rank = 7 - rankIdx
        guard let p = squares[rank][file] else { return "·" }
        return pieceSymbol(p)
    }

    private func pieceSymbol(_ c: Character) -> String {
        let map: [Character: String] = [
            "K": "♔", "Q": "♕", "R": "♖", "B": "♗", "N": "♘", "P": "♙",
            "k": "♚", "q": "♛", "r": "♜", "b": "♝", "n": "♞", "p": "♟",
        ]
        return map[c] ?? "?"
    }
}
