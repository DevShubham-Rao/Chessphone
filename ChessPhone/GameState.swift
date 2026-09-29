import SwiftUI
import Combine
import UIKit

enum InputPhase: Equatable {
    case selectSide
    case opponentSourceColumn, opponentSourceRow
    case opponentTargetColumn, opponentTargetRow
    case promotion
    case engineCalculating
    case engineFailed
    case gameOver
}

/// The engine always advises the user; the user only ever types in the OPPONENT's moves.
///   White: engine recommends the first move right away, then waits for the opponent's reply.
///   Black: app waits for White's first move, then the engine recommends the reply.
///
/// Input scheme
///   Volume UP        : count taps (columns 1-8 = a-h, rows 1-8, promotion 1-4)
///   Volume DOWN      : confirm the count and go to the next step
///   0 taps + confirm : cancel the move you're entering
///   Shake            : replay the engine's last move as haptics
///
/// Columns/rows are always real board coordinates (a1 = 1,1 ... h8 = 8,8),
/// regardless of which side you play. Only the on-screen board flips.
@MainActor
final class ChessPhoneViewModel: ObservableObject {
    @Published private(set) var phase: InputPhase = .selectSide
    @Published private(set) var tapCount: Int = 0
    @Published private(set) var playerColor: PieceColor = .white
    @Published private(set) var game = ChessGame()
    @Published private(set) var lastMove: Move?
    @Published private(set) var selectedSquare: Int?
    @Published private(set) var legalTargets: Set<Int> = []
    @Published private(set) var status: String = "Choose your side."
    @Published private(set) var engineStatus: String = "Engine: starting..."
    @Published private(set) var lastEngineMove: String = ""
    @Published private(set) var recommendedMoveText: String = ""
    @Published private(set) var hapticVisualStage: HapticEngine.VisualStage = .idle

    // Half-entered move (0-based file / rank)
    private var sourceFile = 0
    private var sourceRank = 0
    private var targetFile = 0
    private var promotionCandidates: [Move] = []

    private var engineTask: Task<Void, Never>?
    /// Bumped on every new game so a late engine answer from an old game is ignored.
    private var gameGeneration = 0
    private let shake = ShakeDetector()
    private var inputsRunning = false

    // MARK: - Lifecycle

    func startInputs() {
        guard !inputsRunning else { return }
        inputsRunning = true

        // Mirror every haptic step on the board so the visual and physical
        // instructions stay synchronized.
        HapticEngine.shared.onVisualStage = { [weak self] stage in
            self?.hapticVisualStage = stage
        }

        VolumeButtonHandler.shared.onVolumeUp = { [weak self] in
            Task { @MainActor in self?.handleVolumeUp() }
        }
        VolumeButtonHandler.shared.onVolumeDown = { [weak self] in
            Task { @MainActor in self?.handleVolumeDown() }
        }
        VolumeButtonHandler.shared.start()

        shake.onShake = { [weak self] in
            Task { @MainActor in self?.handleShakeRepeat() }
        }
        shake.start()

        // Volume buttons only work while the screen is on and the app is active.
        UIApplication.shared.isIdleTimerDisabled = true

        Task { await warmUpEngine() }
    }

