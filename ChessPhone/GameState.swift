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
}

private enum GameSaveStore {
    static let key = "ChessPhone.savedGame"

    static func save(game: ChessGame, playerColor: PieceColor, skillLevel: Int, searchDepth: Int) {
        let payload = SavedGame(
            moves: game.moveHistory.map(\.uci),
            playerColor: playerColor.rawValue,
            skillLevel: skillLevel,
            searchDepth: searchDepth
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
    @Published private(set) var scanStatus: String = ""
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
    }

    func stopInputs() {
        inputsRunning = false
        scanTask?.cancel()
        scanTask = nil
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
        // In vision mode, the first Volume Up press while waiting for the opponent
        // is the shutter. Manual tap-entry remains available when vision mode is off.
        if VisionCoordinator.shared.enabled, phase == .opponentSourceColumn, tapCount == 0 {
            requestBoardScan()
            return
        }

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
        deliver(move: move, suffix: .none, spoken: lastSpokenText)
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
        scanTask?.cancel()
        scanTask = nil
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
                           skillLevel: skillLevel, searchDepth: searchDepth)
        hasSavedGame = true
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
        let rebuilt = ChessGame(moves: moves)

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
        lastMove = game.moveHistory.last
        selectedSquare = nil
        legalTargets = []
        promotionCandidates = []
        tapCount = 0
        recommendedMoveText = lastMove.map { seatText($0.uci).uppercased() } ?? ""
        hasSavedGame = true
        syncEngineMemory()

        if game.outcome != nil {
            phase = .gameOver
            status = game.outcome?.summary ?? "Game over."
        } else if game.sideToMove == playerColor {
            startRecommendation()
        } else {
            phase = .opponentSourceColumn
            status = "Saved game restored. Enter your opponent's FROM column."
        }
    }

    /// Takeback.
    ///  - Half-entered opponent move: just cancels the entry.
    ///  - Engine thinking / engine failed: removes the opponent move you just entered.
    ///  - Waiting for the opponent's move: removes the engine's recommendation AND the
    ///    opponent move before it, so you can enter that opponent move again.
    ///  - Game over: removes the move that ended the game.
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

        gameGeneration += 1
        engineTask?.cancel()
        engineTask = nil
        scanTask?.cancel()
        scanTask = nil
        EngineManager.shared.cancelSearch()
        HapticEngine.shared.cancel()
        SpeechEngine.shared.stop()

        var moves = game.moveHistory
        let pliesToRemove: Int

        switch phase {
        case .engineCalculating, .engineFailed:
            // The last move on the board is the opponent move just entered.
            pliesToRemove = 1
        case .gameOver:
            // If the engine's recommendation ended the game, remove it and the
            // opponent move before it; if the opponent's move ended it, remove just that.
            pliesToRemove = game.sideToMove.opposite == playerColor ? 2 : 1
        default:
            // Waiting for the opponent: remove the engine move and the opponent move before it.
            pliesToRemove = 2
        }

        moves.removeLast(min(pliesToRemove, moves.count))

        game = ChessGame(moves: moves)
        lastMove = game.moveHistory.last
        selectedSquare = nil
        legalTargets = []
        promotionCandidates = []
        tapCount = 0
        recommendedMoveText = lastMove.map { seatText($0.uci).uppercased() } ?? ""
        syncEngineMemory()

        if game.moveHistory.isEmpty {
            recommendedMoveText = ""
            GameSaveStore.clear()
            hasSavedGame = false
            phase = .selectSide
            status = "Choose your side."
            return
        }

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
            let reply = await EngineManager.shared.bestMove(
                fen: fen,
                depth: searchDepth,
                skillLevel: skillLevel
            )
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

        // Remember what is moving / being captured BEFORE the move changes the board
        // (used for the spoken version of the move).
        let mover = chosen.flatMap { game.board[$0.from]?.type }
        let captured = chosen.flatMap { capturedPiece(for: $0) }

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
        recommendedMoveText = seatText(move.uci).uppercased()

