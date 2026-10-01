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
    let hapticStage: HapticEngine.VisualStage
    /// Black seat numbering: labels read a...h left to right and 1...8 bottom to top
    /// as seen from Black's seat. (Squares themselves are drawn the same either way.)
    var seatFlipped: Bool = false

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
                        Text("\(seatFlipped ? 8 - rank : rank + 1)")
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
                        Text("\(Square.fileLetters[seatFlipped ? 7 - file : file])·\(seatFlipped ? 8 - file : file + 1)")
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

            // Visual mirror of the haptic counter:
            // file counting sweeps a...h, rank counting sweeps 1...8.
            // The current item is brighter; previous items remain lightly marked.
            hapticOverlay(file: file, rank: rank, size: size)

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

    @ViewBuilder
    private func hapticOverlay(file: Int, rank: Int, size: CGFloat) -> some View {
        let state = hapticStateFor(file: file, rank: rank)
        switch state {
        case .none:
            EmptyView()
        case .past:
            Rectangle()
                .fill(Color.blue.opacity(0.18))
                .overlay(Rectangle().stroke(Color.blue.opacity(0.35), lineWidth: 1))
        case .current:
            Rectangle()
                .fill(Color.blue.opacity(0.52))
                .overlay(Rectangle().stroke(Color.white, lineWidth: 3))
        case .switchMarker:
            Rectangle()
                .fill(Color.orange.opacity(0.45))
                .overlay(Rectangle().stroke(Color.white, lineWidth: 3))
        case .done:
            Rectangle()
                .fill(Color.green.opacity(0.45))
                .overlay(Rectangle().stroke(Color.white, lineWidth: 3))
        }
    }

    private enum HapticCellState { case none, past, current, switchMarker, done }

    private func hapticStateFor(file realFile: Int, rank realRank: Int) -> HapticCellState {
        // The vibration counts in seat numbering, so sweep in that numbering too.
        let file = seatFlipped ? 7 - realFile : realFile
        let rank = seatFlipped ? 7 - realRank : realRank
        switch hapticStage {
        case .idle:
            return .none
        case .fromFile(let n):
            guard n > 0 else { return .none }
            if file < n - 1 { return .past }
            if file == n - 1 { return .current }
            return .none
        case .fromRank(let n):
            guard n > 0 else { return .none }
            if rank < n - 1 { return .past }
            if rank == n - 1 { return .current }
            return .none
        case .switchMarker:
            // Flash the entire board while the long SWITCH vibration plays.
            return .switchMarker
        case .toFile(let n):
            guard n > 0 else { return .none }
            if file < n - 1 { return .past }
            if file == n - 1 { return .current }
            return .none
        case .toRank(let n):
            guard n > 0 else { return .none }
            if rank < n - 1 { return .past }
            if rank == n - 1 { return .current }
            return .none
        case .done:
            return .done
        }
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