    func stopInputs() {
        inputsRunning = false
        VolumeButtonHandler.shared.stop()
        shake.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func warmUpEngine() async {
        engineStatus = "Engine: starting..."
        let ok = await EngineManager.shared.ensureStarted()
        engineStatus = ok ? "Engine: Stockfish ready" : "Engine: FAILED - \(EngineManager.shared.lastError)"
    }

    // MARK: - Screen text

    var phasePrompt: String {
        switch phase {
        case .selectSide: return "Choose your side"
        case .opponentSourceColumn: return "OPPONENT FROM column (1=a ... 8=h)"
        case .opponentSourceRow: return "OPPONENT FROM row (1-8)"
        case .opponentTargetColumn: return "OPPONENT TO column (1=a ... 8=h)"
        case .opponentTargetRow: return "OPPONENT TO row (1-8)"
        case .promotion: return "OPPONENT PROMOTES to (1=Q 2=R 3=B 4=N)"
        case .engineCalculating: return "Engine is thinking..."
        case .engineFailed: return "Engine problem"
        case .gameOver: return "Game over"
        }
    }

    /// What the current tap count means for the current step, e.g. "3 = c".
    var inputPreview: String {
        guard tapCount > 0 else { return "-" }
        switch phase {
        case .opponentSourceColumn, .opponentTargetColumn:
            return "\(tapCount) = \(Square.fileLetters[min(tapCount, 8) - 1])"
        case .promotion:
            let names = [1: "Queen", 2: "Rook", 3: "Bishop", 4: "Knight"]
            return "\(tapCount) = \(names[tapCount] ?? "?")"
        default:
            return "\(tapCount)"
        }
    }

    // MARK: - Hardware input

    func handleVolumeUp() {
        switch phase {
        case .opponentSourceColumn, .opponentSourceRow, .opponentTargetColumn, .opponentTargetRow, .promotion:
            let limit = phase == .promotion ? 4 : 8
            if tapCount >= limit {
                HapticEngine.shared.error()
                status = "Maximum is \(limit)."
                return
            }
            tapCount += 1
            HapticEngine.shared.tick()
        default:
            break
        }
    }

    func handleVolumeDown() {
        switch phase {
        case .opponentSourceColumn, .opponentSourceRow, .opponentTargetColumn, .opponentTargetRow, .promotion:
            confirmInput()
        case .engineFailed:
            retryEngine()
        default:
            break
        }
    }

    func handleShakeRepeat() {
        guard phase != .selectSide, !lastEngineMove.isEmpty, let move = Move(uci: lastEngineMove) else { return }
        playHaptics(for: move, suffix: .none)
    }

    // MARK: - Setup / buttons

    func selectColor(_ color: PieceColor) {
        guard phase == .selectSide else { return }
        resetGameState()
        playerColor = color
        if color == .white {
            // White moves first: the engine recommends the opening move.
            startRecommendation()
        } else {
            // Black: White (your opponent) moves first. Wait for the user to enter it.
            phase = .opponentSourceColumn
            status = "You are Black. Enter White's first move: FROM column."
        }
    }

    func newGame() {
        gameGeneration += 1
        engineTask?.cancel()
        engineTask = nil
        EngineManager.shared.cancelSearch()
        HapticEngine.shared.cancel()
        resetGameState()
        phase = .selectSide
        status = "Choose your side."
    }

    func retryEngine() {
        guard phase == .engineFailed else { return }
        engineStatus = "Engine: retrying..."
        startRecommendation()
    }

    private func resetGameState() {
        game = ChessGame()
        lastMove = nil
        selectedSquare = nil
        legalTargets = []
        promotionCandidates = []
        lastEngineMove = ""
        recommendedMoveText = ""
        tapCount = 0
    }

    // MARK: - Opponent move entry

    /// Bad input for the current step: buzz, explain, stay on the same step.
    private func reject(_ message: String) {
        status = message
        HapticEngine.shared.error()
    }

    // MARK: - Engine recommendation flow
    //
    // Works for either colour. The engine's move is applied to the internal
    // position so the opponent's reply can be validated, but it is only
    // *recommended* to the user. The user only enters the opponent's moves.
    private func startRecommendation() {
        phase = .engineCalculating
        tapCount = 0
        status = "Engine is finding your best move..."
        recommendedMoveText = ""

        let generation = gameGeneration
        engineTask?.cancel()
        engineTask = Task { [weak self] in
            await self?.runRecommendation(generation: generation)
        }
    }

    private func runRecommendation(generation: Int) async {
        let fen = game.fen
        var chosen: Move?
        var failure = ""

        for _ in 0..<2 {
            let reply = await EngineManager.shared.bestMove(fen: fen)
            guard generation == gameGeneration else { return }

            guard let uci = reply else {
                failure = EngineManager.shared.lastError
                continue
            }
            if let move = game.legalMove(uci: uci) {
                chosen = move
                break
            }
            failure = "Stockfish replied '\(uci)', which is not legal here."
        }

        guard generation == gameGeneration else { return }

        guard let move = chosen, game.play(move) else {
            phase = .engineFailed
            engineStatus = "Engine: \(failure.isEmpty ? "unknown failure" : failure)"
            status = "The engine could not find your move. Press volume down (or the Retry button) to try again."
            HapticEngine.shared.error()
            return
        }

        engineStatus = "Engine: Stockfish ready"
        lastMove = move
        lastEngineMove = move.uci
        recommendedMoveText = move.uci.uppercased()

        if let outcome = game.outcome {
            status = "Your recommended move ends the game. \(outcome.summary)"
            phase = .gameOver
            playHaptics(for: move, suffix: .gameOver)
            return
        }

        phase = .opponentSourceColumn
        status = "Play \(move.uci) as \(playerColor.name). Then enter your opponent's move."
        playHaptics(for: move, suffix: game.isInCheck ? .check : .none)
    }

    private func confirmInput() {
        let count = tapCount
        tapCount = 0

        if count == 0 {
            if phase == .opponentSourceColumn {
                reject("Nothing entered. Tap volume up 1-8 times (1=a ... 8=h), then volume down.")
            } else {
                cancelOpponentMoveEntry("Opponent move cancelled. Enter their FROM column again.")
            }
            return
        }

        switch phase {
        case .opponentSourceColumn:
            guard count <= 8 else { reject("Columns are 1-8."); return }
            sourceFile = count - 1
            phase = .opponentSourceRow
            status = "Opponent from column \(Square.fileLetters[sourceFile]). Now their FROM row."
            HapticEngine.shared.confirm()

        case .opponentSourceRow:
            guard count <= 8 else { reject("Rows are 1-8."); return }
            sourceRank = count - 1
            let from = Square.index(file: sourceFile, rank: sourceRank)
            let moves = game.legalMoves(from: from)
            guard !moves.isEmpty else {
                cancelOpponentMoveEntry("\(Square.name(from)): no legal opponent move. Start again.")
                return
            }
            selectedSquare = from
            legalTargets = Set(moves.map { $0.to })
            phase = .opponentTargetColumn
            status = "Opponent from \(Square.name(from)). Now their TO column."
            HapticEngine.shared.confirm()

        case .opponentTargetColumn:
            guard count <= 8 else { reject("Columns are 1-8."); return }
            targetFile = count - 1
            phase = .opponentTargetRow
            status = "Opponent to column \(Square.fileLetters[targetFile]). Now their TO row."
            HapticEngine.shared.confirm()

        case .opponentTargetRow:
            guard count <= 8 else { reject("Rows are 1-8."); return }
            let from = Square.index(file: sourceFile, rank: sourceRank)
            let to = Square.index(file: targetFile, rank: count - 1)
            let candidates = game.legalMoves(from: from).filter { $0.to == to }

            guard !candidates.isEmpty else {
                cancelOpponentMoveEntry("Illegal opponent move: \(Square.name(from)) to \(Square.name(to)). Start again.")
                return
            }

            if candidates.count > 1 || candidates[0].promotion != nil {
                promotionCandidates = candidates
                phase = .promotion
                status = "Opponent promotion: 1=Queen 2=Rook 3=Bishop 4=Knight, then volume down."
                HapticEngine.shared.confirm()
            } else {
                commitOpponentMove(candidates[0])
            }

        case .promotion:
            guard let piece = PieceType.fromPromotionCode(count),
                  let move = promotionCandidates.first(where: { $0.promotion == piece }) else {
                reject("Promotion choices are 1=Queen 2=Rook 3=Bishop 4=Knight.")
                return
            }
            commitOpponentMove(move)

        default:
            break
        }
    }

    private func commitOpponentMove(_ move: Move) {
        guard game.play(move) else {
            cancelOpponentMoveEntry("That opponent move was illegal. Start again.")
            return
        }

        lastMove = move
        selectedSquare = nil
        legalTargets = []
        promotionCandidates = []
        HapticEngine.shared.confirm()

        if let outcome = game.outcome {
            finishGame(outcome)
        } else {
            startRecommendation()
        }
    }

    private func cancelOpponentMoveEntry(_ message: String) {
        phase = .opponentSourceColumn
        selectedSquare = nil
        legalTargets = []
        promotionCandidates = []
        tapCount = 0
        status = message
        HapticEngine.shared.error()
    }

    private func finishGame(_ outcome: GameOutcome) {
        phase = .gameOver
        selectedSquare = nil
        legalTargets = []
        status = "Opponent played \(lastMove?.uci ?? ""). \(outcome.summary)"
        HapticEngine.shared.playGameOver()
    }

    // MARK: - Haptic output

    private func playHaptics(for move: Move, suffix: HapticEngine.Suffix) {
        HapticEngine.shared.playMove(
            fromFile: Square.file(move.from) + 1,
            fromRank: Square.rank(move.from) + 1,
            toFile: Square.file(move.to) + 1,
            toRank: Square.rank(move.to) + 1,
            promotion: move.promotion?.promotionCode ?? 0,
            suffix: suffix
        )
    }
}
