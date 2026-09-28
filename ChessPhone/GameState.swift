import SwiftUI
import Combine

enum InputPhase {
    case selectSide
    case sourceColumn, sourceRow
    case targetColumn, targetRow
    case engineCalculating
}

@MainActor
class ChessPhoneViewModel: ObservableObject {
    @Published var phase: InputPhase = .selectSide
    @Published var tapCount: Int = 0
    @Published var playerColor: String = ""
    @Published var board = BoardModel()

    private var sourceCol = 0
    private var sourceRow = 0
    private var targetCol = 0
    private var targetRow = 0

    private var moveHistory: [String] = []
    private var lastEngineMove = ""

    func handleVolumeUp() {
        guard phase != .selectSide, phase != .engineCalculating else { return }
        tapCount += 1
        HapticEngine.shared.tapTick()
    }

    func handleVolumeDown() {
        guard phase != .selectSide, phase != .engineCalculating else { return }
        advancePhase()
    }

    func handleShakeRepeat() {
        guard !lastEngineMove.isEmpty else { return }
        playHapticsForEngineMove(lastEngineMove)
    }

    func selectColor(_ color: String) {
        playerColor = color
        if color == "WHITE" {
            sendMoveToEngine("e2e4") // already absolute - White's own view == absolute
        }
        phase = .sourceColumn
    }

    private func advancePhase() {
        switch phase {
        case .sourceColumn:
            sourceCol = tapCount; tapCount = 0; phase = .sourceRow
        case .sourceRow:
            sourceRow = tapCount; tapCount = 0; phase = .targetColumn
        case .targetColumn:
            targetCol = tapCount; tapCount = 0; phase = .targetRow
        case .targetRow:
            targetRow = tapCount; tapCount = 0; processPlayerMove()
        default:
            break
        }
    }

    private func processPlayerMove() {
        // Taps are entered from the PLAYER's own side of the board.
        // Convert to absolute board coordinates before building the
        // UCI move string that goes to the engine and the debug board.
        let (absSourceCol, absSourceRow) = toAbsolute(col: sourceCol, row: sourceRow)
        let (absTargetCol, absTargetRow) = toAbsolute(col: targetCol, row: targetRow)
        let move = "\(numberToCol(absSourceCol))\(absSourceRow)\(numberToCol(absTargetCol))\(absTargetRow)"
        phase = .engineCalculating
        sendMoveToEngine(move)
    }

    /// Expects and produces ABSOLUTE UCI move strings (engine's own
    /// coordinate system). Perspective conversion happens at the edges:
    /// processPlayerMove() converts taps -> absolute before calling this,
    /// playHapticsForEngineMove() converts absolute -> player view after.
    private func sendMoveToEngine(_ absoluteMove: String) {
        moveHistory.append(absoluteMove)
        board.apply(uciMove: absoluteMove)
        Task {
            await EngineManager.shared.start()
            let reply = await EngineManager.shared.bestMove(forMoveHistory: moveHistory) ?? "e7e5"
            moveHistory.append(reply)
            board.apply(uciMove: reply)
            self.lastEngineMove = reply
            self.playHapticsForEngineMove(reply)
            self.phase = .sourceColumn
        }
    }

    private func playHapticsForEngineMove(_ absoluteMove: String) {
        guard absoluteMove.count == 4 else { return }
        let chars = Array(absoluteMove)
        let absFromCol = colToNumber(String(chars[0]))
        let absFromRow = Int(String(chars[1])) ?? 0
        let absToCol = colToNumber(String(chars[2]))
        let absToRow = Int(String(chars[3])) ?? 0

        // Convert back to the PLAYER's own side before relaying via haptics.
        let (fromCol, fromRow) = toAbsolute(col: absFromCol, row: absFromRow)
        let (toCol, toRow) = toAbsolute(col: absToCol, row: absToRow)

        HapticEngine.shared.playMove(fromCol: fromCol, fromRow: fromRow, toCol: toCol, toRow: toRow)
    }

    /// A 180-degree board flip is its own inverse, so this single
    /// function converts player-view <-> absolute in both directions.
    /// White's own view already matches absolute, so it's a no-op for White.
    private func toAbsolute(col: Int, row: Int) -> (Int, Int) {
        guard playerColor == "BLACK" else { return (col, row) }
        return (9 - col, 9 - row)
    }

    private func numberToCol(_ num: Int) -> String {
        let cols = ["a","b","c","d","e","f","g","h"]
        guard num >= 1 && num <= 8 else { return "a" }
        return cols[num - 1]
    }

    private func colToNumber(_ col: String) -> Int {
        let cols = ["a","b","c","d","e","f","g","h"]
        return (cols.firstIndex(of: col) ?? 0) + 1
    }
}
