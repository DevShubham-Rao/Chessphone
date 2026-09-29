import SwiftUI

/// Draws the board from the point of view of `bottomColor`:
///  - White at the bottom: rank 8 on top, files a...h left to right.
///  - Black at the bottom: rank 1 on top, files h...a left to right.
/// (i.e. the board is rotated 180 degrees, as on a real board when you sit on Black's side.)
///
/// File labels show the tap number too ("a·1"), rank labels are the row number,
/// so you can read the exact numbers you need to enter straight off the board.
struct BoardView: View {
    let board: [Piece?]
    let bottomColor: PieceColor
    let lastMove: Move?
    let selected: Int?
    let targets: Set<Int>
    let checkSquare: Int?

    private let lightSquare = Color(red: 0.94, green: 0.85, blue: 0.71)
    private let darkSquare = Color(red: 0.71, green: 0.53, blue: 0.39)

    /// File indices, left to right.
    private var files: [Int] {
        bottomColor == .white ? Array(0..<8) : Array((0..<8).reversed())
    }

    /// Rank indices, top to bottom.
    private var ranksTopToBottom: [Int] {
        bottomColor == .white ? Array((0..<8).reversed()) : Array(0..<8)
    }

    var body: some View {
        GeometryReader { geo in
            let labelSize: CGFloat = 20
            let cell = (min(geo.size.width, geo.size.height) - labelSize) / 8

            VStack(spacing: 0) {
                ForEach(ranksTopToBottom, id: \.self) { rank in
                    HStack(spacing: 0) {
                        Text("\(rank + 1)")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: labelSize, height: cell)
                        ForEach(files, id: \.self) { file in
                            squareView(file: file, rank: rank, size: cell)
                        }
                    }
                }
                HStack(spacing: 0) {
                    Spacer().frame(width: labelSize)
                    ForEach(files, id: \.self) { file in
                        Text("\(Square.fileLetters[file])·\(file + 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: cell, height: labelSize)
                    }
                }
            }
            .frame(width: labelSize + cell * 8, height: labelSize + cell * 8)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func squareView(file: Int, rank: Int, size: CGFloat) -> some View {
        let index = rank * 8 + file
        ZStack {
            Rectangle().fill((file + rank) % 2 == 0 ? darkSquare : lightSquare)

            if let m = lastMove, index == m.from || index == m.to {
                Rectangle().fill(Color.yellow.opacity(0.35))
            }
            if index == selected {
                Rectangle().fill(Color.blue.opacity(0.45))
            }
            if index == checkSquare {
                Rectangle().fill(Color.red.opacity(0.55))
            }
            if targets.contains(index) {
                Circle()
                    .fill(Color.green.opacity(0.6))
                    .frame(width: size * 0.3, height: size * 0.3)
            }
            if let piece = board[index] {
                pieceView(piece, size: size)
            }
        }
        .frame(width: size, height: size)
    }

    private func pieceView(_ piece: Piece, size: CGFloat) -> some View {
        // Solid glyphs for both colours. The trailing U+FE0E forces text (not emoji)
        // rendering - without it iOS draws the pawn as a colour emoji.
        Text(glyph(for: piece.type) + "\u{FE0E}")
            .font(.system(size: size * 0.78))
            .foregroundColor(piece.color == .white ? .white : .black)
            .shadow(color: piece.color == .white ? Color.black : Color.clear, radius: 1)
            .shadow(color: piece.color == .white ? Color.black : Color.clear, radius: 1)
    }

    private func glyph(for type: PieceType) -> String {
        switch type {
        case .king: return "\u{265A}"
        case .queen: return "\u{265B}"
        case .rook: return "\u{265C}"
        case .bishop: return "\u{265D}"
        case .knight: return "\u{265E}"
        case .pawn: return "\u{265F}"
        }
    }
}
