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
private struct SavedGame: Codable {
    let moves: [String]
    let playerColor: Int
    let skillLevel: Int
    let searchDepth: Int?
    let startingFEN: String?
    let pendingRecommendation: Bool?
}

private enum GameSaveStore {
    static let key = "ChessPhone.savedGame"

    static func save(game: ChessGame, playerColor: PieceColor, skillLevel: Int, searchDepth: Int, pendingRecommendation: Bool) {
        let payload = SavedGame(
            moves: game.moveHistory.map(\.uci),
            playerColor: playerColor.rawValue,
            skillLevel: skillLevel,
            searchDepth: searchDepth,
            startingFEN: game.startingPosition.fen,
            pendingRecommendation: pendingRecommendation
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> SavedGame? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(SavedGame.self, from: data) else { return nil }
        return saved
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

@MainActor
final class ChessPhoneViewModel: ObservableObject {
    @Published private(set) var phase: InputPhase = .selectSide { didSet { publishSessionState() } }
    @Published private(set) var tapCount: Int = 0
    @Published private(set) var playerColor: PieceColor = .white
    @Published private(set) var game = ChessGame() { didSet { publishSessionState() } }
    @Published private(set) var lastMove: Move?
    @Published private(set) var selectedSquare: Int?
    @Published private(set) var legalTargets: Set<Int> = []
    @Published private(set) var status: String = "Choose your side." { didSet { publishSessionState() } }
    @Published private(set) var engineStatus: String = "Engine: starting..."
    @Published private(set) var lastEngineMove: String = ""
    @Published private(set) var recommendedMoveText: String = ""
    @Published private(set) var hapticVisualStage: HapticEngine.VisualStage = .idle
    @Published private(set) var scanStatus: String = ""
    @Published private(set) var sessionPaused = false
    @Published private(set) var trackingLost = false
    @Published private(set) var suggestionEvaluationText = ""
    @Published private(set) var suggestionConfidence = 0.5
    /// Stockfish "Skill Level" 1...20 (20 = full strength).
    @Published var skillLevel: Int = 20 {
        didSet { UserDefaults.standard.set(skillLevel, forKey: "ChessPhone.skillLevel") }
    }
    /// How deep Stockfish searches, 1...30.
    @Published var searchDepth: Int = 30 {
        didSet { UserDefaults.standard.set(searchDepth, forKey: "ChessPhone.searchDepth") }
    }
    /// When playing Black: number the board from your own seat
    /// (a/1 = bottom-left as you see it) instead of true board coordinates.
    @Published var blackSeatNumbering: Bool = true {
        didSet { UserDefaults.standard.set(blackSeatNumbering, forKey: "ChessPhone.blackSeatNumbering") }
    }
    @Published private(set) var hasSavedGame = false

    /// True when the board is drawn from Black's seat AND coordinates are numbered from that seat.
    var seatFlipped: Bool { playerColor == .black && blackSeatNumbering }

    // Half-entered move (0-based file / rank)
    private var sourceFile = 0
    private var sourceRank = 0
    private var targetFile = 0
    private var promotionCandidates: [Move] = []

    private var engineTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var visionEnabledCancellable: AnyCancellable?
    private var visionSourceCancellable: AnyCancellable?
    private var visionStateCancellable: AnyCancellable?
    private var budgetCancellable: AnyCancellable?
    private var engineFailureAnnounced = false
    private var watchRevision = 0
    /// Position on the physical board before the engine's latest recommendation.
    /// We keep it so the camera can tell whether the user has played that move yet.
    private var pendingOwnMoveFromPosition: Position?
    /// Bumped on every new game so a late engine answer from an old game is ignored.
    private var gameGeneration = 0
    private let shake = ShakeDetector()
    private var inputsRunning = false
    /// What was last announced out loud, so shaking the phone can repeat it.
    private var lastSpokenText = ""

    init() {
        let d = UserDefaults.standard
        if let v = d.object(forKey: "ChessPhone.skillLevel") as? Int { skillLevel = max(1, min(v, 20)) }
        if let v = d.object(forKey: "ChessPhone.searchDepth") as? Int { searchDepth = max(1, min(v, 30)) }
        if let v = d.object(forKey: "ChessPhone.blackSeatNumbering") as? Bool { blackSeatNumbering = v }
        if GameSaveStore.load() != nil {
            hasSavedGame = true
        }

        visionEnabledCancellable = VisionCoordinator.shared.$enabled
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncContinuousWatch() }
            }
        visionSourceCancellable = VisionCoordinator.shared.$sourceKind
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncContinuousWatch() }
            }
        visionStateCancellable = VisionCoordinator.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.publishSessionState() }
        }
        budgetCancellable = VisionCoordinator.shared.$isBudgetPaused.removeDuplicates().sink { [weak self] paused in
            Task { @MainActor in
                guard let self, paused, self.phase != .selectSide else { return }
                self.pauseSession()
                self.status = "Estimated spending limit reached. Paused. Resume authorizes another budget allowance."
                self.sessionEvent(.problem, "Estimated spending limit reached")
                if SpeechEngine.shared.enabled { SpeechEngine.shared.speak("Spending limit reached. Paused.") }
            }
        }
    }

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
        syncContinuousWatch()
    }

    func stopInputs() {
        inputsRunning = false
        scanTask?.cancel()
        scanTask = nil
        watchTask?.cancel()
        watchTask = nil
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

    func handleVolumeUp(manual: Bool = false) {
        guard !sessionPaused else { return }
        switch phase {
        case .opponentSourceColumn, .opponentSourceRow, .opponentTargetColumn, .opponentTargetRow, .promotion:
            let limit = phase == .promotion ? 4 : 8
            if tapCount >= limit {
                status = "Maximum is \(limit)."
                HapticEngine.shared.error(status)
                return
            }
            tapCount += 1
            HapticEngine.shared.tick()
        default:
            break
        }
    }

    func handleVolumeDown() {
        guard !sessionPaused else { return }
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
        deliver(move: move, suffix: .none, spoken: lastSpokenText)
    }

    // MARK: - Setup / buttons

    func selectColor(_ color: PieceColor) {
        guard phase == .selectSide else { return }
        resetGameState()
        playerColor = color
        VisionCoordinator.shared.resetSessionBudget()
        SessionJournal.shared.startSession(playerColor: color, initialFEN: game.fen)
        if color == .white {
            // White moves first: the engine recommends the opening move.
            startRecommendation()
        } else {
            // Black: White (your opponent) moves first. Wait for the user to enter it.
            phase = .opponentSourceColumn
            status = "You are Black. Enter White's first move: FROM column."
        }
        syncContinuousWatch()
        autosave()
    }

    func newGame() {
        SessionJournal.shared.finishSession()
        gameGeneration += 1
        engineTask?.cancel()
        engineTask = nil
        scanTask?.cancel()
        scanTask = nil
        watchTask?.cancel()
        watchTask = nil
        pendingOwnMoveFromPosition = nil
        EngineManager.shared.cancelSearch()
        HapticEngine.shared.cancel()
        SpeechEngine.shared.stop()
        resetGameState()
        GameSaveStore.clear()
        hasSavedGame = false
        phase = .selectSide
        status = "Choose your side."
    }

    /// Manual save (Save button).
    func saveCurrentGame() {
        guard phase != .selectSide else { return }
        autosave()
        status = "Game saved."
    }

    /// Silent save after every move; never touches the on-screen instructions.
    private func autosave() {
        guard phase != .selectSide else { return }
        GameSaveStore.save(game: game, playerColor: playerColor,
                           skillLevel: skillLevel, searchDepth: searchDepth,
                           pendingRecommendation: pendingOwnMoveFromPosition != nil)
        hasSavedGame = true
        SessionJournal.shared.writePGN(confirmedGame.pgn(playerColor: playerColor))
        publishSessionState()
    }

    /// After loading or taking back moves: if the last move was the engine's,
    /// remember it so Shake can replay it.
    private func syncEngineMemory() {
        if let last = game.moveHistory.last, game.sideToMove != playerColor {
            lastEngineMove = last.uci
            let suffix: HapticEngine.Suffix = game.outcome != nil ? .gameOver : (game.isInCheck ? .check : .none)
            lastSpokenText = SpeechEngine.shared.phrase(for: seatMove(last), piece: game.board[last.to]?.type,
                                                        captured: nil, suffix: suffix, outcome: game.outcome,
                                                        mirrored: seatFlipped)
        } else {
            lastEngineMove = ""
            lastSpokenText = ""
        }
    }

    private func restorePendingPhysicalRecommendation() {
        pendingOwnMoveFromPosition = nil
        guard game.sideToMove != playerColor, let last = game.moveHistory.last else { return }
        let prior = ChessGame(startingPosition: game.startingPosition, moves: Array(game.moveHistory.dropLast()))
        if prior.position.sideToMove == playerColor,
           prior.position.board[last.from]?.color == playerColor {
            pendingOwnMoveFromPosition = prior.position
        }
    }

    func resumeSavedGame() {
        guard let saved = GameSaveStore.load(),
              let color = PieceColor(rawValue: saved.playerColor) else {
            hasSavedGame = false
            return
        }

        gameGeneration += 1
        engineTask?.cancel()
        engineTask = nil
        scanTask?.cancel()
        scanTask = nil
        EngineManager.shared.cancelSearch()
        HapticEngine.shared.cancel()
        SpeechEngine.shared.stop()

        let moves = saved.moves.compactMap { Move(uci: $0) }
        guard moves.count == saved.moves.count,
              let initial = try? Position(fen: saved.startingFEN ?? Position.start.fen) else {
            status = "The saved game contains an invalid position or move."
            return
        }
        let rebuilt = ChessGame(startingPosition: initial, moves: moves)

        // Only accept a save if every recorded move rebuilt cleanly.
        guard rebuilt.moveHistory.count == moves.count else {
            GameSaveStore.clear()
            hasSavedGame = false
            status = "The saved game could not be restored."
            return
        }

        playerColor = color
        skillLevel = max(1, min(saved.skillLevel, 20))
        if let depth = saved.searchDepth { searchDepth = max(1, min(depth, 30)) }
        game = rebuilt
        sessionPaused = false
        trackingLost = false
        VisionCoordinator.shared.resetSessionBudget()
        SessionJournal.shared.startSession(playerColor: color, initialFEN: initial.fen)
        lastMove = game.moveHistory.last
        pendingOwnMoveFromPosition = nil
        selectedSquare = nil
        legalTargets = []
        promotionCandidates = []
        tapCount = 0
        recommendedMoveText = lastMove.map { seatText($0.uci).uppercased() } ?? ""
        hasSavedGame = true
        syncEngineMemory()

        if saved.pendingRecommendation ?? true { restorePendingPhysicalRecommendation() }
        if pendingOwnMoveFromPosition == nil {
            recommendedMoveText = ""
            lastEngineMove = ""
            lastSpokenText = ""
        }
        if game.outcome != nil && pendingOwnMoveFromPosition == nil {
            phase = .gameOver
            status = game.outcome?.summary ?? "Game over."
        } else if game.sideToMove == playerColor {
            startRecommendation()
        } else {
            // Saves include the engine's recommended move immediately. After relaunch,
            // the physical board may still be one move behind, so retain that prior board
            // as the expected "you have not played the advice yet" position.
            phase = .opponentSourceColumn
            status = "Saved game restored. Enter your opponent's FROM column."
        }
        syncContinuousWatch()
        autosave()
    }

    /// Cancels partial entry. Otherwise removes the latest confirmed move and
    /// any pending advice, then re-analyzes if it is the player's turn.
    func undo() {
        guard phase != .selectSide else { return }

        // Cancel a partially entered move without changing the board.
        let midEntry: [InputPhase] = [.opponentSourceRow, .opponentTargetColumn,
                                      .opponentTargetRow, .promotion]
        if midEntry.contains(phase) || (phase == .opponentSourceColumn && tapCount > 0) {
            selectedSquare = nil
            legalTargets = []
            promotionCandidates = []
            tapCount = 0
            phase = .opponentSourceColumn
            status = "Move entry cancelled. Enter your opponent's FROM column."
            return
        }

        guard !game.moveHistory.isEmpty else { status = "No moves to undo."; return }
        let hasPendingAdvice = suggestionMove != nil
        gameGeneration += 1
        engineTask?.cancel()
        engineTask = nil
        scanTask?.cancel()
        scanTask = nil
        EngineManager.shared.cancelSearch()
        HapticEngine.shared.cancel()
        SpeechEngine.shared.stop()

        var moves = game.moveHistory
        let pliesToRemove = hasPendingAdvice ? 2 : 1

        moves.removeLast(min(pliesToRemove, moves.count))

        game = ChessGame(startingPosition: game.startingPosition, moves: moves)
        pendingOwnMoveFromPosition = nil
        trackingLost = false
        suggestionEvaluationText = ""
        sessionEvent(.undo, "Takeback applied")
        lastMove = game.moveHistory.last
        selectedSquare = nil
        legalTargets = []
        promotionCandidates = []
        tapCount = 0
        recommendedMoveText = ""
        lastEngineMove = ""
        lastSpokenText = ""

        if game.outcome != nil {
            phase = .gameOver
            status = game.outcome?.summary ?? "Game over."
        } else if game.sideToMove == playerColor {
            startRecommendation()
        } else {
            phase = .opponentSourceColumn
            status = "Takeback complete. Enter your opponent's FROM column."
        }
        autosave()
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
        lastSpokenText = ""
        recommendedMoveText = ""
        tapCount = 0
        pendingOwnMoveFromPosition = nil
        sessionPaused = false
        trackingLost = false
        suggestionEvaluationText = ""
        suggestionConfidence = 0.5
        engineFailureAnnounced = false
    }

    // MARK: - Opponent move entry

    /// Bad input for the current step: buzz, explain, stay on the same step.
    private func reject(_ message: String) {
        status = message
        HapticEngine.shared.error(message)
    }

    // MARK: - Engine recommendation flow
    //
    // Works for either colour. The engine's move is applied to the internal
    // position so the opponent's reply can be validated, but it is only
    // *recommended* to the user. The user only enters the opponent's moves.
    private func startRecommendation() {
        guard game.outcome == nil, game.sideToMove == playerColor else { return }
        suggestionEvaluationText = ""
        if sessionPaused { phase = .engineCalculating; return }
        pendingOwnMoveFromPosition = game.position
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
        ChessDebugLog.shared.record("ENGINE", "Stockfish request", details: "FEN: \(fen)\nDepth: \(searchDepth)\nSkill: \(skillLevel)/20\nSide to move: \(game.sideToMove.name)")
        var chosen: Move?
        var failure = ""

        do {
            let reply = await EngineManager.shared.bestMove(
                fen: fen,
                depth: searchDepth,
                skillLevel: skillLevel
            )
            guard !Task.isCancelled, generation == gameGeneration, !sessionPaused else { return }

            if let uci = reply, let move = game.legalMove(uci: uci) {
                chosen = move
                ChessDebugLog.shared.record("ENGINE RESPONSE", "Stockfish move accepted", details: "UCI: \(uci)\nFEN: \(fen)")
            } else {
                failure = EngineManager.shared.lastError
                if failure.isEmpty { failure = "Stockfish returned a missing or illegal move." }
                ChessDebugLog.shared.record("ENGINE ERROR", "Stockfish returned no move", details: "FEN: \(fen)\nError: \(failure)")
            }
        }

        guard generation == gameGeneration else { return }

        // Remember what is moving / being captured BEFORE the move changes the board
        // (used for the spoken version of the move).
        let mover = chosen.flatMap { game.board[$0.from]?.type }
        let captured = chosen.flatMap { capturedPiece(for: $0) }

        guard let move = chosen, game.play(move) else {
            pendingOwnMoveFromPosition = nil
            phase = .engineFailed
            engineStatus = "Engine: \(failure.isEmpty ? "unknown failure" : failure)"
            status = "The engine could not find your move. Press volume down (or the Retry button) to try again."
            HapticEngine.shared.error()
            sessionEvent(.problem, "Engine could not find a legal move", details: ["reason": failure])
            if !engineFailureAnnounced && SpeechEngine.shared.enabled {
                engineFailureAnnounced = true
                SpeechEngine.shared.speak("Something went wrong. Still trying.")
            }
            return
        }

        engineStatus = "Engine: Stockfish ready"
        lastMove = move
        lastEngineMove = move.uci
        recommendedMoveText = seatText(move.uci).uppercased()
        suggestionEvaluationText = EngineManager.shared.lastEvaluation?.displayText ?? "Evaluation unavailable"
        suggestionConfidence = EngineManager.shared.lastEvaluation?.confidence ?? 0.5
        engineFailureAnnounced = false
        sessionEvent(.suggestion, "Suggested \(pendingOwnMoveFromPosition?.san(for: move) ?? move.uci)",
                     details: ["uci": move.uci, "evaluation": suggestionEvaluationText])

        if let outcome = game.outcome {
            status = "Your recommended move ends the game. \(outcome.summary)"
            phase = .opponentSourceColumn
            announce(move, suffix: .gameOver, piece: mover, captured: captured)
            autosave()
            return
        }

        phase = .opponentSourceColumn
        status = "Play \(seatText(move.uci)) as \(playerColor.name). Then enter your opponent's move."
        autosave()
        announce(move, suffix: game.isInCheck ? .check : .none, piece: mover, captured: captured)
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
            sourceFile = seatFlipped ? 8 - count : count - 1
            phase = .opponentSourceRow
            status = "Opponent from column \(Square.fileLetters[count - 1]). Now their FROM row."
            HapticEngine.shared.confirm()

        case .opponentSourceRow:
            guard count <= 8 else { reject("Rows are 1-8."); return }
            sourceRank = seatFlipped ? 8 - count : count - 1
            let from = Square.index(file: sourceFile, rank: sourceRank)
            let moves = game.legalMoves(from: from)
            guard !moves.isEmpty else {
                ChessDebugLog.shared.record("MOVE CHECK", "Selected source square has no legal moves", details: "Selected: \(Square.name(from))\nSide to move: \(game.sideToMove.name)\nPosition FEN: \(game.fen)\nLegal moves from any square: \(game.legalMoves().map(\.uci).joined(separator: " "))")
                cancelOpponentMoveEntry("\(seatName(from)): no legal opponent move. Start again.")
                return
            }
            selectedSquare = from
            legalTargets = Set(moves.map { $0.to })
            phase = .opponentTargetColumn
            status = "Opponent from \(seatName(from)). Now their TO column."
            HapticEngine.shared.confirm()

        case .opponentTargetColumn:
            guard count <= 8 else { reject("Columns are 1-8."); return }
            targetFile = seatFlipped ? 8 - count : count - 1
            phase = .opponentTargetRow
            status = "Opponent to column \(Square.fileLetters[count - 1]). Now their TO row."
            HapticEngine.shared.confirm()

        case .opponentTargetRow:
            guard count <= 8 else { reject("Rows are 1-8."); return }
            let from = Square.index(file: sourceFile, rank: sourceRank)
            let to = Square.index(file: targetFile, rank: seatFlipped ? 8 - count : count - 1)
            let candidates = game.legalMoves(from: from).filter { $0.to == to }

            guard !candidates.isEmpty else {
                let requested = Move(from: from, to: to, promotion: nil).uci
                let allLegal = game.legalMoves().map(\.uci).sorted().joined(separator: " ")
                ChessDebugLog.shared.record("MOVE REJECTED", "Entered move is not legal in the tracked position", details: "Entered from view coordinates: \(seatName(from))\nEntered to view coordinates: \(seatName(to))\nAbsolute UCI: \(requested)\nPlayer side: \(playerColor.name)\nSide to move: \(game.sideToMove.name)\nSeat flipped: \(seatFlipped)\nPiece on source: \(game.board[from].map { String($0.fenChar) } ?? "empty")\nTracked FEN: \(game.fen)\nLegal moves from source: \(game.legalMoves(from: from).map(\.uci).joined(separator: " "))\nAll legal moves: \(allLegal)")
                cancelOpponentMoveEntry("Illegal opponent move: \(seatName(from)) to \(seatName(to)). Start again.")
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
        let notation = game.position.san(for: move)
        guard game.isLegal(move) else { reject("That move is not legal in the tracked position."); return }
        confirmRecommendedMove()
        guard game.play(move) else {
            ChessDebugLog.shared.record("MOVE REJECTED", "Move failed final legality check", details: "Move: \(move.uci)\nSide to move: \(game.sideToMove.name)\nPosition FEN: \(game.fen)\nLegal moves: \(game.legalMoves().map(\.uci).sorted().joined(separator: " "))")
            cancelOpponentMoveEntry("That opponent move was illegal. Start again.")
            return
        }

        ChessDebugLog.shared.record("MOVE ACCEPTED", "Opponent move committed", details: "Move: \(move.uci)\nResulting FEN: \(game.fen)")

        lastMove = move
        pendingOwnMoveFromPosition = nil
        selectedSquare = nil
        legalTargets = []
        promotionCandidates = []
        trackingLost = false
        recommendedMoveText = ""
        suggestionEvaluationText = ""
        sessionEvent(.move, "Opponent played \(notation)", details: ["uci": move.uci])
        HapticEngine.shared.confirm()

        if let outcome = game.outcome {
            finishGame(outcome)
        } else {
            autosave()
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
        HapticEngine.shared.error(message)
    }

    private func finishGame(_ outcome: GameOutcome) {
        autosave()
        phase = .gameOver
        selectedSquare = nil
        legalTargets = []
        status = outcome.summary
        sessionEvent(.gameOver, outcome.summary)
        let speech = SpeechEngine.shared
        if speech.enabled && speech.timing == .audioOnly {
            HapticEngine.shared.cancel()
        } else {
            HapticEngine.shared.playGameOver()
        }
        if speech.enabled { speech.speak(outcome.summary) }
    }

    // MARK: - Black view (numbering from your own seat)

    /// Rotates a square 180 degrees (a1 <-> h8).
    private func seatSquare(_ square: Int) -> Int { seatFlipped ? 63 - square : square }

    /// The move as the player sees it. Labels, vibration and speech all use this,
    /// so what you see, feel and hear always agree.
    private func seatMove(_ move: Move) -> Move {
        seatFlipped ? Move(from: 63 - move.from, to: 63 - move.to, promotion: move.promotion) : move
    }

    private func seatName(_ square: Int) -> String { Square.name(seatSquare(square)) }

    private func seatText(_ uci: String) -> String {
        guard let move = Move(uci: uci) else { return uci }
        return seatMove(move).uci
    }

    // MARK: - Haptic + audio output

    /// The piece that gets captured by `move` (including en passant). Call BEFORE playing the move.
    private func capturedPiece(for move: Move) -> PieceType? {
        if let target = game.board[move.to] { return target.type }
        if game.board[move.from]?.type == .pawn, Square.file(move.from) != Square.file(move.to) {
            return .pawn   // en passant
        }
        return nil
    }

    /// Builds the spoken text for a freshly played engine move, remembers it (for shake-to-repeat),
    /// and delivers it as vibration and/or speech according to the audio settings.
    private func announce(_ move: Move, suffix: HapticEngine.Suffix, piece: PieceType?, captured: PieceType?) {
        let text = SpeechEngine.shared.phrase(for: seatMove(move), piece: piece, captured: captured,
                                              suffix: suffix, outcome: game.outcome,
                                              mirrored: seatFlipped)
        lastSpokenText = text
        deliver(move: move, suffix: suffix, spoken: text)
    }

    private func deliver(move: Move, suffix: HapticEngine.Suffix, spoken: String) {
        let speech = SpeechEngine.shared
        speech.stop()

        guard speech.enabled else {
            playHaptics(for: move, suffix: suffix)
            return
        }

        switch speech.timing {
        case .together:
            playHaptics(for: move, suffix: suffix)
            speech.speak(spoken)
        case .afterVibration:
            playHaptics(for: move, suffix: suffix) {
                SpeechEngine.shared.speak(spoken)
            }
        case .audioOnly:
            HapticEngine.shared.cancel()
            speech.speak(spoken)
        }
    }

    private func playHaptics(for move: Move, suffix: HapticEngine.Suffix,
                             onFinished: (@MainActor () -> Void)? = nil) {
        let seen = seatMove(move)
        HapticEngine.shared.playMove(
            fromFile: Square.file(seen.from) + 1,
            fromRank: Square.rank(seen.from) + 1,
            toFile: Square.file(seen.to) + 1,
            toRank: Square.rank(seen.to) + 1,
            promotion: seen.promotion?.promotionCode ?? 0,
            suffix: suffix,
            onFinished: onFinished
        )
    }
}

// MARK: - Native command center and session controls

extension ChessPhoneViewModel {
    var physicalPosition: Position { pendingOwnMoveFromPosition ?? game.position }
    var suggestionMove: Move? {
        guard pendingOwnMoveFromPosition != nil, let last = game.moveHistory.last,
              game.sideToMove != playerColor else { return nil }
        return last
    }
    private var confirmedGame: ChessGame {
        let moves = suggestionMove == nil ? game.moveHistory : Array(game.moveHistory.dropLast())
        return ChessGame(startingPosition: game.startingPosition, moves: moves)
    }
    var moveListText: [String] { confirmedGame.numberedMoves }
    var sessionStatus: String {
        if sessionPaused || VisionCoordinator.shared.isBudgetPaused { return "Paused" }
        if phase == .selectSide { return "Choose your side" }
        if trackingLost { return "Lost track" }
        if phase == .gameOver { return "Game over" }
        if phase == .engineFailed { return "Engine problem" }
        if phase == .engineCalculating { return "Thinking" }
        if case .failed(_) = VisionCoordinator.shared.stage, VisionCoordinator.shared.enabled { return "Can't see the board" }
        if suggestionMove != nil || game.sideToMove == playerColor { return "Your move" }
        return "Waiting for opponent"
    }

    func pauseSession() {
        guard !sessionPaused, phase != .selectSide else { return }
        sessionPaused = true
        gameGeneration += 1
        engineTask?.cancel(); engineTask = nil
        scanTask?.cancel(); scanTask = nil
        watchRevision += 1
        watchTask?.cancel(); watchTask = nil
        EngineManager.shared.cancelSearch()
        HapticEngine.shared.cancel()
        SpeechEngine.shared.stop()
        status = "Session paused."
        sessionEvent(.paused, "Session paused")
    }

    func resumeSession() {
        if VisionCoordinator.shared.isBudgetPaused { VisionCoordinator.shared.resumeBudget() }
        sessionPaused = false
        status = "Session resumed."
        sessionEvent(.resumed, "Session resumed")
        if phase != .selectSide && phase != .gameOver && game.sideToMove == playerColor {
            startRecommendation()
        }
        syncContinuousWatch()
    }

    /// Explicit confirmation is also available without a camera, including a mating move.
    func confirmSuggestedMove() {
        guard suggestionMove != nil else { return }
        gameGeneration += 1
        scanTask?.cancel(); scanTask = nil
        confirmRecommendedMove()
        autosave()
        if phase != .gameOver { status = "Your move confirmed. Waiting for your opponent." }
    }

    private func confirmRecommendedMove() {
        guard let move = suggestionMove, let before = pendingOwnMoveFromPosition else { return }
        pendingOwnMoveFromPosition = nil
        recommendedMoveText = ""
        suggestionEvaluationText = ""
        lastEngineMove = ""
        lastSpokenText = ""
        sessionEvent(.move, "You played \(before.san(for: move))", details: ["uci": move.uci, "suggested": "true"])
        if let outcome = game.outcome {
            phase = .gameOver
            status = outcome.summary
            sessionEvent(.gameOver, outcome.summary)
            if SpeechEngine.shared.enabled { SpeechEngine.shared.speak(outcome.summary) }
        }
    }

    /// SAN (Nf3, O-O) and UCI (g1f3, e7e8q), always in real board coordinates.
    @discardableResult
    func submitManualMove(_ notation: String) -> Bool {
        guard phase != .selectSide, phase != .engineCalculating, phase != .engineFailed else {
            status = "Start a game and wait for the engine before entering a move."
            return false
        }
        if let before = pendingOwnMoveFromPosition, let actual = before.legalMove(notation: notation) {
            if actual == suggestionMove {
                confirmSuggestedMove()
                return true
            }
            var rebuilt = ChessGame(startingPosition: game.startingPosition, moves: Array(game.moveHistory.dropLast()))
            guard rebuilt.play(actual) else { return false }
            gameGeneration += 1
            scanTask?.cancel(); scanTask = nil
            game = rebuilt
            pendingOwnMoveFromPosition = nil
            lastMove = actual
            lastEngineMove = ""; lastSpokenText = ""; recommendedMoveText = ""; suggestionEvaluationText = ""
            trackingLost = false
            sessionEvent(.move, "You played \(before.san(for: actual))", details: ["uci": actual.uci, "suggested": "false"])
            if let outcome = game.outcome { finishGame(outcome) }
            else { phase = .opponentSourceColumn; status = "Your move recorded. Waiting for your opponent."; autosave() }
            return true
        }
        guard let move = game.position.legalMove(notation: notation), game.outcome == nil else {
            status = "Illegal or ambiguous move. Use SAN (Nf3) or UCI (g1f3), in real board coordinates."
            sessionEvent(.problem, "Manual move rejected", details: ["input": String(notation.prefix(40))])
            return false
        }
        gameGeneration += 1
        scanTask?.cancel(); scanTask = nil
        commitOpponentMove(move)
        return true
    }

    @discardableResult
    func startNewGame(color: PieceColor, fen: String?) -> Bool {
        let position: Position
        do {
            let text = fen?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty { position = .start }
            else { position = try Position(fen: text) }
        } catch { status = error.localizedDescription; return false }
        newGame()
        playerColor = color
        game = ChessGame(startingPosition: position)
        VisionCoordinator.shared.resetSessionBudget()
        SessionJournal.shared.startSession(playerColor: color, initialFEN: position.fen)
        if let outcome = game.outcome {
            phase = .gameOver; status = outcome.summary
            sessionEvent(.gameOver, outcome.summary)
        } else if game.sideToMove == color { startRecommendation() }
        else { phase = .opponentSourceColumn; status = "Position loaded. Waiting for your opponent." }
        autosave()
        syncContinuousWatch()
        return true
    }

    private func publishSessionState() {
        let vision = VisionCoordinator.shared
        SessionJournal.shared.publish(SessionSnapshot(
            status: sessionStatus, paused: sessionPaused || vision.isBudgetPaused,
            playerColor: playerColor.name, sideToMove: physicalPosition.sideToMove.name,
            fen: physicalPosition.fen, moves: moveListText,
            suggestion: suggestionMove == nil ? nil : recommendedMoveText,
            evaluation: suggestionMove == nil ? nil : suggestionEvaluationText,
            confidence: suggestionMove == nil ? nil : suggestionConfidence,
            estimatedCostUSD: vision.estimatedCostUSD, spendingCapUSD: vision.maxCostUSD,
            visionModel: "Gemini", precheckEnabled: vision.localGateEnabled))
    }

    private func sessionEvent(_ kind: SessionEvent.Kind, _ message: String, details: [String: String] = [:]) {
        SessionJournal.shared.record(kind, message, details: details)
        if kind == .move || kind == .problem || kind == .recovery,
           let jpeg = VisionCoordinator.shared.latestAnalyzedFrame?.jpegData(compressionQuality: 0.75) {
            SessionJournal.shared.saveFrame(jpeg, label: kind.rawValue)
        }
        publishSessionState()
    }
}


// MARK: - Vision board scanning

extension ChessPhoneViewModel {
    /// Powering on continuous watch starts one long lived observer. The camera stream is
    /// sampled locally; Gemini is called only after the picture moves and settles.
    private func syncContinuousWatch() {
        let canWatch = inputsRunning
            && !sessionPaused
            && !VisionCoordinator.shared.isBudgetPaused
            && VisionCoordinator.shared.enabled
            && VisionCoordinator.shared.sourceKind == .glasses
            && phase != .selectSide
            && phase != .gameOver

        if canWatch {
            guard watchTask == nil else { return }
            watchRevision += 1
            let revision = watchRevision
            watchTask = Task { [weak self] in
                await self?.runContinuousWatch()
                if self?.watchRevision == revision { self?.watchTask = nil }
            }
        } else {
            watchRevision += 1
            watchTask?.cancel()
            watchTask = nil
        }
    }

    private func runContinuousWatch() async {
        var fingerprint: [UInt8]?
        var observedGeneration = gameGeneration
        var failures = 0
        scanStatus = "Connecting to glasses..."

        while !Task.isCancelled {
            guard VisionCoordinator.shared.enabled,
                  !sessionPaused, !VisionCoordinator.shared.isBudgetPaused,
                  VisionCoordinator.shared.sourceKind == .glasses,
                  phase != .selectSide,
                  phase != .gameOver else { return }

            if observedGeneration != gameGeneration {
                fingerprint = nil
                observedGeneration = gameGeneration
            }

            if phase == .engineFailed {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, !sessionPaused else { return }
                retryEngine()
                continue
            }

            guard phase == .opponentSourceColumn, tapCount == 0 else {
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }

            do {
                if fingerprint == nil {
                    let generation = gameGeneration
                    let (scan, initialFingerprint) = try await VisionCoordinator.shared
                        .captureWatchBaseline(playerColor: playerColor)
                    guard !Task.isCancelled, generation == gameGeneration, !sessionPaused,
                          phase == .opponentSourceColumn, tapCount == 0 else { continue }
                    fingerprint = initialFingerprint
                    failures = 0
                    processWatchedBoard(scan)
                    continue
                }

                let generation = gameGeneration
                let (image, nextFingerprint) = try await VisionCoordinator.shared
                    .waitForStableChangedFrame(since: fingerprint!)
                fingerprint = nextFingerprint
                guard !Task.isCancelled,
                      generation == gameGeneration, !sessionPaused,
                      phase == .opponentSourceColumn,
                      tapCount == 0 else { continue }

                let scan = try await VisionCoordinator.shared.readBoard(from: image, playerColor: playerColor)
                guard !Task.isCancelled, generation == gameGeneration, !sessionPaused,
                      phase == .opponentSourceColumn, tapCount == 0 else { continue }
                failures = 0
                processWatchedBoard(scan)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if VisionCoordinator.shared.isBudgetPaused { return }
                failures += 1
                scanStatus = "Watch paused: \(error.localizedDescription)"
                status = scanStatus
                if failures == 1 { sessionEvent(.problem, "Board watch failed", details: ["reason": error.localizedDescription]) }
                try? await Task.sleep(nanoseconds: UInt64(min(10.0, pow(2.0, Double(min(failures, 4))))) * 1_000_000_000)
                fingerprint = nil
            }
        }
    }

    /// Reconciles a visual board with both the recommended move and the game history.
    /// This is what lets the watcher wait for the user to physically play the advice.
    private func processWatchedBoard(_ scan: ScannedBoard) {
        guard !sessionPaused else { return }
        ChessDebugLog.shared.record("SCAN", "Comparing scanned board with tracked game", details: "Confidence: \(scan.confidence)\nNotes: \(scan.notes ?? "<none>")\nPlayer side: \(playerColor.name)\nTracked FEN: \(game.fen)\nTracked board:\n\(ChessDebugFormat.board(game.position.board))\nScanned board:\n\(ChessDebugFormat.board(scan.squares))\nChanged squares: \(ChessDebugFormat.differences(from: game.position.board, to: scan.squares))\nPending recommended move: \(pendingOwnMoveFromPosition == nil ? "none" : recommendedMoveText)")
        scanStatus = "Watching board (\(scan.confidence) confidence)."

        if let beforeRecommendation = pendingOwnMoveFromPosition {
            if scan.squares == beforeRecommendation.board {
                trackingLost = false
                ChessDebugLog.shared.record("SCAN MATCH", "Board still matches before recommendation", details: "Expected the recommended move to be played: \(recommendedMoveText)")
                status = "Move ready. Play \(recommendedMoveText) on the board; watching for it."
                return
            }

            if scan.squares == game.position.board {
                ChessDebugLog.shared.record("SCAN MATCH", "Recommended move is visible on the board", details: "Tracked position: \(game.fen)")
                confirmRecommendedMove()
                trackingLost = false
                autosave()
                if phase == .gameOver { return }
                status = "Your move is on the board. Watching for your opponent."
                return
            }

            let playedInstead = beforeRecommendation.legalMoves().filter {
                beforeRecommendation.applying($0).board == scan.squares
            }
            if let actualMove = playedInstead.first {
                ChessDebugLog.shared.record("SCAN MATCH", "Detected user's alternate legal move", details: "Move: \(actualMove.uci)\nLegal alternatives from previous position: \(playedInstead.map(\.uci).joined(separator: " "))")
                // The player chose a different legal move. Replace the engine's speculative
                // move in the saved line with the move that the camera actually saw.
                let priorMoves = Array(game.moveHistory.dropLast())
                var rebuilt = ChessGame(startingPosition: game.startingPosition, moves: priorMoves)
                guard rebuilt.play(actualMove) else {
                    ChessDebugLog.shared.record("ERROR", "Could not rebuild game with detected move", details: "Move: \(actualMove.uci)\nPrior moves: \(priorMoves.map(\.uci).joined(separator: " "))")
                    status = "Board changed, but the move could not be matched. Check the board."
                    return
                }
                game = rebuilt
                lastMove = actualMove
                pendingOwnMoveFromPosition = nil
                recommendedMoveText = ""
                suggestionEvaluationText = ""
                trackingLost = false
                lastEngineMove = ""
                lastSpokenText = ""
                phase = .opponentSourceColumn
                sessionEvent(.move, "You played \(beforeRecommendation.san(for: actualMove))", details: ["uci": actualMove.uci, "suggested": "false"])
                if let outcome = game.outcome { finishGame(outcome); return }
                autosave()
                status = "Detected your move \(seatText(actualMove.uci)). Watching for your opponent."
                return
            }
        }

        switch ScanMatcher.match(scan, against: game.position) {
        case .move(let move):
            ChessDebugLog.shared.record("SCAN MATCH", "Scanned board matches one legal move", details: "Matched UCI: \(move.uci)\nSide to move: \(game.sideToMove.name)")
            status = "Opponent move detected: \(seatText(move.uci))."
            commitOpponentMove(move)
        case .correctedMove(let move, let differingSquares):
            ChessDebugLog.shared.record("SCAN AUTO-CORRECT", "Matched the nearest unique legal move", details: "Move: \(move.uci)\nScanned board differs from the legal result on \(differingSquares) squares; likely a one-square piece-reading error.\nFEN before move: \(game.fen)")
            status = "Opponent move detected: \(seatText(move.uci)) (board read corrected)."
            commitOpponentMove(move)
        case .unchanged:
            trackingLost = false
            if pendingOwnMoveFromPosition == nil {
                status = "Board confirmed. Watching for a move."
            }
        case .nearUnchanged(let differingSquares):
            ChessDebugLog.shared.record("SCAN AUTO-CORRECT", "Board is a near match for the tracked position", details: "Scanned board differs from tracked position on \(differingSquares) squares; treating it as unchanged.")
            status = "Board nearly matches. Waiting for a clearer frame before confirming."
        case .noMatch:
            ChessDebugLog.shared.record("SCAN NO MATCH", "Scanned board does not match one legal move", details: "Legal moves from tracked position: \(game.legalMoves().map(\.uci).sorted().joined(separator: " "))\nChanged squares relative to tracked position: \(ChessDebugFormat.differences(from: game.position.board, to: scan.squares))")
            status = "Board changed, but it does not match one legal move. Hold the glasses steady or check the position."
            markTrackingLost()
        }
    }

    /// Volume Up in vision mode. Additional presses are ignored while a scan is running.
    func requestBoardScan() {
        guard !sessionPaused, !VisionCoordinator.shared.isBudgetPaused else { return }
        guard scanTask == nil else { return }
        guard phase == .opponentSourceColumn, tapCount == 0 else { return }

        HapticEngine.shared.tick()
        scanStatus = "Capturing board..."
        status = "Scanning the board..."
        let generation = gameGeneration

        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runBoardScan(generation: generation)
            if generation == self.gameGeneration { self.scanTask = nil }
        }
    }

    private func runBoardScan(generation: Int) async {
        do {
            let scan = try await VisionCoordinator.shared.captureAndRead(playerColor: playerColor)
            guard !Task.isCancelled, generation == gameGeneration, !sessionPaused,
                  !VisionCoordinator.shared.isBudgetPaused,
                  phase == .opponentSourceColumn, tapCount == 0 else { return }
            scanStatus = "Board read (\(scan.confidence) confidence)."
            // A manual iPhone/glasses scan must reconcile the physical position
            // exactly as continuous watch does, including unplayed suggestions.
            processWatchedBoard(scan)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == gameGeneration, !sessionPaused else { return }
            scanFailed(error)
        }
    }
    private func scanFailed(_ error: Error) {
        guard !Task.isCancelled, !sessionPaused else { return }
        if VisionCoordinator.shared.isBudgetPaused { return }
        ChessDebugLog.shared.record("ERROR", "Scan handling failed", details: "\(error.localizedDescription)\nTracked FEN: \(game.fen)")
        scanStatus = "Scan failed: \(error.localizedDescription)"
        status = scanStatus
        HapticEngine.shared.error()
        if SpeechEngine.shared.enabled {
            SpeechEngine.shared.speak((error as? VisionError)?.spoken ?? "Scan failed.")
        }
    }

    private func markTrackingLost() {
        status = "Lost track of the board. Scan again, enter the missed move, undo, or load the correct FEN in Command Center."
        guard !trackingLost else { return }
        trackingLost = true
        sessionEvent(.problem, "Lost track of the board")
        HapticEngine.shared.error("Lost track of the board.")
        if SpeechEngine.shared.enabled { SpeechEngine.shared.speak("Lost track of the board.") }
    }
}
