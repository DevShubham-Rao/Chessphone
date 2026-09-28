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

    private var sourceCol = 0
    private var sourceRow = 0
    private var targetCol = 0
    private var targetRow = 0

    private var currentFEN = "start"
    private var lastEngineMove = ""

    func handleVolumeUp() {
        guard phase != .selectSide, phase != .engineCalculating else { return }
        tapCount += 1
        HapticEngine.shared.playMove(fromCol: 1, fromRow: 0, toCol: 0, toRow: 0) // single quick tick
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
            sendMoveToEngine("e2e4")
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
        let move = "\(numberToCol(sourceCol))\(sourceRow)\(numberToCol(targetCol))\(targetRow)"
        phase = .engineCalculating
        sendMoveToEngine(move)
    }

    private func sendMoveToEngine(_ move: String) {
        Task.detached(priority: .userInitiated) {
            let reply = StubEngine.bestMove(forFEN: self.currentFEN)
            await MainActor.run {
                self.lastEngineMove = reply
                self.playHapticsForEngineMove(reply)
                self.phase = .sourceColumn
            }
        }
    }

    private func playHapticsForEngineMove(_ move: String) {
        guard move.count == 4 else { return }
        let chars = Array(move)
        let fromCol = colToNumber(String(chars[0]))
        let fromRow = Int(String(chars[1])) ?? 0
        let toCol = colToNumber(String(chars[2]))
        let toRow = Int(String(chars[3])) ?? 0
        HapticEngine.shared.playMove(fromCol: fromCol, fromRow: fromRow, toCol: toCol, toRow: toRow)
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
