import SwiftUI

/// Always draws in absolute orientation (White's side at the bottom) -
/// this is a debugging ground-truth, so it deliberately does NOT flip
/// for a Black player the way the haptic input/output does.
struct DebugBoardView: View {
    let board: BoardModel

    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { rankIdx in
                HStack(spacing: 2) {
                    ForEach(0..<8, id: \.self) { file in
                        Text(board.symbol(rankFromTop: rankIdx, file: file))
                            .font(.system(size: 14, design: .monospaced))
                            .frame(width: 16, height: 16)
                    }
                }
            }
        }
        .padding(6)
        .background(Color.gray.opacity(0.15))
        .cornerRadius(6)
    }
}