        if let outcome = game.outcome {
            status = "Your recommended move ends the game. \(outcome.summary)"
            phase = .gameOver
            announce(move, suffix: .gameOver, piece: mover, captured: captured)
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
        HapticEngine.shared.error()
    }

    private func finishGame(_ outcome: GameOutcome) {
        autosave()
        phase = .gameOver
        selectedSquare = nil
        legalTargets = []
        status = "Opponent played \(lastMove.map { seatText($0.uci) } ?? ""). \(outcome.summary)"
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


// MARK: - Vision board scanning

extension ChessPhoneViewModel {
    /// Volume Up in vision mode. Additional presses are ignored while a scan is running.
    func requestBoardScan() {
        guard scanTask == nil else { return }
        guard phase == .opponentSourceColumn, tapCount == 0 else { return }

        HapticEngine.shared.tick()
        scanStatus = "Capturing board..."
        status = "Scanning the board..."
        let generation = gameGeneration

        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runBoardScan(generation: generation)
            self.scanTask = nil
        }
    }

    private func runBoardScan(generation: Int) async {
        do {
            let scan = try await VisionCoordinator.shared.captureAndRead(playerColor: playerColor)
            guard !Task.isCancelled, generation == gameGeneration else { return }
            scanStatus = "Board read (\(scan.confidence) confidence)."

            switch ScanMatcher.match(scan, against: game.position) {
            case .move(let move):
                status = "Opponent move detected: \(seatText(move.uci))."
                commitOpponentMove(move)

            case .unchanged:
                status = "The board has not changed yet. Play the recommended move, wait for the opponent, then scan again."
                handleShakeRepeat()

            case .noMatch:
                await recommendFromScan(scan, generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == gameGeneration else { return }
            scanFailed(error)
        }
    }

    /// If the photographed board no longer matches the tracked move history, use the
    /// photographed position for this recommendation without corrupting the saved game.
    private func recommendFromScan(_ scan: ScannedBoard, generation: Int) async {
        do {
            let position = try scan.makePosition(sideToMove: playerColor, rightsFrom: game.position)
            status = "Photo differs from the tracked game. Finding a move from the photo..."

            let reply = await EngineManager.shared.bestMove(
                fen: position.fen,
                depth: searchDepth,
                skillLevel: skillLevel
            )
            guard !Task.isCancelled, generation == gameGeneration else { return }
            guard let uci = reply, let move = Move(uci: uci), position.legalMoves().contains(move) else {
                let why = EngineManager.shared.lastError
                throw VisionError.invalidPosition(why.isEmpty ? "engine reply was not legal" : why)
            }

            let mover = position.board[move.from]?.type
            let captured = position.board[move.to]?.type
            let after = position.applying(move)
            let suffix: HapticEngine.Suffix = after.legalMoves().isEmpty
                ? .gameOver
                : (after.isInCheck(after.sideToMove) ? .check : .none)
            let text = SpeechEngine.shared.phrase(
                for: seatMove(move),
                piece: mover,
                captured: captured,
                suffix: suffix,
                outcome: nil,
                mirrored: seatFlipped
            )

            // Do not mutate the tracked ChessGame here. This is a recovery path for
            // a board that no longer matches its move history, so only announce the move.
            lastEngineMove = move.uci
            lastSpokenText = text
            recommendedMoveText = seatText(move.uci).uppercased()
            scanStatus = "Move found from photographed position."
            status = "Play \(seatText(move.uci)) as \(playerColor.name) (from the photographed board)."
            deliver(move: move, suffix: suffix, spoken: text)
        } catch {
            scanFailed(error)
        }
    }

    private func scanFailed(_ error: Error) {
        scanStatus = "Scan failed: \(error.localizedDescription)"
        status = scanStatus
        HapticEngine.shared.error()
        if SpeechEngine.shared.enabled {
            SpeechEngine.shared.speak((error as? VisionError)?.spoken ?? "Scan failed.")
        }
    }
}
